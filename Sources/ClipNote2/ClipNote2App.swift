import SwiftUI

@main
struct ClipNote2App: App {

    /// 只为一件事存在：告诉系统「现在支持哪些方向」。
    /// 纯 SwiftUI 的 App 没有 AppDelegate，而方向这个信息只有它能给。
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// CI 截图用的启动参数；正常启动时为 nil
    private let snapshot: (state: String, appearance: ColorScheme?)?

    init() {
        let args = ProcessInfo.processInfo.arguments

        func value(_ flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
            return args[index + 1]
        }

        if let state = value("-snapshotState") {
            let appearance: ColorScheme?
            switch value("-snapshotAppearance") {
            case "dark": appearance = .dark
            case "light": appearance = .light
            default: appearance = nil
            }
            snapshot = (state, appearance)
        } else {
            snapshot = nil
        }
    }

    var body: some Scene {
        WindowGroup {
            if let snapshot {
                SnapshotRoot(state: snapshot.state, appearance: snapshot.appearance)
            } else {
                RootView()
            }
        }
    }
}
