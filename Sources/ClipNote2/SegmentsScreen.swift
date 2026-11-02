import AVKit
import SwiftUI

/// 分段总结的完整页。
///
/// 为什么单独一页而不是在详情页里展开：**段数不可控**。
/// 实测一条 10 分钟的视频切出 9 段，更长的会更多；展开会把下载按钮
/// 推到第三四屏，而且一展开页面高度翻倍，滚动位置会跳。
///
/// 这一版只做一件事：把段落读清楚，点时间戳从那里开始看。
struct SegmentsScreen: View {
    var item: Item

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var logs: LogStore

    @State private var player: AVPlayer?
    @State private var showPlayer = false
    /// 正在取地址的那一段（存 t，用来只让那一行转圈）
    @State private var preparing: Int?
    @State private var notice: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metric.space4) {
                header

                if let notice {
                    Text(notice)
                        .font(.cnMeta)
                        .foregroundStyle(Color.cnRed)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if item.segments.isEmpty {
                    Text("这条还没有分段。回到详情页点「按段落读」生成。")
                        .font(.cnMeta)
                        .foregroundStyle(Color.cnInk3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Metric.space2)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(item.segments.enumerated()), id: \.offset) { index, segment in
                            row(index: index + 1, segment: segment)
                            if index < item.segments.count - 1 {
                                Rectangle()
                                    .fill(Color.cnHairlineSoft)
                                    .frame(height: 1)
                                    .padding(.leading, 36)
                            }
                        }
                    }
                }
            }
            .padding(Metric.pagePad)
        }
        .background(Color.cnBg)
        .navigationTitle("分段")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .fullScreenCover(isPresented: $showPlayer, onDismiss: {
            // 不加这一句，关掉全屏后音频还在响，而屏幕上已经没有任何播放控件——
            // 用户只能杀进程。
            player?.pause()
            player = nil
        }) {
            if let player {
                PlayerScreen(item: item, player: player)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Metric.space2) {
            Text(item.title)
                .font(.cnTitle)
                .foregroundStyle(Color.cnInk)
                .fixedSize(horizontal: false, vertical: true)

            Text(metaText)
                .font(.cnMeta)
                .foregroundStyle(Color.cnInk3)
        }
    }

    private var metaText: String {
        var parts = ["共 \(item.segments.count) 段"]
        if !item.durationText.isEmpty { parts.append(item.durationText) }
        return parts.joined(separator: " · ")
    }

    private func row(index: Int, segment: APISegment) -> some View {
        Button {
            Task { await play(from: segment) }
        } label: {
            HStack(alignment: .top, spacing: Metric.space3) {
                // 编号用 Inter：中文数字在 10 以后宽度不一，编号会参差不齐
                Text(String(format: "%02d", index))
                    .font(.custom("Inter-SemiBold", size: 13, relativeTo: .subheadline))
                    .foregroundStyle(Color.cnBrand)
                    .frame(width: 24, alignment: .leading)
                    .padding(.top, 3)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: Metric.space2) {
                        Text(segment.title)
                            .font(.cnRowTitle)
                            .foregroundStyle(Color.cnInk)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        timeBadge(segment)
                    }

                    if !segment.summary.isEmpty {
                        Text(segment.summary)
                            .font(.cnChip)
                            .foregroundStyle(Color.cnInk2)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, Metric.space3)
        }
        .buttonStyle(.plain)
        .disabled(preparing != nil)
        .accessibilityLabel("从 \(DetailScreen.mmss(segment.t)) 开始播放：\(segment.title)")
    }

    /// 时间戳就是按钮。给它一个播放三角，用户才知道这里能点——
    /// 光是一串 01:02 看起来只是标注，不会有人去点。
    @ViewBuilder
    private func timeBadge(_ segment: APISegment) -> some View {
        HStack(spacing: 3) {
            if preparing == segment.t {
                ActivitySpinner(style: .medium)
                    .scaleEffect(0.6)
                    .frame(width: 9, height: 9)
            } else {
                Image(systemName: "play.fill")
                    .font(.system(size: 8, weight: .semibold))
            }
            Text(DetailScreen.mmss(segment.t))
                .font(.cnDuration)
        }
        .foregroundStyle(item.playbackAvailable ? Color.cnBrand : Color.cnInk3)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            item.playbackAvailable ? Color.cnBrandSoft : Color.cnCard3,
            in: Capsule()
        )
    }

    /// 从这一段开始看。
    ///
    /// 为什么不在这一页嵌一个播放器：这一页是「读」的场景，一个占半屏的
    /// 播放器会把段落切碎。点了就全屏播——和详情页走的是同一个
    /// `PlayerScreen`，转屏逻辑也只维护一份。
    private func play(from segment: APISegment) async {
        guard item.playbackAvailable else {
            notice = "这条内容没有视频流，不能从时间点播放。"
            return
        }
        guard preparing == nil else { return }

        preparing = segment.t
        defer { preparing = nil }

        do {
            guard let payload = try await library.playback(for: item.id),
                  let url = URL(string: payload.url) else {
                notice = "这条没有可播放的视频。"
                return
            }
            let newPlayer = AVPlayer(url: url)
            // 先定位再播：直接 play 会让用户先听到开头那两秒再跳，很难受。
            // 用不带 completion 的版本——AVPlayer 会把 seek 排在自己的加载队列里，
            // 不需要我们等；等待反而要处理「加载失败」这条额外分支。
            newPlayer.seek(to: CMTime(seconds: Double(segment.t), preferredTimescale: 600))
            player = newPlayer
            showPlayer = true
            newPlayer.play()
            logs.info("segments.jump", "从分段起播", meta: [
                "id": item.id, "t": String(segment.t),
            ])
        } catch let failure as ClipNoteClient.Failure {
            notice = failure.displayMessage
        } catch {
            notice = "取播放地址失败，稍后再试。"
        }
    }
}
