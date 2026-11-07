import SwiftUI
import WebKit

/// Markdown 编辑区（Toast UI Editor，随包离线）。
///
/// 为什么是 WebView：要做工具栏、表格、代码块、实时预览，原生等于自己写一个
/// Markdown 编辑器；Toast UI 是成熟方案，UMD 单文件，不依赖网络。
///
/// 为什么做成"组件"而不是"页面"：它嵌在笔记页里当一种编辑模式，
/// 跳转到另一页再回来，用户会丢失上下文，也多一次导航。
struct MarkdownWebView: UIViewRepresentable {
    @Binding var markdown: String
    var initial: String
    var onReady: () -> Void
    var onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        // 初值用注入而不是 URL 参数：正文可能上千字，
        // 拼进 file:// 的 query 会被截断，也不好转义。
        let encoded = (try? JSONEncoder().encode(initial))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        config.userContentController.addUserScript(WKUserScript(
            source: "window.__INITIAL_MARKDOWN__ = \(encoded);",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        config.userContentController.add(context.coordinator, name: "editor")

        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.keyboardDismissMode = .interactive

        if let url = Self.editorURL() {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    /// 资源可能被 xcodegen 拍平到 bundle 根，也可能保留 editor 子目录。
    /// 两种都试一次——实测打包结果是拍平的，但不想把这个事实写死。
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

            DispatchQueue.main.async {
                switch type {
                case "ready":
                    self.parent.onReady()
                case "error":
                    self.parent.onError(body["message"] as? String ?? "编辑器内部错误")
                case "change":
                    if let value = body["value"] as? String {
                        self.parent.markdown = value
                    }
                default:
                    break
                }
            }
        }
    }
}
