import SwiftUI
import UIKit

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
    /// 重试次数。改这个值会重建 WebView（见 `.id(editorAttempt)`）。
    @State private var editorAttempt = 0

    /// 选图与上传。
    @State private var pendingImage: String?
    @State private var pickingPhoto = false
    @State private var uploadingImage = false
    @State private var imageError: String?

    /// 笔记内 AI。
    @StateObject private var webBox = WebViewBox()
    @State private var aiConfig = AIConfigStore.load()
    @State private var aiRunning = false
    @State private var aiPreview: NoteAIPreview?
    @State private var aiError: String?
    @State private var aiDraft = ""
    @State private var showCustomPrompt = false
    @State private var confirmWholeDoc = false
    /// 键盘弹起时不显示动作条：它和底部格式栏叠在一起会吃掉近 90pt 编辑区，
    /// 而打字时也用不到 AI。有预览时例外——那是用户正要处理的结果。
    @State private var keyboardUp = false

    init(item: Item) {
        self.item = item
        _text = State(initialValue: item.note)
    }

    private var dirty: Bool { text != item.note }
    private var useFallback: Bool { editorError != nil || gaveUp }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let editorError {
                banner("编辑器没能启动：\(editorError)", canRetry: true)
            } else if gaveUp {
                banner("编辑器加载超时，已切回纯文本。内容照常保存。", canRetry: true)
            }

            if let imageError {
                banner(imageError)
            }
            if uploadingImage {
                Text("图片上传中…")
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnInk3)
                    .padding(.horizontal, Metric.pagePad)
                    .padding(.vertical, 4)
            }

            if useFallback {
                plainEditor
            } else {
                editorArea
            }

            aiBlock

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
        .sheet(isPresented: $pickingPhoto) {
            PhotoPicker { image in
                pickingPhoto = false
                upload(image)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardUp = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardUp = false
        }
        .alert("按指令改写", isPresented: $showCustomPrompt) {
            TextField("例如：改写成书面语，保留原意", text: $aiDraft)
            Button("取消", role: .cancel) { aiDraft = "" }
            Button("执行") {
                let instruction = aiDraft
                aiDraft = ""
                Task { await prepare(.custom(instruction)) }
            }
        } message: {
            Text("模型只会按这条指令改，不会顺手改别的。")
        }
        .alert("将处理全文", isPresented: $confirmWholeDoc) {
            Button("取消", role: .cancel) {}
            Button("继续") { Task { await run(.expand, selection: "") } }
        } message: {
            Text("没有选中文字，「补充细节」会把整条笔记交给模型。可能加入原文没有的信息。")
        }
    }

    // MARK: - 笔记内 AI

    @ViewBuilder
    private var aiBlock: some View {
        if useFallback {
            EmptyView()
        } else {
            if let aiError {
                Text(aiError)
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnRed)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Metric.pagePad)
                    .padding(.bottom, 6)
            }
            if let aiPreview {
                NoteAICard(
                    preview: aiPreview,
                    onApply: { Task { await applyPreview() } },
                    onDiscard: { self.aiPreview = nil }
                )
            }
            if !keyboardUp || aiPreview != nil {
                NoteAIBar(configured: aiConfig.isConfigured, running: aiRunning) { action in
                    if case .custom = action {
                        // 自由指令要先问要改什么，不能拿空指令直接发出去
                        aiDraft = ""
                        showCustomPrompt = true
                    } else {
                        Task { await prepare(action) }
                    }
                }
            }
        }
    }

    /// 先取选区，再决定处理范围。
    /// 只有在「没有选区」时才有例外：补充细节要确认整篇，其余直接跑。
    private func prepare(_ action: NoteAIAction) async {
        guard let web = webBox.web else { return }
        let raw = try? await web.evaluateJavaScript("window.__getSelection()")
        let selection = (raw as? String) ?? ""
        if selection.isEmpty, action == .expand {
            confirmWholeDoc = true
            return
        }
        await run(action, selection: selection)
    }

    private func run(_ action: NoteAIAction, selection: String) async {
        // 全文优先问编辑器要最新内容：`text` 是走 350ms 防抖回传的，
        // 用户刚打完字就去点 AI 时它可能还差一个字。
        var content = selection
        if content.isEmpty, let web = webBox.web {
            content = ((try? await web.evaluateJavaScript("window.__getMarkdown()")) as? String) ?? text
        }
        let scopeIsDoc = selection.isEmpty
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            aiError = "这条笔记还是空的，先写一点再让 AI 处理"
            return
        }
        aiRunning = true
        aiError = nil
        aiPreview = nil
        do {
            let result = try await NoteAssistant(config: aiConfig)
                .run(action: action, content: content)
            aiRunning = false

            var warning: String?
            if action.mayAddContent {
                warning = "可能加入原文没有的信息，采用前请过一遍"
            }
            if action.mustKeepText, result.textChanged {
                // 「整理排版」的定义就是不改字。机器能验，就不该只靠提示词。
                warning = "文字有改动——「整理排版」不应该改字，建议放弃后重试"
            }
            aiPreview = NoteAIPreview(
                action: action,
                scope: scopeIsDoc ? "全文" : "选区",
                selection: selection,
                markdown: result.markdown,
                warning: warning
            )
            logs.info("note.ai.preview", "\(action.title) 已生成", meta: [
                "id": item.id,
                "scope": scopeIsDoc ? "doc" : "selection",
                "chars": String(result.markdown.count),
            ])
        } catch {
            aiRunning = false
            let readable = (error as? NoteAIFailure)?.displayMessage ?? "\(error)"
            aiError = readable
            logs.error("note.ai.failed", readable, meta: ["id": item.id])
        }
    }

    /// 采用。走编辑器事务，所以**按一次撤销就能回来**。
    private func applyPreview() async {
        guard let web = webBox.web, let preview = aiPreview else { return }

        // 针对选区生成的结果，必须先确认选区还是原来那段：
        // 用户在这期间点了一下正文，替换就会落到别的地方，而且不报错。
        if !preview.selection.isEmpty {
            let now = (try? await web.evaluateJavaScript("window.__getSelection()")) as? String ?? ""
            guard now == preview.selection else {
                aiError = "选区已经变了，这条结果没有采用。重新选中后再试一次。"
                aiPreview = nil
                return
            }
        }

        let argument = Self.jsString(preview.markdown)
        let script = preview.selection.isEmpty
            ? "window.__replaceAll(\(argument))"
            : "window.__replaceSelection(\(argument))"
        _ = try? await web.evaluateJavaScript(script)
        aiPreview = nil
        aiError = nil
        logs.info("note.ai.applied", "\(preview.action.title) 已采用", meta: [
            "id": item.id,
            "scope": preview.selection.isEmpty ? "doc" : "selection",
        ])
    }

    private static func jsString(_ value: String) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8)
        return String(data: data, encoding: .utf8) ?? "\"\""
    }

    private func banner(_ message: String, canRetry: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(message)
                .font(.cnMeta)
                .foregroundStyle(Color.cnRed)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if canRetry {
                Button("重试") { retryEditor() }
                    .font(.cnChip)
                    .foregroundStyle(Color.cnBrand)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Metric.pagePad)
        .padding(.vertical, 6)
    }

    /// 压图 → 上传 → 让页面插到光标处。
    ///
    /// 失败必须说话。静默失败会让用户以为图已经插进去了，关掉页面才发现没有。
    private func upload(_ image: UIImage) {
        imageError = nil
        guard let data = image.clipnoteJPEG() else {
            imageError = "这张图片读不出来，换一张试试"
            logs.error("note.image.failed", "压图失败", meta: ["id": item.id])
            return
        }
        uploadingImage = true
        Task {
            do {
                let url = try await ClipNoteClient.production.uploadImage(jpeg: data)
                await MainActor.run {
                    uploadingImage = false
                    pendingImage = url
                    logs.info("note.image.uploaded", "图片已插入", meta: [
                        "id": item.id, "kb": String((data.count + 1023) / 1024),
                    ])
                }
            } catch {
                await MainActor.run {
                    uploadingImage = false
                    let readable = (error as? ClipNoteClient.Failure)?.displayMessage
                        ?? "网络不稳，稍后再试"
                    imageError = "图片没传上去：\(readable)"
                    logs.error("note.image.failed", readable, meta: ["id": item.id])
                }
            }
        }
    }

    /// 重建 WebView，而不是只把标记清掉：
    /// 只清标记的话，同一个已经死掉的页面还在，重试永远等不到 ready。
    private func retryEditor() {        editorReady = false
        editorError = nil
        gaveUp = false
        editorAttempt += 1
        logs.info("editor.retry", "重试编辑器", meta: [
            "id": item.id, "attempt": String(editorAttempt),
        ])
    }

    private var editorArea: some View {
        ZStack {
            MarkdownWebView(
                markdown: $text,
                pendingImage: $pendingImage,
                initial: text,
                onReady: {
                    editorReady = true
                    logs.info("editor.ready", "编辑器就绪", meta: ["id": item.id])
                },
                onError: { message in
                    editorError = message
                    logs.error("editor.failed", message, meta: ["id": item.id])
                },
                onPickImage: {
                    imageError = nil
                    pickingPhoto = true
                },
                onTrace: { step in
                    // 每一步都进日志：用户上报后能直接看到卡在哪一步
                    logs.info("editor.trace", step, meta: ["id": item.id])
                },
                onWebView: { web in
                    webBox.web = web
                }
            )
            // 换掉 id 才会真正重建 WebView
            .id(editorAttempt)
            if !editorReady, editorError == nil, !gaveUp {
                RingSpinner(size: 16, color: .cnBrand)
            }
        }
        .onAppear {
            // 8 秒：自研页面在真机上约 0.5 秒就绪（日志有记录），
            // 20 秒那种宽限是给旧版 1.1MB 页面留的，现在只会让「卡住」更难忍。
            // 记下本次尝试序号：重试之后，上一次的定时器不能再把新页面判死。
            let current = editorAttempt
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                if !editorReady, editorError == nil, editorAttempt == current {
                    gaveUp = true
                    logs.error("editor.timeout", "8 秒未就绪，退回纯文本", meta: ["id": item.id])
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
