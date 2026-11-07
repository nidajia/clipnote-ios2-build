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

        let (url, trace) = Self.preparedIndexURL()
        for line in trace { onTrace(line) }
        guard let url else {
            onTrace("找不到可加载的 index.html")
            DispatchQueue.main.async { self.onError("编辑器页面没有准备好（资源缺失）") }
            return web
        }
        onTrace("开始加载 \(url.lastPathComponent)")
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    /// 编辑器资源清单（被 xcodegen 拍平到 bundle 根）。
    static let assetNames = [
        "index.html",
        "toastui-editor.js",
        "toastui-editor.css",
        "toastui-editor-dark.css",
        "zh-cn.js",
    ]

    /// 准备可加载的页面地址。
    ///
    /// **关键：不直接从 app bundle 里 loadFileURL。**
    /// WKWebView 对 `file://` 子资源的读取受沙盒限制，从 bundle 根加载 HTML 时，
    /// 同目录的 js/css 可能被静默拒绝——表现就是白屏、JS 一行都不执行，
    /// 而且没有任何错误回调。这类失败极难从现象反推。
    ///
    /// 所以先把资源复制到 Caches/editor，再从那里加载：
    /// 该目录在进程自己的容器里，读权限没有歧义。
    /// 复制只做一次（按文件大小判断是否需要重刷）。
    static func preparedIndexURL() -> (URL?, [String]) {
        var trace: [String] = []
        let fm = FileManager.default
        guard let cacheRoot = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return (nil, ["拿不到 Caches 目录"])
        }
        let dir = cacheRoot.appendingPathComponent("editor", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        for name in assetNames {
            let bundled = Bundle.main.url(forResource: name, withExtension: nil)
                ?? Bundle.main.url(forResource: (name as NSString).deletingPathExtension,
                                  withExtension: (name as NSString).pathExtension,
                                  subdirectory: "editor")
            guard let bundled else {
                trace.append("缺资源：\(name)")
                continue
            }
            let target = dir.appendingPathComponent(name)
            let sameSize = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                == (try? bundled.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            if !sameSize {
                try? fm.removeItem(at: target)
                do {
                    try fm.copyItem(at: bundled, to: target)
                    trace.append("复制 \(name)")
                } catch {
                    trace.append("复制失败 \(name)：\(error.localizedDescription)")
                }
            }
        }

        let index = dir.appendingPathComponent("index.html")
        guard fm.fileExists(atPath: index.path) else {
            return (nil, trace + ["没有 index.html"])
        }
        return (index, trace)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private let parent: MarkdownWebView

        init(_ parent: MarkdownWebView) {
            self.parent = parent
        }

        // MARK: 导航

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onTrace("页面加载完成")

            // 不信任 JS 的 ready 消息：它可能因为处理器没注册、脚本抛错而永远不来。
            // 页面加载完主动探一次，把真实状态写进日志。
            webView.evaluateJavaScript(
                "typeof toastui !== 'undefined' && !!toastui.Editor"
            ) { value, error in
                if let error {
                    self.parent.onTrace("探针失败：\(error.localizedDescription)")
                    self.parent.onError("编辑器脚本没有就绪：\(error.localizedDescription)")
                    return
                }
                let ok = (value as? Bool) ?? false
                self.parent.onTrace("探针 toastui=\(ok)")
                if !ok {
                    self.parent.onError("编辑器脚本没有加载（toastui 未定义）")
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
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String else {
                parent.onTrace("收到无法解析的消息")
                return
            }

            DispatchQueue.main.async {
                switch type {
                case "ready":
                    self.parent.onTrace("JS ready")
                    self.parent.onReady()
                case "error":
                    let message = body["message"] as? String ?? "编辑器内部错误"
                    self.parent.onTrace("JS 错误：\(message)")
                    self.parent.onError(message)
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
