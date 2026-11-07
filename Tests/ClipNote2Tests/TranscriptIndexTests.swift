import XCTest
@testable import ClipNote2

/// 字幕命中：验收点是「搜到的词真的在那一句里」和「多词规则与条目搜索一致」。
@MainActor
final class TranscriptIndexTests: XCTestCase {

    private let lines = [
        TranscriptLine(t: 0, text: "今天我们聊估值"),
        TranscriptLine(t: 45, text: "估值跑在收入前面，这是核心问题"),
        TranscriptLine(t: 90, text: "所以资本开支的回收周期被低估了"),
    ]

    func testFindsMatchingLine() {
        let hits = TranscriptIndex.hits(in: lines, query: "回收周期")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.t, 90)
    }

    func testMultipleHitsInTimeOrder() {
        let hits = TranscriptIndex.hits(in: lines, query: "估值")
        XCTAssertEqual(hits.map(\.t), [0, 45], "命中应按时间先后")
    }

    func testMultipleTermsMustAllMatchSameLine() {
        // 与条目搜索同一套规则：多词「都要命中」，但要在同一句里
        XCTAssertTrue(TranscriptIndex.hits(in: lines, query: "估值 收入").count == 1)
        XCTAssertTrue(TranscriptIndex.hits(in: lines, query: "估值 回收周期").isEmpty)
    }

    func testLimit() {
        // "估值" 命中前两句；limit 要能截断
        XCTAssertEqual(TranscriptIndex.hits(in: lines, query: "估值", limit: 2).count, 2)
        XCTAssertEqual(TranscriptIndex.hits(in: lines, query: "估值", limit: 1).count, 1)
    }

    func testEmptyQueryGivesNothing() {
        XCTAssertTrue(TranscriptIndex.hits(in: lines, query: "   ").isEmpty)
    }

    func testCaseInsensitive() {
        let mixed = [TranscriptLine(t: 1, text: "讲 NVDA 的资本开支")]
        XCTAssertEqual(TranscriptIndex.hits(in: mixed, query: "nvda").count, 1)
    }

    func testNoMatch() {
        XCTAssertTrue(TranscriptIndex.hits(in: lines, query: "光伏").isEmpty)
    }
}
