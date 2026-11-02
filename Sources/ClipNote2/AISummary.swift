import Foundation
import Security

/// AI 配置。key 存 Keychain，不进 UserDefaults、不进仓库、不进 App 包。
struct AIConfig: Codable, Equatable {
    var base: String = ""
    var model: String = ""
    var key: String = ""

    var isConfigured: Bool {
        !base.trimmed.isEmpty && !model.trimmed.isEmpty && !key.trimmed.isEmpty
    }

    /// OpenAI 兼容的 chat/completions 地址
    var endpoint: URL? {
        let trimmed = base.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed + "/chat/completions")
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// 常见服务商。base 与 model 都只是「预填」，用户可以改。
enum AIProviderPreset: String, CaseIterable, Identifiable {
    case siliconflow, dashscope, deepseek, moonshot, openai, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .siliconflow: return "硅基流动"
        case .dashscope: return "阿里百炼 · 千问"
        case .deepseek: return "DeepSeek"
        case .moonshot: return "月之暗面"
        case .openai: return "OpenAI"
        case .custom: return "自定义（OpenAI 兼容）"
        }
    }

    var base: String {
        switch self {
        case .siliconflow: return "https://api.siliconflow.cn/v1"
        case .dashscope: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .deepseek: return "https://api.deepseek.com/v1"
        case .moonshot: return "https://api.moonshot.cn/v1"
        case .openai: return "https://api.openai.com/v1"
        case .custom: return ""
        }
    }

    var model: String {
        switch self {
        case .siliconflow: return "Qwen/Qwen2.5-7B-Instruct"
        case .dashscope: return "qwen-plus"
        case .deepseek: return "deepseek-chat"
        case .moonshot: return "moonshot-v1-8k"
        case .openai: return "gpt-4o-mini"
        case .custom: return ""
        }
    }

    /// 从已存的 base 反推服务商，用于回显
    static func match(base: String) -> AIProviderPreset {
        allCases.first { !$0.base.isEmpty && $0.base == base } ?? .custom
    }
}

enum AIConfigStore {
    private static let service = "com.clipnote.v2.ai"
    private static let account = "default"

    static func load() -> AIConfig {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let config = try? JSONDecoder().decode(AIConfig.self, from: data)
        else { return AIConfig() }
        return config
    }

    @discardableResult
    static func save(_ config: AIConfig) -> Bool {
        guard let data = try? JSONEncoder().encode(config) else { return false }
        SecItemDelete(baseQuery as CFDictionary)
        var query = baseQuery
        query[kSecValueData as String] = data
        // 只在本机可用、解锁后可读：不参与 iCloud 钥匙串同步
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// 生成结果
struct SummaryResult: Equatable {
    var summary: String
    var keyPoints: [String]
    var labels: [String]
}

enum SummarizeFailure: Error, Equatable {
    case notConfigured
    case http(Int, String)
    case transport(String)
    case emptyReply
    case unparsable(String)

    var displayMessage: String {
        switch self {
        case .notConfigured:
            return "还没配置 AI 服务。"
        case .http(let status, let detail):
            return detail.isEmpty ? "服务返回 \(status)。" : detail
        case .transport(let detail):
            return "连不上模型服务。\(detail)"
        case .emptyReply:
            return "模型返回了空内容。"
        case .unparsable(let raw):
            return "模型没有按 JSON 回答：\(raw.prefix(40))"
        }
    }
}

/// 调用户自己的模型服务，生成摘要 / 要点 / 标签。
///
/// 为什么在手机上直接调、不经我们服务端：key 是用户自己的，额度也是用户的。
/// 服务端代调意味着任何拿到分享链接的人都能花他的额度。
struct Summarizer {
    var config: AIConfig
    var session: URLSession = .shared

    func summarize(
        title: String,
        description: String,
        platform: String,
        duration: String
    ) async throws -> SummaryResult {
        guard config.isConfigured, let endpoint = config.endpoint else {
            throw SummarizeFailure.notConfigured
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.key)", forHTTPHeaderField: "Authorization")

        let payload: [String: Any] = [
            "model": config.model,
            "temperature": 0.3,
            "messages": [
                ["role": "system", "content": Self.instructions],
                ["role": "user", "content": Self.userContent(
                    title: title, description: description,
                    platform: platform, duration: duration
                )],
            ],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            throw SummarizeFailure.unparsable("请求体拼不出来")
        }
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SummarizeFailure.transport(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let text = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw SummarizeFailure.http(http.statusCode, text)
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw SummarizeFailure.emptyReply
        }

        return try Self.parse(content)
    }

    /// 测试连接用：一次极短的调用，只为确认 base / model / key 三样都对。
    func ping() async throws {
        _ = try await summarize(title: "连接测试", description: "只回一个 JSON 即可。",
                                platform: "", duration: "")
    }

    // MARK: - 提示词

    private static let instructions = """
    你是「片记」的内容摘要助手。只输出一个 JSON 对象，不要任何解释、不要 Markdown 代码块。
    格式：
    {"summary": "60-110 字的中文概述", "keyPoints": ["3-6 条要点"], "labels": ["3-6 个标签"]}
    要求：
    - 只依据用户给出的标题与简介，不要编造具体数字、时间或结论。
    - 信息不足时，summary 直说「可用信息有限」，不要硬凑。
    - keyPoints 每条不超过 30 字，说人话。
    - labels 是名词性标签，每个不超过 6 字。
    """

    private static func userContent(
        title: String, description: String, platform: String, duration: String
    ) -> String {
        var lines = ["标题：\(title)"]
        if !platform.isEmpty { lines.append("平台：\(platform)") }
        if !duration.isEmpty { lines.append("时长：\(duration)") }
        lines.append("简介：\(description.isEmpty ? "（没有简介）" : description)")
        return lines.joined(separator: "\n")
    }

    // MARK: - 解析

    /// 模型经常把 JSON 包在 ```json 里，或者前后加一句话。这里只认最外层那对花括号。
    static func parse(_ raw: String) throws -> SummaryResult {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            // 去掉首行的 ```json / ``` 和结尾的 ```
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            if let fence = text.range(of: "```", options: .backwards) {
                text = String(text[..<fence.lowerBound])
            }
        }
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end
        else {
            throw SummarizeFailure.unparsable(text)
        }
        let jsonText = String(text[start...end])

        guard let data = jsonText.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw SummarizeFailure.unparsable(jsonText)
        }

        let summary = (root["summary"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else {
            throw SummarizeFailure.unparsable(jsonText)
        }

        return SummaryResult(
            summary: summary,
            keyPoints: strings(root["keyPoints"], limit: 8, maxLength: 80),
            labels: strings(root["labels"], limit: 8, maxLength: 20)
        )
    }

    private static func strings(_ raw: Any?, limit: Int, maxLength: Int) -> [String] {
        guard let array = raw as? [Any] else { return [] }
        var out: [String] = []
        for one in array {
            let text = (one as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            out.append(String(text.prefix(maxLength)))
            if out.count >= limit { break }
        }
        return out
    }
}
