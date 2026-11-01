import UIKit
import XCTest
@testable import ClipNote2

/// 方向锁的状态机。
///
/// 这里只能验「允许哪些方向」，验不了「界面有没有真的转过去」——
/// 后者要真机或模拟器旋转，而 `simctl` 没有旋转命令。
/// 但这一层仍然值得测：如果 `mask` 一直是竖屏，`requestGeometryUpdate`
/// 会被系统直接拒绝，而且**不报错**。那种失败在真机上只表现为「点了没反应」。
///
/// 类上不加 `@MainActor`：那会让 `override func setUp()` 带上隔离，
/// 与 `XCTestCase` 的 nonisolated 声明冲突，编译不过。
/// 改成每条方法自己标。
final class OrientationLockTests: XCTestCase {

    @MainActor
    private func resetToPortrait() {
        OrientationLock.shared.force(.portrait)
    }

    @MainActor
    func testDefaultsToPortrait() {
        resetToPortrait()
        XCTAssertEqual(OrientationLock.shared.mask, .portrait)
        XCTAssertFalse(OrientationLock.shared.mask.contains(.landscape))
    }

    @MainActor
    func testEnteringFullscreenOpensLandscape() {
        resetToPortrait()
        OrientationLock.shared.enterFullscreenPlayer()
        // .allButUpsideDown 也包含竖屏：横屏播放时用户把手机转回去，不该被强行钉住
        XCTAssertTrue(OrientationLock.shared.mask.contains(.landscape))
        XCTAssertTrue(OrientationLock.shared.mask.contains(.portrait))
    }

    @MainActor
    func testExitingFullscreenClosesLandscape() {
        resetToPortrait()
        OrientationLock.shared.enterFullscreenPlayer()
        OrientationLock.shared.exitFullscreenPlayer()
        XCTAssertEqual(OrientationLock.shared.mask, .portrait)
        XCTAssertFalse(OrientationLock.shared.mask.contains(.landscape))
    }

    @MainActor
    func testEnteringTwiceIsIdempotent() {
        resetToPortrait()
        OrientationLock.shared.enterFullscreenPlayer()
        let first = OrientationLock.shared.mask
        OrientationLock.shared.enterFullscreenPlayer()
        XCTAssertEqual(OrientationLock.shared.mask, first)
    }

    /// AppDelegate 是唯一把 mask 交给系统的地方。
    /// 它如果返回了别的东西（比如写死 `.portrait`），上面几条全绿也没用。
    @MainActor
    func testAppDelegateReportsTheLockedMask() {
        resetToPortrait()
        let delegate = AppDelegate()
        let window: UIWindow? = nil

        XCTAssertEqual(
            delegate.application(UIApplication.shared, supportedInterfaceOrientationsFor: window),
            .portrait
        )

        OrientationLock.shared.enterFullscreenPlayer()
        let reported = delegate.application(
            UIApplication.shared, supportedInterfaceOrientationsFor: window
        )
        XCTAssertEqual(reported, OrientationLock.shared.mask)
        XCTAssertTrue(reported.contains(.landscape))
    }
}
