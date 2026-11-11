import XCTest
@testable import ClipNote2

/// 云端转写。
///
/// 这一层要守住的不是「能调通」，而是三件容易悄悄错的事：
/// 1. 切片必须**无缝无重叠**，否则字幕会漏一段或重复一段；
/// 2. 每段的时间戳要加回**全局偏移**，否则第 10 段的时间还从 0 开始，跳转全错；
/// 3. 服务商只回一段纯文字时，不能因为没时间戳就把文字丢了。
final class CloudTranscribeTests: XCTestCase {

    // MARK: - 切片

    func testZeroDurationPlansNothing() {
        XCTAssertTrue(TranscribeChunkPlanner.plan(durationSeconds: 0).isEmpty)
    }

    func testShortAudioIsOneChunk() {
        let plan = TranscribeChunkPlanner.plan(durationSeconds: 60)
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].startSeconds, 0)
        XCTAssertEqual(plan[0].durationSeconds, 60)
    }

    func testExactlyOneChunkLength() {
        let plan = TranscribeChunkPlanner.plan(durationSeconds: 120)
        XCTAssertEqual(plan.count, 1, "正好 120 秒不该切成两段")
    }

    func testOneSecondOverSpillsIntoSecondChunk() {
        let plan = TranscribeChunkPlanner.plan(durationSeconds: 121)
        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan[1].startSeconds, 120)
        XCTAssertEqual(plan[1].durationSeconds, 1)
    }

    func testChunksCoverAudioWithoutGapsOrOverlap() {
        let plan = TranscribeChunkPlanner.plan(durationSeconds: 600)
        XCTAssertEqual(plan.count, 5)
        XCTAssertEqual(plan.first?.startSeconds, 0)
        XCTAssertEqual(plan.last?.endSeconds, 600, "最后一段必须收在音频末尾")
        for (index, chunk) in plan.enumerated() {
            XCTAssertEqual(chunk.index, index)
            if index > 0 {
                XCTAssertEqual(chunk.startSeconds, plan[index - 1].endSeconds,
                               "段与段之间既不能有缝也不能重叠")
            }
        }
    }

    func testCustomChunkLength() {
        let plan = TranscribeChunkPlanner.plan(durationSeconds: 100, chunkSeconds: 30)
        XCTAssertEqual(plan.map(\.startSeconds), [0, 30, 60, 90])
        XCTAssertEqual(plan.last?.durationSeconds, 10)
    }

    // MARK: - 引擎选择

    func testAutoPicksCloudWhenConfigured() {
        XCTAssertEqual(TranscribeEngineDecision.resolve(preference: .auto, cloudReady: true), .cloud)
    }

    func testAutoFallsBackToOnDeviceWithoutConfig() {
        XCTAssertEqual(TranscribeEngineDecision.resolve(preference: .auto, cloudReady: false), .onDevice)
    }

    func testExplicitOnDeviceIsRespectedEvenWhenCloudIsReady() {
        // 音频要不要离开设备是用户的决定，配了模型也不该覆盖他的选择
        XCTAssertEqual(TranscribeEngineDecision.resolve(preference: .onDevice, cloudReady: true), .onDevice)
    }

    func testExplicitCloudDegradesInsteadOfFailing() {
        XCTAssertEqual(TranscribeEngineDecision.resolve(preference: .cloud, cloudReady: false), .onDevice)
    }

    // MARK: - 模型名

    func testTranscribeModelIsNotTheChatModel() {
        // 拿对话模型名去调 /audio/transcriptions 会 404——这是最容易犯的错
        XCTAssertEqual(TranscribeModel.resolve(base: AIProviderPreset.siliconflow.base, override: ""),
                       "FunAudioLLM/SenseVoiceSmall")
    }

    func testOverrideWins() {
        XCTAssertEqual(TranscribeModel.resolve(base: AIProviderPreset.siliconflow.base,
                                               override: " whisper-1 "),
                       "whisper-1")
    }

    func testProviderWithoutASRHasNoDefault() {
        XCTAssertEqual(TranscribeModel.resolve(base: AIProviderPreset.deepseek.base, override: ""), "")
    }

    func testConfigEndpointHandlesTrailingSlash() {
        let config = CloudASRConfig(base: "https://api.siliconflow.cn/v1/", key: "k", model: "m")
        XCTAssertEqual(config.endpoint?.absoluteString,
                       "https://api.siliconflow.cn/v1/audio/transcriptions")
    }

    func testConfigRequiresAllThree() {
        XCTAssertFalse(CloudASRConfig(base: "", key: "k", model: "m").isReady)
        XCTAssertFalse(CloudASRConfig(base: "b", key: "", model: "m").isReady)
        XCTAssertFalse(CloudASRConfig(base: "b", key: "k", model: "").isReady)
        XCTAssertTrue(CloudASRConfig(base: "b", key: "k", model: "m").isReady)
    }

    // MARK: - 句子与时间

    func testSentencesSplitOnChinesePunctuation() {
        let parts = SpeechTextSplitter.sentences("第一句。第二句！第三句？")
        XCTAssertEqual(parts, ["第一句。", "第二句！", "第三句？"])
    }

    func testTrailingFragmentIsKept() {
        XCTAssertEqual(SpeechTextSplitter.sentences("有结尾。没结尾"), ["有结尾。", "没结尾"])
    }

    func testProportionalChunksCoverTheWindow() {
        let pieces = SpeechTextSplitter.chunks(text: "短句。稍微长一点的一句。", start: 120, duration: 10)
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces[0].t, 120, accuracy: 0.001, "必须从这一段的起点开始")
        let end = pieces.map { $0.t + $0.duration }.max() ?? 0
        XCTAssertEqual(end, 130, accuracy: 0.5, "铺满整个窗口，不留尾巴")
        XCTAssertLessThan(pieces[0].duration, pieces[1].duration, "字数多的那句分到更长的时间")
    }

    func testProportionalKeepsEveryCharacter() {
        let text = "第一句。第二句。第三句。"
        let pieces = SpeechTextSplitter.chunks(text: text, start: 0, duration: 9)
        XCTAssertEqual(pieces.map(\.text).joined(), text, "不许丢字")
    }

    // MARK: - 返回解析

    func testVerboseReplyUsesRealTimestamps() throws {
        let json = """
        {"text":"甲。乙。","segments":[{"start":0.0,"end":2.5,"text":"甲。"},
                                       {"start":2.5,"end":6.0,"text":"乙。"}]}
        """
        let pieces = try CloudASRReply.speechChunks(from: Data(json.utf8),
                                                    offset: 240, window: 120)
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces[0].t, 240, accuracy: 0.001, "偏移要加回去")
        XCTAssertEqual(pieces[1].t, 242.5, accuracy: 0.001)
        XCTAssertEqual(pieces[1].duration, 3.5, accuracy: 0.001)
    }

    func testPlainReplyFallsBackToProportional() throws {
        let json = #"{"text":"没有时间戳的一句。还有一句。"}"#
        let pieces = try CloudASRReply.speechChunks(from: Data(json.utf8),
                                                    offset: 60, window: 30)
        XCTAssertEqual(pieces.count, 2, "没有时间戳也要把句子拆出来")
        XCTAssertEqual(pieces[0].t, 60, accuracy: 0.001)
    }

    func testEmptyReplyYieldsNoChunks() throws {
        let pieces = try CloudASRReply.speechChunks(from: Data(#"{"text":"   "}"#.utf8),
                                                    offset: 0, window: 10)
        XCTAssertTrue(pieces.isEmpty, "空白段不算失败，只要没有字就不返回")
    }

    func testGarbageReplyThrows() {
        XCTAssertThrowsError(try CloudASRReply.speechChunks(from: Data("not json".utf8),
                                                            offset: 0, window: 10))
        XCTAssertThrowsError(try CloudASRReply.speechChunks(from: Data("[1,2]".utf8),
                                                            offset: 0, window: 10))
    }

    // MARK: - 任务提交

    func testASRJobCarriesAudioAndModel() async throws {
        var captured: [String: Any]?
        var client = AIJobClient()
        client.pollInterval = 0.001
        client.transport = AIJobTransport(
            create: { body in
                captured = body
                return AIJobSnapshot(id: "j1", kind: "asr", status: "done",
                                     text: "一段话", segments: [])
            },
            status: { _ in throw AIJobFailure.timeout }
        )

        let config = CloudASRConfig(base: "https://example.test/v1",
                                    key: "sk-test",
                                    model: "FunAudioLLM/SenseVoiceSmall",
                                    language: "zh")
        let reply = try await client.runASR(audio: Data([0x01, 0x02]),
                                            mime: "audio/mp4",
                                            filename: "chunk-0.m4a",
                                            config: config)

        XCTAssertEqual(reply.text, "一段话")
        XCTAssertEqual(captured?["kind"] as? String, "asr")
        XCTAssertEqual(captured?["model"] as? String, "FunAudioLLM/SenseVoiceSmall")
        XCTAssertEqual(captured?["mime"] as? String, "audio/mp4")
        XCTAssertEqual(captured?["audio"] as? String, "AQI=", "音频按 base64 交给服务端")
    }

    // MARK: - 错误文案    // MARK: - 错误文案

    func testErrorsSayWhatToDo() {
        XCTAssertTrue(CloudASRError.notConfigured.errorDescription?.contains("AI 设置") == true)
        XCTAssertTrue(CloudASRError.http(401, "").errorDescription?.contains("Key") == true)
        XCTAssertTrue(CloudASRError.http(404, "").errorDescription?.contains("模型") == true)
        XCTAssertTrue(CloudASRError.http(429, "").errorDescription?.contains("限流") == true)
        let chunk = CloudASRError.chunkFailed(index: 2, startSeconds: 240, message: "超时")
        XCTAssertTrue(chunk.errorDescription?.contains("第 3 段") == true)
        XCTAssertTrue(chunk.errorDescription?.contains("4:00") == true, "要说清是第几分钟，方便重试时判断")
    }

    // MARK: - 与行聚合的接缝

    func testCloudChunksBecomeReadableLines() {
        // 云端回来的句子间隔小，应该被合成连续的行，而不是一句一行
        let chunks = [
            SpeechChunk(t: 0, duration: 1.2, text: "这句话讲的是"),
            SpeechChunk(t: 1.3, duration: 1.0, text: "存储的分层。"),
            SpeechChunk(t: 6.0, duration: 1.0, text: "换了一段。"),
        ]
        let lines = SpeechLineBuilder.lines(from: chunks)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].text, "这句话讲的是存储的分层。")
        XCTAssertEqual(lines[1].t, 6, "行时间是整秒（TranscriptLine.t 是 Int）")
    }
}
