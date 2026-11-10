import XCTest
@testable import ClipNote2

/// 笔记内 AI 的契约测试。
///
/// 只验「我们自己能保证的部分」：提示词的硬约束、回复清洗、
/// 以及「整理排版有没有偷偷改字」这条机器校验。
/// 模型实际写得怎么样，单测管不了，也不该假装管得了。
final class NoteAITests: XCTestCase {

    private let config = AIConfig(base: "https://example.test/v1", model: "test-model", key: "sk-test")

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    private func makeAssistant() -> NoteAssistant {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [StubURLProtocol.self]
        return NoteAssistant(config: config, session: URLSession(configuration: sessionConfig))
    }

    private func bodyData(_ request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    private func reply(_ content: String) -> Data {
        let payload: [String: Any] = ["choices": [["message": ["content": content]]]]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }

    // MARK: - 提示词

    func testTidyPromptForbidsChangingText() {
        let text = NotePrompt.instruction(for: .tidy)
        XCTAssertTrue(text.contains("一个字都不许"), "「整理排版」必须把「不许改字」写在最前面")
        XCTAssertTrue(text.contains("禁止"), "还要明确列出禁止项，只说不许不够")
    }

    func testExpandPromptForbidsExternalFacts() {
        let text = NotePrompt.instruction(for: .expand)
        // 规格（产品路线 2.3）：只能基于笔记已有信息，禁止引入外部事实。
        // 上一版放开了「背景/定义/例子」，等于允许编造，这里钉住回不去。
        XCTAssertTrue(text.contains("只能用原文已有的信息"))
        XCTAssertTrue(text.contains("严格禁止"))
        XCTAssertFalse(text.contains("可以补充：背景"))
    }

    func testOutlinePromptAsksForRealCompression() {
        let text = NotePrompt.instruction(for: .outline)
        XCTAssertTrue(text.contains("六成"), "要给出可衡量的压缩目标，否则模型容易原样返回")
        XCTAssertTrue(text.contains("25 字"))
        XCTAssertTrue(text.contains("小标题"), "碎片式笔记要先归类，才有可见变化")
    }

    func testSummaryPromptProducesOneParagraph() {
        let text = NotePrompt.instruction(for: .summary)
        XCTAssertTrue(text.contains("一段话"))
        XCTAssertTrue(text.contains("120 字"))
        XCTAssertTrue(text.contains("不用列表"), "总结是段落，不是又一份要点")
    }

    func testActionsFlagWhichOnesMayAddContent() {
        XCTAssertFalse(NoteAIAction.tidy.mayAddContent)
        XCTAssertFalse(NoteAIAction.outline.mayAddContent)
        XCTAssertFalse(NoteAIAction.summary.mayAddContent)
        XCTAssertTrue(NoteAIAction.expand.mayAddContent)
        XCTAssertTrue(NoteAIAction.custom("改写成书面语").mayAddContent)
    }

    // MARK: - 结果质量

    func testIdenticalResultIsDetected() {
        XCTAssertTrue(NoteAIQuality.isIdentical("同一段话\n", to: "同一段话"))
        XCTAssertFalse(NoteAIQuality.isIdentical("同一段话。", to: "同一段话"))
    }

    func testCompressionCheck() {
        XCTAssertTrue(NoteAIQuality.didNotCompress("一样长", from: "一样长"))
        XCTAssertTrue(NoteAIQuality.didNotCompress("更长了更长了", from: "短"))
        XCTAssertFalse(NoteAIQuality.didNotCompress("短", from: "长一些的原文"))
    }

    func testNoChangeMessageTellsUserWhatToDo() {
        let message = NoteAIQuality.identicalMessage
        XCTAssertTrue(message.contains("没有改动"), "要说清是模型没改，不是功能坏了")
        XCTAssertTrue(message.contains("按指令改写"), "要给出下一步怎么做")
    }

    // MARK: - 回复清洗

    func testCleanReplyStripsCodeFence() {
        let raw = "```markdown\n# 标题\n\n正文\n```"
        XCTAssertEqual(NoteAIResult.cleanReply(raw), "# 标题\n\n正文")
    }

    func testCleanReplyKeepsInnerCodeBlock() {
        let raw = "说明\n\n```js\nconst a = 1\n```"
        XCTAssertEqual(NoteAIResult.cleanReply(raw), raw, "中间真正的代码块不能被当成外层围栏剥掉")
    }

    // MARK: - 文字保真

    func testPlainTextIgnoresFormatting() {
        let before = "标题\n\n甲乙丙"
        let after = "# 标题\n\n- 甲\n- 乙\n- 丙"
        XCTAssertEqual(
            MarkdownPlainText.extract(before),
            MarkdownPlainText.extract(after),
            "只改排版不该被判定为改字"
        )
    }

    func testPlainTextIgnoresHighlightAndLinks() {
        XCTAssertEqual(
            MarkdownPlainText.extract("看 =={g}这段== 和 [链接](https://x)"),
            MarkdownPlainText.extract("看 这段 和 链接")
        )
    }

    func testPlainTextDetectsInsertedWords() {
        XCTAssertNotEqual(
            MarkdownPlainText.extract("甲乙丙"),
            MarkdownPlainText.extract("甲乙丙丁"),
            "多一个字必须能查出来——这是「整理排版」的底线"
        )
    }

    func testPlainTextDropsTableSeparatorRow() {
        XCTAssertEqual(
            MarkdownPlainText.extract("| a | b |\n| --- | --- |\n| 1 | 2 |"),
            MarkdownPlainText.extract("a b 1 2")
        )
    }

    // MARK: - 请求与结果

    func testRequestShape() async throws {
        var path: String?
        var auth: String?
        var body: [String: Any]?

        StubURLProtocol.handler = { [weak self] request in
            path = request.url?.path
            auth = request.value(forHTTPHeaderField: "Authorization")
            if let data = self?.bodyData(request) {
                body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
            return (200, ["Content-Type": "application/json"], self?.reply("整理后的内容") ?? Data())
        }

        let result = try await makeAssistant().run(action: .tidy, content: "原始内容")
        XCTAssertEqual(path, "/v1/chat/completions")
        XCTAssertEqual(auth, "Bearer sk-test")
        XCTAssertEqual(body?["model"] as? String, "test-model")
        let messages = body?["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.count, 2)
        XCTAssertEqual(messages?.first?["role"] as? String, "system")
        XCTAssertTrue(
            (messages?.last?["content"] as? String ?? "").contains("原始内容"),
            "正文必须原样带给模型"
        )
        XCTAssertEqual(result.markdown, "整理后的内容")
    }

    func testTextChangedFlagWhenModelAddsWords() async throws {
        StubURLProtocol.handler = { [weak self] _ in
            (200, [:], self?.reply("# 标题\n\n甲乙丙，另外还有一句原文没有的话") ?? Data())
        }
        let result = try await makeAssistant().run(action: .tidy, content: "# 标题\n\n甲乙丙")
        XCTAssertTrue(result.textChanged, "模型加了一句，必须被标记出来")
    }

    func testTextUnchangedWhenOnlyFormattingDiffers() async throws {
        StubURLProtocol.handler = { [weak self] _ in
            (200, [:], self?.reply("# 标题\n\n- 甲\n- 乙") ?? Data())
        }
        let result = try await makeAssistant().run(action: .tidy, content: "标题\n\n甲乙")
        XCTAssertFalse(result.textChanged)
    }

    func testEmptyReplyThrows() async throws {
        StubURLProtocol.handler = { [weak self] _ in
            (200, [:], self?.reply("   ") ?? Data())
        }
        do {
            _ = try await makeAssistant().run(action: .outline, content: "内容")
            XCTFail("空回复应该抛错，否则用户会看到一张空预览卡")
        } catch let failure as NoteAIFailure {
            XCTAssertEqual(failure, .emptyReply)
        }
    }

    func testNotConfiguredThrows() async {
        let empty = NoteAssistant(config: AIConfig())
        do {
            _ = try await empty.run(action: .tidy, content: "内容")
            XCTFail("没配模型时不该发请求")
        } catch let failure as NoteAIFailure {
            XCTAssertEqual(failure, .notConfigured)
            XCTAssertTrue(failure.displayMessage.contains("AI 设置"), "要说清去哪儿配置")
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    func testHTTPErrorCarriesMessage() async {
        StubURLProtocol.handler = { _ in (401, [:], Data("bad key".utf8)) }
        do {
            _ = try await makeAssistant().run(action: .tidy, content: "内容")
            XCTFail("401 应该抛错")
        } catch let failure as NoteAIFailure {
            if case .http(let status, _) = failure {
                XCTAssertEqual(status, 401)
            } else {
                XCTFail("不是 http 错误：\(failure)")
            }
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }
}
