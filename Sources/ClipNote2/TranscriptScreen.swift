import SwiftUI
import AVFoundation

/// 当前播放位置落在第几句。纯函数，便于单测。
///
/// 为什么单独拎出来：高亮判定错一格，用户就会觉得「跟读不准」，
/// 而这个错很难在真机上一眼看出来。数字对了，界面才对。
enum TranscriptFollow {

    /// 返回最后一句满足 `t <= seconds` 的下标；早于第一句时返回 0。
    ///
    /// 用二分而不是线性扫描：一小时的视频可能有 800 句，
    /// 而播放器每 0.4 秒问一次。
    static func index(at seconds: Double, in lines: [TranscriptLine]) -> Int? {
        guard !lines.isEmpty else { return nil }
        let target = Int(seconds.rounded(.down))
        if target < lines[0].t { return nil }      // 还没开口，不该高亮任何一句

        var low = 0
        var high = lines.count - 1
        var answer = 0
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].t <= target {
                answer = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return answer
    }
}

/// 逐句跟读。转写落地在本机，播放时高亮当前句，点句子跳过去。
///
/// 和 Web 端的差别（不硬搬）：Web 是一个独立页面、从库里点进去。
/// 这里挂在详情页的播放器上——用户是**边看边跟**，不是先看完再看文字。
/// 所以这一页共用详情页那个 `AVPlayer` 实例，来回切不重播、不重新拉流。
struct TranscriptScreen: View {
    var item: Item
    var player: AVPlayer?

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var logs: LogStore

    @State private var lines: [TranscriptLine] = []
    @State private var loading = true
    @State private var message: String?
    @State private var current: Int?
    @State private var timeObserver: Any?

    private let store = LocalTranscriptStore()

    var body: some View {
        Group {
            if loading {
                HStack(spacing: Metric.space2) {
                    RingSpinner(size: 14, color: .cnBrand)
                    Text("正在读取字幕…")
                        .font(.cnChip)
                        .foregroundStyle(Color.cnInk3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let message {
                VStack(spacing: Metric.space3) {
                    Text(message)
                        .font(.cnChip)
                        .foregroundStyle(Color.cnInk3)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Metric.pagePad)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        .background(Color.cnBg)
        .navigationTitle("逐句跟读")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onAppear { attachObserver() }
        .onDisappear { detachObserver() }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Button {
                            seek(to: line.t)
                        } label: {
                            HStack(alignment: .top, spacing: Metric.space2) {
                                Text(mmss(line.t))
                                    .font(.cnMeta)
                                    .foregroundStyle(index == current ? Color.cnBrand : Color.cnInk3)
                                    .frame(width: 46, alignment: .leading)
                                Text(line.text)
                                    .font(.cnChip)
                                    .foregroundStyle(index == current ? Color.cnInk : Color.cnInk2)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 7)
                            .padding(.horizontal, Metric.pagePad)
                            .background(index == current ? Color.cnBrand.opacity(0.08) : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(index)
                    }
                }
                .padding(.vertical, Metric.space2)
            }
            .onChange(of: current) { value in
                guard let value else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(value, anchor: .center)
                }
            }
        }
    }

    // MARK: - 数据

    private func load() async {
        // 先看本机：字幕一经取回就不再联网。同一集反复进出不该重复打服务端，
        // 而且缓存之后，飞行模式下也能读。
        if let cached = store.load(id: item.id), !cached.lines.isEmpty {
            lines = cached.lines
            loading = false
            logs.info("transcript.cached", "读本地字幕", meta: [
                "id": item.id, "lines": String(cached.lines.count),
            ])
            return
        }

        do {
            let result = try await library.transcript(for: item.id)
            guard result.source == "subtitle", !result.lines.isEmpty else {
                message = "这条没有字幕。可以在详情页用「本机转写」先转成文字。"
                loading = false
                return
            }
            lines = result.lines.map { TranscriptLine(t: $0.t, text: $0.text) }
            store.save(LocalTranscript(
                itemId: item.id,
                lines: lines,
                durationSeconds: result.durationSeconds,
                createdAt: Date(),
                locale: "zh"
            ))
            loading = false
            logs.info("transcript.saved", "字幕落本地", meta: [
                "id": item.id, "lines": String(lines.count),
            ])
        } catch {
            message = "字幕没取到：\(error.localizedDescription)"
            loading = false
        }
    }

    // MARK: - 播放联动

    private func attachObserver() {
        guard timeObserver == nil, let player else { return }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.4, preferredTimescale: 600),
            queue: .main
        ) { time in
            let seconds = time.seconds.isFinite ? time.seconds : 0
            let index = TranscriptFollow.index(at: seconds, in: lines)
            if index != current { current = index }
        }
    }

    private func detachObserver() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
    }

    private func seek(to seconds: Int) {
        guard let player else { return }
        player.seek(to: CMTime(seconds: Double(seconds), preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        if player.rate == 0 { player.play() }
    }

    private func mmss(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
