import AppIntents
import UIKit

/// 「导入到片记」——给 iOS 快捷指令用的 App 操作。
///
/// 为什么要有它：让快捷指令自己拼 HTTP 请求太容易错（sharecode、请求头、
/// JSON 请求体、URL 编码，任何一处写错都表现为「按了没反应」，而且没有报错可看）。
/// 把这一步收进 App 里，快捷指令里就只需要「选片记的这个操作」。
///
/// `openAppWhenRun = false`：不切到片记前台，用户刷抖音不受打断。
/// 参数留空时会自己读剪贴板，所以两种用法都支持：
///   1. 快捷指令里把「剪贴板」传给参数（推荐，最稳）
///   2. 不传参数，由 App 自己读
struct QuickImportIntent: AppIntent {
    static var title: LocalizedStringResource = "导入到片记"
    static var description = IntentDescription("把视频链接（或整段分享文案）导入片记，后台自动解析并生成摘要。")
    /// 不打开 App：活儿在服务端跑，这里只需要把链接发出去。
    static var openAppWhenRun: Bool = false

    @Parameter(title: "链接或分享文案", description: "留空则自动读取剪贴板")
    var text: String?

    init() {}

    init(text: String?) {
        self.text = text
    }

    func perform() async throws -> some IntentResult {
        var payload = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if payload.isEmpty {
            // UIPasteboard 是 UIKit 的东西，必须在主线程读；
            // perform() 默认在后台，所以显式切一次。
            payload = await MainActor.run {
                (UIPasteboard.general.string ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard !payload.isEmpty else {
            return .result()
        }
        // 静默语义：失败也不抛给用户看，与快捷指令那边的约定一致。
        _ = try? await ClipNoteClient.production.quickImport(text: payload)
        return .result()
    }
}

/// 让「片记」出现在快捷指令的 App 列表里，并预置一条现成的。
struct ClipNoteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: QuickImportIntent(),
            phrases: [
                "用\(.applicationName)保存这条",
                "导入到\(.applicationName)",
            ],
            shortTitle: "导入到片记",
            systemImageName: "square.and.arrow.down.on.square"
        )
    }
}
