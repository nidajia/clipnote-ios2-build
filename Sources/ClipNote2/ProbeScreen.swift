import SwiftUI
import WebKit

/// 诊断页：只回答一个问题——**这个 WebView 能不能执行内联 JS**。
///
/// 不是功能代码，是排障工具。留着的理由：编辑器那条链路已经三次因为
/// "分不清是慢、是没加载、还是脚本没执行"而白跑，下次再遇到同类问题，
/// 这张页面能在 4 分钟内给出边界。
struct ProbeScreen: View {
    var body: some View {
        WebView(url: Bundle.main.url(forResource: "probe", withExtension: "html"))
            .ignoresSafeArea(edges: .bottom)
    }

    private struct WebView: UIViewRepresentable {
        var url: URL?

        func makeUIView(context: Context) -> WKWebView {
            let config = WKWebViewConfiguration()
            let web = WKWebView(frame: .zero, configuration: config)
            if let url {
                web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            }
            return web
        }

        func updateUIView(_ web: WKWebView, context: Context) {}
    }
}
