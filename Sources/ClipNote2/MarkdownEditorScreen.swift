import SwiftUI
import WebKit

/// Markdown 编辑器（Toast UI Editor，随包离线分发）。
///
/// 为什么用 WebView 而不是原生富文本：
/// 原生 `TextEditor` 只有纯文本；要做工具栏、表格、代码块、实时预览，
/// 等于自己写一个 Markdown 编辑器——那正是用户明确否掉的事。
/// Toast UI 是成熟的现成方案，UMD 单文件，不依赖网络。
///
/// 代价写在明处：键盘与选区和原生不完全一致，粘贴图片暂不支持（附件本期不做）。
struct MarkdownEditorScreen: View {
    var item: Item

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var logs: LogStore

    @State private var text: String
    @State private var ready = false
    @State private var saving = false
    @State private var failed: String?

    init(item: Item) {
        self.item = item
        _text = State(initialValue: item.note)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let failed {
                Text(failed)
                    .font(.cnMeta)
                    .foregroundStyle(Color.cnRed)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Metric.pagePad)
                    .padding(.vertical, 6)
            }

            MarkdownWebView(
                markdown: $text,
                initial: item.note,
                onReady: { ready = true },
                // 离屏保存：用户按返回时可能还有一次 change 在路上，
                // 所以每次内容变化都记一次，而不是只依赖「完成」按钮。
                onChange: { _ in }
            )
            .overlay(alignment: .center) {
                if !ready {
                    RingSpinner(size: 16, color: .cnBrand)
                }
            }
        }
        .background(Color.cnBg)
        .navigationTitle("编辑笔记")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(saving ? "保存中…" : "保存") {
                    Task { await save() }
                }
                .font(.cnChip)
                .disabled(saving || !ready)
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let ok = await library.saveNote(id: item.id, note: text)
        if ok {
            logs.info("note.md_saved", "Markdown 笔记已保存", meta: [
                "id": item.id, "chars": String(text.count),
            ])
            dismiss()
        } else {
            failed = "没保存成功，检查网络后重试。"
        }
    }
}

/// WKWebView 包装。
///
/// 桥只有两个方向：
/// - JS → Swift：`ready`（编辑器初始化完成）与 `change`（内容变了）；
/// - Swift → JS：只在初始化时注入一次初值。
/// 不做双向实时同步——那会形成回环（Swift 设值 → JS 抛 change → Swift 设值）。
struct MarkdownWebView: UIViewRepresentable {
    @Binding var markdown: String
    var initial: String
    var onReady: () -> Void
    var onChange: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        // 初值用注入而不是 URL 参数：正文可能上千字，
        // 拼进 file:// 的 query 会被截断，也不好转义。
        let encoded = (try? JSONEncoder().encode(initial))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        let script = WKUserScript(
            source: "window.__INITIAL_MARKDOWN__ = \(encoded);",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(script)
        config.userContentController.add(context.coordinator, name: "editor")

        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        // 编辑器自己管滚动，外层再滚会打架
        web.scrollView.isScrollEnabled = true
        web.scrollView.keyboardDismissMode = .interactive

        if let url = Self.editorURL() {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    /// 资源可能被 xcodegen 拍平到 bundle 根，也可能保留 editor 子目录。
    /// 两种都试一次，省得以后改打包方式又踩一遍。
    static func editorURL() -> URL? {
        Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "editor")
            ?? Bundle.main.url(forResource: "index", withExtension: "html")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        private let parent: MarkdownWebView

        init(_ parent: MarkdownWebView) {
            self.parent = parent
        }

        func userContentController(_ controller: WKUserContentController,
                                  didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            if type == "ready" {
                parent.onReady()
            } else if type == "change", let value = body["value"] as? String {
                // 回到主线程改 SwiftUI 状态
                DispatchQueue.main.async {
                    self.parent.markdown = value
                    self.parent.onChange(value)
                }
            }
        }
    }
}
