import SwiftUI

/// 应用外壳。
///
/// 当前只有两个 Tab：首页、我。
/// 书签与知识库属于第二包——不要为了「看起来完整」先放空 Tab。
struct RootView: View {
    @StateObject private var downloads: DownloadStore
    @StateObject private var library: LibraryStore
    @StateObject private var logs: LogStore

    init() {
        // 日志以本地为准，error 自动上报。网络不通时本地文件还在——
        // 那正是最需要日志的时候，所以不能只依赖服务端。
        let uploader: @Sendable ([LogEntry]) async -> Void = { entries in
            await ClipNoteClient.production.uploadLogs(entries)
        }
        let logStore = LogStore(uploader: uploader)
        _logs = StateObject(wrappedValue: logStore)
        _library = StateObject(wrappedValue: LibraryStore(client: .production, log: logStore))
        _downloads = StateObject(wrappedValue: DownloadStore(log: logStore))
    }

    var body: some View {
        TabView {
            NavigationStack {
                HomeScreen()
            }
            .tabItem { Label("首页", systemImage: "house.fill") }

            NavigationStack {
                MeScreen()
            }
            .tabItem { Label("我", systemImage: "person.fill") }
        }
        .tint(Color.cnBrand)
        .environmentObject(downloads)
        .environmentObject(library)
        .environmentObject(logs)
        // 首帧就拉一次库。失败会落到首页的失败态，也会进日志。
        .task {
            // 启动日志放在这里而不是 init：View 的 init 会被调用多次，
            // 放 init 里会往日志文件写一串重复的「启动」。
            logs.info("app.launch", "启动", meta: ["version": "8.0.0 (1)"])
            await library.reload()
        }
    }
}

#Preview("浅色") {
    RootView().preferredColorScheme(.light)
}

#Preview("深色") {
    RootView().preferredColorScheme(.dark)
}
