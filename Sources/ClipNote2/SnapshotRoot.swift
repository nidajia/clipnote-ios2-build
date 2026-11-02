import SwiftUI

/// 仅用于 CI 截图：通过启动参数直接进入指定状态。
///
/// 正常启动走 `RootView`，不经过这里，也不碰这里的样本库。
/// 之所以要这个入口，是因为 `ImageRenderer` 画不出 `List` / `TabView`
/// （UIKit 背书的容器会整张渲染成系统「不可用」占位符），
/// 只能真的把 App 启动起来再截屏。
///
/// 数据来自 bundle 里的 `library-sample.json`，走的是**与线上相同的解码器**。
/// 于是每张截图都在同时证明两件事：解码没错，渲染没错。而且不依赖网络，
/// 同一份代码任何时候截出来都一样——这是截图能当证据的前提。
struct SnapshotRoot: View {
    private let state: String
    private let appearance: ColorScheme?
    private let detailItem: Item?

    @State private var tab: Int
    @StateObject private var downloads: DownloadStore
    @StateObject private var library: LibraryStore
    @StateObject private var logs: LogStore

    init(state: String, appearance: ColorScheme?) {
        self.state = state
        self.appearance = appearance
        _tab = State(initialValue: state == "me" ? 1 : 0)

        // 每次启动用独立的临时目录：否则上一次截图种下的「已下载」
        // 会留在 Documents 里，把这一次的「未下载」状态带脏。
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-\(UUID().uuidString)", isDirectory: true)
        // 截图用独立的 LogStore：不写真实日志、不上报，避免把假事件灌进服务端
        let logStore = LogStore(directory: sandbox, uploader: nil)
        // 「我」和日志页需要内容可看，否则永远是空态
        if state == "logs" || state == "me" {
            logStore.info("app.launch", "启动", meta: ["version": AppVersion.text])
            logStore.info("library.loaded", "同步完成 8 条",
                          meta: ["count": "8", "version": "lv_1793265909_1", "ms": "412"])
            logStore.info("import.created", "导入成功", meta: ["created": "1", "ms": "1913"])
            logStore.warn("playback.unavailable", "该内容没有视频流",
                          meta: ["id": "seed0000000005"])
            logStore.error("network.failed", "连不上服务端。请求超时。",
                           meta: ["path": "/api/v2/library", "kind": "transport", "ms": "20013"])
        }
        let store = DownloadStore(directory: sandbox, log: logStore)

        // 传 sandbox 作为缓存目录：不让某次真实运行留下的缓存混进截图，
        // 每张图的数据只来自 bundle 里的 fixture。
        let lib = LibraryStore(client: nil, cacheDirectory: sandbox)
        // 注意顺序：**只有需要数据的状态才加载**。
        // 之前先无条件 loadFixture 再切状态，结果 loading / failed 两张图都带着
        // 一屏数据，和列表图长得一模一样——截图「拍到了」，但拍的是别的东西。
        switch state {
        case "empty":
            lib.applyEmpty()
        case "failed":
            lib.markFailed("服务端返回的不是数据。多半是线上版本还没更新。")
        case "loading":
            break // 保持 idle，首页即加载态
        default:
            if let data = Item.sampleData {
                try? lib.loadFixture(data)
            }
        }

        var detail: Item?
        if state.hasPrefix("detail") {
            detail = state == "detail-note"
                ? lib.items.first { $0.kind == .note }
                : lib.items.first
            if let id = detail?.id {
                switch state {
                case "detail-downloading": store.seedDownloading(id, value: 0.62)
                case "detail-downloaded": store.seedDownloaded(id)
                default: break
                }
            }
        }
        self.detailItem = detail

        _downloads = StateObject(wrappedValue: store)
        _library = StateObject(wrappedValue: lib)
        _logs = StateObject(wrappedValue: logStore)
    }

    var body: some View {
        Group {
            if state == "logs" {
                // 日志页在「我」里，截图没法点进去，直接作为根呈现
                NavigationStack { LogScreen() }
            } else if state == "trash" {
                NavigationStack { TrashScreen(previewItems: previewTrash) }
            } else if state.hasPrefix("onboarding") {
                // 引导是首启才出现的，截图靠 previewPhase 直接停到某一帧。
                // 真机上这条路径由 RootView 的 AppStorage 判定，与这里同一套视图。
                OnboardingFlow(previewPhase: onboardingPhase)
            } else if state == "player-landscape" {
                // 直接作为根呈现，不走 fullScreenCover：截图不关心转场动画，
                // 只关心这一页在横屏尺寸下排得对不对。方向由 PlayerScreen
                // 自己的 onAppear 去要，和真机走的是同一段代码。
                if let item = library.items.first {
                    PlayerScreen(item: item, player: nil)
                } else {
                    Color.black
                }
            } else {
                tabs
            }
        }
        .tint(Color.cnBrand)
        .preferredColorScheme(appearance)
        .environmentObject(downloads)
        .environmentObject(library)
        .environmentObject(logs)
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            NavigationStack {
                HomeScreen(
                    initialSelection: detailItem,
                    detailPrepare: detailPrepare,
                    showsImport: state == "import"
                )
            }
            .tabItem { Label("首页", systemImage: "house.fill") }
            .tag(0)

            NavigationStack {
                MeScreen()
            }
            .tabItem { Label("我", systemImage: "person.fill") }
            .tag(1)
        }
    }

    /// 引导截图停在的那一帧。`.welcome` 用 nil 表示（init 默认值）。
    private var onboardingPhase: SyncPhase? {
        switch state {
        case "onboarding-syncing":
            return .syncing(.connecting)
        case "onboarding-done":
            // 条数取真实样本的条数，不写死一个数字——
            // 否则改了 fixture，截图会开始说谎
            return .done(count: library.items.count, milliseconds: 620)
        case "onboarding-failed":
            return .failed(message: "连不上服务端。请求超时。", step: .connecting)
        default:
            return nil
        }
    }

    /// 回收站截图用的两条已删条目
    private var previewTrash: [APILibraryItem] {
        guard let data = Item.sampleData,
              let lib = try? JSONDecoder().decode(APILibrary.self, from: data) else { return [] }
        return lib.items.prefix(2).enumerated().map { index, item in
            var copy = item
            copy.deletedAt = 1_793_430_625_000 - index * 86_400_000
            return copy
        }
    }

    /// 只给 `detail-ready` 用：模拟「已经取到播放地址」，
    /// 好让按钮下面那行「720P · 约 124 MB」有截图可对照。
    private var detailPrepare: DetailScreen.PrepareState? {
        guard state == "detail-ready" else { return nil }
        return .ready(APIPlaybackPayload(
            url: "https://clipnote.app.workbuddy.host/proxy?u=sample.mp4",
            mimeType: "video/mp4",
            quality: "720P",
            bytes: 130_257_119,
            expiresAt: 0
        ))
    }
}
