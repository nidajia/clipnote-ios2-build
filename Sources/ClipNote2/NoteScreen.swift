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
    /// 新建的笔记：模板已经铺好，光标直接落在文末，用户接着写。
    /// 不这么做的话，新建完光标停在标题前面，第一下打字会插进「# 标题」里。
    var beginAtEnd: Bool = false

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
    /// 「补充细节」的两种模式：只用原文 / 允许查资料。
    /// 用对话框而不是两个按钮：多一个按钮就多一个常驻入口，
    /// 而「要不要查资料」是每次都可能变的判断，不适合钉死成一个开关。
    @State private var showExpandMode = false
    /// 键盘弹起时不显示动作条：它和底部格式栏叠在一起会吃掉近 90pt 编辑区，
    /// 而打字时也用不到 AI。有预览时例外——那是用户正要处理的结果。
    @State private var keyboardUp = false

    init(item: Item, beginAtEnd: Bool = false) {
        self.item = item
        self.beginAtEnd = beginAtEnd
        _text = State(initialValue: item.note)
    }

    private var dirty: Bool { text != item.note }
    /// 库里最新的那条。保存之后 `updatedAt` 会变，而 `item` 是进页面那一刻的副本。
    private var current: Item { library.items.first { $0.id == item.id } ?? item }
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
            // 从视频进来写笔记时，要能回去看那条视频——否则笔记页是个死路。
            // 笔记条目本身没有视频，就不显示这个入口。
            ToolbarItem(placement: .navigationBarLeading) {
                if item.kind == .video {
                    NavigationLink {
                        DetailScreen(item: item)
                    } label: {
                        Text("视频").font(.cnChip)
                    }
                }
            }
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
        .confirmationDialog("补充细节", isPresented: $showExpandMode, titleVisibility: .visible) {
            Button("只用原文的信息") { Task { await prepare(.expand(external: false)) } }
            Button("允许查外部资料（会标注）") { Task { await prepare(.expand(external: true)) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("没有选中文字时会处理全文。两种模式都不会改动你写的句子；查资料的补充会标「（外部）」。")
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
                    switch action {
                    case .custom:
                        // 自由指令要先问要改什么，不能拿空指令直接发出去
                        aiDraft = ""
                        showCustomPrompt = true
                    case .expand:
                        // 两种模式由用户当场选，不替他决定要不要查资料
                        showExpandMode = true
                    default:
                        Task { await prepare(action) }
                    }
                }
            }
        }
    }

    /// 先取选区，再决定处理范围。
    /// 选哪些文字、处理全文还是选区，都在这一步定下来，后续不再变。
    private func prepare(_ action: NoteAIAction) async {
        guard let web = webBox.web else { return }
        // 用 `__scope()` 而不是 `__getSelection()`：
        // 后者在 WebView 失焦（点了原生按钮）之后只能返回空串，
        // 于是「选了一段」会被判成「整篇」——这正是那段对话里最刺眼的问题。
        let raw = try? await web.evaluateJavaScript("window.__scope()")
        let scope = Self.parseScope(raw)
        logs.info("note.ai.scope", "作用域已确定", meta: [
            "id": item.id,
            "kind": scope.kind,
            "chars": String(scope.text.count),
        ])
        await run(action, selection: scope.text, range: scope.range)
    }

    /// 解析 `__scope()` 的返回。
    ///
    /// `kind` 是唯一的作用域判据：`doc` 才处理整篇。
    /// 不再用「text 是不是空」猜——空串有两种含义（真没选、选区丢了），
    /// 而这两种必须区分。
    static func parseScope(_ raw: Any?) -> (text: String, range: NoteAIRange?, kind: String) {
        guard let dict = raw as? [String: Any] else { return ("", nil, "doc") }
        let kind = (dict["kind"] as? String) ?? "doc"
        let text = (dict["text"] as? String) ?? ""
        let from = (dict["from"] as? Int) ?? 0
        let to = (dict["to"] as? Int) ?? 0
        guard kind != "doc", !text.isEmpty, to > from else { return ("", nil, "doc") }
        return (text, NoteAIRange(from: from, to: to, text: text), kind)
    }

    private func run(_ action: NoteAIAction, selection: String, range: NoteAIRange?) async {
        // 全文优先问编辑器要最新内容：`text` 是走 350ms 防抖回传的，
        // 用户刚打完字就去点 AI 时它可能还差一个字。
        var content = selection
        if content.isEmpty, let web = webBox.web {
            content = ((try? await web.evaluateJavaScript("window.__getMarkdown()")) as? String) ?? text
        }
        // 判据是「有没有范围」，不是「内容空不空」
        let scopeIsDoc = range == nil
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            aiError = "这条笔记还是空的，先写一点再让 AI 处理"
            return
        }
        // 短内容模型确实无从下手。与其发一次请求再报「没改动」，不如先说清楚。
        guard !NoteAIQuality.isTooShortFor(action, content: content) else {
            aiError = "内容太短（\(content.count) 字），「\(action.title)」没有可改的余地。多写两句再试。"
            logs.info("note.ai.too_short", "内容过短，未发请求", meta: [
                "id": item.id, "action": action.title, "chars": String(content.count),
            ])
            return
        }
        aiRunning = true
        aiError = nil
        aiPreview = nil
        // 把模型与长度写进日志：出问题时能一眼看出是「配了哪个模型」和「它回了几字」，
        // 不用再来回猜。
        logs.info("note.ai.request", "\(action.title) 请求已发出", meta: [
            "id": item.id,
            "model": aiConfig.model,
            "scope": scopeIsDoc ? "doc" : "selection",
            "chars": String(content.count),
        ])
        do {
            let result = try await NoteAssistant(config: aiConfig)
                .run(action: action, content: content)
            aiRunning = false
            logs.info("note.ai.reply", "收到回复", meta: [
                "id": item.id,
                "model": aiConfig.model,
                "chars": String(result.markdown.count),
                "identical": NoteAIQuality.isIdentical(result.markdown, to: content) ? "1" : "0",
            ])

            // 原样返回不等于成功。弹一张和原文一样的预览卡让用户点「采用」，
            // 只会让人以为功能坏了——直接说清楚，并给出下一步怎么改。
            guard !NoteAIQuality.isIdentical(result.markdown, to: content) else {
                aiError = NoteAIQuality.identicalMessage(length: content.count)
                logs.info("note.ai.noop", "模型未改动内容", meta: [
                    "id": item.id, "action": action.title, "model": aiConfig.model,
                ])
                return
            }

            var warning: String?
            if action.mayAddContent {
                warning = action.isReport
                    ? nil
                    : "模型可能加入不准确的内容，采用前请过一遍"
            }
            if action == .outline, NoteAIQuality.didNotCompress(result.markdown, from: content) {
                warning = "结果没比原文短，可能没有真正压缩，采用前请确认"
            }
            if action == .tidy, NoteAIQuality.didOverSplit(result.markdown, from: content) {
                // 用户的原话：「相当于把每句话打个回车就结束了」。
                // 提示词已经写明禁止，但模型仍可能这么干，所以机器再判一次。
                warning = "段落被拆得比原文多不少，可能只是给每句加了回车，采用前请对比"
            }
            if action == .summary, NoteAIQuality.summaryTooThin(result.markdown, from: content) {
                warning = "总结偏短，可能只覆盖了开头，建议放弃后重试"
            }
            if action.mustKeepText, result.textChanged {
                // 「整理排版」的定义就是不改字。机器能验，就不该只靠提示词。
                warning = "文字有改动——「整理排版」不应该改字，建议放弃后重试"
            }
            aiPreview = NoteAIPreview(
                action: action,
                // 把字数写进范围里：用户要能一眼看出「这次动的是 42 字还是 383 字」
                scope: scopeIsDoc ? "全文 · \(content.count) 字" : "选区 · \(content.count) 字",
                selection: selection,
                range: range,
                markdown: result.markdown,
                diff: TextDiff.segments(from: content, to: result.markdown),
                basis: result.basis,
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
        // 核实结果是一份报告，写回正文没有意义——卡片上也只有「知道了」。
        guard !preview.isReport else {
            aiPreview = nil
            return
        }

        // 选区结果按**当时的位置**写，不按「当前选区」写。
        // 生成要几十秒，这期间用户点一下正文，当前选区就已经不是那段了。
        // 位置核对在 JS 里做：那里的文字必须还是当初那段，否则拒绝。
        let argument = Self.jsString(preview.markdown)
        var call = "window.__replaceAll(\(argument))"
        if let range = preview.range {
            call = "window.__applyScope(\(argument), \(range.from), \(range.to), \(Self.jsString(range.text)))"
        }
        let returned = try? await web.evaluateJavaScript(call)
        if preview.range == nil {
            guard (returned as? Bool) == true else {
                aiError = "写入没有生效（编辑器拒绝了这次替换），正文未改动。"
                logs.error("note.ai.apply_failed", "整篇替换被拒绝", meta: ["id": item.id])
                return
            }
        } else {
            let result = returned as? [String: Any]
            guard (result?["ok"] as? Bool) == true else {
                let reason = (result?["reason"] as? String) ?? "apply_failed"
                aiError = reason == "range_changed"
                    ? "那段文字已经变了，这条结果没有采用。重新选中后再试一次。"
                    : "写入没有生效，正文未改动。"
                logs.error("note.ai.apply_failed", "范围回写被拒绝：\(reason)", meta: ["id": item.id])
                aiPreview = nil
                return
            }
        }

        aiPreview = nil
        aiError = nil
        let after = ((try? await web.evaluateJavaScript("window.__getMarkdown()")) as? String) ?? ""
        logs.info("note.ai.applied", "\(preview.action.title) 已采用", meta: [
            "id": item.id,
            "scope": preview.range == nil ? "doc" : "selection",
            "before": String(preview.markdown.count),
            "after": String(after.count),
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
                    if beginAtEnd {
                        webBox.web?.evaluateJavaScript("window.__focusEnd()") { _, _ in }
                    }
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
            if let stamp = timeStamp {
                Text("·").font(.cnCaption).foregroundStyle(Color.cnInk3)
                Text(stamp)
                    .font(.cnCaption)
                    .foregroundStyle(Color.cnInk3)
                    .lineLimit(1)
            }
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

    /// 「修改 11-11 00:10」，新建的写成「创建 …」。
    ///
    /// 用户的原话是「笔记也不显示啥时候创建和修改的」。
    /// 这里只放一个时间，不给两行字：状态栏是给人扫一眼的，不是档案页。
    private var timeStamp: String? {
        guard let date = current.updatedAt ?? current.createdAt else { return nil }
        let label = current.updatedAt == nil ? "创建" : "修改"
        return "\(label) \(HomeScreen.stamp(date))"
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
