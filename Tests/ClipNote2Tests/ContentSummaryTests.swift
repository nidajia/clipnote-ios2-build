import XCTest
@testable import ClipNote2

final class ContentSummaryTests: XCTestCase {
    private var lines: [APITranscriptLine] {
        (0..<12).map { APITranscriptLine(t: $0 * 60, text: "正文主题\($0)，这是必须被模型读到的内容") }
    }
    private func reply(times: [Int]? = nil, expand: String = "还需要核实什么？") throws -> String {
        let chapters = (times ?? lines.map(\.t)).enumerated().map { index, t in
            ["t": t, "title": "主题\(index)", "detail": "本章依据正文解释原因。进一步区分证据与推断。", "expand": expand] as [String: Any]
        }
        return String(data: try JSONSerialization.data(withJSONObject: [
            "summary": "依据全文得到的结论", "keyPoints": ["证据"], "labels": ["科技"], "chapters": chapters
        ]), encoding: .utf8)!
    }
    func testPreservesRealTimesAndAllChapterFields() throws {
        let result = try ContentSummarizer.parse(reply(), lines: lines, duration: 720)
        XCTAssertEqual(result.chapters.count, 12)
        XCTAssertEqual(result.chapters.map(\.t), lines.map(\.t))
        XCTAssertTrue(result.chapters.allSatisfy { !$0.detail.isEmpty && !$0.expand.isEmpty })
    }
    func testSparseTranscriptKeepsItsAvailableTimeAnchors() {
        XCTAssertEqual(TranscriptCompressor.plan(lines).map(\.t), lines.map(\.t))
    }
    func testRejectsAllZeroRatherThanFabricatingTimes() throws {
        XCTAssertThrowsError(try ContentSummarizer.parse(reply(times: Array(repeating: 0, count: 12)), lines: lines, duration: 720))
    }
    func testRejectsMissingExtensionAndIncompleteChapters() throws {
        XCTAssertThrowsError(try ContentSummarizer.parse(reply(expand: ""), lines: lines, duration: 720))
        XCTAssertThrowsError(try ContentSummarizer.parse(reply(times: [0, 60, 120]), lines: lines, duration: 720))
    }
    func testRejectsBeyondDurationAndReversedTimes() throws {
        XCTAssertThrowsError(try ContentSummarizer.parse(reply(times: Array(lines.map(\.t).reversed())), lines: lines, duration: 720))
        XCTAssertThrowsError(try ContentSummarizer.parse(reply(), lines: lines, duration: 300))
    }
    func testShortTranscriptUsesOnlyAvailableAnchors() throws {
        let short = Array(lines.prefix(2))
        let value = try ContentSummarizer.parse(reply(times: [0, 60]), lines: short, duration: 90)
        XCTAssertEqual(value.chapters.map(\.t), [0, 60])
    }
    func testRejectsEnoughChaptersThatOnlyCoverTheBeginning() throws {
        let long = (0..<30).map { APITranscriptLine(t: $0 * 60, text: "主题\($0)") }
        XCTAssertThrowsError(try ContentSummarizer.parse(reply(), lines: long, duration: 1800))
    }
    func testTextOnlyDoesNotInventChapters() throws {
        XCTAssertTrue(try ContentSummarizer.parse(reply(), lines: [], duration: 0).chapters.isEmpty)
    }
    func testRequestReadsFirstAndLastTranscriptAndRetriesInvalidReplyOnce() async throws {
        var requests: [[String: Any]] = []
        let valid = try reply()
        let transport = AIJobTransport(create: { body in
            requests.append(body)
            return AIJobSnapshot(id: "test", status: "done", text: requests.count == 1 ? "{}" : valid)
        }, status: { _ in XCTFail("已经完成，不应轮询"); throw AIJobFailure.gone })
        let summarizer = ContentSummarizer(config: AIConfig(base: "https://example.test/v1", model: "test", key: "test"),
                                          jobs: AIJobClient(transport: transport), template: .brief, customPrompt: "")
        let value = try await summarizer.summarize(title: "不能只读标题", lines: lines, duration: 720)
        XCTAssertEqual(value.chapters.count, 12)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?["max_tokens"] as? Int, 6000)
        let messages = try XCTUnwrap(requests.first?["messages"] as? [[String: String]])
        XCTAssertTrue(messages[1]["content"]!.contains("正文主题0"))
        XCTAssertTrue(messages[1]["content"]!.contains("正文主题11"))
    }
    func testTruncationAndMissingBodyNeverSavePartialSummary() async throws {
        var calls = 0
        let transport = AIJobTransport(create: { _ in
            calls += 1
            return AIJobSnapshot(id: "test", status: "done", text: "{}", finishReason: "length")
        }, status: { _ in throw AIJobFailure.gone })
        let summarizer = ContentSummarizer(config: AIConfig(base: "https://example.test/v1", model: "test", key: "test"),
                                          jobs: AIJobClient(transport: transport))
        do { _ = try await summarizer.summarize(title: "标题", lines: [], duration: 0); XCTFail() } catch {}
        XCTAssertEqual(calls, 0)
        do { _ = try await summarizer.summarize(title: "标题", lines: lines, duration: 720); XCTFail() }
        catch { XCTAssertEqual(error as? SummarizeFailure, .truncated) }
        XCTAssertEqual(calls, 1)
    }
    func testTranscriptFallsBackToCacheOnEmptyOrFailedRemote() async throws {
        let cached = Array(lines.prefix(2))
        let empty = try await SummaryTranscriptLoader.load(remote: { [] }, cached: cached)
        let failed = try await SummaryTranscriptLoader.load(remote: { throw AIJobFailure.gone }, cached: cached)
        XCTAssertEqual(empty.map(\.text), cached.map(\.text))
        XCTAssertEqual(failed.map(\.t), cached.map(\.t))
        let noSource = try await SummaryTranscriptLoader.load(remote: { [] }, cached: [])
        XCTAssertTrue(noSource.isEmpty)
    }
    func testVeryLongSingleLineIsSplitWithoutLosingUnicodeOrTime() {
        let text = String(repeating: "开头👩‍💻结尾", count: 800)
        let chunks = ContentSummarizer.transcriptChunks([APITranscriptLine(t: 7, text: text)])
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.flatMap { $0 }.map(\.text).joined(), text)
        XCTAssertTrue(chunks.allSatisfy { chunk in
            chunk.allSatisfy { $0.t == 7 } && chunk.reduce(0) { $0 + "[\($1.t)] \($1.text)\n".utf8.count } <= 4500
        })
    }

    func testPartialRemoteUsesFullerLocalAndRejectsShortCacheAsComplete() throws {
        let remote = try JSONDecoder().decode(APITranscript.self, from: Data(#"{"lines":[{"t":0,"text":"开头"},{"t":220,"text":"中段"}],"durationSeconds":1200,"partial":true}"#.utf8))
        let cache = LocalTranscript(itemId: "x", lines: [TranscriptLine(t: 2, text: "开头"),
                                                         TranscriptLine(t: 620, text: "中段"),
                                                         TranscriptLine(t: 1190, text: "尾段")],
                                    durationSeconds: 1200, createdAt: Date(), locale: "zh-CN")
        let chosen = SummaryTranscriptInput.choose(remote: remote, cached: cache, itemDuration: 1200)
        XCTAssertEqual(chosen.lines.last?.t, 1190)
        XCTAssertFalse(chosen.partial)
        XCTAssertTrue(SummaryTranscriptInput.choose(remote: remote, cached: nil, itemDuration: 1200).partial)
        let incompleteCache = LocalTranscript(itemId: "x", lines: [TranscriptLine(t: 210, text: "还没到结尾")],
                                              durationSeconds: 220, createdAt: Date(), locale: "zh-CN")
        XCTAssertTrue(SummaryTranscriptInput.choose(remote: nil, cached: incompleteCache, itemDuration: 1200).partial)
    }

    func testLongVideoSendsEveryChunkAndProgrammaticallyKeepsChapterTimes() async throws {
        let long = (0..<12).map { index in
            APITranscriptLine(t: index * 300, text: "主题锚点\(index)-" + String(repeating: "正文", count: 450))
        }
        var sent: [String] = []
        let transport = AIJobTransport(create: { body in
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            let user = try XCTUnwrap(messages.last?["content"])
            sent.append(user)
            let raw = user.contains("正文：")
                ? #"{"title":"可核查观点","detail":"解释原因并对照正文给出的实例。","expand":"还有哪些证据？"}"#
                : #"{"summary":"这段视频的核心结论来自各个章节","keyPoints":["实例支持结论"],"labels":[],"chapters":[]}"#
            return AIJobSnapshot(id: "test", status: "done", text: raw)
        }, status: { _ in throw AIJobFailure.gone })
        let subject = ContentSummarizer(config: AIConfig(base: "https://example.test/v1", model: "test", key: "test"),
                                        jobs: AIJobClient(transport: transport))
        let result = try await subject.summarize(title: "长片", lines: long, duration: 3600)
        XCTAssertEqual(result.chapters.map(\.t), long.map(\.t))
        XCTAssertEqual(sent.count, long.count + 1)
        for index in long.indices { XCTAssertTrue(sent[index].contains("主题锚点\(index)-")) }
        XCTAssertTrue(sent.last?.contains("[3300]") == true)
    }

    func testChapterTreeKeepsTwelveRootsZeroTimeAndMatchingConcepts() throws {
        let chapters = try ContentSummarizer.parse(reply(), lines: lines, duration: 720).chapters
        let nodes = Outliner.chapterTree(chapters)
        XCTAssertEqual(nodes.count, 12)
        XCTAssertEqual(nodes.map(\.title), chapters.map(\.title))
        XCTAssertEqual(nodes.first?.t, 0)
        XCTAssertEqual(nodes.last?.t, 660)
        XCTAssertTrue(nodes.first!.children.contains { $0.title.contains("依据正文") })
        let data = try JSONSerialization.data(withJSONObject: nodes.map(ClipNoteClient.encodeNode))
        let restored = try JSONDecoder().decode([OutlineNode].self, from: data)
        XCTAssertEqual(restored, nodes)
        XCTAssertTrue(restored.first!.markdown().contains("[00:00]"))
    }
    func testSegmentsRejectRepeatedTimeInsteadOfInventingDistribution() {
        let raw = #"{"segments":[{"t":0,"title":"甲"},{"t":0,"title":"乙"}]}"#
        XCTAssertThrowsError(try Segmenter.parse(raw, transcript: lines))
    }
}
