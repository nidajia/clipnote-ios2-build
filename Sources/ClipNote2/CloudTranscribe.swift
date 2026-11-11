import AVFoundation
import Foundation

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// 转写引擎。用户可选，默认按「配没配模型」自动决定。
enum TranscribeEngine: String, CaseIterable, Identifiable {
    case auto
    case cloud
    case onDevice

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "自动"
        case .cloud: return "云端"
        case .onDevice: return "本机"
        }
    }
}

/// 决定这次用哪条路。
///
/// 为什么要「自动」而不是直接默认云端：没配模型的人（或断网时）点进来必须还能用。
/// 但只要有配置，默认就该是云端——本机识别在长视频上慢到不可用，
/// 而且准确率明显不如云端，这一点用户已经明确说过了。
enum TranscribeEngineDecision {
    static func resolve(preference: TranscribeEngine, cloudReady: Bool) -> TranscribeEngine {
        switch preference {
        case .auto: return cloudReady ? .cloud : .onDevice
        case .cloud: return cloudReady ? .cloud : .onDevice
        case .onDevice: return .onDevice
        }
    }
}

/// 云端转写的参数。base / key 复用「我 · AI 设置」里那一份，
/// 用户不需要为转写再配一套凭据。
struct CloudASRConfig: Equatable {
    var base: String
    var key: String
    var model: String
    var language: String = "zh"

    var isReady: Bool {
        !base.trimmed.isEmpty && !key.trimmed.isEmpty && !model.trimmed.isEmpty
    }

    /// OpenAI 兼容的语音转写地址。
    var endpoint: URL? {
        let trimmed = base.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed + "/audio/transcriptions")
    }
}

/// 转写模型和服务商是两套名字：对话模型能聊天，不能转写。
///
/// 所以不能拿 `AIConfig.model` 去调 `/audio/transcriptions`（那会 404），
/// 也不该让用户自己去猜——按 base 认服务商，给一个能用的默认值。
enum TranscribeModel {
    static func presets(for base: String) -> [String] {
        switch AIProviderPreset.match(base: base) {
        case .siliconflow: return ["FunAudioLLM/SenseVoiceSmall"]
        case .dashscope: return ["paraformer-v2", "sensevoice-v1"]
        case .openai: return ["whisper-1", "gpt-4o-mini-transcribe"]
        case .deepseek, .moonshot, .custom: return []
        }
    }

    /// 没显式指定时用第一个预设；服务商不支持就返回空串（此时云端不可用）。
    static func resolve(base: String, override: String) -> String {
        let custom = override.trimmed
        if !custom.isEmpty { return custom }
        return presets(for: base).first ?? ""
    }
}

/// 音频切片。切成段有两个原因：单请求有体积上限，而且**要有进度**——
/// 一小时音频一次上传，界面会几十分钟只有转圈。
struct TranscribeChunk: Equatable {
    var index: Int
    var startSeconds: Int
    var durationSeconds: Int

    var endSeconds: Int { startSeconds + durationSeconds }
}

enum TranscribeChunkPlanner {
    /// 2 分钟一段。再短请求数暴涨，再长单段失败重试代价大、进度也粗。
    static let defaultChunkSeconds = 120

    static func plan(durationSeconds: Int, chunkSeconds: Int = defaultChunkSeconds) -> [TranscribeChunk] {
        guard durationSeconds > 0, chunkSeconds > 0 else { return [] }
        var out: [TranscribeChunk] = []
        var start = 0
        var index = 0
        while start < durationSeconds {
            let length = min(chunkSeconds, durationSeconds - start)
            out.append(TranscribeChunk(index: index, startSeconds: start, durationSeconds: length))
            start += length
            index += 1
        }
        return out
    }
}

/// 把一段纯文本切成句子，并按字数比例分配时间。
///
/// 什么时候用：服务商只回一整段文字、不回逐句时间（SenseVoice 的 `json`
/// 就是这种）。没有时间戳，分段和书签就全废，所以宁可给一个按比例的估计——
/// 2 分钟窗口内，字数和说话时长基本成正比，误差在几秒。
enum SpeechTextSplitter {
    static let sentenceEnds: Set<Character> = ["。", "！", "？", "；", "…", ".", "!", "?", ";"]

    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var buffer = ""
        for char in text {
            buffer.append(char)
            if sentenceEnds.contains(char) {
                let trimmed = buffer.trimmed
                if !trimmed.isEmpty { out.append(trimmed) }
                buffer = ""
            }
        }
        let tail = buffer.trimmed
        if !tail.isEmpty { out.append(tail) }
        return out
    }

    /// 按字数比例铺在 [start, start+duration] 上。
    static func chunks(text: String, start: Double, duration: Double) -> [SpeechChunk] {
        let parts = sentences(text)
        guard !parts.isEmpty else { return [] }
        let totalChars = parts.reduce(0) { $0 + max(1, $1.count) }
        let window = max(duration, 0.1)
        var cursor = start
        var out: [SpeechChunk] = []
        for part in parts {
            let weight = Double(max(1, part.count)) / Double(totalChars)
            let length = window * weight
            out.append(SpeechChunk(t: cursor, duration: length, text: part))
            cursor += length
        }
        return out
    }
}

/// 云端转写的失败原因。每条都要说出「哪一段、为什么、怎么办」。
enum CloudASRError: LocalizedError, Equatable {
    case notConfigured
    case http(Int, String)
    case badReply(String)
    case empty
    case transport(String)
    /// 服务端已经把原因说清楚（401、模型名不对、任务过期…），原样展示。
    case service(String)
    case chunkFailed(index: Int, startSeconds: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "没配转写模型。去「我 · AI 设置」填好服务地址与 Key，或在面板上改用本机转写。"
        case .http(let status, let message):
            switch status {
            case 401, 403:
                return "转写服务拒绝了 Key（\(status)）。到「我 · AI 设置」检查 Key。"
            case 404:
                return "转写模型不存在（404）。这个服务商的模型名可能不一样，去设置里换一个。"
            case 413:
                return "这一段音频太大了，服务商拒收。重试一次；每次都这样就改用本机转写。"
            case 429:
                return "转写服务限流了（429）。等一分钟再试。"
            default:
                let tail = message.isEmpty ? "" : "：\(message)"
                return "转写服务报错 \(status)\(tail)"
            }
        case .badReply(let detail):
            return "转写服务返回了看不懂的内容（\(detail)）。换一个模型试试。"
        case .empty:
            return "识别完了但没有文字。可能是纯音乐、人声太轻，或者音轨是空的。"
        case .transport(let message):
            return "连不上转写服务：\(message)"
        case .service(let message):
            return message
        case .chunkFailed(let index, let start, let message):
            return "第 \(index + 1) 段（第 \(Self.mmss(start)) 起）没成功：\(message)"
        }
    }

    static func mmss(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// 解析 `/audio/transcriptions` 的返回。
///
/// 两种形态都要认：`json` 只有 `text`；`verbose_json` 带逐句 `segments`。
/// 有 segments 就用真时间，没有就按字数比例铺——**不能因为没时间戳就丢掉文字**。
enum CloudASRReply {
    static func speechChunks(from data: Data, offset: Double, window: Double) throws -> [SpeechChunk] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw CloudASRError.badReply("不是 JSON")
        }
        guard let dict = object as? [String: Any] else {
            throw CloudASRError.badReply("顶层不是对象")
        }

        if let segments = dict["segments"] as? [[String: Any]], !segments.isEmpty {
            var out: [SpeechChunk] = []
            for segment in segments {
                let text = (segment["text"] as? String ?? "").trimmed
                guard !text.isEmpty else { continue }
                let start = (segment["start"] as? Double) ?? 0
                let end = (segment["end"] as? Double) ?? (start + 1)
                out.append(SpeechChunk(t: offset + start,
                                       duration: max(0.1, end - start),
                                       text: text))
            }
            if !out.isEmpty { return out }
        }

        let text = (dict["text"] as? String ?? "").trimmed
        guard !text.isEmpty else { return [] }
        return SpeechTextSplitter.chunks(text: text, start: offset, duration: window)
    }
}

/// 云端转写：切片 → 逐段上传 → 合并成带时间戳的行。
///
/// 并发 3 段：串行在 1 小时的内容上要发 30 次请求，等得没有必要；
/// 全并发又会把手机的上行带宽切成碎片、也更容易被限流。
struct CloudTranscriber {
    private let concurrency: Int
    /// 走服务端任务：一段音频要转几十秒，直连时切到后台就断。
    private let jobs: AIJobClient

    init(concurrency: Int = 3, jobs: AIJobClient = AIJobClient()) {
        self.concurrency = max(1, concurrency)
        self.jobs = jobs
    }

    func transcribe(
        audio: URL,
        durationSeconds: Int,
        itemId: String,
        config: CloudASRConfig,
        onProgress: @escaping (Int, Int, Int) -> Void
    ) async throws -> LocalTranscript {
        guard config.isReady else {
            throw CloudASRError.notConfigured
        }
        let chunks = TranscribeChunkPlanner.plan(durationSeconds: durationSeconds)
        guard !chunks.isEmpty else { throw CloudASRError.empty }

        var collected: [SpeechChunk] = []
        var done = 0
        var recognizedChars = 0

        var cursor = 0
        while cursor < chunks.count {
            try Task.checkCancellation()
            let window = Array(chunks[cursor..<min(cursor + concurrency, chunks.count)])
            let results = try await withThrowingTaskGroup(of: (Int, [SpeechChunk]).self) { group in
                for chunk in window {
                    group.addTask {
                        let slice = try await Self.exportSlice(
                            from: audio,
                            startSeconds: chunk.startSeconds,
                            durationSeconds: chunk.durationSeconds
                        )
                        defer { TranscribeCleanup.removeIfScratch(slice) }
                        let data = try Data(contentsOf: slice)
                        let reply = try await upload(
                            chunk: data,
                            chunkMeta: chunk,
                            config: config
                        )
                        return (chunk.index, reply)
                    }
                }
                var out: [(Int, [SpeechChunk])] = []
                for try await value in group { out.append(value) }
                return out
            }

            for (_, pieces) in results.sorted(by: { $0.0 < $1.0 }) {
                collected.append(contentsOf: pieces)
                recognizedChars += pieces.reduce(0) { $0 + $1.text.count }
            }
            done += window.count
            cursor += window.count
            onProgress(done, chunks.count, recognizedChars)
        }

        // 段是并发回来的，时间顺序要重新排；否则字幕会跳来跳去。
        collected.sort { $0.t < $1.t }
        let lines = SpeechLineBuilder.lines(from: collected)
        guard !lines.isEmpty else { throw CloudASRError.empty }

        return LocalTranscript(
            itemId: itemId,
            lines: lines,
            durationSeconds: durationSeconds,
            createdAt: Date(),
            locale: config.language
        )
    }

    // MARK: - 单段

    /// 一段音频交给服务端任务去转。
    ///
    /// 重试放在任务层：提交失败会自己重试两次；任务本身失败了不重试——
    /// 401 或模型名不对这类问题，重发一百次也一样，白白多等两轮。
    private func upload(
        chunk: Data,
        chunkMeta: TranscribeChunk,
        config: CloudASRConfig
    ) async throws -> [SpeechChunk] {
        let reply: (text: String, segments: [AIJobSegment])
        do {
            reply = try await jobs.runASR(
                audio: chunk,
                mime: "audio/mp4",
                filename: "chunk-\(chunkMeta.index).m4a",
                config: config
            )
        } catch let failure as AIJobFailure {
            let message: String
            switch failure {
            case .notConfigured:
                throw CloudASRError.notConfigured
            case .failed(let text):
                message = text
            case .gone:
                message = "任务过期了（服务端重启或超过一小时），重新开始一次。"
            case .timeout:
                message = "等太久了，可能这一段卡住了。"
            case .transport(let text):
                message = text
            }
            throw CloudASRError.chunkFailed(index: chunkMeta.index,
                                             startSeconds: chunkMeta.startSeconds,
                                             message: message)
        } catch is CancellationError {
            throw CancellationError()
        }

        let offset = Double(chunkMeta.startSeconds)
        var pieces: [SpeechChunk] = []
        for segment in reply.segments {
            let text = segment.text.trimmed
            guard !text.isEmpty else { continue }
            pieces.append(SpeechChunk(t: offset + segment.start,
                                      duration: max(0.1, segment.end - segment.start),
                                      text: text))
        }
        if !pieces.isEmpty { return pieces }

        // 服务商只回了一整段文字：按字数比例铺在这个窗口里。
        // 没有时间戳也不能把文字丢掉——分段和书签全靠它。
        return SpeechTextSplitter.chunks(
            text: reply.text,
            start: offset,
            duration: Double(chunkMeta.durationSeconds)
        )
    }

    // MARK: - 切片

    /// 把整条 m4a 的一段导出来。
    ///
    /// 为什么不再从 mp4 切：整条音轨只解一次（`AudioExtractor`），后面切片是
    /// 音频级别的拷贝，几乎不花时间；从视频重新解码每段要几秒，30 段就是几分钟。
    static func exportSlice(
        from audio: URL,
        startSeconds: Int,
        durationSeconds: Int
    ) async throws -> URL {
        let asset = AVURLAsset(url: audio)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw CloudASRError.badReply("音轨切片失败")
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("cn-chunk-\(UUID().uuidString).m4a")
        try? FileManager.default.removeItem(at: output)
        session.outputURL = output
        session.outputFileType = .m4a
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: Double(startSeconds), preferredTimescale: 600),
            duration: CMTime(seconds: Double(durationSeconds), preferredTimescale: 600)
        )

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        guard session.status == .completed else {
            throw CloudASRError.badReply(session.error?.localizedDescription ?? "切片导出失败")
        }
        return output
    }
}
