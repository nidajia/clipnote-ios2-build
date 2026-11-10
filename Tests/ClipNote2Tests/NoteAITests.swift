import XCTest
@testable import ClipNote2

/// 笔记内 AI 的契约测试。
///
/// 只验「我们自己能保证的部分」：提示词的硬约束、回复清洗、差异标记、
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
        XCTAssertTrue(text.contains("一个字都不许"))
        XCTAssertTrue(text.contains("禁止"))
    }

    func testExpandModesDiffer() {
        let strict = NotePrompt.instruction(for: .expand(external: false))
        let open = NotePrompt.instruction(for: .expand(external: true))

        XCTAssertTrue(strict.contains("只能用原文已有的信息"))
        XCTAssertTrue(strict.contains("严格禁止"), "只用原文模式下必须明说不许引入外部事实")
        XCTAssertFalse(strict.contains("（外部）"))

        XCTAssertTrue(open.contains("（外部）"), "查资料模式要求每处外部补充带标记，用户才认得出哪些不是自己写的")
        XCTAssertNotEqual(strict, open)
    }

    func testOutlinePromptAsksForRealCompression() {
        let text = NotePrompt.instruction(for: .outline)
        XCTAssertTrue(text.contains("六成"))
        XCTAssertTrue(text.contains("25 字"))
        XCTAssertTrue(text.contains("小标题"))
    }

    func testSummaryPromptProducesOneParagraph() {
        let text = NotePrompt.instruction(for: .summary)
        XCTAssertTrue(text.contains("一段话"))
        XCTAssertTrue(text.contains("120 字"))
        XCTAssertTrue(text.contains("不用列表"))
    }

    func testTranslateKeepsStructure() {
        let text = NotePrompt.instruction(for: .translate)
        XCTAssertTrue(text.contains("保留"), "翻译要保留 Markdown 结构，否则表格和列表会被压平")
        XCTAssertTrue(text.contains("==…=="))
    }

    func testCompleteRequiresBasisWhenUnsure() {
        let text = NotePrompt.instruction(for: .complete)
        XCTAssertTrue(text.contains(NotePrompt.basisMarker))
    }

    func testVerifyDoesNotRewrite() {
        let text = NotePrompt.instruction(for: .verify)
        XCTAssertTrue(text.contains("不要改写原文"))
        XCTAssertTrue(NoteAIAction.verify.isReport, "核实只出报告，不能写回正文")
    }

    func testActionsFlagWhichOnesMayAddContent() {
        XCTAssertFalse(NoteAIAction.tidy.mayAddContent)
        XCTAssertFalse(NoteAIAction.outline.mayAddContent)
        XCTAssertFalse(NoteAIAction.summary.mayAddContent)
        XCTAssertFalse(NoteAIAction.translate.mayAddContent)
        XCTAssertTrue(NoteAIAction.expand(external: false).mayAddContent)
        XCTAssertTrue(NoteAIAction.expand(external: true).mayAddContent)
        XCTAssertTrue(NoteAIAction.complete.mayAddContent)
        XCTAssertTrue(NoteAIAction.custom("改写成书面语").mayAddContent)
    }

    // MARK: - 回复清洗与依据

    func testCleanReplyStripsCodeFence() {
        let raw = "```markdown\n# 标题\n\n正文\n```"
        XCTAssertEqual(NoteAIResult.cleanReply(raw), "# 标题\n\n正文")
    }

    func testSplitBasis() {
        let raw = "补全后的句子\n\n\(NotePrompt.basisMarker)\n出自《增广贤文》，把握较高"
        let (body, basis) = NoteAIResult.splitBasis(raw)
        XCTAssertEqual(body, "补全后的句子")
        XCTAssertEqual(basis, "出自《增广贤文》，把握较高")
    }

    func testSplitBasisWithoutMarker() {
        let (body, basis) = NoteAIResult.splitBasis("只有正文")
        XCTAssertEqual(body, "只有正文")
        XCTAssertNil(basis)
    }

    func testBasisIsStrippedFromAppliedMarkdown() async throws {
        StubURLProtocol.handler = { [weak self] _ in
            (200, [:], self?.reply("前半句补全了后半句\n\n\(NotePrompt.basisMarker)\n依据说明") ?? Data())
        }
        let result = try await makeAssistant().run(action: .complete, content: "前半句")
        XCTAssertEqual(result.markdown, "前半句补全了后半句", "依据不能混进正文")
        XCTAssertEqual(result.basis, "依据说明")
    }

    // MARK: - 文字保真

    func testPlainTextIgnoresFormatting() {
        XCTAssertEqual(
            MarkdownPlainText.extract("标题\n\n甲乙丙"),
            MarkdownPlainText.extract("# 标题\n\n- 甲\n- 乙\n- 丙")
        )
    }

    func testPlainTextDetectsInsertedWords() {
        XCTAssertNotEqual(MarkdownPlainText.extract("甲乙丙"), MarkdownPlainText.extract("甲乙丙丁"))
    }

    // MARK: - 差异标记

    func testDiffFindsInsertedText() {
        let segments = TextDiff.segments(from: "甲乙丙", to: "甲乙丁丙")
        XCTAssertTrue(segments.contains { $0.kind == .insert && $0.text.contains("丁") })
        XCTAssertTrue(segments.contains { $0.kind == .same })
    }

    func testDiffFindsDeletedText() {
        let segments = TextDiff.segments(from: "甲乙丙", to: "甲丙")
        XCTAssertTrue(segments.contains { $0.kind == .delete && $0.text.contains("乙") })
    }

    func testDiffOfIdenticalTextIsAllSame() {
        let segments = TextDiff.segments(from: "一样", to: "一样")
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.kind, .same)
    }

    func testDiffFallsBackForLongText() {
        let long = String(repeating: "甲乙丙丁戊", count: 400)
        let segments = TextDiff.segments(from: long, to: long + "新的")
        XCTAssertFalse(segments.isEmpty)
        XCTAssertTrue(segments.contains { $0.kind == .insert }, "长文本退回按行比对后仍要能标出新增")
    }

    // MARK: - 质量判定

    func testIdenticalResultIsDetected() {
        XCTAssertTrue(NoteAIQuality.isIdentical("同一段话\n", to: "同一段话"))
        XCTAssertFalse(NoteAIQuality.isIdentical("同一段话。", to: "同一段话"))
    }

    func testNoChangeMessageTellsUserWhatToDo() {
        let message = NoteAIQuality.identicalMessage
        XCTAssertTrue(message.contains("没有改动"))
        XCTAssertTrue(message.contains("按指令改写"))
    }

    // MARK: - 请求与错误

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
        let userMessage = messages?.last?["content"] as? String ?? ""
        XCTAssertTrue(userMessage.contains("<note>"), "原文要用标签包住，避免模型把分隔线当素材边界")
        XCTAssertTrue(userMessage.contains("原始内容"))
        XCTAssertEqual(result.markdown, "整理后的内容")
    }

    func testTextChangedFlagWhenModelAddsWords() async throws {
        StubURLProtocol.handler = { [weak self] _ in
            (200, [:], self?.reply("# 标题\n\n甲乙丙，另外还有一句原文没有的话") ?? Data())
        }
        let result = try await makeAssistant().run(action: .tidy, content: "# 标题\n\n甲乙丙")
        XCTAssertTrue(result.textChanged)
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
            XCTAssertTrue(failure.displayMessage.contains("AI 设置"))
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
