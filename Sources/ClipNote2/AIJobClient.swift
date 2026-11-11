import Foundation

/// AISummary 里的 `trimmed` 是 fileprivate，别的文件看不见。
private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// 一次后台任务的当前状态。
///
/// 为什么要经过服务端：模型调用要几十秒，而 iOS 一进后台就把请求挂死。
/// 直接调的时候，用户切出去看个消息，回来就是「连不上模型服务」，白等。
/// 改成「提交任务 → 轮询」之后，活儿在服务端跑，切走不影响。
struct AIJobSnapshot: Decodable, Equatable {
    var id: String = ""
    var kind: String = ""
    var status: String = ""
    var text: String?
    var segments: [AIJobSegment]?
    var elapsed: Int?
    /// 上游的结束原因。`length` = 撞到 max_tokens 被截断。
    var finishReason: String?
    var error: AIJobErrorBody?

    var isDone: Bool { status == "done" }
    var isFailed: Bool { status == "failed" }

    enum CodingKeys: String, CodingKey {
        case id, kind, status, text, segments, elapsed, finishReason, error
    }

    init(id: String, kind: String = "", status: String = "queued",
         text: String? = nil, segments: [AIJobSegment]? = nil,
         elapsed: Int? = nil, finishReason: String? = nil,
         error: AIJobErrorBody? = nil) {
        self.id = id
        self.kind = kind
        self.status = status
        self.text = text
        self.segments = segments
        self.elapsed = elapsed
        self.finishReason = finishReason
        self.error = error
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text)
        segments = try c.decodeIfPresent([AIJobSegment].self, forKey: .segments)
        elapsed = try c.decodeIfPresent(Int.self, forKey: .elapsed)
        finishReason = try c.decodeIfPresent(String.self, forKey: .finishReason)
        error = try c.decodeIfPresent(AIJobErrorBody.self, forKey: .error)
    }
}

struct AIJobSegment: Decodable, Equatable, Sendable {
    var start: Double = 0
    var end: Double = 0
    var text: String = ""
}

struct AIJobErrorBody: Decodable, Equatable {
    var code: String = ""
    var message: String = ""
}

enum AIJobFailure: LocalizedError, Equatable {
    case notConfigured
    /// 任务本身失败了（上游 401、模型没回内容等），带服务端给的那句话。
    case failed(String)
    /// 任务过期或服务端重启过。可以重新发起。
    case gone
    case timeout
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "没配模型。去「我 · AI 设置」填好服务地址、模型和 Key。"
        case .failed(let message):
            return message
        case .gone:
            return "这个任务已经过期了（服务端重启或超过一小时），重新发起一次。"
        case .timeout:
            return "等太久了，任务可能还卡在服务端。过一会儿再试。"
        case .transport(let message):
            return "连不上服务端：\(message)。任务已经交上去了，回去之后会自动接着等。"
        }
    }
}

/// 提交任务、轮询结果。
///
/// 轮询特意**不把网络失败当失败**：切到后台时请求会断，那是预期的。
/// 任务在服务端继续跑，回到前台后下一个轮询就能拿到结果。
/// 任务接口的两个动作。抽成闭包是为了能在单测里替换：
/// 直接依赖 `ClipNoteClient` 的话，测试要么打真网络、要么整段跳过。
struct AIJobTransport {
    var create: ([String: Any]) async throws -> AIJobSnapshot
    var status: (String) async throws -> AIJobSnapshot

    static let production = AIJobTransport(
        create: { try await ClipNoteClient.production.createAIJob($0) },
        status: { try await ClipNoteClient.production.aiJob(id: $0) }
    )
}

struct AIJobClient {
    var transport: AIJobTransport = .production
    var pollInterval: TimeInterval = 1.5
    /// 最长等 15 分钟。1 小时的音频按 30 段、每段几秒算，远到不了这个数。
    var maxWait: TimeInterval = 900

    func runChat(
        messages: [[String: String]],
        config: AIConfig,
        maxTokens: Int? = nil
    ) async throws -> String {
        try await runChatResult(messages: messages, config: config, maxTokens: maxTokens).text
    }

    func runChatResult(
        messages: [[String: String]],
        config: AIConfig,
        maxTokens: Int? = nil
    ) async throws -> (text: String, finishReason: String?) {
        guard config.isConfigured, !config.base.trimmed.isEmpty else {
            throw AIJobFailure.notConfigured
        }
        var body: [String: Any] = [
            "kind": "chat",
            "base": config.base,
            "key": config.key,
            "model": config.model,
            "messages": messages,
            "temperature": 0.2,
        ]
        if let maxTokens { body["max_tokens"] = maxTokens }

        let job = try await submit(body)
        let finished = try await wait(job)
        guard let text = finished.text?.trimmed, !text.isEmpty else {
            throw AIJobFailure.failed("模型没给内容（可能是额度或长度限制）")
        }
        return (text, finished.finishReason)
    }

    /// 一段音频的转写。返回纯文本和（可能的）逐句时间。
    func runASR(
        audio: Data,
        mime: String,
        filename: String,
        config: CloudASRConfig
    ) async throws -> (text: String, segments: [AIJobSegment]) {
        guard config.isReady else { throw AIJobFailure.notConfigured }
        let body: [String: Any] = [
            "kind": "asr",
            "base": config.base,
            "key": config.key,
            "model": config.model,
            "audio": audio.base64EncodedString(),
            "mime": mime,
            "filename": filename,
        ]
        let job = try await submit(body)
        let finished = try await wait(job)
        let text = (finished.text ?? "").trimmed
        let segments = finished.segments ?? []
        guard !text.isEmpty || !segments.isEmpty else {
            throw AIJobFailure.failed("这一段没转出文字（可能是静音或语言不对）")
        }
        return (text, segments)
    }

    // MARK: - 提交

    private func submit(_ body: [String: Any]) async throws -> AIJobSnapshot {
        var lastError: Error?
        // 提交本身很快（服务端只是入队）。连不上时重试两次，
        // 别因为电梯里那两秒没信号就让用户重新点一遍。
        for attempt in 0..<3 {
            do {
                return try await transport.create(body)
            } catch let failure as ClipNoteClient.Failure {
                lastError = failure
                guard failure.isTransient else { throw AIJobFailure.failed(failure.displayMessage) }
            } catch {
                lastError = error
            }
            if attempt < 2 {
                try? await Task.sleep(nanoseconds: UInt64(1.2 * Double(attempt + 1) * 1_000_000_000))
            }
        }
        let message = (lastError as? ClipNoteClient.Failure)?.displayMessage
            ?? lastError?.localizedDescription
            ?? "提交失败"
        throw AIJobFailure.transport(message)
    }

    // MARK: - 轮询

    private func wait(_ first: AIJobSnapshot) async throws -> AIJobSnapshot {
        var job = first
        let deadline = Date().addingTimeInterval(maxWait)
        var misses = 0

        while true {
            if job.isDone { return job }
            if job.isFailed {
                throw AIJobFailure.failed(job.error?.message ?? "任务失败")
            }
            if Date() > deadline { throw AIJobFailure.timeout }

            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))

            do {
                job = try await transport.status(job.id)
                misses = 0
            } catch let failure as ClipNoteClient.Failure {
                if case .http(let status, let code, _) = failure, status == 404, code == "JOB_GONE" {
                    throw AIJobFailure.gone
                }
                // 后台断连是预期内的：任务在服务端，回来接着等。
                misses += 1
                if misses > 40 {
                    throw AIJobFailure.transport(failure.displayMessage)
                }
                // 断得越久，间隔越长，别在没网时刷请求
                try? await Task.sleep(nanoseconds: UInt64(min(Double(misses), 6) * 1_000_000_000))
            } catch {
                misses += 1
                if misses > 40 { throw AIJobFailure.transport(error.localizedDescription) }
            }
        }
    }
}
