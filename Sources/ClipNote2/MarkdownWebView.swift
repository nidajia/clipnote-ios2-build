import SwiftUI
import WebKit

/// Markdown 编辑区（Toast UI Editor，随包离线）。
///
/// 两次"一直转圈"之后定的规矩：**每一步都要留痕**。
/// WebView 的失败模式太多（文件没找到、脚本没加载、JS 抛错、消息没送达），
/// 而界面上它们长得完全一样。所以导航回调、JS 错误、探针结果全部写进运行日志，
/// 用户上报日志后能直接看到卡在哪一步。
struct MarkdownWebView: UIViewRepresentable {
    @Binding var markdown: String
    var initial: String
    var onReady: () -> Void
    var onError: (String) -> Void
    /// 每一步的状态回调，供上层写日志。
    var onTrace: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.startedAt = Date()
        let config = WKWebViewConfiguration()

        let encoded = (try? JSONEncoder().encode(initial))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        config.userContentController.addUserScript(WKUserScript(
            source: "window.__INITIAL_MARKDOWN__ = \(encoded);",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        config.userContentController.add(context.coordinator, name: "editor")

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.keyboardDismissMode = .interactive

        guard let url = Self.bundleURL() else {
            onTrace("包里没有 editor-bundle.html")
            DispatchQueue.main.async { self.onError("编辑器页面缺失（editor-bundle.html）") }
            return web
        }
        let sizeKB = ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) / 1024
        onTrace("页面 \(url.lastPathComponent) \(sizeKB)KB")
        onTrace("开始加载 \(url.lastPathComponent)")
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    /// 单文件页面：CSS 与 JS 全部内联（见 Tools/build_editor_bundle.py）。
    ///
    /// 为什么不再用「HTML + 同目录 js/css」：真机上页面能加载完成，
    /// 但同目录脚本不执行，`toastui` 未定义且无任何错误回调——连试三版都卡在这。
    /// 单文件没有子资源请求，这类失败就整类消失。
    static func bundleURL() -> URL? {
        Bundle.main.url(forResource: "editor-bundle", withExtension: "html")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private let parent: MarkdownWebView
        /// 用于区分「慢」和「不执行」：每个节点都带上距离创建过去的毫秒数。
        var startedAt = Date()

        private func elapsed() -> Int {
            Int(Date().timeIntervalSince(startedAt) * 1000)
        }

        init(_ parent: MarkdownWebView) {
            self.parent = parent
        }

        // MARK: 导航

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onTrace("页面加载完成 \(elapsed())ms")

            // 不信任 JS 的 ready 消息：它可能因为处理器没注册、脚本抛错而永远不来。
            // 页面加载完主动探一次，把真实状态写进日志。
            // 分两步探：`toastui 存在但 Editor 没有`是这次真正的故障形态
            // （npm 的 dist 缺 prosemirror，运行到一半抛错），
            // 之前两种都报成"未定义"，把排查方向带偏了三次。
            webView.evaluateJavaScript(
                "[typeof toastui, (typeof toastui !== 'undefined' ? typeof toastui.Editor : '')]"
            ) { value, error in
                if let error {
                    self.parent.onTrace("探针失败：\(error.localizedDescription)")
                    self.parent.onError("编辑器脚本没有就绪：\(error.localizedDescription)")
                    return
                }
                let kinds = (value as? [String]) ?? []
                let toastuiKind = kinds.count > 0 ? kinds[0] : "?"
                let editorKind = kinds.count > 1 ? kinds[1] : "?"
                self.parent.onTrace("探针 toastui=\(toastuiKind) Editor=\(editorKind) \(self.elapsed())ms")
                if toastuiKind == "undefined" {
                    self.parent.onError("编辑器脚本没有加载（toastui 未定义）")
                } else if editorKind != "function" {
                    self.parent.onError("编辑器脚本不完整（toastui 在，Editor=" + editorKind + "）")
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                     withError error: Error) {
            parent.onTrace("加载失败：\(error.localizedDescription)")
            parent.onError("页面加载失败：\(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            parent.onTrace("初期加载失败：\(error.localizedDescription)")
            parent.onError("页面加载失败：\(error.localizedDescription)")
        }

        // MARK: 桥

        func userContentController(_ controller: WKUserContentController,
                                  didReceive message: WKScriptMessage) {
            // 先解析成值类型再切线程：解析是纯函数，可以单测（见 EditorEvent）。
            let event = EditorEvent.parse(message.body)

            DispatchQueue.main.async {
                switch event {
                case .ready:
                    self.parent.onTrace("JS ready \(self.elapsed())ms")
                    self.parent.onReady()
                case .change(let value):
                    self.parent.markdown = value
                case .failure(let text):
                    self.parent.onTrace("JS 错误：\(text)")
                    self.parent.onError(text)
                case .degraded(let text):
                    // 页面里的「降级但不致命」信息。写进日志，但不触发退回纯文本：
                    // 工具栏折叠没绕开这类问题，用户仍然能用 ⋯ 展开，不该因此丢掉富文本。
                    self.parent.onTrace("JS 降级：\(text)")
                case .ignored:
                    self.parent.onTrace("收到无法解析的消息")
                }
            }
        }
    }
}
