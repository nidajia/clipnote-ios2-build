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

    init(state: String, appearance: ColorScheme?) {
        self.state = state
        self.appearance = appearance
        _tab = State(initialValue: state == "me" ? 1 : 0)

        // 每次启动用独立的临时目录：否则上一次截图种下的「已下载」
        // 会留在 Documents 里，把这一次的「未下载」状态带脏。
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-\(UUID().uuidString)", isDirectory: true)
        let store = DownloadStore(directory: sandbox)

        let lib = LibraryStore(client: nil)
        if let data = Item.sampleData {
            try? lib.loadFixture(data)
        }
        switch state {
        case "empty":
            lib.applyEmpty()
        case "failed":
            lib.markFailed("服务端返回的不是数据。多半是线上版本还没更新。")
        case "loading":
            break // 保持 idle，首页即加载态
        default:
            break
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
    }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                HomeScreen(initialSelection: detailItem)
            }
            .tabItem { Label("首页", systemImage: "house.fill") }
            .tag(0)

            NavigationStack {
                MeScreen()
            }
            .tabItem { Label("我", systemImage: "person.fill") }
            .tag(1)
        }
        .tint(Color.cnBrand)
        .preferredColorScheme(appearance)
        .environmentObject(downloads)
        .environmentObject(library)
    }
}
