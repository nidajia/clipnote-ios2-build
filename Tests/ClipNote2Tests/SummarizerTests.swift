import XCTest
@testable import ClipNote2

/// 模型回复的解析。
///
/// 这一段是整个 AI 链路里**唯一不能靠"看着像对"来判断**的地方：
/// 模型不保证只回 JSON，也不保证字段齐全。解析错了，界面上会出现
/// 空摘要或半截文字，而截图看起来完全正常。
final class SummarizerTests: XCTestCase {

    func testParsesPlainJSON() throws {
        let raw = #"{"summary":"一段摘要","keyPoints":["要点一","要点二"],"labels":["AI","投资"]}"#
        let result = try Summarizer.parse(raw)
        XCTAssertEqual(result.summary, "一段摘要")
        XCTAssertEqual(result.keyPoints, ["要点一", "要点二"])
        XCTAssertEqual(result.labels, ["AI", "投资"])
    }

    func testParsesFencedCodeBlock() throws {
        // 最常见的形态：模型不听话，包一层 ```json
        let raw = """
        ```json
        {"summary":"包在代码块里","keyPoints":["a"],"labels":[]}
        ```
        """
        XCTAssertEqual(try Summarizer.parse(raw).summary, "包在代码块里")
    }

    func testParsesWhenModelAddsProse() throws {
        let raw = #"好的，这是结果：{"summary":"前后有废话","keyPoints":[],"labels":[]} 希望有帮助。"#
        XCTAssertEqual(try Summarizer.parse(raw).summary, "前后有废话")
    }

    func testRejectsWhenSummaryMissing() {
        // 没有 summary 就等于没生成：宁可报错，也不要存一条空摘要进快照
        XCTAssertThrowsError(try Summarizer.parse(#"{"keyPoints":["a"]}"#))
        XCTAssertThrowsError(try Summarizer.parse(#"{"summary":"   "}"#))
    }

    func testRejectsNonJSON() {
        XCTAssertThrowsError(try Summarizer.parse("抱歉，我无法完成这个请求。"))
    }

    func testCleansAndCapsArrays() throws {
        let raw = #"""
        {"summary":"有脏数据",
         "keyPoints":["  两边有空格  ","", "很长的要点\u{2026}", null],
         "labels":["这是一个超过二十个字符长度的标签名称用来验证截断"]}
        """#
        let result = try Summarizer.parse(raw)
        XCTAssertEqual(result.keyPoints.first, "两边有空格")
        XCTAssertFalse(result.keyPoints.contains(""))
        XCTAssertLessThanOrEqual(result.labels.first?.count ?? 0, 20)
    }

    func testConfigEndpointToleratesTrailingSlash() {
        let config = AIConfig(base: "https://api.example.com/v1///", model: "m", key: "k")
        XCTAssertEqual(config.endpoint?.absoluteString,
                       "https://api.example.com/v1/chat/completions")
        XCTAssertTrue(config.isConfigured)
    }

    func testConfigIsNotConfiguredWithBlanks() {
        XCTAssertFalse(AIConfig(base: " ", model: "m", key: "k").isConfigured)
        XCTAssertFalse(AIConfig(base: "https://x/v1", model: "", key: "k").isConfigured)
    }
}
