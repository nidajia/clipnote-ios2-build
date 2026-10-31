import AVKit
import SwiftUI

/// 详情页（画布 05 / 07 / 08）
///
/// 播放器先给封面 + 播放键，点了才创建 `AVPlayer`：
/// 一来首帧稳定（截图可比），二来避免未点播就占用解码资源。
struct DetailScreen: View {
    var item: Item

    @EnvironmentObject private var downloads: DownloadStore

    @State private var player: AVPlayer?
    @State private var playing = false

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

                    HStack(spacing: 6) {
                        Text(item.metaLine)
                        Text("·")
                        Text(item.duration)
                    }
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk3)

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

                        Button(action: startPlayback) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(Color.cnInk)
                                .frame(width: 56, height: 56)
                                .background(Color.white.opacity(0.92), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("播放")
                    }
                }
            }
            .clipped()
    }

    private var playbackURL: URL? {
        downloads.localURL(for: item.id) ?? item.mediaURL
    }

    private func startPlayback() {
        guard let url = playbackURL else { return }
        let newPlayer = AVPlayer(url: url)
        player = newPlayer
        playing = true
        newPlayer.play()
    }

    // MARK: - 下载区

    @ViewBuilder
    private var downloadSection: some View {
        VStack(alignment: .leading, spacing: Metric.space3) {
            if downloads.isDownloaded(item.id) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text("已下载 · \(sizeText) · 存于本机，离线可看")
                        .font(.cnMeta)
                }
                .foregroundStyle(Color.cnGreen)

                PrimaryButton(title: playing ? "正在播放" : "在本地播放") {
                    startPlayback()
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
                PrimaryButton(title: "下载到本地") {
                    downloads.start(item)
                }

                Text("视频文件由服务端代理直链下发。B 站签名约 2 小时过期，失效时会自动重新解析，不需要手动刷新。")
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk3)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
