import SwiftUI
import UIKit

/// 合集目录页：**先看目录，再挑一集看**。
///
/// 之前从发现页点「合集」，直接落到某一集的详情页——用户的原话是
/// 「不应该先出来视频目录吗，然后再点击后直接观看」。合集是一部作品，
/// 详情页只是一集；把作品当成一集打开，等于把「追这部」这件事藏了起来。
///
/// 目录里的每一行点下去就是**直接播**：
/// - 已入库的那一集 → 进详情页并自动起播（有笔记、分段、评论，还能离线）
/// - 没入库的那一集 → 应用内在线播放（`/preview` 解析地址，不跳浏览器）
///
/// 数据来自 `/api/v2/items/{id}/season`；离线时退化成「库里同一合集的那几集」，
/// 至少能把自己存过的看掉。
struct CollectionScreen: View {
    /// 库里那条「代表条目」，服务端用它认合集。
    var itemId: String
    /// 离线兜底用：库里条目的 seasonId。
    var seasonId: String = ""
    var title: String = ""
    var cover: String = ""
    var total: Int = 0

    @EnvironmentObject private var library: LibraryStore

    @State private var season: APISeason?
    @State private var loading = true
    @State private var failed = ""
    /// 排序选择存在本地：用户选过「旧→新」，下次进来还是它。
    @AppStorage(SeasonOrder.storageKey) private var orderRaw = SeasonOrder.index.rawValue
    /// 正在应用内播放的那一组（从某一集开始，可连着往下看）。
    @State private var playing: PlayQueue?
    /// 打开目录后要滚到哪一集（上次看的那集）。
    @State private var scrollTarget: String?

    /// 「上次点开的是哪一集」。按合集存在 UserDefaults 里。
    ///
    /// 之前只记「库里那条代表条目」（`current`），用户点第 8 集看完退出，
    /// 再进来又回到代表条目，看起来就像**根本没记住**。
    private var lastEpisodeKey: String {
        "cn.lastEpisode." + (seasonId.isEmpty ? itemId : seasonId)
    }

    private func rememberedEpisode() -> String? {
        UserDefaults.standard.string(forKey: lastEpisodeKey)
    }

    private func remember(_ ep: APISeasonEpisode) {
        guard !ep.videoId.isEmpty else { return }
        UserDefaults.standard.set(ep.videoId, forKey: lastEpisodeKey)
        // 关闭播放页返回时 `.task` 不会再执行，所以这里就把定位设好，
        // 否则列表还停在库里那条代表条目上。
        scrollTarget = ep.videoId
    }

    /// 「正在看」只认最近点开的那一集；从没点过才退回库里代表条目。
    /// 写成 `remembered || current` 会同时高亮两条，看起来像根本没记住。
    private func isWatching(_ ep: APISeasonEpisode) -> Bool {
        if let vid = rememberedEpisode(), !vid.isEmpty,
           rawEpisodes.contains(where: { $0.videoId == vid }) {
            return ep.videoId == vid
        }
        return ep.current
    }

    /// 头部封面：没给就用「你看过的那一集」的封面顶着。
    private var displayCover: String {
        if !cover.isEmpty { return cover }
        guard !seasonId.isEmpty else { return "" }
        let sameSeason = library.items.filter { $0.seasonId == seasonId }
        if let vid = rememberedEpisode(),
           let hit = sameSeason.first(where: { $0.videoId == vid }),
           let url = hit.coverURL?.absoluteString, !url.isEmpty {
            return url
        }
        if let latest = sameSeason.max(by: { $0.seasonIndex < $1.seasonIndex }),
           let url = latest.coverURL?.absoluteString, !url.isEmpty {
            return url
        }
        return ""
    }

    private var headTitle: String {
        if let t = season?.title, !t.isEmpty { return t }
        return title.isEmpty ? "合集" : title
    }

    private var rawEpisodes: [APISeasonEpisode] {
        if let season, !season.episodes.isEmpty { return season.episodes }
        return localEpisodes
    }

    private var order: SeasonOrder { SeasonOrder.stored(orderRaw) }

    private var episodes: [APISeasonEpisode] {
        order.sorted(rawEpisodes)
    }

    private var savedCount: Int {
        rawEpisodes.filter { !$0.itemId.isEmpty }.count
    }

    private var currentIndex: Int? {
        rawEpisodes.firstIndex(where: { $0.current })
            ?? rawEpisodes.firstIndex(where: { !$0.itemId.isEmpty })
    }

    /// 离线时用：库里同一合集的条目。
    private var localEpisodes: [APISeasonEpisode] {
        guard !seasonId.isEmpty else { return [] }
        return library.items
            .filter { $0.seasonId == seasonId }
            .sorted { $0.seasonIndex < $1.seasonIndex }
            .map { one in
                var ep = APISeasonEpisode()
                ep.videoId = one.videoId
                ep.title = one.title
                ep.itemId = one.id
                ep.current = one.id == itemId
                ep.url = one.sourceURL
                return ep
            }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header

                    if loading, rawEpisodes.isEmpty {
                        HStack(spacing: 6) {
                            RingSpinner(size: 12, color: .cnBrand)
                            Text("正在拉合集目录…")
                                .font(.cnCaption)
                                .foregroundStyle(Color.cnInk3)
                        }
                        .padding(Metric.pagePad)
                    } else if rawEpisodes.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(failed.isEmpty ? "这个合集暂时没有拉到剧集。" : failed)
                                .font(.cnMeta)
                                .foregroundStyle(Color.cnInk3)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("重试") {
                                Task { await load(force: true) }
                            }
                            .font(.cnChip)
                            .foregroundStyle(Color.cnBrand)
                            .buttonStyle(.plain)
                        }
                        .padding(Metric.pagePad)
                    } else {
                        sortBar
                        // 合集动辄几百集（实测有一部 503 集），逐行建视图会卡；
                        // LazyVStack 只渲染屏幕内的那几行。
                        // `.id(orderRaw)`：换排序时整块重建。
                        // 不加这一句，LazyVStack 会按 id 复用原来的行，
                        // 顺序看起来没变——要退出去再进来才刷新（用户实测）。
                        LazyVStack(spacing: 0) {
                            ForEach(Array(episodes.enumerated()), id: \.element.videoId) { offset, ep in
                                episodeRow(ep, number: number(of: ep, fallback: offset + 1))
                                    .id(ep.videoId)
                                if ep.videoId != episodes.last?.videoId {
                                    Divider()
                                        .overlay(Color.cnHairlineSoft)
                                        .padding(.leading, Metric.pagePad + 34)
                                }
                            }
                        }
                        .id(orderRaw)
                    }
                }
                .padding(.bottom, Metric.space6)
            }
            // 目录拉到之后，直接滚到「上次看的那一集」：
            // 503 集从第 1 集开始翻，等于把功能废了。
            .onChange(of: scrollTarget) { target in
                guard let target else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
            }
        }
        .background(Color.cnBg)
        .navigationTitle(headTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task { await load(force: false) }
        .sheet(item: $playing, onDismiss: {
            // 播放页里可能刚「收藏到首页」，回来把「已存」标记刷新一下。
            Task { await load(force: true) }
        }) { q in
            DiscoverPlayerScreen(item: q.current, queue: q)
                .environmentObject(library)
        }
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: Metric.space3) {
            HStack(alignment: .top, spacing: Metric.space3) {
                ZStack {
                    RoundedRectangle(cornerRadius: Metric.radiusCover, style: .continuous)
                        .fill(Color.cnCard3)
                    if !displayCover.isEmpty {
                        RemoteImage(url: URL(string: displayCover))
                    }
                }
                .frame(width: 104, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: Metric.radiusCover,
                                            style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    // 标题只在导航栏出现一次：这里再写一遍，
                    // 顶部两行一模一样的字，看着像没加载完。
                    Text(countLine)
                        .font(.cnCaption)
                        .foregroundStyle(Color.cnInk3)
                    // 一句话把规则写在页面上：点=应用内播，长按才跳站。
                    // 同时也是这一版的「长相」——旧包不会有这一行。
                    Text("点任意一集直接在应用内播放 · 要跳原站请长按")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.cnInk3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(Metric.pagePad)
    }

    private var countLine: String {
        let totalCount = season?.total ?? total
        var parts: [String] = []
        if totalCount > 0 {
            parts.append("共 \(totalCount) 集")
        } else if !rawEpisodes.isEmpty {
            parts.append("共 \(rawEpisodes.count) 集")
        }
        if savedCount > 0 {
            parts.append("已存 \(savedCount) 集")
        }
        if let currentIndex, currentIndex < rawEpisodes.count {
            let n = number(of: rawEpisodes[currentIndex], fallback: currentIndex + 1)
            parts.append("上次看第 \(n) 集")
        }
        return parts.isEmpty ? "目录" : parts.joined(separator: " · ")
    }

    // MARK: 排序

    /// 排序：按集数 / 按时间（时间再点一次翻方向）。
    ///
    /// 两格而不是三格：「按时间」自己带方向，标签直接写「新→旧」/「旧→新」，
    /// 再点一下就翻过来。选择存在 AppStorage，下次进来还是上次那个。
    private var sortBar: some View {
        HStack(spacing: 6) {
            sortChip(title: "按集数", active: order == .index) {
                orderRaw = SeasonOrder.index.rawValue
            }
            sortChip(title: timeTitle, active: order.isTime) {
                orderRaw = order.toggledTime.rawValue
            }
            Spacer(minLength: 0)
            Text("\(episodes.count) 集")
                .font(.cnCaption)
                .foregroundStyle(Color.cnInk3)
        }
        .padding(.horizontal, Metric.pagePad)
        .padding(.bottom, Metric.space2)
    }

    /// 「按时间」这格的文字带着方向：不用点开才知道现在是哪一头。
    private var timeTitle: String {
        order == .oldest ? "按时间 旧→新" : "按时间 新→旧"
    }

    private func sortChip(title: String, active: Bool,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.cnChip)
                .foregroundStyle(active ? Color.cnBg : Color.cnInk2)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(active ? Color.cnInk : Color.cnCard, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: 行

    @ViewBuilder
    private func episodeRow(_ ep: APISeasonEpisode, number: Int) -> some View {
        // 去处只有两种，且由 `EpisodeRouting` 统一判定（有单测锁住）：
        // 已入库 → 详情页并自动起播（有笔记、分段、评论，离线也能看）；
        // 其余一律应用内播放。**外部打开不在这条路径上**。
        let saved = library.items.first { $0.id == ep.itemId }
        if let saved,
           EpisodeRouting.route(itemId: ep.itemId, isInLibrary: true) == .openSavedItem {
            NavigationLink {
                DetailScreen(item: saved, autoPlay: true)
            } label: {
                rowLabel(ep, number: number)
            }
            .buttonStyle(.plain)
            .contextMenu { externalMenu(ep) }
        } else {
            // 跳站要用户显式选（长按菜单 / 播放页里的「浏览器」按钮）。
            Button {
                remember(ep)
                playing = playQueue(startingAt: ep)
            } label: {
                rowLabel(ep, number: number)
            }
            .buttonStyle(.plain)
            .contextMenu { externalMenu(ep) }
        }
    }

    private func rowLabel(_ ep: APISeasonEpisode, number: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(isWatching(ep) ? Color.cnBrand : Color.cnInk3)
                .frame(minWidth: 24)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(ep.title.isEmpty ? "第 \(number) 集" : ep.title)
                    .font(.cnMeta)
                    .foregroundStyle(isWatching(ep) ? Color.cnBrand : Color.cnInk)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 5) {
                    if ep.views > 0 {
                        Text("\(DiscoverScreen.compact(ep.views)) 次播放")
                    }
                    if ep.created > 0 {
                        Text(Self.day(ep.created))
                    }
                    if !ep.itemId.isEmpty, !isWatching(ep) {
                        Text("已存")
                            .foregroundStyle(Color.cnGreen)
                    }
                }
                .font(.cnCaption)
                .foregroundStyle(Color.cnInk3)
            }

            Spacer(minLength: 0)

            // 「正在看」跟着你最近点开的那一集，而不是库里那条代表条目：
            // 否则点第 504 集播完退出，标签还挂在上一条上。
            if isWatching(ep) {
                Text("正在看")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.cnBrand)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.cnBrandSoft, in: Capsule())
            } else {
                Image(systemName: "play.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.cnInk3)
            }
        }
        .padding(.horizontal, Metric.pagePad)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    /// 外部打开是**选项**，不是默认：长按某一集才会出现。
    @ViewBuilder
    private func externalMenu(_ ep: APISeasonEpisode) -> some View {
        if let url = URL(string: ep.url), !ep.url.isEmpty {
            Button {
                UIApplication.shared.open(url)
            } label: {
                Label("在浏览器打开这一集", systemImage: "safari")
            }
        }
    }

    // MARK: 数据

    private func number(of ep: APISeasonEpisode, fallback: Int) -> Int {
        // 服务端给的是全集顺序，行号直接用位置；排序切成「按时间」时
        // 位置会乱，所以集数从 videoId 在原始列表里的位置取。
        if let pos = rawEpisodes.firstIndex(where: { $0.videoId == ep.videoId }) {
            return pos + 1
        }
        return fallback
    }

    private func load(force: Bool) async {
        if !force, season != nil { return }
        guard !itemId.isEmpty else {
            loading = false
            return
        }
        loading = true
        failed = ""
        do {
            // 离线（截图/预览）时 LibraryStore 会直接给种子目录；
            // 真断网时这里抛错，下面退化成「库里同合集的条目」。
            let result = try await library.season(id: itemId)
            season = result
            if result.episodes.isEmpty {
                failed = "服务端没返回剧集，可能这个合集已经下架。"
            }
        } catch {
            failed = library.isOffline
                ? "离线模式下只能看已存的几集。"
                : "合集目录没拉到，检查一下网络再试。"
        }
        loading = false
        markScrollTarget()
    }

    /// 记住「该滚到哪一集」：当前那一集优先，其次最后一个已存的。
    private func markScrollTarget() {
        let remembered = rememberedEpisode()
        let hitRemembered = rawEpisodes.contains(where: { $0.videoId == remembered })
        // 点过某一集：永远回到它，即使视图重跑也别被代表条目覆盖回去。
        if hitRemembered, let remembered {
            if scrollTarget != remembered { scrollTarget = remembered }
            return
        }
        guard scrollTarget == nil else { return }
        let target = rawEpisodes.first(where: { $0.current })?.videoId
            ?? rawEpisodes.last(where: { !$0.itemId.isEmpty })?.videoId
        // 长目录需要跳，否则用户要自己翻几十屏。
        if let target, rawEpisodes.count > 30 {
            scrollTarget = target
        }
    }

    /// 从某一集开始播，并把整组带上（播放页里能直接上一集/下一集）。
    private func playQueue(startingAt ep: APISeasonEpisode) -> PlayQueue? {
        let list = episodes
        guard let index = list.firstIndex(where: { $0.videoId == ep.videoId }) else {
            return nil
        }
        return PlayQueue(items: list.map(previewItem), index: index)
    }

    private func previewItem(_ ep: APISeasonEpisode) -> APIDiscoverItem {
        var one = APIDiscoverItem()
        one.id = ep.videoId
        one.videoId = ep.videoId
        one.platform = "bilibili"
        one.title = ep.title
        one.cover = displayCover
        one.author = library.items.first(where: { $0.id == itemId })?.author ?? ""
        one.views = ep.views
        one.url = ep.url
        one.inLibrary = false
        return one
    }

    private static func day(_ ts: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

/// 点某一集之后去哪。
///
/// 只有两种去处，**没有第三种**：已存的进详情页（自动起播），其余在应用内播。
/// 单独抽出来是为了能被单测锁住——真机上出现过「点一集就跳浏览器」，
/// 根因就是这里曾有过第三个分支：没入库就直接 `UIApplication.shared.open`。
enum EpisodeRoute: Equatable {
    case openSavedItem
    case playInApp
}

enum EpisodeRouting {
    /// - Parameters:
    ///   - itemId: 服务端标的「这一集在库里」的条目 id（空串表示没存）
    ///   - isInLibrary: 这个 id 是否真能在当前库里找到（快照可能过期）
    static func route(itemId: String, isInLibrary: Bool) -> EpisodeRoute {
        // 顺序有意义：**只有 id 非空且库里真能找到**才进详情。
        // id 有值但本地没有（快照过期）时退回应用内播放，而不是去浏览器。
        guard !itemId.isEmpty, isInLibrary else { return .playInApp }
        return .openSavedItem
    }
}
