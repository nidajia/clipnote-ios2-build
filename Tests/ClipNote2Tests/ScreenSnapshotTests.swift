import SwiftUI
import XCTest
@testable import ClipNote2

/// 整屏快照。
///
/// 这里要回答的不是「好不好看」，而是三个只能在真实渲染里确认的问题：
/// 1. 行高 72 放进真正的 `List` 后是否仍成立
/// 2. 关掉自带分隔线后，`listRowSeparatorTint` 是否给出想要的线
/// 3. `NavigationStack` / `TabView` 的导航栏与底栏能否被 `ImageRenderer` 画出来
@MainActor
final class ScreenSnapshotTests: XCTestCase {

    /// 带 Tab 栏与导航栏的外壳，与 RootView 保持同构
    private struct Shell<Content: View>: View {
        var initialTab: Int
        let content: Content

        init(initialTab: Int = 0, @ViewBuilder content: () -> Content) {
            self.initialTab = initialTab
            self.content = content()
        }

        @State private var tab: Int? = nil

        var body: some View {
            TabView(selection: Binding(
                get: { tab ?? initialTab },
                set: { tab = $0 }
            )) {
                NavigationStack {
                    content
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
        }
    }

    func testHomeList() throws {
        let view = Shell { HomeScreen(items: Item.demoLibrary) }
        try SnapshotSupport.write(view, name: "home-list", scheme: .light, size: SnapshotSupport.phone)
    }

    func testHomeEmpty() throws {
        let view = Shell { HomeScreen(items: []) }
        try SnapshotSupport.write(view, name: "home-empty", scheme: .light, size: SnapshotSupport.phone)
    }

    func testHomeDark() throws {
        let view = Shell { HomeScreen(items: Item.demoLibrary) }
        try SnapshotSupport.write(view, name: "home-dark", scheme: .dark, size: SnapshotSupport.phone)
    }

    func testMe() throws {
        let view = Shell(initialTab: 1) { HomeScreen(items: Item.demoLibrary) }
        try SnapshotSupport.write(view, name: "me", scheme: .light, size: SnapshotSupport.phone)
    }
}
