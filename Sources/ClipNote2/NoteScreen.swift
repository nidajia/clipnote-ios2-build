import SwiftUI

/// 我的笔记。独立一页。
///
/// 为什么不放在详情页里直接编辑：详情页已经有简介、AI 摘要、作者备注三段文字，
/// 再加一个可编辑区域就是第四段，滚动条会变得很长，而「读」和「写」是两种状态——
/// 混在一页里，用户既读不干净也写不专注。
///
/// 两种编辑模式写的是**同一个字段**：
/// - 纯文本：快速记一句，起手最快；
/// - Markdown：要标题、表格、代码块时切过去。
/// 模式切换不跳页——上一版跳到一个新页面，用户回来后上下文全丢了。
struct NoteScreen: View {
    var item: Item

    enum Mode: String, CaseIterable, Identifiable {
        case plain = "纯文本"
        case markdown = "Markdown"
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var logs: LogStore

    @State private var text: String
    @State private var saving = false
    @State private var failed = false

    @State private var mode: Mode = .plain
    @State private var editorReady = false
    @State private var editorError: String?
    /// 编辑器迟迟不 ready 时给用户一句话，而不是一直转圈。
    @State private var readyTimeout = false

    init(item: Item) {
        self.item = item
        _text = State(initialValue: item.note)
    }

    private var dirty: Bool { text != item.note }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            modeBar

            if mode == .plain {
                plainEditor
            } else {
                markdownEditor
            }

            Divider().overlay(Color.cnHairline)
            statusBar
        }
        .background(Color.cnBg)
        .navigationTitle("我的笔记")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("保存") { Task { await save() } }
                    .font(.cnChip)
                    .disabled(!dirty || saving)
            }
        }
        .onDisappear {
            // 直接返回也要留下：用户不会记得点保存，而丢一段自己写的字
            // 比任何界面问题都严重。dirty 判断保证不会白写一次。
            if dirty { Task { await save() } }
        }
    }

    // MARK: - 模式切换

    private var modeBar: some View {
        HStack(spacing: Metric.space2) {
            ForEach(Mode.allCases) { one in
                Button {
                    mode = one
                } label: {
                    Text(one.rawValue)
                        .font(.cnCaption)
                        .foregroundStyle(mode == one ? Color.cnBrand : Color.cnInk3)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            mode == one ? Color.cnBrandSoft : Color.clear,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            if mode == .markdown, !editorReady, editorError == nil {
                Text(readyTimeout ? "编辑器没加载起来" : "加载中…")
                    .font(.cnMeta)
                    .foregroundStyle(readyTimeout ? Color.cnRed : Color.cnInk3)
            }
        }
        .padding(.horizontal, Metric.pagePad)
        .padding(.vertical, 6)
    }

    // MARK: - 纯文本

    private var plainEditor: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("写点什么：这条视频对你有什么用、哪句话值得记、下次要试什么。")
                    .font(.cnBody)
                    .foregroundStyle(Color.cnInk3)
                    .padding(.horizontal, Metric.pagePad)
                    .padding(.top, 10)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.cnBody)
                .foregroundStyle(Color.cnInk)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, Metric.pagePad - 5)
                .padding(.top, 2)
        }
    }

    // MARK: - Markdown

    private var markdownEditor: some View {
        ZStack {
            if let editorError {
                // 出错就把话说清楚。一直转圈是最糟的反馈——用户不知道等还是重试。
                VStack(spacing: Metric.space2) {
                    Text("编辑器没能启动")
                        .font(.cnChip)
                        .foregroundStyle(Color.cnInk)
                    Text(editorError)
                        .font(.cnMeta)
                        .foregroundStyle(Color.cnRed)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Metric.pagePad)
                    Text("可以先切回「纯文本」继续写，内容不会丢。")
                        .font(.cnMeta)
                        .foregroundStyle(Color.cnInk3)
                }
            } else {
                MarkdownWebView(
                    markdown: $text,
                    initial: text,
                    onReady: {
                        editorReady = true
                        readyTimeout = false
                    },
                    onError: { editorError = $0 }
                )
                if !editorReady {
                    RingSpinner(size: 16, color: .cnBrand)
                }
            }
        }
        .onAppear {
            // 3 秒还没 ready 就不再假装"快好了"
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if !editorReady && editorError == nil { readyTimeout = true }
            }
        }
    }

    // MARK: - 状态条

    private var statusBar: some View {
        HStack {
            Text("\(text.count) 字")
                .font(.cnCaption)
                .foregroundStyle(Color.cnInk3)
            Spacer()
            if failed {
                Text("没存上，检查网络")
                    .font(.cnCaption)
                    .foregroundStyle(Color.cnRed)
            } else if saving {
                Text("保存中…")
                    .font(.cnCaption)
                    .foregroundStyle(Color.cnInk3)
            }
        }
        .padding(.horizontal, Metric.pagePad)
        .padding(.vertical, Metric.space2)
    }

    private func save() async {
        guard dirty, !saving else { return }
        saving = true
        failed = false
        defer { saving = false }
        let value = text
        let ok = await library.saveNote(id: item.id, note: value)
        if !ok { failed = true }
        logs.info("note.edit", "笔记落盘", meta: [
            "id": item.id, "chars": String(value.count), "ok": ok ? "1" : "0",
        ])
    }
}
