import Foundation

/// 编辑器页面与原生端之间的消息协议。
///
/// 单独拎出来的理由很具体：同一块空白页面，可能是脚本没加载、可能初始化抛错、
/// 也可能只是慢。之前这几种都报成一句含糊的话，把排查方向带偏了三次。
/// 字符串散在 Coordinator 的 switch 里就没法单测，放这里可以。
///
/// 约定（JS 侧见 `Tools/build_editor_bundle.py` / `editor-src/src/editor.js`）：
/// - `ready`    页面就绪
/// - `change`   内容变化，带 `value`（Markdown 原文）
/// - `error`    致命，原生端应退回纯文本
/// - `trace`    降级但不致命（例如工具栏折叠没绕开），只写日志
/// - `pickImage` 页面要求选图：WebView 里做不了系统相册，必须交回原生
enum EditorEvent: Equatable {
    case ready
    case change(String)
    case failure(String)
    case degraded(String)
    case pickImage
    case ignored

    static func parse(_ body: Any) -> EditorEvent {
        guard let dict = body as? [String: Any],
              let type = dict["type"] as? String else {
            return .ignored
        }

        switch type {
        case "ready":
            return .ready

        case "change":
            // 没有 value 的 change 是坏消息：照着它写会把笔记清空。
            guard let value = dict["value"] as? String else { return .ignored }
            return .change(value)

        case "error":
            if let message = dict["message"] as? String, !message.isEmpty {
                return .failure(message)
            }
            return .failure("编辑器内部错误")

        case "trace":
            guard let message = dict["message"] as? String, !message.isEmpty else {
                return .ignored
            }
            return .degraded(message)

        case "pickImage":
            return .pickImage

        default:
            return .ignored
        }
    }
}
