import XCTest
@testable import ClipNote2

/// 合集目录里「点某一集」的去处。
///
/// 真机反馈过两次「点一集就跳 B 站」。根因是这里曾有过第三个分支：
/// 没入库就 `UIApplication.shared.open` 直接甩去浏览器。
/// 现在把它压成一条纯规则并锁进测试——任何一次改动把「外部打开」
/// 加回主路径，这几条会立刻变红。
final class EpisodeRoutingTests: XCTestCase {

    /// 已入库：进详情页（自动起播），因为那里有笔记、分段、评论，离线也能看。
    func testSavedEpisodeOpensDetail() {
        XCTAssertEqual(EpisodeRouting.route(itemId: "mw123", isInLibrary: true),
                       .openSavedItem)
    }

    /// 没入库：应用内在线播放。
    func testUnsavedEpisodePlaysInApp() {
        XCTAssertEqual(EpisodeRouting.route(itemId: "", isInLibrary: false),
                       .playInApp)
    }

    /// 最容易出错的一档：服务端说「这一集在库里」，但本地快照还没有它
    /// （刚收藏还没同步回来）。这时必须退化成应用内播放，绝不能去浏览器。
    func testStaleItemIdStillPlaysInApp() {
        XCTAssertEqual(EpisodeRouting.route(itemId: "mw123", isInLibrary: false),
                       .playInApp)
    }

    /// 穷举输入空间里仅有的四种组合：结果必须是「两种去处」之一。
    /// 这个测试的意图不是覆盖分支，而是声明「没有第三种去处」。
    func testNoExternalDestinationExists() {
        for itemId in ["", "mw123"] {
            for saved in [true, false] {
                let route = EpisodeRouting.route(itemId: itemId, isInLibrary: saved)
                XCTAssertTrue(route == .openSavedItem || route == .playInApp,
                              "itemId=\(itemId) isInLibrary=\(saved) 出现了意外的去处")
            }
        }
    }
}
