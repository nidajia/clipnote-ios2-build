import XCTest
@testable import ClipNote2

/// 跟读高亮的正确性只能靠数字验证：真机上差一句，肉眼很难判断「是这句还是上一句」。
@MainActor
final class TranscriptFollowTests: XCTestCase {

    private let lines = [
        TranscriptLine(t: 0, text: "第一句"),
        TranscriptLine(t: 12, text: "第二句"),
        TranscriptLine(t: 30, text: "第三句"),
        TranscriptLine(t: 31, text: "第四句"),
    ]

    func testBeforeFirstLineIsNil() {
        // 还没开口不应该有任何一句高亮，否则一进页面就有一条亮着
        XCTAssertNil(TranscriptFollow.index(at: -1, in: lines))
    }

    func testExactStart() {
        XCTAssertEqual(TranscriptFollow.index(at: 12, in: lines), 1)
        XCTAssertEqual(TranscriptFollow.index(at: 0, in: lines), 0)
    }

    func testInsideInterval() {
        // 12~30 之间都属于第二句
        XCTAssertEqual(TranscriptFollow.index(at: 12.4, in: lines), 1)
        XCTAssertEqual(TranscriptFollow.index(at: 29.9, in: lines), 1)
    }

    func testBoundaryGoesToNextLine() {
        XCTAssertEqual(TranscriptFollow.index(at: 30, in: lines), 2)
        XCTAssertEqual(TranscriptFollow.index(at: 31, in: lines), 3)
    }

    func testAfterLastLineStaysOnLast() {
        XCTAssertEqual(TranscriptFollow.index(at: 9999, in: lines), 3)
    }

    func testEmptyIsNil() {
        XCTAssertNil(TranscriptFollow.index(at: 5, in: []))
    }

    func testBinarySearchMatchesLinearScan() {
        // 二分实现最容易在边界写错，用线性扫一遍对拍
        let many = (0..<200).map { TranscriptLine(t: $0 * 3, text: "x") }
        for second in stride(from: -2.0, through: 620.0, by: 0.717) {
            var expected: Int?
            for (index, line) in many.enumerated() where Double(line.t) <= second {
                expected = index
            }
            XCTAssertEqual(TranscriptFollow.index(at: second, in: many), expected,
                           "秒数 \(second) 的定位和线性结果不一致")
        }
    }
}
