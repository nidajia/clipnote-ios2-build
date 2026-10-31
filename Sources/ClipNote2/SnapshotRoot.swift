import SwiftUI

/// 仅用于 CI 截图：通过启动参数直接进入指定状态。
///
/// 正常启动走 `RootView`，不经过这里。
/// 之所以要这个入口，是因为 `ImageRenderer` 画不出 `List` / `TabView`
/// （UIKit 背书的容器会整张渲染成系统「不可用」占位符），
/// 只能真的把 App 启动起来再截屏。
struct SnapshotRoot: View {
    var state: String
    var appearance: ColorScheme?

    @State private var tab: Int

    init(state: String, appearance: ColorScheme?) {
        self.state = state
        self.appearance = appearance
        _tab = State(initialValue: state == "me" ? 1 : 0)
    }

    private var items: [Item] {
        state == "empty" ? [] : Item.demoLibrary
    }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                HomeScreen(items: items)
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
    }
}
