import SwiftUI

/// 应用外壳。
///
/// 当前只有两个 Tab：首页、我。
/// 书签与知识库属于第二包——不要为了「看起来完整」先放空 Tab。
///
/// 第一次启动先走引导（画布 01 / 02）：欢迎 → 首次同步 → 进首页。
/// 「首次」用 `AppStorage` 记，只出现一次；想再看一遍得删掉 App 重装。
struct RootView: View {
    /// 引导走完才为 true。钥匙存在 UserDefaults，重装才会重置。
    @AppStorage("clipnote.onboarded") private var onboarded = false

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
        // 方向切换失败也要进日志：用户只会觉得「点了没反应」，
        // 而这条日志能说明是系统拒绝了旋转请求。
        OrientationLock.shared.logger = logStore
        _logs = StateObject(wrappedValue: logStore)
        _library = StateObject(wrappedValue: LibraryStore(client: .production, log: logStore))
        _downloads = StateObject(wrappedValue: DownloadStore(log: logStore))
    }

    var body: some View {
        Group {
            if onboarded {
                tabs
            } else {
                OnboardingFlow {
                    onboarded = true
                }
            }
        }
        .environmentObject(downloads)
        .environmentObject(library)
        .environmentObject(logs)
        // 启动日志放在这里而不是 init：View 的 init 会被调用多次，
        // 放 init 里会往日志文件写一串重复的「启动」。
        .task {
            logs.info("app.launch", "启动", meta: ["version": AppVersion.text])
        }
    }

    private var tabs: some View {
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
        // 首次同步由引导页发起（它要在过程中点亮步骤行）。这里只补一次：
        // 判据是「本次进程里还没同步过」，而不是「phase 是不是 idle」——
        // 有缓存时启动就是 loaded，那样会变成「有缓存就永不刷新」。
        // 刷新期间界面显示的是缓存列表，不会闪加载态。
        .task {
            guard library.lastSyncAt == nil else { return }
            await library.reload()
        }
    }
}

// `#Preview` 宏要求 iOS 17 部署目标。这里降到 16，所以用老的 PreviewProvider——
// 反正预览只在 Xcode 里用，行为一样。
struct RootViewPreviews: PreviewProvider {
    static var previews: some View {
        Group {
            RootView()
                .preferredColorScheme(.light)
                .previewDisplayName("浅色")
            RootView()
                .preferredColorScheme(.dark)
                .previewDisplayName("深色")
        }
    }
}
