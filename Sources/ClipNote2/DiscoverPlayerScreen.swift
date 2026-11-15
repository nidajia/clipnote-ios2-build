import AVKit
import SwiftUI

/// 发现页里「点开就能看」的播放页。
///
/// 为什么要单独一页而不是跳去原站：用户的原话是「点进去不跳转 App 反而是浏览器」。
/// 外部跳转有两层不可控——先跳浏览器、浏览器再唤起 App，慢且经常失败。
/// 既然服务端本来就能解析出可播放地址，直接在 App 里播是最短的路径。
///
/// 关键约束：**不入库、不跑流水线**。走 `/api/v2/preview`，
/// 只解析播放地址（B 站约 1 秒，抖音走第三方），不写入同步快照、
/// 不触发下载和转写。想留下的内容由用户点「收藏」显式决定。
/// 「一组可连续播放的剧集」。
///
/// 合集目录里点开某一集时带上整组：播放页里就能上一集/下一集，
/// 不必退回目录、再滑到那一行。
struct PlayQueue: Identifiable, Equatable {
    var items: [APIDiscoverItem]
    var index: Int
    var id: String {
        current.id
    }

    /// 当前播的那一条。索引越界时退回第一条，绝不让取值崩。
    var current: APIDiscoverItem {
        if items.indices.contains(index) { return items[index] }
        return items.first ?? APIDiscoverItem()
    }
}

struct DiscoverPlayerScreen: View {
    /// 队列为空时就是单条预览。
    var item: APIDiscoverItem
    var queue: [APIDiscoverItem]

    /// 当前播到队列里的第几条（队列为空时恒为 0）。
    @State private var idx: Int

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore

    @State private var preview: APIPreview?
    @State private var player: AVPlayer?
    @State private var loading = true
    @State private var errorText = ""
    @State private var saving = false
    @State private var saved = false
    @State private var notice = ""

    init(item: APIDiscoverItem, queue: PlayQueue? = nil) {
        self.item = item
        self.queue = queue?.items ?? []
        _idx = State(initialValue: queue?.index ?? 0)
    }

    /// 正在播的那一条。队列换了就跟着换。
    private var current: APIDiscoverItem {
        queue.indices.contains(idx) ? queue[idx] : item
    }

    private var hasQueue: Bool { queue.count > 1 }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                playerArea

                if hasQueue {
                    queueBar
                }

                    VStack(alignment: .leading, spacing: Metric.space3) {
                        Text(current.title)
                            .font(.cnRowTitle)
                            .foregroundStyle(.white)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 6) {
                            Text(current.author)
                                .font(.cnCaption)
                                .foregroundStyle(.white.opacity(0.6))
                            if current.views > 0 {
                                Text("· \(DiscoverScreen.compact(current.views)) 次播放")
                                    .font(.cnCaption)
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                            Spacer(minLength: 0)
                        }

                        if !notice.isEmpty {
                            Text(notice)
                                .font(.cnCaption)
                                .foregroundStyle(Color.cnRed)
                        }

                        HStack(spacing: Metric.space3) {
                            Button {
                                Task { await save() }
                            } label: {
                                HStack(spacing: 5) {
                                    if saving {
                                        RingSpinner(size: 11, color: .white)
                                    } else {
                                        Image(systemName: saved ? "checkmark" : "plus")
                                            .font(.system(size: 11, weight: .bold))
                                    }
                                    Text(saved ? "已收藏到首页" : "收藏到首页")
                                        .font(.cnChip)
                                }
                                .foregroundStyle(saved ? Color.cnInk3 : .white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(saved ? Color.white.opacity(0.15)
                                                  : Color.cnBrand, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(saving || saved)

                            if let url = URL(string: current.url) {
                                Link(destination: url) {
                                    HStack(spacing: 5) {
                                        Image(systemName: "safari")
                                            .font(.system(size: 11, weight: .semibold))
                                        Text("浏览器")
                                            .font(.cnChip)
                                    }
                                    .foregroundStyle(.white.opacity(0.8))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color.white.opacity(0.12), in: Capsule())
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .padding(Metric.pagePad)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // 关闭按钮用固定位置的 overlay，而不是导航栏工具栏：
        // 之前放工具栏里，视频加载时 AVPlayer 会反复重排导航栏安全区，
        // 左上角那个「关闭」就会跟着乱跳。
        .overlay(alignment: .topLeading) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.16), in: Circle())
            }
            .padding(.top, 8)
            .padding(.leading, 16)
            .accessibilityLabel("关闭")
        }
        .task { await load() }
        // 换集：先把旧的掐掉，再重新解析这一集的地址。
        // 不掐会两条音轨一起响（详情页踩过同样的坑）。
        .onChange(of: idx) { _ in
            player?.pause()
            player = nil
            preview = nil
            saved = false
            notice = ""
            Task { await load() }
        }
        .onDisappear { player?.pause() }
    }

    /// 队列里换集的按钮条：第 N/M 集 + 上一集/下一集。
    private var queueBar: some View {
        HStack(spacing: Metric.space2) {
            stepButton(title: "上一集", chevron: "chevron.left", to: idx - 1)

            Spacer(minLength: 0)
            Text("第 \(idx + 1)/\(queue.count) 集")
                .font(.cnCaption)
                .foregroundStyle(.white.opacity(0.65))
            Spacer(minLength: 0)

            stepButton(title: "下一集", chevron: "chevron.right", to: idx + 1, trailing: true)
        }
        .padding(.horizontal, Metric.pagePad)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func stepButton(title: String, chevron: String, to target: Int,
                            trailing: Bool = false) -> some View {
        let enabled = queue.indices.contains(target)
        Button {
            idx = target
        } label: {
            HStack(spacing: 4) {
                if !trailing {
                    Image(systemName: chevron).font(.system(size: 10, weight: .semibold))
                }
                Text(title).font(.cnChip)
                if trailing {
                    Image(systemName: chevron).font(.system(size: 10, weight: .semibold))
                }
            }
            .foregroundStyle(enabled ? Color.white : Color.white.opacity(0.3))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.white.opacity(enabled ? 0.14 : 0.06), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    @ViewBuilder
    private var playerArea: some View {
        if let player {
            VideoPlayer(player: player)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .background(Color.black)
        } else {
            ZStack {
                Color.black
                VStack(spacing: Metric.space3) {
                    if loading {
                        RingSpinner(size: 22, color: .white)
                        Text("正在解析视频…")
                            .font(.cnMeta)
                            .foregroundStyle(.white.opacity(0.7))
                    } else {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 22))
                            .foregroundStyle(.white.opacity(0.7))
                        Text(errorText)
                            .font(.cnMeta)
                            .foregroundStyle(.white.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        if let url = URL(string: current.url) {
                            Link("去原站看", destination: url)
                                .font(.cnChip)
                                .foregroundStyle(Color.cnBrand)
                        }
                    }
                }
                .padding(Metric.pagePad)
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
        }
    }

    private func load() async {
        guard !library.isOffline else {
            loading = false
            errorText = "离线模式下没法解析视频"
            return
        }
        loading = true
        errorText = ""
        do {
            let result = try await library.preview(url: current.url)
            preview = result
            guard !result.streamUrl.isEmpty, let url = URL(string: result.streamUrl) else {
                throw ClipNoteClient.Failure.transport("这条没有可播放的视频流")
            }
            let one = AVPlayer(url: url)
            player = one
            one.play()
        } catch {
            errorText = "解析不到播放地址。这条可能已经下架，或者需要去原站看。"
        }
        loading = false
    }

    /// 收藏 = 真的入库（导出、笔记、分段、离线都跟着可用）。
    ///
    /// 用 quickImport 而不是 importItem：它会在服务端有 AI 配置时顺手
    /// 提交摘要任务，用户下次打开首页就是完整的一条。
    private func save() async {
        saving = true
        defer { saving = false }
        do {
            _ = try await library.quickImport(text: current.url)
            saved = true
            notice = ""
        } catch {
            notice = "收藏失败：\(error)"
        }
    }
}
