import SwiftUI

/// 字幕页。
///
/// 定位变了：不是「跟着播放读」，而是**把字幕当成一份产物**——
/// 能看、能复制、能导出成 SRT 拿去剪映或 Premiere 用，没有字幕时当场识别一份。
///
/// 为什么砍掉跟读：真机验过之后，边看边跟的场景在手机上并不成立
/// （16:9 播放器已经占掉半屏，剩下的高度只够三行字）。
/// 而「这条视频说了什么、能不能带走」是刚需。
struct TranscriptScreen: View {
    var item: Item

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var logs: LogStore

    @State private var lines: [TranscriptLine] = []
    @State private var source: String = ""
    @State private var durationSeconds: Int = 0
    @State private var loading = true
    @State private var message: String?
    @State private var showTranscribe = false
    @State private var copied = false

    private let store = LocalTranscriptStore.shared

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
                emptyState(message)
            } else {
                content
            }
        }
        .background(Color.cnBg)
        .navigationTitle("字幕")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !lines.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button(copied ? "已复制" : "复制全文") { copyAll() }
                        if let url = srtURL() {
                            ShareLink(item: url) {
                                Text("导出 SRT")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $showTranscribe) {
            TranscribeSheet(item: item) { transcript in
                lines = transcript.lines
                source = "local"
                durationSeconds = transcript.durationSeconds
                message = nil
                showTranscribe = false
            }
        }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(source == "subtitle" ? "平台字幕" : "本机识别")
                        .font(.cnCaption)
                        .foregroundStyle(Color.cnBrand)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.cnBrandSoft, in: Capsule())
                    Text("\(lines.count) 句 · \(mmss(durationSeconds))")
                        .font(.cnCaption)
                        .foregroundStyle(Color.cnInk3)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Metric.pagePad)
                .padding(.top, Metric.space2)
                .padding(.bottom, Metric.space3)

                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: Metric.space2) {
                        Text(mmss(line.t))
                            .font(.cnMeta)
                            .foregroundStyle(Color.cnInk3)
                            .frame(width: 46, alignment: .leading)
                        Text(line.text)
                            .font(.cnChip)
                            .foregroundStyle(Color.cnInk2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, Metric.pagePad)
                }
            }
            .padding(.bottom, Metric.space4)
        }
    }

    private func emptyState(_ text: String) -> some View {
        VStack(spacing: Metric.space4) {
            Text(text)
                .font(.cnChip)
                .foregroundStyle(Color.cnInk3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Metric.pagePad)

            // 没有字幕就当场识别一份。把人踢回详情页再找入口是没有意义的。
            PrimaryButton(title: "识别字幕") { showTranscribe = true }
                .padding(.horizontal, Metric.pagePad)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 数据

    private func load() async {
        if let cached = store.load(id: item.id), !cached.lines.isEmpty {
            lines = cached.lines
            durationSeconds = cached.durationSeconds
            // 来源按缓存里的 locale 无法判定，用「已有字幕」表述，
            // 不假装知道它是平台给的还是自己识别的。
            source = "subtitle"
            loading = false
            return
        }

        do {
            let result = try await library.transcript(for: item.id)
            guard result.source == "subtitle", !result.lines.isEmpty else {
                message = "这条没有字幕。"
                loading = false
                return
            }
            lines = result.lines.map { TranscriptLine(t: $0.t, text: $0.text) }
            durationSeconds = result.durationSeconds
            source = "subtitle"
            store.save(LocalTranscript(
                itemId: item.id,
                lines: lines,
                durationSeconds: durationSeconds,
                createdAt: Date(),
                locale: "zh"
            ))
            loading = false
            logs.info("transcript.saved", "字幕落本地", meta: [
                "id": item.id, "lines": String(lines.count),
            ])
        } catch {
            message = "字幕没取到：\n\(error.localizedDescription)"
            loading = false
        }
    }

    // MARK: - 导出

    private func copyAll() {
        UIPasteboard.general.string = lines.map(\.text).joined(separator: "\n")
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            copied = false
        }
    }

    private func srtURL() -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(item.title.prefix(24))-字幕.srt")
        guard let data = SRTFormat.text(lines: lines, duration: durationSeconds)
            .data(using: .utf8) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private func mmss(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
