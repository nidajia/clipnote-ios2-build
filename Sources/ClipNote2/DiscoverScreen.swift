import Combine
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
    @EnvironmentObject private var network: NetworkMonitor

    /// 截图用：预设初始分类。正常启动为 nil，落在「全部」。
    init(initialCategory: String? = nil) {
        _category = State(initialValue: initialCategory ?? "全部")
    }

    @State private var feed: APIDiscoverFeed?
    @State private var subs: [APISubscription] = []
    /// 正在同步关注列表（按钮转圈用）。
    @State private var checkingSubs = false
    @State private var loading = false
    @State private var errorText = ""
    @State private var category: String
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

    /// 标题关键词屏蔽：只存本机，命中就不显示。
    @AppStorage("cn.blockedKeywords") private var blockedKeywordsRaw = "[]"
    /// 刚屏蔽掉的那个词，留 5 秒让用户反悔。
    @State private var undoKeyword: String?
    @State private var undoTask: Task<Void, Never>?
    /// 正在选关键词的那条标题（nil 表示选择弹层没开）。
    @State private var keywordPrompt: KeywordPrompt?
    @State private var keywordDraft = ""

    private var blockedKeywords: [String] { KeywordBlock.decode(blockedKeywordsRaw) }

    /// 每条内容第一次出现在发现页的时间（秒）。
    ///
    /// 用来做「新的靠前、上次没看的依次往下」：服务端热榜顺序会整批洗牌，
    /// 用户重新打开时同一批内容换个位置，等于没变化。按首次出现时间排序后，
    /// 新抓到的自然排前面，旧的顺着往下排，不会消失。
    @AppStorage("cn.feedFirstSeen") private var firstSeenRaw = "{}"

    /// 作者条的自动轮播：4 秒走一格，用户拖动后暂停 8 秒。
    @State private var ticker = Timer.publish(every: 4, on: .main, in: .common).autoconnect()
    @State private var autoScrollIndex = 0
    @State private var lastUserScrollAt = Date.distantPast

    private var firstSeen: [String: Int] {
        guard let data = firstSeenRaw.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: Int].self, from: data) else { return [:] }
        return map
    }

    private func registerFirstSeen(_ items: [APIDiscoverItem]) {
        guard !items.isEmpty else { return }
        var map = firstSeen
        let now = Int(Date().timeIntervalSince1970)
        var changed = false
        for item in items where map[item.id] == nil {
            map[item.id] = now
            changed = true
        }
        guard changed else { return }
        if map.count > 800 {
            // 只留最近 800 条，避免这个键无限长大。
            let trimmed = map.sorted { $0.value > $1.value }.prefix(800)
            map = Dictionary(uniqueKeysWithValues: trimmed.map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(map), let text = String(data: data, encoding: .utf8) {
            firstSeenRaw = text
        }
    }

    /// 新的在前；同一批内保持服务端给的顺序（用原始下标做 tiebreaker）。
    private func orderedByFirstSeen(_ items: [APIDiscoverItem]) -> [APIDiscoverItem] {
        let stamps = firstSeen
        return items.enumerated()
            .sorted { lhs, rhs in
                let a = stamps[lhs.element.id] ?? 0
                let b = stamps[rhs.element.id] ?? 0
                if a != b { return a > b }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private var hot: [APIDiscoverItem] {
        guard let feed else { return [] }
        if category == "合集" { return [] }
        let raw: [APIDiscoverItem]
        if category == "全部" {
            raw = feed.hot
        } else {
            // 用服务端分好组的那一份。之前是从 hot 里 filter，而 hot 只有前 60 条，
            // 「商业」「学习」排在 60 名之外 → 切过去一片空白。
            var base: [APIDiscoverItem] = []
            if let sec = feed.sections.first(where: { $0.category == category }) {
                base = sec.items
            }
            // 追加下滑加载的部分，按 id 去重。
            let seen = Set(base.map(\.id))
            base.append(contentsOf: extra.filter { !seen.contains($0.id) })
            raw = base
        }
        let filtered = KeywordBlock.filter(raw, keywords: blockedKeywords, title: { $0.title })
        return orderedByFirstSeen(filtered)
    }

    private var collections: [APIDiscoverCollection] { feed?.collections ?? [] }

    private var mine: [APIDiscoverItem] {
        guard let feed else { return [] }
        let raw = category == "全部" ? feed.mine : feed.mine.filter { $0.category == category }
        return KeywordBlock.filter(raw, keywords: blockedKeywords, title: { $0.title })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metric.space5) {
                if !errorText.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Text(errorText)
                            .font(.cnMeta)
                            .foregroundStyle(Color.cnRed)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("重试") {
                            Task { await load(refresh: true) }
                        }
                        .font(.cnMeta)
                        .foregroundStyle(Color.cnBrand)
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, Metric.pagePad)
                }

                if subs.isEmpty, hot.isEmpty, mine.isEmpty, loading {
                    skeleton
                } else {
                    subsSection
                    // 合集与订阅新片并排；切到具体分类时收起，避免和下面的分类列表重复。
                    if category == "全部" { duoSection }
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
            await refreshIfStale()
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
            AuthorSheet(sub: sub) {
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
        .sheet(item: $keywordPrompt) { prompt in
            KeywordBlockSheet(
                title: prompt.title,
                suggestions: KeywordBlock.suggestions(from: prompt.title),
                draft: $keywordDraft,
                blocked: blockedKeywords,
                onBlock: { keyword in
                    blockKeyword(keyword)
                    keywordPrompt = nil
                },
                onUnblock: { keyword in
                    blockedKeywordsRaw = KeywordBlock.encode(
                        KeywordBlock.removing(keyword, from: blockedKeywords))
                }
            )
        }
        .overlay(alignment: .bottom) {
            if let keyword = undoKeyword {
                HStack(spacing: 10) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.cnInk2)
                    Text("已屏蔽「\(keyword)」")
                        .font(.cnMeta)
                        .foregroundStyle(Color.cnInk)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button("撤销") { undoBlockedKeyword() }
                        .font(.cnChip)
                        .foregroundStyle(Color.cnBrand)
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.cnCard, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.cnHairline, lineWidth: 1))
                .shadow(color: Color.black.opacity(0.12), radius: 12, y: 4)
                .padding(.horizontal, Metric.pagePad)
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: 订阅

    @ViewBuilder
    private var subsSection: some View {
        if !subs.isEmpty {
            VStack(alignment: .leading, spacing: Metric.space3) {
                HStack(spacing: 6) {
                    Text("关注更新")
                        .font(.cnTitle)
                        .foregroundStyle(Color.cnInk)
                    Text("\(subs.count) 个")
                        .font(.cnCaption)
                        .foregroundStyle(Color.cnInk3)
                    Spacer(minLength: 0)
                    if checkingSubs {
                        RingSpinner(size: 11, color: .cnBrand)
                    } else {
                        // 自动同步之外再给一个明确的入口：
                        // 「明明更了却没显示」时，用户第一反应是找一个刷新键。
                        Button {
                            Task { await forceCheckSubs() }
                        } label: {
                            Text("检查更新")
                                .font(.cnCaption)
                                .foregroundStyle(Color.cnBrand)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Metric.pagePad)

                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Metric.space3) {
                            ForEach(subs) { sub in
                                subCard(sub)
                                    .id(sub.key)
                            }
                        }
                        .padding(.horizontal, Metric.pagePad)
                    }
                    // 自动轮播：横条不滚就一直停在第一个作者，后面的等于没有。
                    // 用户自己拖动后停 8 秒再继续，避免「手还没松开就被抢走」。
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 8).onChanged { _ in
                            lastUserScrollAt = Date()
                        }
                    )
                    .onReceive(ticker) { _ in
                        guard subs.count > 1 else { return }
                        guard Date().timeIntervalSince(lastUserScrollAt) > 8 else { return }
                        // 关注列表可能刚被同步刷新过（变短），下标要先夹住。
                        guard autoScrollIndex < subs.count else {
                            autoScrollIndex = 0
                            return
                        }
                        autoScrollIndex = autoScrollIndex >= subs.count - 1 ? 0 : autoScrollIndex + 1
                        withAnimation(.easeInOut(duration: 0.45)) {
                            proxy.scrollTo(subs[autoScrollIndex].key, anchor: .leading)
                        }
                    }
                }
            }
        }
    }

    /// 关注卡片：**头像点开作者主页，其余部分进入这个人的更新列表**。
    ///
    /// 用户原话「关注的人点击头像应该也可以跳转对应作者主页」——
    /// 头像本来就是「这个人」的符号，点它去主页比再点开一层列表更直觉。
    private func subCard(_ sub: APISubscription) -> some View {
        // 整张卡都进**应用内作者页**，不再跳外部：
        // 用户原话「我不一定非要跳到他们那看，我还可以在软件里看才对呀」。
        // 去原站的入口只保留在作者页的上方（地址栏那颗）。
        Button {
            openedSub = sub
        } label: {
            VStack(spacing: 6) {
                avatarBubble(sub)
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
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func avatarBubble(_ sub: APISubscription) -> some View {
        ZStack(alignment: .bottomTrailing) {
                RemoteImage(url: URL(string: sub.avatar))
                    .background(
                        Circle()
                            .fill(Color.cnCard3)
                            .overlay(
                                Image(systemName: "person.fill")
                                    .font(.system(size: 18))
                                    .foregroundStyle(Color.cnInk3)
                            )
                    )
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
    }

    // MARK: - 关键词屏蔽

    /// 屏蔽一个词：列表立刻少一截，底部留 5 秒撤销。
    ///
    /// 不做二次确认——用户要的就是「按一下就没」，多一步确认等于多一次打断；
    /// 真正的安全网是那 5 秒。
    private func blockKeyword(_ keyword: String) {
        let before = blockedKeywords
        let after = KeywordBlock.adding(keyword, to: before)
        guard after != before else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            blockedKeywordsRaw = KeywordBlock.encode(after)
            undoKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        undoTask?.cancel()
        undoTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) { undoKeyword = nil }
        }
    }

    private func undoBlockedKeyword() {
        guard let keyword = undoKeyword else { return }
        undoTask?.cancel()
        blockedKeywordsRaw = KeywordBlock.encode(KeywordBlock.removing(keyword, from: blockedKeywords))
        withAnimation(.easeInOut(duration: 0.18)) { undoKeyword = nil }
    }

    /// 长按菜单：先给一个「直接屏蔽建议词」，再给一个「自己选词」。
    @ViewBuilder
    private func keywordMenu(for title: String) -> some View {
        let suggestions = KeywordBlock.suggestions(from: title)
        if let first = suggestions.first {
            Button {
                blockKeyword(first)
            } label: {
                Label("屏蔽「\(first)」", systemImage: "eye.slash")
            }
        }
        Button {
            keywordDraft = suggestions.first ?? ""
            keywordPrompt = KeywordPrompt(title: title)
        } label: {
            Label("选择关键词屏蔽…", systemImage: "character.cursor.ibeam")
        }
    }

    /// 这个作者最新一条的发布时间。
    /// 不能取 `videos.first`：接口回来的顺序并不保证最新在前，
    /// 一旦是正序，`first` 就成了几年前那条，界面会写「长期未更新」——
    /// 用户看到的却是他前两天刚发的视频。服务端已经算过 `latestAt`，
    /// 这里再兜一层 `max`，两个来源哪个更新用哪个。
    private func newestCreated(_ sub: APISubscription) -> Int {
        max(sub.latestAt, sub.videos.map(\.created).max() ?? 0)
    }

    private func hasNew(_ sub: APISubscription) -> Bool {
        let created = newestCreated(sub)
        guard created > 0 else { return false }
        // 72 小时内算新。再久的就不是「更新」而是「历史」了。
        return Date().timeIntervalSince1970 - Double(created) < 72 * 3600
    }

    private func latestText(_ sub: APISubscription) -> String {
        let created = newestCreated(sub)
        guard created > 0 else {
            return sub.lastCheckedAt == 0 ? "待同步" : "无更新"
        }
        // 超过 30 天就别写「245 天前」了——那看起来像 Bug，其实是真的没发新东西。
        let age = Date().timeIntervalSince1970 - Double(created)
        if age > 86400 * 30 { return "长期未更新" }
        return Self.relative(created)
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
                        .contextMenu { keywordMenu(for: one.title) }
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
                            .contextMenu { keywordMenu(for: one.title) }
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
        // 点合集先进**目录**，不再直接落到某一集的详情页：
        // 合集是「一部作品」，详情页是「一集」，把作品当一集打开，
        // 用户根本不知道还有别的集（原话：不应该先出来视频目录吗）。
        if one.itemId.isEmpty {
            collectionLabel(one)
        } else {
            NavigationLink {
                CollectionScreen(itemId: one.itemId,
                                 seasonId: one.seasonId,
                                 title: one.title,
                                 cover: one.cover,
                                 total: one.total)
            } label: {
                collectionLabel(one)
            }
            .buttonStyle(.plain)
        }
    }

    private func collectionLabel(_ one: APIDiscoverCollection) -> some View {
        HStack(alignment: .top, spacing: Metric.space3) {
            ZStack {
                RoundedRectangle(cornerRadius: Metric.radiusCover, style: .continuous)
                    .fill(Color.cnCard3)
                if !collectionCover(one).isEmpty {
                    RemoteImage(url: URL(string: collectionCover(one)))
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

    // MARK: - 合集 / 订阅新片（并排）

    /// 左边「我的合集」，右边「订阅新片」。
    ///
    /// 用户原话：「发现页应该右边弄个我订阅的作者的新发视频列表，放合集右边」，
    /// 且两种都要「像发现页那种搞个封面和标题」。所以这里统一成竖版卡片：
    /// 封面 + 两行标题 + 一行元信息，取代只有文字的列表行。
    @ViewBuilder
    private var duoSection: some View {
        let cols = Array(collections.prefix(6))
        let fresh = Array(freshFromSubs.prefix(6))
        if !cols.isEmpty || !fresh.isEmpty {
            HStack(alignment: .top, spacing: Metric.space3) {
                VStack(alignment: .leading, spacing: Metric.space2) {
                    duoHeader("我的合集", count: collections.count)
                    ForEach(cols) { one in
                        collectionDuoCard(one)
                    }
                    if cols.isEmpty { duoHint("还没有多集作品") }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: Metric.space2) {
                    duoHeader("订阅新片", count: freshFromSubs.count)
                    ForEach(fresh) { one in
                        freshDuoCard(one)
                    }
                    if fresh.isEmpty { duoHint("关注的人还没更新") }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, Metric.pagePad)
        }
    }

    /// 订阅里所有作者的最新视频，按发布时间倒序。
    ///
    /// 取全部再排序：「谁刚更新」比「关注列表的顺序」重要；两边各取前 6 条，
    /// 其余去作者页看。
    private var freshFromSubs: [SubFresh] {
        var seen = Set<String>()
        var out: [SubFresh] = []
        for sub in subs {
            for video in sub.videos {
                guard !video.videoId.isEmpty, !seen.contains(video.videoId) else { continue }
                seen.insert(video.videoId)
                out.append(SubFresh(id: video.videoId,
                                    title: video.title,
                                    cover: video.cover,
                                    author: sub.name,
                                    created: video.created,
                                    url: video.url,
                                    platform: sub.platform))
            }
        }
        return out.sorted { $0.created > $1.created }
    }

    /// 合集封面：服务端没给就用「这个合集里你存过的那一集」的封面顶上。
    ///
    /// 合集本身没有封面字段，之前一片灰底，看起来像加载失败。
    private func collectionCover(_ one: APIDiscoverCollection) -> String {
        if !one.cover.isEmpty { return one.cover }
        guard !one.seasonId.isEmpty else { return "" }
        let same = library.items.filter { $0.seasonId == one.seasonId }
        if let latest = same.max(by: { $0.seasonIndex < $1.seasonIndex }),
           let url = latest.coverURL?.absoluteString, !url.isEmpty {
            return url
        }
        return ""
    }

    private func duoHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.cnRowTitle)
                .foregroundStyle(Color.cnInk)
            Text("\(count)")
                .font(.cnCaption)
                .foregroundStyle(Color.cnInk3)
            Spacer(minLength: 0)
        }
        .padding(.bottom, 2)
    }

    private func duoHint(_ text: String) -> some View {
        Text(text)
            .font(.cnCaption)
            .foregroundStyle(Color.cnInk3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }

    private func duoCover(_ raw: String, seconds: Int) -> some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.cnCard3)
            if !raw.isEmpty, let url = URL(string: raw) {
                RemoteImage(url: url)
            }
            if seconds > 0 {
                Text(Self.clock(seconds))
                    .font(.cnDuration)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.black.opacity(0.55), in: Capsule())
                    .padding(4)
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func duoCardBody(cover raw: String, title: String, meta: String,
                            seconds: Int = 0) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            duoCover(raw, seconds: seconds)
            Text(title.isEmpty ? "未命名" : title)
                .font(.cnChip)
                .foregroundStyle(Color.cnInk)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(meta)
                .font(.system(size: 9))
                .foregroundStyle(Color.cnInk3)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func collectionDuoCard(_ one: APIDiscoverCollection) -> some View {
        if one.itemId.isEmpty {
            duoCardBody(cover: collectionCover(one), title: one.title,
                        meta: "共 \(one.total) 集")
        } else {
            NavigationLink {
                CollectionScreen(itemId: one.itemId,
                                 seasonId: one.seasonId,
                                 title: one.title,
                                 cover: one.cover,
                                 total: one.total)
            } label: {
                duoCardBody(cover: collectionCover(one), title: one.title,
                            meta: "共 \(one.total) 集")
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func freshDuoCard(_ one: SubFresh) -> some View {
        // 库里有的直接进详情；没入库的沿用「应用内预览」，不跳浏览器。
        if let item = library.items.first(where: { $0.videoId == one.id }) {
            NavigationLink {
                DetailScreen(item: item)
            } label: {
                duoCardBody(cover: one.cover, title: one.title, meta: duoMeta(one),
                            seconds: item.durationSeconds)
            }
            .buttonStyle(.plain)
        } else {
            Button {
                playing = discoverItem(from: one)
            } label: {
                duoCardBody(cover: one.cover, title: one.title, meta: duoMeta(one))
            }
            .buttonStyle(.plain)
        }
    }

    private func duoMeta(_ one: SubFresh) -> String {
        let name = one.author.isEmpty ? "未知作者" : one.author
        guard one.created > 0 else { return name }
        return "\(name) · \(Self.shortAge(one.created))"
    }

    private func discoverItem(from one: SubFresh) -> APIDiscoverItem {
        var item = APIDiscoverItem()
        item.id = one.id
        item.videoId = one.id
        item.platform = one.platform
        item.title = one.title
        item.cover = one.cover
        item.author = one.author
        item.url = one.url
        item.created = one.created
        return item
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
        let ago = one.created > 0 ? Self.shortAge(one.created) : ""
        return cardLink(one) {
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
                        if !ago.isEmpty {
                            // 发布时间：让「这一批是不是新的」一眼可见。
                            // 没有这一项，用户没法判断页面到底刷没刷。
                            Text(ago)
                                .font(.cnCaption)
                                .foregroundStyle(Color.cnInk3)
                        }
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

    /// 时长：feed 自己带就用它，没带就回查本库。
    ///
    /// 抖音那两个接口都不给时长，但已入库的抖音条目是有的（导入时完整解析过）。
    /// 不回查就会出现「同一个视频，首页有时长、发现页没有」——用户看到的是
    /// 「刚打开有、过一会没了」。
    private func playSeconds(_ one: APIDiscoverItem) -> Int {
        if one.duration > 0 { return one.duration }
        // videoId 是可选：热榜条目（例如抖音热榜）根本没有视频 id。
        guard let vid = one.videoId, !vid.isEmpty else { return 0 }
        return library.items.first(where: { $0.videoId == vid })?.durationSeconds ?? 0
    }

    private func cover(_ one: APIDiscoverItem, width: CGFloat, height: CGFloat) -> some View {
        let seconds = playSeconds(one)
        return ZStack {
            RoundedRectangle(cornerRadius: Metric.radiusCover, style: .continuous)
                .fill(Color.cnCard3)

            if one.cover.isEmpty {
                Text(one.platform == "douyin" ? "抖音" : "B站")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.cnInk3)
            } else {
                RemoteImage(url: URL(string: one.cover))
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
                if seconds > 0 {
                    HStack {
                        Spacer()
                        Text(Self.clock(seconds))
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

    /// 进页面时按「内容多新」决定要不要再拉一次。
    ///
    /// 以前只有 `feed == nil` 才拉：切回这个 Tab 永远是上次那一批。
    /// 用户的原话是「昨天和今天每次打开内容还是那些」。
    /// 现在：没有内容 → 拉；上次拉取超过 10 分钟 → **静默**再拉
    /// （不清屏、不打断滚动，失败也保留旧内容）。
    private func refreshIfStale() async {
        guard let feed else {
            await load(refresh: false)
            return
        }
        let age = Date().timeIntervalSince1970 - Double(feed.fetchedAt) / 1000
        guard age > 600 else { return }
        await load(refresh: false)
    }

    private func load(refresh: Bool) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        errorText = ""
        do {
            feed = try await library.discoverFeed(refresh: refresh)
            // 首次见到的时间在这里登记：渲染阶段写 @AppStorage 会触发重绘循环。
            registerFirstSeen(feed?.hot ?? [])
        } catch {
            // 断网和「服务端挂了」是两件事，文案要分开：
            // 前者用户自己能解决（连上网），后者只能等。
            errorText = (network.settled && network.isDown)
                ? "当前离线 · 热榜和关注都需要联网。已下载的条目在首页仍可正常看。"
                : "热榜拉不到，检查一下网络。已经存的内容不受影响。"
        }
        subs = await library.subscriptions()
        // 关注列表只在「关注那一刻」抓过一次，之后一直不动——
        // 用户看到的就是「明明更新了还显示没更新」。这里顺手同步一次。
        Task { await refreshSubsIfStale() }
    }

    /// 上次检查超过 10 分钟就同步查一次（服务端一次最多查 4 个，最久的优先）。
    private func refreshSubsIfStale() async {
        guard !subs.isEmpty, !checkingSubs, !library.isOffline else { return }
        let nowMs = Date().timeIntervalSince1970 * 1000
        let stale = subs.contains { nowMs - Double($0.lastCheckedAt) > 10 * 60 * 1000 }
        guard stale else { return }
        await forceCheckSubs()
    }

    /// 手动「检查更新」：不看时间，直接查。
    private func forceCheckSubs() async {
        guard !checkingSubs, !library.isOffline else { return }
        checkingSubs = true
        defer { checkingSubs = false }
        let fresh = await library.checkSubscriptions()
        if !fresh.isEmpty { subs = fresh }
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

    /// 列表右侧那一小行「多久之前」。超过一周就不显示了——
    /// 「23 天前」对一个「前沿」列表没有任何用处，只会占位置。
    static func shortAge(_ ts: Int) -> String {
        let diff = Date().timeIntervalSince1970 - Double(ts)
        if diff < 0 { return "" }
        if diff < 3600 { return "\(max(1, Int(diff / 60))) 分钟前" }
        if diff < 86400 { return "\(Int(diff / 3600)) 小时前" }
        if diff < 86400 * 7 { return "\(Int(diff / 86400)) 天前" }
        return ""
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
/// 应用内作者页。
///
/// 用户原话：「发现页点击作者们的头像直接能看到他们最近新发的视频，然后上方是
/// 他们头像点击进入跳转，我不一定非要跳到他们那看，我还可以在软件里看才对呀」。
/// 所以默认**留在应用内**：上面是身份区（点头像才去原站），下面是 TA 最近的视频，
/// 点一条就在应用内播。
struct AuthorSheet: View {
    var onRemove: () -> Void

    /// 进来时手上那条（可能已经有 videos）；`sub` 是刷新后的版本。
    @State private var sub: APISubscription
    @State private var loading = false
    @State private var notice = ""

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    @State private var playing: APIDiscoverItem?
    /// 库里已有的那条：点开走详情页（有摘要、笔记、评论）。
    @State private var lookedUp: Item?

    init(sub: APISubscription, onRemove: @escaping () -> Void) {
        _sub = State(initialValue: sub)
        self.onRemove = onRemove
    }

    private var platformName: String {
        sub.platform == "bilibili" ? "B 站" : (sub.platform == "douyin" ? "抖音" : sub.platform)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Metric.space3) {
                    header
                    actionRow
                    if !notice.isEmpty {
                        Text(notice)
                            .font(.cnCaption)
                            .foregroundStyle(Color.cnRed)
                            .padding(.horizontal, Metric.pagePad)
                    }
                    videoList
                    removeButton
                }
                .padding(.vertical, Metric.space4)
            }
            .background(Color.cnBg)
            .navigationTitle(sub.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $playing) { one in
                DiscoverPlayerScreen(item: one)
                    .environmentObject(library)
            }
            .navigationDestination(isPresented: Binding(
                get: { lookedUp != nil },
                set: { if !$0 { lookedUp = nil } }
            )) {
                if let lookedUp {
                    DetailScreen(item: lookedUp)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: Metric.space3) {
            // 头像点一下才去原站——这是**唯一的出口**，不做成默认行为。
            Button {
                openHome()
            } label: {
                RemoteImage(url: URL(string: sub.avatar))
                    .background(Circle().fill(Color.cnCard3))
                .frame(width: 56, height: 56)
                .clipShape(Circle())
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Color.cnInk.opacity(0.85), in: Circle())
                        .overlay(Circle().strokeBorder(Color.cnBg, lineWidth: 1.5))
                        .offset(x: 3, y: 3)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("去\(platformName)看 \(sub.name) 的主页")

            VStack(alignment: .leading, spacing: 3) {
                Text(sub.name)
                    .font(.cnTitle)
                    .foregroundStyle(Color.cnInk)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(platformName) · 最近 \(sub.videos.count) 条")
                        .font(.cnCaption)
                        .foregroundStyle(Color.cnInk3)
                    if sub.lastCheckedAt > 0 {
                        Text(Self.checkedText(sub.lastCheckedAt))
                            .font(.system(size: 9))
                            .foregroundStyle(Color.cnInk3)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metric.pagePad)
    }

    private var actionRow: some View {
        HStack(spacing: Metric.space2) {
            Button {
                openHome()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 10, weight: .semibold))
                    Text("在\(platformName)打开主页")
                        .font(.cnChip)
                }
                .foregroundStyle(Color.cnBrand)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(Color.cnBrandSoft, in: Capsule())
            }
            .buttonStyle(.plain)

            Button {
                Task { await refresh() }
            } label: {
                HStack(spacing: 4) {
                    if loading {
                        RingSpinner(size: 10, color: .cnInk2)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    Text(loading ? "检查中…" : "刷新最近视频")
                        .font(.cnChip)
                }
                .foregroundStyle(Color.cnInk2)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(Color.cnCard, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(loading)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metric.pagePad)
    }

    @ViewBuilder
    private var videoList: some View {
        if sub.videos.isEmpty {
            Text("还没拉到这个人的投稿。点上面「刷新最近视频」试一次。")
                .font(.cnMeta)
                .foregroundStyle(Color.cnInk3)
                .padding(.horizontal, Metric.pagePad)
                .padding(.top, Metric.space2)
        } else {
            ForEach(sub.videos, id: \.videoId) { video in
                Button {
                    open(video)
                } label: {
                    HStack(spacing: Metric.space3) {
                        RemoteImage(url: URL(string: video.cover),
                                    placeholder: Color.cnCard3)
                        .frame(width: 80, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                        VStack(alignment: .leading, spacing: 3) {
                            Text(video.title)
                                .font(.cnMeta)
                                .foregroundStyle(Color.cnInk)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            HStack(spacing: 6) {
                                if video.created > 0 {
                                    Text(DiscoverScreen.relative(video.created))
                                        .font(.cnCaption)
                                        .foregroundStyle(Color.cnInk3)
                                }
                                if video.views > 0 {
                                    Text(DiscoverScreen.compact(video.views) + " 播放")
                                        .font(.cnCaption)
                                        .foregroundStyle(Color.cnInk3)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Metric.pagePad)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if let url = URL(string: video.url) {
                        Button {
                            UIApplication.shared.open(url)
                        } label: {
                            Label("在原站打开这一条", systemImage: "safari")
                        }
                    }
                }
            }
        }
    }

    private var removeButton: some View {
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
                    in: RoundedRectangle(cornerRadius: Metric.radiusButton, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Metric.pagePad)
        .padding(.top, Metric.space4)
    }

    private func openHome() {
        let ok = PlatformLink.openAuthor(platform: sub.platform, uid: sub.uid)
        if !ok {
            notice = "这个作者没有可跳转的主页地址。"
        }
    }

    /// 点一条视频：入库过就进详情（有摘要/笔记/评论），没入库就在应用内播。
    private func open(_ video: APISubVideo) {
        if let item = library.items.first(where: { $0.videoId == video.videoId }) {
            playing = nil
            lookedUp = item
            return
        }
        playing = previewItem(video)
    }

    private func refresh() async {
        guard !loading, !library.isOffline else { return }
        loading = true
        notice = ""
        defer { loading = false }
        if let fresh = await library.subscription(key: sub.key) {
            sub = fresh
        } else {
            notice = "没拉到更新，检查一下网络再试。"
        }
    }

    private static func checkedText(_ ms: Int) -> String {
        let age = Date().timeIntervalSince1970 - Double(ms) / 1000
        if age < 120 { return "刚检查过" }
        if age < 3600 { return "\(Int(age / 60)) 分钟前检查" }
        if age < 86400 { return "\(Int(age / 3600)) 小时前检查" }
        return "\(Int(age / 86400)) 天前检查"
    }

    private func previewItem(_ video: APISubVideo) -> APIDiscoverItem {
        var one = APIDiscoverItem()
        one.id = video.videoId
        one.videoId = video.videoId
        one.platform = sub.platform
        one.title = video.title
        one.cover = video.cover
        one.author = sub.name
        one.avatar = sub.avatar
        one.views = video.views
        one.url = video.url
        return one
    }
}

/// 已屏蔽分类的管理。
/// 订阅里的一条新片。合集的模型不能复用（字段不同），单独一层更清楚。
private struct SubFresh: Identifiable, Equatable {
    let id: String
    let title: String
    let cover: String
    let author: String
    let created: Int
    let url: String
    let platform: String
}

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

// MARK: - 关键词屏蔽弹层

/// 正在选关键词的那条标题。用一层包装是因为 `sheet(item:)` 需要 Identifiable，
/// 而 String 不满足；直接用 Bool + 另一个变量容易在切换条目时错位。
private struct KeywordPrompt: Identifiable {
    let id = UUID()
    let title: String
}

/// 选词面板：可以从标题里挑，也可以自己打。
private struct KeywordBlockSheet: View {
    let title: String
    let suggestions: [String]
    @Binding var draft: String
    let blocked: [String]
    let onBlock: (String) -> Void
    let onUnblock: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Metric.space3) {
                Text("标题里出现这个词，就在发现页直接不显示。改完立刻生效。")
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk3)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("如：复盘、荐股、带货", text: $draft)
                    .font(.cnBody)
                    .padding(Metric.space3)
                    .background(Color.cnCard3,
                                in: RoundedRectangle(cornerRadius: Metric.radiusButton, style: .continuous))

                if !suggestions.isEmpty {
                    Text("从这条标题里选")
                        .font(.cnCaption)
                        .foregroundStyle(Color.cnInk3)
                    chips(suggestions, removable: false)
                }

                if !blocked.isEmpty {
                    Text("已屏蔽（点一下取消）")
                        .font(.cnCaption)
                        .foregroundStyle(Color.cnInk3)
                    chips(blocked, removable: true)
                }

                Spacer(minLength: 0)
            }
            .padding(Metric.pagePad)
            .background(Color.cnBg)
            .navigationTitle("关键词屏蔽")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                        .font(.cnChip)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("屏蔽") {
                        onBlock(trimmed)
                        dismiss()
                    }
                    .font(.cnChip)
                    .disabled(trimmed.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func chips(_ words: [String], removable: Bool) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(words, id: \.self) { word in
                    Button {
                        if removable {
                            onUnblock(word)
                        } else {
                            draft = word
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(word)
                                .font(.cnChip)
                            if removable {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                            }
                        }
                        .foregroundStyle(removable ? Color.cnInk2 : Color.cnBrand)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(removable ? Color.cnCard3 : Color.cnBrandSoft, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
