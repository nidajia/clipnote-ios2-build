import SwiftUI

/// 发现页：只看你关心的。
///
/// 为什么需要这一页：首页是「我存了什么」，是过去时；热榜是「外面在发生什么」，
/// 是现在时。两件事放在一起，谁都不好用——39 条存的里面掺 60 条热榜，
/// 用户既找不到自己存的，也看不清外面。
///
/// 内容分四块，优先级从上到下：
/// 1. **关注更新**：订阅的人发新东西了（最确定、最有价值）
/// 2. **你存过的话题**：热榜里命中你库关键词的（把「看过」和「正在发生」连起来）
/// 3. **前沿热榜**：B 站热榜 + 抖音热点，按兴趣权重排，娱乐类在服务端就滤掉了
/// 4. **屏蔽管理**：长按卡片标的「不感兴趣」都收在这里，可以撤销
struct DiscoverScreen: View {
    @EnvironmentObject private var library: LibraryStore

    @State private var feed: APIDiscoverFeed?
    @State private var subs: [APISubscription] = []
    @State private var loading = false
    @State private var errorText = ""
    @State private var category = "全部"
    @State private var blocking: APIDiscoverItem?
    @State private var showBlockSheet = false
    @State private var showBlockedList = false
    @State private var openedSub: APISubscription?
    /// 正在预览的那条（点卡片 = 应用内直接看，不跳浏览器）。
    @State private var playing: APIDiscoverItem?
    /// 下滑加载的追加内容（按分类翻页，B 站搜索）。
    @State private var extra: [APIDiscoverItem] = []
    @State private var morePage = 1
    @State private var loadingMore = false
    @State private var noMore = false

    private var hot: [APIDiscoverItem] {
        guard let feed else { return [] }
        if category == "合集" { return [] }
        guard category != "全部" else { return feed.hot }
        // 用服务端分好组的那一份。之前是从 hot 里 filter，而 hot 只有前 60 条，
        // 「商业」「学习」排在 60 名之外 → 切过去一片空白。
        var base: [APIDiscoverItem] = []
        if let sec = feed.sections.first(where: { $0.category == category }) {
            base = sec.items
        }
        // 追加下滑加载的部分，按 id 去重。
        let seen = Set(base.map(\.id))
        base.append(contentsOf: extra.filter { !seen.contains($0.id) })
        return base
    }

    private var collections: [APIDiscoverCollection] { feed?.collections ?? [] }

    private var mine: [APIDiscoverItem] {
        guard let feed else { return [] }
        guard category != "全部" else { return feed.mine }
        return feed.mine.filter { $0.category == category }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metric.space5) {
                if !errorText.isEmpty {
                    Text(errorText)
                        .font(.cnMeta)
                        .foregroundStyle(Color.cnRed)
                        .padding(.horizontal, Metric.pagePad)
                }

                if subs.isEmpty, hot.isEmpty, mine.isEmpty, loading {
                    skeleton
                } else {
                    subsSection
                    mineSection
                    // 分类栏放这里而不是塞进热榜区块：切到「合集」时热榜区块
                    // 整个不渲染，分类栏跟着消失，用户就再也切不回「全部 / 科技」——
                    // 表现就是「点了合集回不去」。分类栏必须始终可见。
                    filterBar
                    if category == "合集" {
                        collectionsSection
                    } else {
                        hotSection
                    }
                    blockedFooter
                }
            }
            .padding(.bottom, Metric.space6)
        }
        .background(Color.cnBg)
        .refreshable { await load(refresh: true) }
        .navigationTitle("发现")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await load(refresh: true) }
                } label: {
                    if loading {
                        RingSpinner(size: 15, color: .cnInk2)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.cnInk2)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("刷新热榜")
            }
        }
        .task {
            if feed == nil { await load(refresh: false) }
        }
        .onChange(of: category) { _ in
            extra = []
            morePage = 1
            noMore = false
        }
        .sheet(item: $blocking) { one in
            BlockSheet(item: one) { cat in
                Task { await block(one, category: cat) }
            }
        }
        .sheet(item: $playing) { one in
            DiscoverPlayerScreen(item: one)
                .environmentObject(library)
        }
        .sheet(item: $openedSub) { sub in
            SubSheet(sub: sub) {
                Task {
                    await library.removeSubscription(key: sub.key)
                    subs = await library.subscriptions()
                }
            }
        }
        .sheet(isPresented: $showBlockedList) {
            BlockedListSheet(cats: feed?.blockedCats ?? []) { cat in
                Task {
                    await library.unblockCategory(cat)
                    await load(refresh: true)
                }
            }
        }
    }

    // MARK: 订阅

    @ViewBuilder
    private var subsSection: some View {
        if !subs.isEmpty {
            VStack(alignment: .leading, spacing: Metric.space3) {
                sectionHeader("关注更新", detail: "\(subs.count) 个")

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Metric.space3) {
                        ForEach(subs) { sub in
                            Button {
                                openedSub = sub
                            } label: {
                                subCard(sub)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Metric.pagePad)
                }
            }
        }
    }

    private func subCard(_ sub: APISubscription) -> some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: URL(string: sub.avatar)) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        Circle()
                            .fill(Color.cnCard3)
                            .overlay(
                                Image(systemName: "person.fill")
                                    .font(.system(size: 18))
                                    .foregroundStyle(Color.cnInk3)
                            )
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(Circle())

                // 有新内容才点亮小红点。「有没有更新」是这一块最关键的信息，
                // 藏在详情里就等于没有。
                if hasNew(sub) {
                    Circle()
                        .fill(Color.cnRed)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().strokeBorder(Color.cnBg, lineWidth: 2))
                }
            }

            Text(sub.name)
                .font(.cnCaption)
                .foregroundStyle(Color.cnInk2)
                .lineLimit(1)
                .frame(width: 68)

            Text(latestText(sub))
                .font(.system(size: 9))
                .foregroundStyle(Color.cnInk3)
                .lineLimit(1)
                .frame(width: 68)
        }
    }

    private func hasNew(_ sub: APISubscription) -> Bool {
        guard let first = sub.videos.first, first.created > 0 else { return false }
        // 72 小时内算新。再久的就不是「更新」而是「历史」了。
        return Date().timeIntervalSince1970 - Double(first.created) < 72 * 3600
    }

    private func latestText(_ sub: APISubscription) -> String {
        guard let first = sub.videos.first, first.created > 0 else {
            return sub.lastCheckedAt == 0 ? "待同步" : "无更新"
        }
        // 超过 30 天就别写「245 天前」了——那看起来像 Bug，其实是真的没发新东西。
        let age = Date().timeIntervalSince1970 - Double(first.created)
        if age > 86400 * 30 { return "长期未更新" }
        return Self.relative(first.created)
    }

    // MARK: 你存过的话题

    @ViewBuilder
    private var mineSection: some View {
        if !mine.isEmpty {
            VStack(alignment: .leading, spacing: Metric.space3) {
                sectionHeader("你存过的，今天又火了", detail: "\(mine.count) 条")

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Metric.space3) {
                        ForEach(mine) { one in
                            mineCard(one)
                        }
                    }
                    .padding(.horizontal, Metric.pagePad)
                }
            }
        }
    }

    private func mineCard(_ one: APIDiscoverItem) -> some View {
        cardLink(one) {
            VStack(alignment: .leading, spacing: 6) {
                cover(one, width: 200, height: 112)

                Text("「\(one.libraryKeyword)」")
                    .font(.cnCaption)
                    .foregroundStyle(Color.cnBrand)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.cnBrandSoft, in: Capsule())

                Text(one.title)
                    .font(.cnRowTitle)
                    .foregroundStyle(Color.cnInk)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(one.author)
                    .font(.cnCaption)
                    .foregroundStyle(Color.cnInk3)
                    .lineLimit(1)
            }
            .frame(width: 200, alignment: .leading)
            .padding(Metric.space2)
            .background(
                Color.cnCard,
                in: RoundedRectangle(cornerRadius: Metric.radiusCard, style: .continuous)
            )
        }
        .contextMenu {
            Button(role: .destructive) {
                blocking = one
            } label: {
                Label("不感兴趣", systemImage: "hand.thumbsdown")
            }
        }
    }

    // MARK: 热榜

    private var hotSection: some View {
        VStack(alignment: .leading, spacing: Metric.space3) {
            sectionHeader("前沿热榜", detail: feed.map { Self.agoText($0.fetchedAt) } ?? "")

            VStack(spacing: 0) {
                ForEach(Array(hot.enumerated()), id: \.element.id) { index, one in
                    if index > 0 {
                        Divider()
                            .overlay(Color.cnHairlineSoft)
                            .padding(.leading, Metric.pagePad + 104)
                    }
                    hotRow(one)
                        .onAppear {
                            if one.id == hot.last?.id {
                                Task { await loadMore() }
                            }
                        }
                }
            }
        }
    }

    /// 合集一栏：我存过的所有多集作品。
    ///
    /// 之前合集只藏在每条视频的详情页里，用户得先猜「这条是不是合集」。
    /// 全部摊在发现页，一眼看到自己在追哪几部。
    private var collectionsSection: some View {
        VStack(alignment: .leading, spacing: Metric.space3) {
            sectionHeader("我的合集", detail: "\(collections.count) 部")

            if collections.isEmpty {
                Text("还没有多集作品。你在 B 站收藏的合集会出现在这里。")
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk3)
                    .padding(.horizontal, Metric.pagePad)
            } else {
                VStack(spacing: 0) {
                    ForEach(collections) { one in
                        collectionRow(one)
                        if one.id != collections.last?.id {
                            Divider().overlay(Color.cnHairlineSoft)
                                .padding(.leading, Metric.pagePad + 104)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func collectionRow(_ one: APIDiscoverCollection) -> some View {
        let target = library.items.first(where: { $0.id == one.itemId })
        if let target {
            NavigationLink {
                DetailScreen(item: target)
            } label: {
                collectionLabel(one)
            }
            .buttonStyle(.plain)
        } else {
            collectionLabel(one)
        }
    }

    private func collectionLabel(_ one: APIDiscoverCollection) -> some View {
        HStack(alignment: .top, spacing: Metric.space3) {
            ZStack {
                RoundedRectangle(cornerRadius: Metric.radiusCover, style: .continuous)
                    .fill(Color.cnCard3)
                if !one.cover.isEmpty {
                    AsyncImage(url: URL(string: one.cover)) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            Color.clear
                        }
                    }
                }
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text("\(one.index)/\(one.total)")
                            .font(.cnDuration)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.black.opacity(0.6), in: Capsule())
                    }
                }
                .padding(3)
            }
            .frame(width: 92, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: Metric.radiusCover, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(one.title)
                    .font(.cnRowTitle)
                    .foregroundStyle(Color.cnInk)
                    .lineLimit(1)
                Text("共 \(one.total) 集 · 已存第 \(one.index) 集")
                    .font(.cnCaption)
                    .foregroundStyle(Color.cnBrand)
                Text(one.episodeTitle)
                    .font(.cnCaption)
                    .foregroundStyle(Color.cnInk3)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metric.pagePad)
        .padding(.vertical, Metric.space3)
        .contentShape(Rectangle())
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(feed?.categories ?? ["全部"], id: \.self) { name in
                    Button {
                        category = name
                    } label: {
                        Text(name)
                            .font(.cnChip)
                            .foregroundStyle(category == name ? Color.cnBg : Color.cnInk2)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(
                                category == name ? Color.cnInk : Color.cnCard,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Metric.pagePad)
        }
    }

    private func hotRow(_ one: APIDiscoverItem) -> some View {
        cardLink(one) {
            HStack(alignment: .top, spacing: Metric.space3) {
                cover(one, width: 92, height: 56)

                VStack(alignment: .leading, spacing: 4) {
                    Text(one.title)
                        .font(.cnRowTitle)
                        .foregroundStyle(Color.cnInk)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 6) {
                        if !one.category.isEmpty, one.category != "其他" {
                            Text(one.category)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.cnBrand)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.cnBrandSoft, in: Capsule())
                        }
                        Text(one.author)
                            .font(.cnCaption)
                            .foregroundStyle(Color.cnInk3)
                            .lineLimit(1)
                        if one.views > 0 {
                            Text(Self.compact(one.views))
                                .font(.cnCaption)
                                .foregroundStyle(Color.cnInk3)
                        }
                        Spacer(minLength: 0)
                        if one.inLibrary {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.cnGreen)
                        }
                    }
                }
            }
            .padding(.horizontal, Metric.pagePad)
            .padding(.vertical, Metric.space3)
            .contentShape(Rectangle())
        }
        .contextMenu {
            Button {
                // 收藏 = 真的入库：之后能离线、能写笔记、能进摘要和分段。
                Task { try? await library.quickImport(text: one.url) }
            } label: {
                Label("收藏到首页", systemImage: "plus.circle")
            }
            Button {
                playing = one
            } label: {
                Label("在应用内播放", systemImage: "play.circle")
            }
            Button(role: .destructive) {
                blocking = one
            } label: {
                Label("不感兴趣", systemImage: "hand.thumbsdown")
            }
            if let url = URL(string: one.url) {
                Link(destination: url) {
                    Label("在浏览器打开", systemImage: "safari")
                }
            }
        }
    }

    // MARK: 屏蔽管理

    private var blockedFooter: some View {
        VStack(alignment: .leading, spacing: Metric.space2) {
            Button {
                showBlockedList = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 12, weight: .semibold))
                    Text(blockedText)
                        .font(.cnCaption)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(Color.cnInk3)
                .padding(Metric.space3)
                .background(
                    Color.cnCard,
                    in: RoundedRectangle(cornerRadius: Metric.radiusCard, style: .continuous)
                )
            }
            .buttonStyle(.plain)

            Text("长按任意卡片可以标记「不感兴趣」，同类内容以后不再出现。")
                .font(.cnCaption)
                .foregroundStyle(Color.cnInk3)
        }
        .padding(.horizontal, Metric.pagePad)
    }

    private var blockedText: String {
        let cats = feed?.blockedCats ?? []
        if cats.isEmpty { return "还没有屏蔽任何分类" }
        return "已屏蔽 \(cats.count) 类：\(cats.joined(separator: "、"))"
    }

    // MARK: 组件

    private func sectionHeader(_ title: String, detail: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.cnTitle)
                .foregroundStyle(Color.cnInk)
            if !detail.isEmpty {
                Text(detail)
                    .font(.cnCaption)
                    .foregroundStyle(Color.cnInk3)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metric.pagePad)
    }

    /// 卡片统一入口：在库里就进详情，不在就开浏览器。
    ///
    /// 这两件事对用户是同一个动作（「我要看这条」），但结果不同——
    /// 库里能看摘要、分段、评论，库里没有就只能去原站。
    @ViewBuilder
    private func cardLink<C: View>(_ one: APIDiscoverItem,
                                   @ViewBuilder content: () -> C) -> some View {
        let vid = one.videoId ?? ""
        if !vid.isEmpty,
           let item = library.items.first(where: { $0.videoId == vid }) {
            NavigationLink {
                DetailScreen(item: item)
            } label: {
                content()
            }
            .buttonStyle(.plain)
        } else {
            Button {
                // 点开就在 App 里看（服务端预览解析，不入库）。
                // 之前是 UIApplication.open → 跳浏览器，用户明确说不要。
                playing = one
            } label: {
                content()
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func cover(_ one: APIDiscoverItem, width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: Metric.radiusCover, style: .continuous)
                .fill(Color.cnCard3)

            if one.cover.isEmpty {
                Text(one.platform == "douyin" ? "抖音" : "B站")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.cnInk3)
            } else {
                AsyncImage(url: URL(string: one.cover)) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        Color.clear
                    }
                }
            }

            // 平台角标：用户的原话是「抖音和 B 站热榜视频我分辨不出来」。
            // 两个平台的封面风格本来就接近，只能靠明确标识。
            VStack {
                HStack {
                    Text(one.platform == "douyin" ? "抖音" : "B站")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(one.platform == "douyin" ? Color.black.opacity(0.72)
                                                              : Color(red: 0.98, green: 0.45,
                                                                      blue: 0.60).opacity(0.92),
                                    in: Capsule())
                    Spacer()
                }
                Spacer()
                if one.duration > 0 {
                    HStack {
                        Spacer()
                        Text(Self.clock(one.duration))
                            .font(.cnDuration)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.black.opacity(0.55), in: Capsule())
                    }
                }
            }
            .padding(3)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: Metric.radiusCover, style: .continuous))
    }

    private var skeleton: some View {
        VStack(spacing: Metric.space3) {
            ForEach(0..<6, id: \.self) { _ in
                HStack(spacing: Metric.space3) {
                    RoundedRectangle(cornerRadius: Metric.radiusCover, style: .continuous)
                        .fill(Color.cnCard3)
                        .frame(width: 92, height: 56)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 4).fill(Color.cnCard3)
                            .frame(height: 12)
                        RoundedRectangle(cornerRadius: 4).fill(Color.cnCard3)
                            .frame(width: 120, height: 10)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Metric.pagePad)
            }
        }
        .padding(.top, Metric.space3)
    }

    // MARK: 动作

    private func load(refresh: Bool) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        errorText = ""
        do {
            feed = try await library.discoverFeed(refresh: refresh)
        } catch {
            errorText = "热榜拉不到，检查一下网络。已经存的内容不受影响。"
        }
        subs = await library.subscriptions()
    }

    /// 下滑到底部时继续取。只对具体分类有效——「全部」已经是混合流，
    /// 再按分类翻页会重复。
    private func loadMore() async {
        guard !loadingMore, !noMore else { return }
        guard category != "全部", category != "合集" else { return }
        loadingMore = true
        defer { loadingMore = false }
        let next = morePage + 1
        let rows = await library.discoverMore(category: category, page: next)
        if rows.isEmpty {
            noMore = true
        } else {
            extra.append(contentsOf: rows)
            morePage = next
        }
    }

    private func block(_ one: APIDiscoverItem, category: String) async {
        await library.blockDiscover(itemId: one.id, category: category)
        await load(refresh: true)
    }

    // MARK: 格式化

    static func compact(_ n: Int) -> String {
        if n >= 100_000_000 { return String(format: "%.1f亿", Double(n) / 100_000_000) }
        if n >= 10_000 { return String(format: "%.1f万", Double(n) / 10_000) }
        return "\(n)"
    }

    static func clock(_ seconds: Int) -> String {
        let m = seconds / 60, s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }

    static func relative(_ ts: Int) -> String {
        let diff = Date().timeIntervalSince1970 - Double(ts)
        if diff < 3600 { return "\(max(1, Int(diff / 60))) 分钟前" }
        if diff < 86400 { return "\(Int(diff / 3600)) 小时前" }
        return "\(Int(diff / 86400)) 天前"
    }

    static func agoText(_ ms: Int) -> String {
        guard ms > 0 else { return "" }
        return relative(ms / 1000) + "更新"
    }
}

// MARK: - 不感兴趣

/// 长按后的分类选择。
///
/// 为什么要选分类而不是「直接屏蔽这一条」：单条屏蔽只解决一次，
/// 分类屏蔽才解决一类。用户说的「下次再遇到同样的就不会弹了」指的是后者。
private struct BlockSheet: View {
    var item: APIDiscoverItem
    var onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    private let cats = ["军事", "明星", "吃瓜", "游戏", "体育", "搞笑",
                        "情感", "猎奇", "二次元", "AI作品", "生活", "其他"]

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Metric.space4) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                        .font(.cnRowTitle)
                        .foregroundStyle(Color.cnInk)
                        .lineLimit(2)
                    if !item.category.isEmpty {
                        Text("系统判定：\(item.category)")
                            .font(.cnCaption)
                            .foregroundStyle(Color.cnInk3)
                    }
                }
                .padding(.horizontal, Metric.pagePad)

                Text("这类内容以后不再出现。选一个最接近的：")
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk2)
                    .padding(.horizontal, Metric.pagePad)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)],
                          spacing: 8) {
                    ForEach(cats, id: \.self) { cat in
                        Button {
                            onPick(cat)
                            dismiss()
                        } label: {
                            Text(cat)
                                .font(.cnChip)
                                .foregroundStyle(Color.cnInk)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(
                                    Color.cnCard,
                                    in: RoundedRectangle(cornerRadius: 10,
                                                         style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Metric.pagePad)

                Spacer(minLength: 0)
            }
            .padding(.top, Metric.space4)
            .background(Color.cnBg)
            .navigationTitle("不感兴趣")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// 订阅详情：这个人的最新几条。
private struct SubSheet: View {
    var sub: APISubscription
    var onRemove: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Metric.space3) {
                    HStack(spacing: Metric.space3) {
                        AsyncImage(url: URL(string: sub.avatar)) { phase in
                            if case .success(let image) = phase {
                                image.resizable().scaledToFill()
                            } else {
                                Circle().fill(Color.cnCard3)
                            }
                        }
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            Text(sub.name)
                                .font(.cnTitle)
                                .foregroundStyle(Color.cnInk)
                            Text(sub.platform == "bilibili" ? "B 站" : "抖音")
                                .font(.cnCaption)
                                .foregroundStyle(Color.cnInk3)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Metric.pagePad)

                    ForEach(sub.videos, id: \.videoId) { video in
                        Button {
                            if let url = URL(string: video.url) {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            HStack(spacing: Metric.space3) {
                                AsyncImage(url: URL(string: video.cover)) { phase in
                                    if case .success(let image) = phase {
                                        image.resizable().scaledToFill()
                                    } else {
                                        Color.cnCard3
                                    }
                                }
                                .frame(width: 80, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 6,
                                                            style: .continuous))

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(video.title)
                                        .font(.cnMeta)
                                        .foregroundStyle(Color.cnInk)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    if video.created > 0 {
                                        Text(DiscoverScreen.relative(video.created))
                                            .font(.cnCaption)
                                            .foregroundStyle(Color.cnInk3)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, Metric.pagePad)
                        }
                        .buttonStyle(.plain)
                    }

                    if sub.videos.isEmpty {
                        Text("还没有拉到这个人的投稿，下拉刷新首页后再来。")
                            .font(.cnMeta)
                            .foregroundStyle(Color.cnInk3)
                            .padding(.horizontal, Metric.pagePad)
                    }

                    Button(role: .destructive) {
                        onRemove()
                        dismiss()
                    } label: {
                        Text("取消关注")
                            .font(.cnButton)
                            .foregroundStyle(Color.cnRed)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                Color.cnCard,
                                in: RoundedRectangle(cornerRadius: Metric.radiusButton,
                                                     style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, Metric.pagePad)
                    .padding(.top, Metric.space4)
                }
                .padding(.vertical, Metric.space4)
            }
            .background(Color.cnBg)
            .navigationTitle("关注")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

/// 已屏蔽分类的管理。
private struct BlockedListSheet: View {
    var cats: [String]
    var onUnblock: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if cats.isEmpty {
                    Text("还没有屏蔽任何分类")
                        .font(.cnMeta)
                        .foregroundStyle(Color.cnInk3)
                }
                ForEach(cats, id: \.self) { cat in
                    HStack {
                        Text(cat).font(.cnBody)
                        Spacer(minLength: 0)
                        Button("恢复") { onUnblock(cat) }
                            .font(.cnCaption)
                            .foregroundStyle(Color.cnBrand)
                            .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("已屏蔽")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
