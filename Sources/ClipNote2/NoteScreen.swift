import SwiftUI

/// 我的笔记。独立一页。
///
/// 打开就是完整编辑器，没有模式切换。
/// 上一版做成「纯文本 / Markdown」二选一，打开后用户还要先做一个决定才知道能写什么——
/// 编辑器应该一进来就什么都有。
///
/// 但**不能有死路**：富文本起不来时自动退回纯文本，并且说清为什么。
struct NoteScreen: View {
    var item: Item

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var logs: LogStore

    @State private var text: String
    @State private var saving = false
    @State private var failed = false

    @State private var editorReady = false
    @State private var editorError: String?
    /// 超时也走降级：一条永远等不到的 ready 消息不该把用户锁在转圈里。
    @State private var gaveUp = false

    init(item: Item) {
        self.item = item
        _text = State(initialValue: item.note)
    }

    private var dirty: Bool { text != item.note }
    private var useFallback: Bool { editorError != nil || gaveUp }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let editorError {
                banner("编辑器没能启动：\(editorError)")
            } else if gaveUp {
                banner("编辑器加载超时，已切回纯文本。内容照常保存。")
            }

            if useFallback {
                plainEditor
            } else {
                editorArea
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

    private func banner(_ message: String) -> some View {
        Text(message)
            .font(.cnMeta)
            .foregroundStyle(Color.cnRed)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metric.pagePad)
            .padding(.vertical, 6)
    }

    private var editorArea: some View {
        ZStack {
            MarkdownWebView(
                markdown: $text,
                initial: text,
                onReady: {
                    editorReady = true
                    logs.info("editor.ready", "编辑器就绪", meta: ["id": item.id])
                },
                onError: { message in
                    editorError = message
                    logs.error("editor.failed", message, meta: ["id": item.id])
                },
                onTrace: { step in
                    // 每一步都进日志：用户上报后能直接看到卡在哪一步
                    logs.info("editor.trace", step, meta: ["id": item.id])
                }
            )
            if !editorReady, editorError == nil, !gaveUp {
                RingSpinner(size: 16, color: .cnBrand)
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                if !editorReady, editorError == nil {
                    gaveUp = true
                    logs.error("editor.timeout", "4 秒未就绪，退回纯文本", meta: ["id": item.id])
                }
            }
        }
    }

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
