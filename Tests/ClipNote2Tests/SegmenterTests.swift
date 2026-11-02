import XCTest
@testable import ClipNote2

/// 分段链路的两段纯逻辑：把字幕压成行、把模型回复吸附成秒。
///
/// 这两处错了，界面**看起来完全正常**——段落整齐、时间戳长得也像那么回事，
/// 只是点进去对不上。所以必须用测试钉住，不能靠截图判断。
final class SegmenterTests: XCTestCase {

    private func line(_ t: Int, _ text: String) -> APITranscriptLine {
        APITranscriptLine(t: t, text: text)
    }

    // MARK: - 压缩

    func testCompressMergesIntoWindows() {
        // 每 5 秒一句，窗口 25 秒：第一桶从 0 收到 25，第二桶从 30 收到结尾
        let lines = (0..<10).map { line($0 * 5, "第\($0)句") }
        let blocks = TranscriptCompressor.compress(lines, window: 25)

        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].t, 0)
        XCTAssertEqual(blocks[1].t, 30, "跨过 25 秒之后的第一句才开新桶")
        XCTAssertTrue(blocks[0].text.hasSuffix("第5句"), "第 5 句正好落在边界上，归前一桶")
    }

    func testCompressKeepsEveryWord() {
        let lines = (0..<12).map { line($0 * 3, "词\($0)") }
        let blocks = TranscriptCompressor.compress(lines, window: 20)
        let merged = blocks.map(\.text).joined()
        for index in 0..<12 {
            XCTAssertTrue(merged.contains("词\(index)"), "第 \(index) 句被吞掉了")
        }
    }

    func testCompressSkipsBlank() {
        let lines = [line(0, "有内容"), line(2, "   "), line(4, "")]
        XCTAssertEqual(TranscriptCompressor.compress(lines, window: 25).count, 1)
    }

    func testPlanWidensWindowForLongInput() {
        // 2000 句 × 3 秒 ≈ 100 分钟，字数远超 12000 → 窗口必须被放宽
        let lines = (0..<2000).map { line($0 * 3, String(repeating: "字", count: 10)) }
        let blocks = TranscriptCompressor.plan(lines)

        XCTAssertLessThan(blocks.count, 2000)
        let chars = blocks.reduce(0) { $0 + $1.text.count }
        XCTAssertGreaterThanOrEqual(chars, 2000 * 10, "压缩不能丢正文，只能合并行")
    }

    // MARK: - 解析

    func testParseSnapsToNearestTimestamp() throws {
        // 模型常给 137 这种「两个已知时间点中间」的值
        let lines = [line(0, "a"), line(130, "b"), line(152, "c")]
        let raw = #"{"segments":[{"t":137,"title":"中段","summary":"说明"}]}"#

        let segments = try Segmenter.parse(raw, transcript: lines)
        XCTAssertEqual(segments.first?.t, 130, "137 离 130 更近，必须吸附到 130")
    }

    func testParseSnapsForwardWhenCloser() throws {
        let lines = [line(0, "a"), line(130, "b"), line(152, "c")]
        let raw = #"{"segments":[{"t":150,"title":"中段"}]}"#
        XCTAssertEqual(try Segmenter.parse(raw, transcript: lines).first?.t, 152)
    }

    func testParseKeepsTitleAndSorts() throws {
        let lines = [line(0, "a"), line(60, "b"), line(120, "c")]
        let raw = #"{"segments":[{"t":120,"title":"后","summary":"后段"},{"t":0,"title":"前"}]}"#
        let segments = try Segmenter.parse(raw, transcript: lines)

        XCTAssertEqual(segments.map(\.title), ["前", "后"], "输出必须按时间排序")
        XCTAssertEqual(segments.last?.summary, "后段")
    }

    func testParseToleratesCodeFence() throws {
        let lines = [line(0, "a")]
        let raw = """
        ```json
        {"segments":[{"t":0,"title":"开场","summary":"一句话"}]}
        ```
        """
        XCTAssertEqual(try Segmenter.parse(raw, transcript: lines).count, 1)
    }

    func testParseDropsSegmentsWithoutTitle() throws {
        let lines = [line(0, "a")]
        let raw = #"{"segments":[{"t":0,"title":"  "},{"t":0,"title":"有标题"}]}"#
        let segments = try Segmenter.parse(raw, transcript: lines)
        XCTAssertEqual(segments.map(\.title), ["有标题"])
    }

    func testParseRejectsEmptySegments() {
        let lines = [line(0, "a")]
        XCTAssertThrowsError(try Segmenter.parse(#"{"segments":[]}"#, transcript: lines))
    }

    func testParseRejectsNonJSON() {
        let lines = [line(0, "a")]
        XCTAssertThrowsError(try Segmenter.parse("模型今天不想干活", transcript: lines))
    }

    // MARK: - 模型备注

    func testModelNoteClassifiesByPurpose() {
        XCTAssertEqual(ModelCatalog.note(for: "Qwen/Qwen2.5-7B-Instruct").chattable, true)
        XCTAssertEqual(ModelCatalog.note(for: "BAAI/bge-m3").chattable, false)
        XCTAssertEqual(ModelCatalog.note(for: "FunAudioLLM/SenseVoiceSmall").chattable, false)
        XCTAssertEqual(ModelCatalog.note(for: "black-forest-labs/FLUX.1-schnell").chattable, false)
    }

    func testModelNoteMentionsVendor() {
        XCTAssertTrue(ModelCatalog.note(for: "deepseek-chat").note.contains("DeepSeek"))
        XCTAssertTrue(ModelCatalog.note(for: "Qwen/Qwen2.5-7B-Instruct").note.contains("通义千问"))
        // 认不出来的厂商不硬编，只给用途
        XCTAssertEqual(ModelCatalog.note(for: "some-unknown-model").note, "对话模型")
    }
}
