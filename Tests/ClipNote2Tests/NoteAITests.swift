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
        let message = NoteAIQuality.identicalMessage(length: 42)
        XCTAssertTrue(message.contains("42 字"), "要带上长度，用户才知道是不是内容太短")
        XCTAssertTrue(message.contains("按指令改写"))
    }

    func testTooShortContentIsDetected() {
        XCTAssertTrue(NoteAIQuality.isTooShortFor(.outline, content: "好"))
        XCTAssertFalse(NoteAIQuality.isTooShortFor(.outline, content: String(repeating: "字", count: 20)))
        XCTAssertFalse(NoteAIQuality.isTooShortFor(.tidy, content: "甲乙丙丁"))
        XCTAssertTrue(NoteAIQuality.isTooShortFor(.summary, content: "短句"))
    }

    // MARK: - 请求与错误

    func testRetriesOnceWhenModelEchoes() async throws {
        var calls = 0
        StubURLProtocol.handler = { [weak self] _ in
            calls += 1
            // 第一次原样返回，第二次才真正改写——弱模型的典型表现
            let body = calls == 1 ? "原文" : "改写的原文"
            return (200, [:], self?.reply(body) ?? Data())
        }
        let result = try await makeAssistant().run(action: .tidy, content: "原文")
        XCTAssertEqual(calls, 2, "模型照抄时应该自动重试一次")
        XCTAssertEqual(result.markdown, "改写的原文")
    }

    func testGivesUpAfterOneRetry() async throws {
        var calls = 0
        StubURLProtocol.handler = { [weak self] _ in
            calls += 1
            return (200, [:], self?.reply("原文") ?? Data())
        }
        let result = try await makeAssistant().run(action: .tidy, content: "原文")
        XCTAssertEqual(calls, 2, "只重试一次，不要变成死循环")
        XCTAssertEqual(result.markdown, "原文", "两次都照抄就如实返回，由上层告诉用户")
    }

    func testEchoedNoteTagsAreStripped() {
        XCTAssertEqual(NoteAIResult.cleanReply("<note>\n好\n</note>"), "好",
                       "弱模型会连包裹标签一起吐回来，那不是内容")
    }

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

    // MARK: - 作用域：选了一段就不能动整篇

    func testScopeParsesSavedSelection() {
        // 用户在点按钮前选了一段，点按钮时 WebView 失焦，
        // `__scope()` 用记住的位置返回 kind=saved。原生端必须认它。
        let raw: [String: Any] = ["kind": "saved", "text": "第一段话", "from": 1, "to": 5]
        let scope = NoteScreen.parseScope(raw)
        XCTAssertEqual(scope.kind, "saved")
        XCTAssertEqual(scope.text, "第一段话")
        XCTAssertEqual(scope.range?.from, 1)
        XCTAssertEqual(scope.range?.to, 5)
        XCTAssertEqual(scope.range?.text, "第一段话", "范围要带上原文，回写前要用它核对")
    }

    func testScopeFallsBackToDocOnlyWhenKindSaysSo() {
        // kind=doc 才是整篇。空 text 不能当作判据——
        // 空串有兩種含义（真没选、选区丢了），混为一谈正是原来的 bug。
        let raw: [String: Any] = ["kind": "doc", "text": "", "from": 0, "to": 0]
        let scope = NoteScreen.parseScope(raw)
        XCTAssertEqual(scope.kind, "doc")
        XCTAssertNil(scope.range)
    }

    func testScopeIgnoresBrokenPayload() {
        XCTAssertNil(NoteScreen.parseScope(nil).range)
        XCTAssertNil(NoteScreen.parseScope("不是字典").range)
        // 位置不合法时按整篇处理，不能拿 (0,0) 去回写
        let raw: [String: Any] = ["kind": "live", "text": "x", "from": 5, "to": 5]
        XCTAssertNil(NoteScreen.parseScope(raw).range)
    }

    // MARK: - 排版被「一刀一段」

    func testParagraphCountIgnoresStructure() {
        // 列表、标题、引用、表格不算普通段落：
        // 把一坨并列信息整理成列表是**对的**，不该被当成拆碎。
        let text = "# 标题\n\n- 一\n- 二\n\n> 引用\n\n| a | b |\n\n正文一段。"
        XCTAssertEqual(NoteAIQuality.paragraphCount(text), 1)
    }

    func testOverSplitIsDetected() {
        let before = "泡沫不在估值，而在现金流。利润是纸面的，利息是现金的。资本开支前置，回收周期被拉长。"
        // 「每句话打个回车」的典型产物
        let after = "泡沫不在估值，而在现金流。\n\n利润是纸面的，利息是现金的。\n\n资本开支前置，回收周期被拉长。"
        XCTAssertTrue(NoteAIQuality.didOverSplit(after, from: before))
    }

    func testNormalTidyIsNotFlagged() {
        let before = "血酬定律\n水型相 去长江以北发展\n遇事不决桂枝汤"
        let after = "## 要点\n\n- 血酬定律\n- 水型相：去长江以北发展\n- 遇事不决桂枝汤"
        XCTAssertFalse(NoteAIQuality.didOverSplit(after, from: before))
    }

    func testThinSummaryIsDetected() {
        let source = String(repeating: "这是一段比较长的笔记内容，讲现金流和估值的关系。", count: 12)
        XCTAssertTrue(NoteAIQuality.summaryTooThin("这篇讲的是泡沫。", from: source))
        let good = String(repeating: "作者认为泡沫的核心在现金流而不是估值。", count: 6)
        XCTAssertFalse(NoteAIQuality.summaryTooThin(good, from: source))
    }

    func testShortSourceDoesNotTriggerThinSummary() {
        // 短笔记本来就只能总结出一句，不该报「只覆盖了开头」
        XCTAssertFalse(NoteAIQuality.summaryTooThin("一句话。", from: "很短的一段。"))
    }

    // MARK: - 新笔记模板

    func testTemplateHasTitleAndHeadings() {
        let body = NoteTemplate.body(title: "周二复盘")
        XCTAssertTrue(body.hasPrefix("# 周二复盘"), "大标题要用用户输入的标题")
        for heading in NoteTemplate.headings {
            XCTAssertTrue(body.contains("## \(heading)"), "缺少小标题：\(heading)")
        }
    }

    func testTemplateTitleCanBeReadBack() {
        XCTAssertEqual(NoteTemplate.title(in: NoteTemplate.body(title: "预算评审")), "预算评审")
        XCTAssertNil(NoteTemplate.title(in: "没有大标题的一段"))
    }
}
