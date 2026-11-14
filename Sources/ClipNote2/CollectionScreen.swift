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
    @State private var sort = "index"
    /// 正在应用内播放的那一集（没入库的走这里）。
    @State private var playing: APIDiscoverItem?
    /// 打开目录后要滚到哪一集（上次看的那集）。
    @State private var scrollTarget: String?

    private var headTitle: String {
        if let t = season?.title, !t.isEmpty { return t }
        return title.isEmpty ? "合集" : title
    }

    private var rawEpisodes: [APISeasonEpisode] {
        if let season, !season.episodes.isEmpty { return season.episodes }
        return localEpisodes
    }

    private var episodes: [APISeasonEpisode] {
        guard sort == "time" else { return rawEpisodes }
        // 没有发布时间的排到最后，而不是当成 1970 排最前——
        // 「最新更新」里第一集是 0 播放的老视频，看着就像排序坏了。
        return rawEpisodes.sorted {
            let a = $0.created > 0 ? $0.created : Int.max
            let b = $1.created > 0 ? $1.created : Int.max
            return a < b
        }
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
        }) { one in
            DiscoverPlayerScreen(item: one)
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
                    if !cover.isEmpty {
                        AsyncImage(url: URL(string: cover)) { phase in
                            if case .success(let image) = phase {
                                image.resizable().scaledToFill()
                            } else {
                                Color.clear
                            }
                        }
                    }
                }
                .frame(width: 104, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: Metric.radiusCover,
                                            style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(headTitle)
                        .font(.cnTitle)
                        .foregroundStyle(Color.cnInk)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(countLine)
                        .font(.cnCaption)
                        .foregroundStyle(Color.cnInk3)
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
            parts.append("上次看第 \(number(of: rawEpisodes[currentIndex],
                                          fallback: currentIndex + 1)) 集")
        }
        return parts.isEmpty ? "目录" : parts.joined(separator: " · ")
    }

    // MARK: 排序

    private var sortBar: some View {
        HStack(spacing: Metric.space3) {
            ForEach([("index", "按集数"), ("time", "按时间")], id: \.0) { key, label in
                Button {
                    sort = key
                } label: {
                    Text(label)
                        .font(.cnChip)
                        .foregroundStyle(sort == key ? Color.cnBg : Color.cnInk2)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(sort == key ? Color.cnInk : Color.cnCard, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            Text("\(episodes.count) 集")
                .font(.cnCaption)
                .foregroundStyle(Color.cnInk3)
        }
        .padding(.horizontal, Metric.pagePad)
        .padding(.bottom, Metric.space2)
    }

    // MARK: 行

    @ViewBuilder
    private func episodeRow(_ ep: APISeasonEpisode, number: Int) -> some View {
        // 已入库：进详情页并自动起播——那里有笔记、分段、评论，离线也能看。
        if let saved = library.items.first(where: { $0.id == ep.itemId }) {
            NavigationLink {
                DetailScreen(item: saved, autoPlay: true)
            } label: {
                rowLabel(ep, number: number)
            }
            .buttonStyle(.plain)
            .contextMenu { externalMenu(ep) }
        } else {
            // 没入库：应用内在线播放。绝不默认跳浏览器——
            // 跳站要用户显式选（长按菜单 / 播放页里的「浏览器」按钮）。
            Button {
                playing = previewItem(ep)
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
                .foregroundStyle(ep.current ? Color.cnBrand : Color.cnInk3)
                .frame(minWidth: 24)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(ep.title.isEmpty ? "第 \(number) 集" : ep.title)
                    .font(.cnMeta)
                    .foregroundStyle(ep.current ? Color.cnBrand : Color.cnInk)
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
                    if !ep.itemId.isEmpty, !ep.current {
                        Text("已存")
                            .foregroundStyle(Color.cnGreen)
                    }
                }
                .font(.cnCaption)
                .foregroundStyle(Color.cnInk3)
            }

            Spacer(minLength: 0)

            if ep.current {
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
        if library.isOffline {
            // 离线：用库里同合集的条目兜底，不再打网络。
            loading = false
            failed = ""
            markScrollTarget()
            return
        }
        loading = true
        failed = ""
        do {
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
        guard scrollTarget == nil else { return }
        let target = rawEpisodes.first(where: { $0.current })?.videoId
            ?? rawEpisodes.last(where: { !$0.itemId.isEmpty })?.videoId
        // 只有长目录才需要跳：几十集的小合集两屏就看完了，
        // 一进来就把它滚掉反而看不到标题和「共 N 集」。
        if let target, rawEpisodes.count > 30 {
            scrollTarget = target
        }
    }

    private func previewItem(_ ep: APISeasonEpisode) -> APIDiscoverItem {
        var one = APIDiscoverItem()
        one.id = ep.videoId
        one.videoId = ep.videoId
        one.platform = "bilibili"
        one.title = ep.title
        one.cover = cover
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
