import SwiftUI
import UIKit

/// App 的方向锁。
///
/// 为什么不是「只改 Info.plist 放开横屏」：那样列表页、导入面板、回收站、日志页
/// 都会在横屏下出现，而这些状态画布从没画过、也没验证过。
/// 这里让 App **默认锁竖屏**，只有全屏播放页在屏幕上时放开横屏——
/// B 站、YouTube 都是这个模型：App 本身竖屏，进全屏才转。
///
/// 类本身不加 `@MainActor`：`AppDelegate` 的那个回调是同步的、且要读 `mask`，
/// 给它加隔离只会换来一堆 `assumeIsolated`。`mask` 只在主线程读写，由下面
/// 那几个 `@MainActor` 方法保证；读取端（AppDelegate）本来就在主线程。
final class OrientationLock {
    static let shared = OrientationLock()

    /// 当前允许的方向。`AppDelegate` 把它交给系统。
    ///
    /// 默认只有竖屏：新加的页面不该因为「忘了收」而突然能转。
    private(set) var mask: UIInterfaceOrientationMask = .portrait

    /// 由 RootView 注入，用来记录切换失败。方向没转成是可见的，
    /// 但用户只会觉得「按钮没反应」，日志里留一条才查得动。
    weak var logger: LogStore?

    private init() {}

    @MainActor
    func enterFullscreenPlayer() {
        // 允许集合放开到「除倒置以外全部」，但**请求**的是横屏。
        //
        // 这两件事必须分开：如果只请求 `.allButUpsideDown`，而当时正好是竖屏，
        // 系统会认为「竖屏也在允许范围内」，于是原地不动——
        // 表现就是「进了全屏页，但界面没转」，而且没有任何报错。
        apply(allow: .allButUpsideDown, request: .landscape)
    }

    @MainActor
    func exitFullscreenPlayer() {
        apply(allow: .portrait, request: .portrait)
    }

    /// 截图用：没有「进出全屏」这个动作，直接指定方向。
    @MainActor
    func force(_ mask: UIInterfaceOrientationMask) {
        apply(allow: mask, request: mask)
    }

    /// 切换允许方向并请求系统转过去。
    ///
    /// 顺序不能反：先 `setNeedsUpdateOfSupportedInterfaceOrientations()` 让系统知道
    /// 支持的方向变了，再 `requestGeometryUpdate`。反过来会得到一次静默失败——
    /// 代码看着写了，界面一动不动，而且没有任何报错。
    @MainActor
    private func apply(allow: UIInterfaceOrientationMask, request: UIInterfaceOrientationMask) {
        mask = allow

        guard let scene = activeScene else { return }

        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: request)) { [weak self] error in
            // 没转成不是功能故障（用户还能再点一次），但要看得到。
            // 这条回调不保证在主线程，所以弹回主线程再写日志。
            let detail = error.localizedDescription
            Task { @MainActor in
                self?.logger?.error("orientation.failed", "方向没有切换过去", meta: [
                    "target": "\(request.rawValue)",
                    "reason": detail,
                ])
            }
        }
    }

    @MainActor
    private var activeScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }
}

/// 只需要回答一个问题：现在支持哪些方向。
///
/// 纯 SwiftUI 的 App 没有 AppDelegate，但方向这个信息只有它能给。
/// 为它挂一个 `@UIApplicationDelegateAdaptor` 是标准做法；
/// 不要为了避开而用 `UIDevice.setValue(forKey: "orientation")`——
/// 那是私有接口，iOS 16 起已经失效。
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationLock.shared.mask
    }
}
