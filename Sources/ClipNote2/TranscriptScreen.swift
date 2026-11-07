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
    /// 从搜索结果点进来时要落到的秒数：滚到那一句并标出来。
    var focusAt: Int? = nil

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var logs: LogStore

    @State private var lines: [TranscriptLine] = []
    @State private var source: String = ""
    @State private var durationSeconds: Int = 0
    @State private var loading = true
    @State private var message: String?
    @State private var error: String?
    @State private var showTranscribe = false
    @State private var copied = false
    @State private var focused: Int?
    @State private var annotations: [APIAnnotation] = []
    @State private var editing: AnnotationTarget?

    private let store = LocalTranscriptStore.shared

    /// sheet(item:) 需要一个 Identifiable。用句子的秒数当 id——同一句只有一个批注。
    struct AnnotationTarget: Identifiable {
        let id: Int
        let line: TranscriptLine
    }

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
        .sheet(item: $editing) { target in
            AnnotationEditor(
                quote: target.line.text,
                timeText: mmss(target.line.t),
                existing: annotation(for: target.line.t)?.note ?? "",
                onSave: { note in save(note, for: target.line) },
                onDelete: annotation(for: target.line.t) == nil
                    ? nil
                    : { save("", for: target.line) }
            )
        }
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
        ScrollViewReader { proxy in
        ScrollView {
            if let error {
                Text(error)
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnRed)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Metric.pagePad)
                    .padding(.top, Metric.space2)
            }
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

                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .top, spacing: Metric.space2) {
                        Text(mmss(line.t))
                            .font(.cnMeta)
                            .foregroundStyle(index == focused ? Color.cnBrand : Color.cnInk3)
                            .frame(width: 46, alignment: .leading)
                        Text(line.text)
                            .font(.cnChip)
                            .foregroundStyle(index == focused ? Color.cnInk : Color.cnInk2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)

                        Button {
                            editing = AnnotationTarget(id: line.t, line: line)
                        } label: {
                            Image(systemName: annotation(for: line.t) == nil
                                  ? "plus.circle" : "text.bubble.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(annotation(for: line.t) == nil
                                                 ? Color.cnInk3 : Color.cnBrand)
                                .frame(width: 28, height: 24)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, Metric.pagePad)
                    .background(index == focused ? Color.cnBrand.opacity(0.08) : Color.clear)
                    .id(index)

                    if let note = annotation(for: line.t)?.note, !note.isEmpty {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "text.bubble")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.cnBrand)
                                .padding(.top, 3)
                            Text(note)
                                .font(.cnMeta)
                                .foregroundStyle(Color.cnInk2)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, 46 + Metric.space2)
                        .padding(.trailing, Metric.pagePad)
                        .padding(.bottom, 4)
                    }
                }
            }
            .padding(.bottom, Metric.space4)
        }
        .onAppear {
            guard let focused else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(focused, anchor: .center)
                }
            }
        }
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
        // 批注跟着条目走，不是跟着字幕文件走：字幕可以重新识别，
        // 但批注是用户写的，不能因为换了一份字幕就丢。
        annotations = library.items.first { $0.id == item.id }?.annotations ?? []

        if let cached = store.load(id: item.id), !cached.lines.isEmpty {
            lines = cached.lines
            durationSeconds = cached.durationSeconds
            // 来源按缓存里的 locale 无法判定，用「已有字幕」表述，
            // 不假装知道它是平台给的还是自己识别的。
            source = "subtitle"
            focused = focusIndex()
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
            focused = focusIndex()
            loading = false
            logs.info("transcript.saved", "字幕落本地", meta: [
                "id": item.id, "lines": String(lines.count),
            ])
        } catch {
            message = "字幕没取到：\n\(error.localizedDescription)"
            loading = false
        }
    }

    /// 定位到「第一句不早于 focusAt」的那句。
    private func focusIndex() -> Int? {
        guard let focusAt else { return nil }
        return lines.firstIndex { $0.t >= focusAt }
    }

    // MARK: - 批注

    private func annotation(for t: Int) -> APIAnnotation? {
        annotations.first { $0.t == t }
    }

    /// 保存一句的批注。空内容即删除。
    ///
    /// 整体替换而不是逐条增删：批注数量少（一条片子通常几句到几十句），
    /// 整体替换让「界面看到的」和「服务端存的」永远一致。
    private func save(_ note: String, for line: TranscriptLine) {
        var next = annotations.filter { $0.t != line.t }
        if !note.isEmpty {
            next.append(APIAnnotation(t: line.t, quote: line.text, note: note))
        }
        next.sort { $0.t < $1.t }
        annotations = next

        Task {
            if let failure = await library.saveAnnotations(id: item.id, annotations: next) {
                error = failure
                return
            }
            logs.info("annotation.saved", note.isEmpty ? "删除批注" : "写入批注", meta: [
                "id": item.id, "t": String(line.t),
            ])
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
