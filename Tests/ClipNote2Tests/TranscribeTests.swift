import XCTest
@testable import ClipNote2

/// 本机转写的纯逻辑：断行、时间戳单调、覆盖率、落盘、可用性判定。
///
/// 为什么这些值得单测：`SFSpeechRecognizer` 在模拟器上跑不起来（
/// `supportsOnDeviceRecognition` 恒为 false），真机路径在 CI 里一辈子走不到。
/// 于是唯一能自动验证的就是「系统给了一串词，我们把它整理成什么样」——
/// 那恰好是这段代码里唯一会出错、也唯一能测的部分。
final class TranscribeTests: XCTestCase {

    // MARK: - 断行

    func testShortGapsMergeIntoOneLine() {
        let lines = SpeechLineBuilder.lines(from: [
            SpeechChunk(t: 0.0, duration: 0.4, text: "今天"),
            SpeechChunk(t: 0.4, duration: 0.4, text: "我们"),
            SpeechChunk(t: 0.8, duration: 0.4, text: "聊聊"),
        ])
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.text, "我们今天聊聊")
        XCTAssertEqual(lines.first?.t, 0)
    }

    func testLongPauseStartsNewLine() {
        let lines = SpeechLineBuilder.lines(from: [
            SpeechChunk(t: 0, duration: 0.4, text: "今天的会"),
            SpeechChunk(t: 3.0, duration: 0.4, text: "明天继续"),
        ])
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.map(\.text), ["今天的会", "明天继续"])
        XCTAssertEqual(lines.last?.t, 3)
    }

    func testSentenceEndBreaksEvenWithoutPause() {
        let lines = SpeechLineBuilder.lines(from: [
            SpeechChunk(t: 0, duration: 0.4, text: "我们先看结论。"),
            SpeechChunk(t: 0.5, duration: 0.4, text: "再看原因"),
        ])
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.first?.text, "我们先看结论。")
        // 同一秒内的第二行必须往后推一秒，否则界面上两段会并列在同一时间点
        XCTAssertEqual(lines.last?.t, 1)
    }

    func testTimestampsAreStrictlyIncreasing() {
        let lines = SpeechLineBuilder.lines(from: [
            SpeechChunk(t: 2.0, duration: 0.3, text: "第一句话。"),
            SpeechChunk(t: 2.0, duration: 0.3, text: "第二句话。"),
            SpeechChunk(t: 2.0, duration: 0.3, text: "第三句话。"),
        ])
        XCTAssertEqual(lines.count, 3)
        for index in 1..<lines.count {
            XCTAssertGreaterThan(lines[index].t, lines[index - 1].t)
        }
    }

    func testLongChunkForcesBreak() {
        let long = String(repeating: "字", count: 50)
        let lines = SpeechLineBuilder.lines(from: [
            SpeechChunk(t: 0, duration: 1.0, text: long),
            SpeechChunk(t: 1.0, duration: 1.0, text: "结束了这一段落"),
        ])
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.first?.text.count, 50)
    }

    // MARK: - 噪音过滤

    func testFillerOnlyFragmentIsDropped() {
        let lines = SpeechLineBuilder.lines(from: [
            SpeechChunk(t: 0, duration: 0.2, text: "嗯"),
            SpeechChunk(t: 2.0, duration: 0.2, text: "今天我们来聊聊这个"),
        ])
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.text, "今天我们来聊聊这个")
    }

    func testAllFillerStillReturnsLines() {
        // 整条只有语气词时不能返回空数组：上层会把空当成「转写失败」，
        // 而实际上识别是成功的，只是没说人话。
        let lines = SpeechLineBuilder.lines(from: [
            SpeechChunk(t: 0, duration: 0.2, text: "嗯"),
            SpeechChunk(t: 2.0, duration: 0.2, text: "啊"),
        ])
        XCTAssertEqual(lines.count, 2)
    }

    func testEmptyInputProducesNothing() {
        XCTAssertTrue(SpeechLineBuilder.lines(from: []).isEmpty)
        XCTAssertTrue(SpeechLineBuilder.lines(from: [
            SpeechChunk(t: 0, duration: 0.2, text: "   "),
        ]).isEmpty)
    }

    // MARK: - 中英混排

    func testLatinWordsKeepSpaceButChineseDoesNot() {
        let lines = SpeechLineBuilder.lines(from: [
            SpeechChunk(t: 0, duration: 0.3, text: "machine"),
            SpeechChunk(t: 0.3, duration: 0.3, text: "learning"),
            SpeechChunk(t: 0.6, duration: 0.3, text: "模型"),
        ])
        XCTAssertEqual(lines.first?.text, "machine learning模型")
    }

    // MARK: - 覆盖率

    func testCoverageAndCharCount() {
        let transcript = LocalTranscript(
            itemId: "a",
            lines: [TranscriptLine(t: 0, text: "一二三"), TranscriptLine(t: 30, text: "四五六")],
            durationSeconds: 100,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            locale: "zh-CN"
        )
        XCTAssertEqual(transcript.coverage, 0.3, accuracy: 0.0001)
        XCTAssertEqual(transcript.charCount, 6)
        XCTAssertEqual(transcript.lastT, 30)
    }

    func testCoverageIsZeroWithoutDuration() {
        let transcript = LocalTranscript(
            itemId: "a",
            lines: [TranscriptLine(t: 10, text: "一二三")],
            durationSeconds: 0,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            locale: "zh-CN"
        )
        XCTAssertEqual(transcript.coverage, 0)
    }

    func testAPILinesMirrorLocalLines() {
        let transcript = LocalTranscript(
            itemId: "a",
            lines: [TranscriptLine(t: 7, text: "第七秒")],
            durationSeconds: 60,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            locale: "zh-CN"
        )
        // 喂给 Segmenter 的形态必须和服务端字幕一致，否则分段那条链路要分叉
        XCTAssertEqual(transcript.apiLines.first?.t, 7)
        XCTAssertEqual(transcript.apiLines.first?.text, "第七秒")
    }

    // MARK: - 落盘

    func testStoreRoundTrip() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let store = LocalTranscriptStore(directory: sandbox)
        let transcript = LocalTranscript(
            itemId: "douyin/7123456789",
            lines: [TranscriptLine(t: 0, text: "第一行"), TranscriptLine(t: 12, text: "第二行")],
            durationSeconds: 120,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            locale: "zh-CN"
        )
        XCTAssertFalse(store.has(id: transcript.itemId))

        store.save(transcript)
        XCTAssertTrue(store.has(id: transcript.itemId))

        let loaded = try XCTUnwrap(store.load(id: transcript.itemId))
        XCTAssertEqual(loaded.itemId, transcript.itemId)
        XCTAssertEqual(loaded.lines, transcript.lines)
        XCTAssertEqual(loaded.durationSeconds, 120)

        store.remove(id: transcript.itemId)
        XCTAssertNil(store.load(id: transcript.itemId))
    }

    func testStoreFileNamesArePathSafe() {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let store = LocalTranscriptStore(directory: sandbox)
        // 带斜杠的 id 不能直接当文件名，否则会写到不存在的子目录里，静默失败
        let transcript = LocalTranscript(
            itemId: "xiaohongshu/65f0a1b2",
            lines: [TranscriptLine(t: 0, text: "有内容")],
            durationSeconds: 10,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            locale: "zh-CN"
        )
        store.save(transcript)
        XCTAssertNotNil(store.load(id: transcript.itemId))
        XCTAssertFalse(store.url(for: transcript.itemId).lastPathComponent.contains("/"))
    }

    // MARK: - 可用性判定

    func testGateWithoutRecognizerIsUnavailable() {
        let support = TranscribeGate.support(hasRecognizer: false, onDevice: false)
        guard case .unavailable(let reason) = support else {
            return XCTFail("没有识别器时不该给出「可用」")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    func testGateWithoutOnDeviceAssetsNeedsAssets() {
        // 模拟器走的就是这一支：引擎在，但本机识别跑不了
        XCTAssertEqual(TranscribeGate.support(hasRecognizer: true, onDevice: false), .needsAssets)
    }

    func testGateReadyOnlyWhenBothHold() {
        XCTAssertEqual(TranscribeGate.support(hasRecognizer: true, onDevice: true), .ready)
    }

    func testSupportMessagesAreActionable() {
        // 三条文案都要说清「为什么」或「怎么办」，不能只说「不可用」
        XCTAssertTrue(TranscribeSupport.needsAssets.message.contains("听写"))
        if case .unavailable(let reason) = TranscribeSupport.unavailable("测试原因") {
            XCTAssertEqual(reason, "测试原因")
        }
        XCTAssertFalse(TranscribeSupport.ready.message.isEmpty)
    }
}
