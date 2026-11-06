import XCTest
@testable import ClipNote2

/// SRT 的验收标准很硬：**导出的文件要能被剪映/Premiere 直接导入**。
/// 格式错一格，对方只会说"不支持"，不会指出哪一行。
@MainActor
final class SRTFormatTests: XCTestCase {

    private let lines = [
        TranscriptLine(t: 0, text: "第一句"),
        TranscriptLine(t: 12, text: "第二句"),
        TranscriptLine(t: 3605, text: "超过一小时的那句"),
    ]

    func testStructure() {
        let text = SRTFormat.text(lines: lines, duration: 4000)
        XCTAssertTrue(text.hasPrefix("1\n00:00:00,000 --> 00:00:12,000\n第一句\n\n"),
                      "首条必须完全符合 SRT 规范，实际是：\n\(text.prefix(60))")
    }

    func testEndTimeIsNextStart() {
        let text = SRTFormat.text(lines: lines, duration: 4000)
        XCTAssertTrue(text.contains("00:00:12,000 --> 01:00:05,000"),
                      "第二条的结束时间应等于第三条的开始时间")
    }

    func testLastLineUsesDuration() {
        let text = SRTFormat.text(lines: lines, duration: 5000)
        XCTAssertTrue(text.contains("01:00:05,000 --> 01:23:20,000"),
                      "最后一条结束时间应取总时长")
    }

    func testLastLineHasMinimumLength() {
        // 总时长比最后一句还早时，不能产出零长度字幕
        let text = SRTFormat.text(lines: [TranscriptLine(t: 100, text: "末句")], duration: 90)
        XCTAssertTrue(text.contains("00:01:40,000 --> 00:01:42,000"))
    }

    func testHourFormatting() {
        XCTAssertEqual(SRTFormat.time(3605), "01:00:05,000")
        XCTAssertEqual(SRTFormat.time(0), "00:00:00,000")
        XCTAssertEqual(SRTFormat.time(59), "00:00:59,000")
    }

    func testNegativeClamped() {
        XCTAssertEqual(SRTFormat.time(-10), "00:00:00,000")
    }

    func testEmptyGivesEmpty() {
        XCTAssertEqual(SRTFormat.text(lines: [], duration: 100), "")
    }

    func testIndexIsOneBasedAndSequential() {
        let text = SRTFormat.text(lines: lines, duration: 4000)
        XCTAssertTrue(text.contains("\n2\n"))
        XCTAssertTrue(text.contains("\n3\n"))
        XCTAssertFalse(text.contains("\n0\n"), "SRT 序号从 1 开始")
    }
}
