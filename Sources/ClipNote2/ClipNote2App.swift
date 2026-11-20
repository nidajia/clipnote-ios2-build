import SwiftUI

@main
struct ClipNote2App: App {

    /// 只为一件事存在：告诉系统「现在支持哪些方向」。
    /// 纯 SwiftUI 的 App 没有 AppDelegate，而方向这个信息只有它能给。
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// CI 截图用的启动参数；正常启动时为 nil
    private let snapshot: (state: String, appearance: ColorScheme?)?

    init() {
        // 封面图默认缓存只有几百 KB，翻两页就被挤掉，于是每次刷新都重新下载——
        // 用户看到的就是「图片半天才出来」。调大内存与磁盘缓存，二次访问直接命中。
        URLCache.shared = URLCache(memoryCapacity: 32 * 1024 * 1024,
                                   diskCapacity: 256 * 1024 * 1024,
                                   diskPath: "clipnote-cover-cache")

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
