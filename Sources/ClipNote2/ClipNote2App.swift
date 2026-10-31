import SwiftUI

@main
struct ClipNote2App: App {
    var body: some Scene {
        WindowGroup {
            // 这一阶段 App 本身就是组件画廊：
            // 装机后可以直接用肉眼比对画布，不需要走业务路径。
            ComponentGallery()
        }
    }
}
