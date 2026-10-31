import SwiftUI

/// 应用外壳。
///
/// 当前只有两个 Tab：首页、我。
/// 书签与知识库属于第二包——不要为了「看起来完整」先放空 Tab。
struct RootView: View {
    @StateObject private var downloads = DownloadStore()
    @StateObject private var library = LibraryStore(client: .production)

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
        // 首帧就拉一次库。失败会落到首页的失败态，不会被吞掉。
        .task { await library.reload() }
    }
}

#Preview("浅色") {
    RootView().preferredColorScheme(.light)
}

#Preview("深色") {
    RootView().preferredColorScheme(.dark)
}
