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
struct DiscoverPlayerScreen: View {
    var item: APIDiscoverItem

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore

    @State private var preview: APIPreview?
    @State private var player: AVPlayer?
    @State private var loading = true
    @State private var errorText = ""
    @State private var saving = false
    @State private var saved = false
    @State private var notice = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    playerArea

                    VStack(alignment: .leading, spacing: Metric.space3) {
                        Text(item.title)
                            .font(.cnRowTitle)
                            .foregroundStyle(.white)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 6) {
                            Text(item.author)
                                .font(.cnCaption)
                                .foregroundStyle(.white.opacity(0.6))
                            if item.views > 0 {
                                Text("· \(DiscoverScreen.compact(item.views)) 次播放")
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

                            if let url = URL(string: item.url) {
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
            .navigationTitle("预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
        }
        .task { await load() }
        .onDisappear { player?.pause() }
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
                        if let url = URL(string: item.url) {
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
            let result = try await library.preview(url: item.url)
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
            _ = try await library.quickImport(text: item.url)
            saved = true
            notice = ""
        } catch {
            notice = "收藏失败：\(error)"
        }
    }
}
