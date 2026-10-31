import AVKit
import SwiftUI

/// 详情页（画布 05 / 07 / 08）
///
/// 播放器先给封面 + 播放键，点了才创建 `AVPlayer`：
/// 一来首帧稳定（截图可比），二来避免未点播就占用解码资源。
///
/// 播放地址**不在模型里**：视频流地址几小时后会过期，所以每次要播/要下载时
/// 现取一次 `/api/v2/items/{id}/playback`。已下载的文件优先，离线也能看。
struct DetailScreen: View {
    var item: Item

    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var library: LibraryStore

    @State private var player: AVPlayer?
    @State private var playing = false
    @State private var isPreparing = false
    @State private var notice: String?

    /// 简介太短就不整块渲染。
    ///
    /// 真实数据的 `desc` 常常只是「感谢索导的配音@索拉KG5TEP」——16 个字，
    /// 挂一个「简介」小标题去压一句致谢，比留白更难看。
    /// 20 这个阈值是产品判断，不是技术限制；要改就改这一处。
    private var showsSummary: Bool { item.summary.count >= 20 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                playerSurface

                VStack(alignment: .leading, spacing: Metric.space3) {
                    Text(item.title)
                        .font(.cnTitle)
                        .foregroundStyle(Color.cnInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(metaLine)
                        .font(.cnMeta)
                        .foregroundStyle(Color.cnInk3)

                    if showsSummary {
                        Rectangle()
                            .fill(Color.cnHairline)
                            .frame(height: 1)
                            .padding(.vertical, Metric.space1)

                        Text("简介")
                            .font(.cnCaption)
                            .foregroundStyle(Color.cnInk3)

                        Text(item.summary)
                            .font(.cnChip)
                            .foregroundStyle(Color.cnInk2)
                            .lineSpacing(6)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let notice {
                        Text(notice)
                            .font(.cnMeta)
                            .foregroundStyle(Color.cnRed)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    downloadSection
                        .padding(.top, Metric.space2)
                }
                .padding(Metric.pagePad)
            }
        }
        .background(Color.cnBg)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }

    /// 服务端已经给好 `metaLine` 和 `durationText`，这里只负责摆位置，
    /// 不拼平台名、不换算时长。
    private var metaLine: String {
        item.durationText.isEmpty ? item.metaLine : "\(item.metaLine) · \(item.durationText)"
    }

    // MARK: - 播放器

    private var playerSurface: some View {
        // 用 Color.clear 撑出 16:9 再叠内容：直接给 ZStack 加 aspectRatio
        // 在高度不受约束的 ScrollView 里容易塌成 0。
        Color.clear
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                if playing, let player {
                    VideoPlayer(player: player)
                } else {
                    ZStack {
                        LinearGradient(
                            colors: [item.coverTop, item.coverBottom],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )

                        if let url = item.coverURL {
                            AsyncImage(url: url, transaction: Transaction(animation: nil)) { phase in
                                if case .success(let image) = phase {
                                    image.resizable().scaledToFill()
                                }
                            }
                        }

                        if item.playbackAvailable {
                            playButton
                        } else {
                            noStreamBadge
                        }
                    }
                }
            }
            .clipped()
    }

    private var playButton: some View {
        Button {
            Task { await startPlayback() }
        } label: {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.92))
                    .frame(width: 56, height: 56)
                if isPreparing {
                    RingSpinner(size: 20, color: .cnInk)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Color.cnInk)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isPreparing)
        .accessibilityLabel("播放")
    }

    /// 没有视频流时给一句说明，而不是一个点了没反应的播放键
    private var noStreamBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 11, weight: .semibold))
            Text("该内容没有视频流")
                .font(.cnCaption)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.5), in: Capsule())
    }

    private func startPlayback() async {
        // 已下载优先：本地文件离线可看，也不消耗一次地址解析
        if let local = downloads.localURL(for: item.id) {
            play(local)
            return
        }
        guard player == nil else {
            player?.play()
            playing = true
            return
        }

        isPreparing = true
        notice = nil
        defer { isPreparing = false }

        do {
            guard let url = try await library.playbackURL(for: item.id) else {
                notice = "该内容没有视频流。"
                return
            }
            play(url)
        } catch let failure as ClipNoteClient.Failure {
            notice = failure.displayMessage
        } catch {
            notice = "取播放地址失败，请稍后重试。"
        }
    }

    private func play(_ url: URL) {
        let newPlayer = AVPlayer(url: url)
        player = newPlayer
        playing = true
        newPlayer.play()
    }

    // MARK: - 下载区

    @ViewBuilder
    private var downloadSection: some View {
        VStack(alignment: .leading, spacing: Metric.space3) {
            if !item.playbackAvailable {
                Text("这条内容以文字为主，没有可下载的视频。")
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk3)
                    .fixedSize(horizontal: false, vertical: true)

            } else if downloads.isDownloaded(item.id) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text("已下载 · \(sizeText) · 存于本机，离线可看")
                        .font(.cnMeta)
                }
                .foregroundStyle(Color.cnGreen)

                PrimaryButton(title: playing ? "正在播放" : "在本地播放") {
                    Task { await startPlayback() }
                }

                Text("删除条目不会自动删除文件。清理请在「我 · 下载与存储」里进行。")
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk3)
                    .fixedSize(horizontal: false, vertical: true)

            } else if let value = downloads.progressValue(for: item.id) {
                DownloadProgressCard(progress: value) {
                    downloads.cancel(item.id)
                }

                Text("下载在后台继续，离开此页不会中断。")
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk3)

            } else {
                PrimaryButton(title: "下载到本地", isLoading: isPreparing) {
                    Task { await startDownload() }
                }

                Text("视频文件由服务端代理直链下发。地址会过期，失效时自动重新解析，不需要手动刷新。")
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func startDownload() async {
        isPreparing = true
        notice = nil
        defer { isPreparing = false }

        do {
            guard let url = try await library.playbackURL(for: item.id) else {
                notice = "该内容没有可下载的视频。"
                return
            }
            downloads.start(item.id, url: url)
        } catch let failure as ClipNoteClient.Failure {
            notice = failure.displayMessage
        } catch {
            notice = "取下载地址失败，请稍后重试。"
        }
    }

    private var sizeText: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: downloads.byteCount(for: item.id))
    }
}

// MARK: - 下载进度卡（画布 07）

struct DownloadProgressCard: View {
    var progress: Double
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: Metric.space3) {
            ZStack {
                Circle()
                    .stroke(Color.cnCard3, lineWidth: 3)
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, progress)))
                    .stroke(Color.cnBrand, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.custom("Inter-SemiBold", size: 10, relativeTo: .caption2))
                    .foregroundStyle(Color.cnInk)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text("正在下载")
                    .font(.cnRowTitle)
                    .foregroundStyle(Color.cnInk)
                Text("可离开此页，后台继续")
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk3)
            }

            Spacer(minLength: 0)

            Button("取消", action: onCancel)
                .font(.cnChip)
                .foregroundStyle(Color.cnRed)
                .buttonStyle(.plain)
                .accessibilityLabel("取消下载")
        }
        .padding(Metric.space3)
        .background(
            Color.cnCard,
            in: RoundedRectangle(cornerRadius: Metric.radiusCard, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metric.radiusCard, style: .continuous)
                .strokeBorder(Color.cnHairline, lineWidth: 1)
        )
    }
}
