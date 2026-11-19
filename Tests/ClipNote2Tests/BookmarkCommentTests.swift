import XCTest
@testable import ClipNote2

/// 「收藏评论」的验收点：时间点能被改，评论能被改，改完不重复、不乱序。
///
/// 这里只测纯逻辑。视图里那两个入口（时间轴长按、列表铅笔）靠截图和真机看，
/// 但「点了保存之后数据变成什么」必须在这里定死。
final class BookmarkCommentTests: XCTestCase {

    func testParsesTheThreeFormatsThePlayerShows() {
        XCTAssertEqual(BookmarkComment.seconds(from: "90"), 90)
        XCTAssertEqual(BookmarkComment.seconds(from: "12:30"), 750)
        XCTAssertEqual(BookmarkComment.seconds(from: "1:02:03"), 3723)
        XCTAssertEqual(BookmarkComment.seconds(from: " 0:05 "), 5)
    }

    func testRejectsAmbiguousOrOutOfRangeInput() {
        for text in ["", "  ", "abc", "1:2", "0:90", "12:60", "1:2:3", "1:02:03:04", "-5", "12:3x"] {
            XCTAssertNil(BookmarkComment.seconds(from: text), "应该拒绝：\(text)")
        }
    }

    func testEditingChangesTimeAndNoteInPlace() {
        let list = [
            APIBookmark(t: 30, note: "开场"),
            APIBookmark(t: 300, note: "中段"),
            APIBookmark(t: 600, note: "结尾"),
        ]
        let out = BookmarkComment.applying(time: 315, note: "  改成这里  ", originalTime: 300, to: list)
        XCTAssertEqual(out.map(\.t), [30, 315, 600])
        XCTAssertEqual(out[1].note, "改成这里", "首尾空白应被去掉")
        XCTAssertEqual(out.count, 3)
    }

    func testMovingOntoAnotherBookmarkKeepsOneRow() {
        let list = [
            APIBookmark(t: 30, note: "开场"),
            APIBookmark(t: 300, note: "中段"),
        ]
        let out = BookmarkComment.applying(time: 30, note: "挪过去", originalTime: 300, to: list)
        XCTAssertEqual(out.count, 1, "同一秒两条会在时间轴上叠成一个点")
        XCTAssertEqual(out[0].t, 30)
        XCTAssertEqual(out[0].note, "挪过去")
    }

    func testEditedBookmarkIsSortedAndMarkedAsUserWritten() {
        let list = [APIBookmark(t: 30, note: "开场"), APIBookmark(t: 600, note: "结尾")]
        let out = BookmarkComment.applying(time: 900, note: "补一句", originalTime: 30, to: list)
        XCTAssertEqual(out.map(\.t), [600, 900])
        XCTAssertEqual(out[1].by, "user")
    }

    func testDisplayFallsBackForEmptyNote() {
        XCTAssertEqual(BookmarkComment.display("   "), "还没写评论")
        XCTAssertEqual(BookmarkComment.display(" 一句 "), "一句")
    }
}
