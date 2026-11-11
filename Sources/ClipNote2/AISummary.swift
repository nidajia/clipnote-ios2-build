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

        // 先 update，不存在才 add。
        //
        // 原来是 delete + add：中间有一瞬间条目不存在，而这期间任何一次
        // load() 都会拿到空配置。更要紧的是 add 依赖 delete 真的删掉了，
        // 一旦 delete 因为任何原因没匹配上，add 会返回 errSecDuplicateItem，
        // 于是「保存成功」其实什么都没改——真机上就是这个表现。
        let query = baseQuery
        let attributes: [String: Any] = [kSecValueData as String: data]

        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }

        var insert = baseQuery
        insert[kSecValueData as String] = data
        // 只在本机可用、解锁后可读：不参与 iCloud 钥匙串同步
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
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

// MARK: - 模型列表
//
// 服务商的 `/models` 只返回 id，**不返回「这是不是对话模型」**。
// 所以「备注」只能本地按名字猜。猜错的代价是用户选了个向量模型、
// 然后收到一句看不懂的 400，所以宁可多藏几个：embed / rerank / tts
// 这些默认不出现在列表里，要看得手动打开「显示全部」。

struct AIModel: Identifiable, Equatable {
    var id: String
    /// 「通义千问 · 对话模型」这种，帮用户看懂这串 id 是什么
    var note: String
    /// 能不能拿来聊天。不能的默认收起来。
    var chattable: Bool
}

enum ModelCatalog {
    /// 拉服务商的模型列表。`GET {base}/models`，OpenAI 兼容接口都有这个。
    static func fetch(
        base: String,
        key: String,
        session: URLSession = .shared
    ) async throws -> [AIModel] {
        let trimmed = base.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty, let url = URL(string: trimmed + "/models") else {
            throw SummarizeFailure.notConfigured
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

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

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SummarizeFailure.unparsable(String(data: data.prefix(80), encoding: .utf8) ?? "")
        }

        // OpenAI / 硅基流动 / 月之暗面 都是 {"data":[{"id":…}]}；
        // 少数网关用 {"models":[…]}，一起认了。
        var ids: [String] = []
        if let list = root["data"] as? [[String: Any]] {
            ids = list.compactMap { $0["id"] as? String }
        } else if let list = root["models"] as? [[String: Any]] {
            ids = list.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }
        }

        var seen = Set<String>()
        var out: [AIModel] = []
        for id in ids {
            let name = id.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty || seen.contains(name) { continue }
            seen.insert(name)
            let info = note(for: name)
            out.append(AIModel(id: name, note: info.note, chattable: info.chattable))
        }
        guard !out.isEmpty else {
            throw SummarizeFailure.unparsable("列表是空的")
        }
        // 能聊天的排前面，其次按名字：用户九成是在找第一个
        return out.sorted { lhs, rhs in
            if lhs.chattable != rhs.chattable { return lhs.chattable }
            return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
    }

    /// 按名字猜用途。这是**猜测**，不是接口给的事实——
    /// 所以文案里只说「对话模型」这种粗分类，不说参数量、不说上下文长度。
    static func note(for id: String) -> (note: String, chattable: Bool) {
        let lower = id.lowercased()

        func kind(_ text: String, chattable: Bool = true) -> (String, Bool) {
            let vendor = vendorName(lower)
            return (vendor.isEmpty ? text : "\(vendor) · \(text)", chattable)
        }

        // 先判重排：`bge-reranker` 里也含 `bge`，顺序反了会被认成向量模型
        if lower.contains("rerank") { return kind("重排模型", chattable: false) }
        // bge / gte / m3e 是常见的向量模型前缀，名字里根本不带 embed
        if lower.contains("embed") || lower.contains("bge")
            || lower.contains("gte-") || lower.contains("m3e") {
            return kind("向量模型", chattable: false)
        }
        if lower.contains("whisper") || lower.contains("sensevoice")
            || lower.contains("paraformer") || lower.contains("asr") {
            return kind("语音识别", chattable: false)
        }
        if lower.contains("tts") || lower.contains("cosyvoice") || lower.contains("audio") {
            return kind("语音合成", chattable: false)
        }
        if lower.contains("flux") || lower.contains("sdxl") || lower.contains("stable-diffusion")
            || lower.contains("kolors") || lower.contains("image") {
            return kind("图片生成", chattable: false)
        }
        if lower.contains("reasoner") || lower.contains("-r1") || lower.contains("thinking")
            || lower.contains("-think") {
            return kind("推理模型")
        }
        if lower.contains("-vl") || lower.contains("vision") || lower.contains("omni") {
            return kind("视觉理解")
        }
        if lower.contains("coder") || lower.contains("code") {
            return kind("代码模型")
        }
        return kind("对话模型")
    }

    private static func vendorName(_ lower: String) -> String {
        if lower.contains("qwen") || lower.contains("qwq") { return "通义千问" }
        if lower.contains("deepseek") { return "DeepSeek" }
        if lower.contains("glm") || lower.contains("chatglm") { return "智谱" }
        if lower.contains("moonshot") || lower.contains("kimi") { return "月之暗面" }
        if lower.contains("gpt") || lower.contains("o1") || lower.contains("o3") { return "OpenAI" }
        if lower.contains("claude") { return "Anthropic" }
        if lower.contains("llama") { return "Llama" }
        if lower.contains("yi-") { return "零一万物" }
        if lower.contains("internlm") { return "书生" }
        if lower.contains("baichuan") { return "百川" }
        return ""
    }
}

/// 标签的封闭分类表。
///
/// 为什么不让模型自由发挥：线上实测 3 条内容产出 12 个标签，**每个都只出现一次**，
/// 而且「互联网泡沫 / AI泡沫 / 资本泡沫 / 科技泡沫」说的是同一件事。
/// 这样的标签页等于「12 个词，每个点进去 1 条」，比收藏夹本身还没用。
///
/// 标签的职责是**聚合**，不是描述。描述已经由 summary 和 keyPoints 承担了。
/// 所以这份表要足够宽（覆盖常见内容类型），但必须封闭。
enum TagVocabulary {
    static let all: [String] = [
        "AI", "科技", "编程", "产品", "设计",
        "商业", "投资", "财经", "创业", "营销",
        "职场", "效率", "学习", "教育", "心理",
        "健康", "运动", "饮食", "旅行", "生活",
        "历史", "文化", "艺术", "影视", "音乐",
        "游戏", "科普", "法律", "其他",
    ]

    /// 提示词里那一句。单独抽出来，改词表时不用去动整段 instructions。
    static var promptLine: String {
        "- labels 只能从下面这份分类表里选，选 2 到 3 个，**原样照抄**，不要自造，不要改写：\n"
            + "  " + all.joined(separator: "、") + "\n"
            + "  这份表是封闭的。它是用来把多条内容串起来的分类，不是这一条的描述；\n"
            + "  具体的人名、事件、产品名写在 summary 里，不要塞进 labels。\n"
            + "  实在没有合适的才用「其他」，且最多一个。"
    }
}

/// 生成结果
struct SummaryResult: Equatable {
    var summary: String
    var keyPoints: [String]
    var labels: [String]
}

extension SummarizeFailure {
    /// 任务层的失败翻成界面能直接显示的话。三处共用，别各写一份。
    static func from(_ failure: AIJobFailure) -> SummarizeFailure {
        switch failure {
        case .notConfigured: return .notConfigured
        case .failed(let message): return .service(message)
        case .gone: return .service("任务过期了（服务端重启或超过一小时），重新生成一次。")
        case .timeout: return .service("等太久了，稍后再试。")
        case .transport(let message): return .service(message)
        }
    }
}

enum SummarizeFailure: Error, Equatable {
    case notConfigured
    case http(Int, String)
    case transport(String)
    case emptyReply
    /// 模型被输出上限截断了。和 `unparsable` 分开：
    /// 前者是「把上限调大就好」，后者是「模型没按格式回答」，处理方式完全不同。
    case truncated
    case unparsable(String)
    /// 服务端已经把原因说清楚了，原样展示。
    case service(String)

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
        case .truncated:
            return "模型的回复被截断了，分段没写完。换一个输出上限更大的模型，或先缩短这条视频。"
        case .service(let message):
            return message
        case .unparsable(let raw):
            // 把长度也带出来：接近上限就说明是截断，而不是模型乱答。
            // 只给开头 40 字时，这两种原因在日志里长得一模一样，
            // 排查会走错方向（真机上就为这个多花了一轮）。
            return "模型没有按 JSON 回答（\(raw.count) 字）：\(raw.prefix(32))"
        }
    }
}

/// 调用户自己的模型服务，生成摘要 / 要点 / 标签。
///
/// 调用改走服务端任务（2026-11-11）。
///
/// 原来在手机上直接调，理由是「key 和额度都是用户的，服务端代调会让拿到分享链接的人
/// 花他的额度」。这条代价被接受了：直连时一切到后台请求就挂死，用户只能干等——
/// 那是每天都会遇到的，而分享链接只有他自己有。任务接口仍要共享码，
/// Key 只在任务存续期内留在内存，结束即清。
struct Summarizer {
    var config: AIConfig
    var jobs: AIJobClient = AIJobClient()
    /// 摘要模板。只影响这一条链路（见 `SummaryTemplate` 顶部说明）。
    var template: SummaryTemplate = SummaryTemplateStore.load()
    var customPrompt: String = SummaryTemplateStore.loadCustomPrompt()

    func summarize(
        title: String,
        description: String,
        platform: String,
        duration: String
    ) async throws -> SummaryResult {
        guard config.isConfigured else {
            throw SummarizeFailure.notConfigured
        }

        let messages: [[String: String]] = [
            ["role": "system", "content": Self.instructions(
                template: template, customPrompt: customPrompt
            )],
            ["role": "user", "content": Self.userContent(
                title: title, description: description,
                platform: platform, duration: duration
            )],
        ]

        let content: String
        do {
            content = try await jobs.runChat(messages: messages, config: config)
        } catch let failure as AIJobFailure {
            throw SummarizeFailure.from(failure)
        }

        return try Self.parse(content)
    }

    /// 测试连接用：一次极短的调用，只为确认 base / model / key 三样都对。
    func ping() async throws {
        _ = try await summarize(title: "连接测试", description: "只回一个 JSON 即可。",
                                platform: "", duration: "")
    }

    // MARK: - 提示词

    static func instructions(template: SummaryTemplate, customPrompt: String) -> String {
        var text = baseInstructions
        let extra: String
        if template == .custom {
            extra = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            extra = template.instruction
        }
        if !extra.isEmpty {
            text += "\n" + extra
        }
        return text
    }

    private static let baseInstructions = """
    你是「片记」的内容摘要助手。只输出一个 JSON 对象，不要任何解释、不要 Markdown 代码块。
    格式：
    {"summary": "60-110 字的中文概述", "keyPoints": ["3-6 条要点"], "labels": ["2-3 个分类"]}
    要求：
    - 只依据用户给出的标题与简介，不要编造具体数字、时间或结论。
    - 信息不足时，summary 直说「可用信息有限」，不要硬凑。
    - keyPoints 每条不超过 30 字，说人话。
    """ + "\n" + TagVocabulary.promptLine

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

// MARK: - 分段总结
//
// 为什么要在手机上报一次再发：B 站的 AI 字幕是「按 1~2 秒硬切、没有标点」的碎片，
// 一条 30 分钟的视频有 800 多行。原样丢给模型有两个问题：
//   1. 每行带一个时间戳，结构开销比正文还大；
//   2. 句子被切碎了，模型读到的是「综合能力反超CLAUDE」接「重夺地表最强」，
//      它会把两件事当成一件。
// 所以先按时间窗口合并成整句，再喂。这不是省 token，是让模型能读。

enum TranscriptCompressor {
    /// 单行喂给模型时，前面挂的秒数标记。用原始秒数而不是「12:30」：
    /// 让模型做一次「分:秒 → 秒」的换算，就一定会出现 ±1 秒的误差，
    /// 而我们要求它**原样抄**这个数字，换算误差从源头上没有了。
    static func compress(
        _ lines: [APITranscriptLine],
        window: Int
    ) -> [(t: Int, text: String)] {
        var out: [(t: Int, text: String)] = []
        var start: Int?
        var bucket: [String] = []

        func flush() {
            guard let begin = start, !bucket.isEmpty else { return }
            out.append((t: begin, text: bucket.joined(separator: "，")))
            start = nil
            bucket = []
        }

        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            if start == nil { start = line.t }
            bucket.append(text)
            // 一旦这一桶跨过窗口，就在**下一句**之前收口，
            // 不把正在说的半句话切成两段。
            if line.t - (start ?? line.t) >= window {
                flush()
            }
        }
        flush()
        return out
    }

    /// 按总字数自动选窗口：短内容 25 秒，长的逐步放宽到 60 秒。
    ///
    /// 目标不是「压到多少字」，而是「让 8k 上下文的模型装得下」。
    /// 实测中文约 1.5 字一个 token，所以 12000 字 ≈ 8000 token，是上限。
    static func plan(_ lines: [APITranscriptLine]) -> [(t: Int, text: String)] {
        var window = 25
        var blocks = compress(lines, window: window)
        while window < 60 {
            let chars = blocks.reduce(0) { $0 + $1.text.count }
            if blocks.count <= 140, chars <= 12000 { break }
            window += 5
            blocks = compress(lines, window: window)
        }
        return blocks
    }
}

/// 一次分段生成的体检数据。
///
/// 为什么要记这些：分段的好坏在模拟器里看不出来（截图用的是手写常量）。
/// 真机跑完只有四个能自动判定的信号，靠它们而不是靠肉眼：
///   1. 段数是否落在 4–9
///   2. 首段是否为 0、末段是否覆盖到 80% 以后
///   3. 模型给的原始秒数里有多少**恰好**命中转写时间点（`exact`）
///   4. 喂进去多少字（`chars`）——判断是不是顶到上下文上限了
struct SegmentStats: Equatable {
    /// 模型给了几段
    var raw = 0
    /// 原始 t 恰好等于某个已知时间点的条数。偏低说明模型在「自己换算」
    var exact = 0
    /// 被吸附改过位置的条数
    var snapped = 0
    var firstT = 0
    var lastT = 0
    /// 压缩后喂模型的块数与字数
    var blocks = 0
    var chars = 0
}

struct SegmentOutcome {
    var segments: [APISegment]
    var stats: SegmentStats
}

/// 从转写里挑几个「值得回看的点」。
///
/// 和分段的分工：分段回答「这条讲了什么」（覆盖全片、按顺序），
/// 建议回答「如果我只看三分钟，该看哪三分钟」（稀疏、按价值）。
/// 两者都基于同一份字幕，所以**不需要额外拉一次转写**。
struct BookmarkSuggestor {
    var config: AIConfig
    /// 走服务端任务：这条也要几十秒，直连时切到后台就断。
    var jobs: AIJobClient = AIJobClient()

    func suggest(
        title: String,
        lines: [APITranscriptLine],
        existing: [APIBookmark]
    ) async throws -> [APIBookmark] {
        guard config.isConfigured else {
            throw SummarizeFailure.notConfigured
        }
        let blocks = TranscriptCompressor.plan(lines)
        guard !blocks.isEmpty else { throw SummarizeFailure.emptyReply }

        let messages: [[String: String]] = [
            ["role": "system", "content": Self.instructions],
            ["role": "user", "content": Self.userContent(
                title, blocks: blocks, existing: existing
            )],
        ]
        // 3 条建议 × 约 60 token，1200 够用且不会被默认值截断
        let reply: (text: String, finishReason: String?)
        do {
            reply = try await jobs.runChatResult(messages: messages, config: config, maxTokens: 1200)
        } catch let failure as AIJobFailure {
            throw SummarizeFailure.from(failure)
        }
        if reply.finishReason == "length" { throw SummarizeFailure.truncated }

        return try Self.parse(reply.text, transcript: lines)
    }

    // MARK: - 提示词

    private static let instructions = """
    你是「片记」的标记助手。用户把视频转成了文字稿，请从中挑出 3 个最值得回看的点。
    只输出一个 JSON 对象，不要任何解释、不要 Markdown 代码块。
    格式：{"bookmarks":[{"t": 123, "note": "为什么值得回看，20 字以内"}]}
    要求：
    - 必须正好 3 条。
    - t 必须是方括号里的**原始秒数**，原样照抄，不要自己换算、不要四舍五入。
    - 三条之间至少隔 60 秒，别挤在一起。
    - note 要说「看到了什么」或「为什么值得回看」，不要写「重点」「精彩」这种空话。
    - 挑的是「一眼会想再看一遍」的地方：关键结论、反转、具体案例、有数字的段。
    """

    private static func userContent(
        _ title: String, blocks: [(t: Int, text: String)], existing: [APIBookmark]
    ) -> String {
        var head = "视频标题：\(title)\n\n文字稿（方括号内是秒数）：\n"
        head += blocks.map { "[\($0.t)] \($0.text)" }.joined(separator: "\n")
        if !existing.isEmpty {
            // 已经标过的位置不用再建议一遍，否则用户会觉得 AI 没记住
            let marked = existing.map { "\($0.t)" }.joined(separator: "、")
            head += "\n\n用户已经标过这些秒数，请避开：\(marked)"
        }
        return head
    }

    // MARK: - 解析

    static func parse(_ raw: String, transcript: [APITranscriptLine]) throws -> [APIBookmark] {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            if let fence = text.range(of: "```", options: .backwards) {
                text = String(text[..<fence.lowerBound])
            }
        }
        // 先逐个捡完整对象：模型少写半个大括号时，前面的书签还能保住。
        var array: [Any] = JSONSalvage.objects(text, key: "bookmarks")
        if array.isEmpty {
            guard let root = JSONSalvage.root(text),
                  let whole = root["bookmarks"] as? [Any]
            else { throw SummarizeFailure.unparsable(text) }
            array = whole
        }

        let known = transcript.map(\.t).sorted()
        var out: [APIBookmark] = []
        var seen = Set<Int>()
        for one in array {
            guard let dict = one as? [String: Any] else { continue }
            let note = (dict["note"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let value = (dict["t"] as? Int) ?? Int((dict["t"] as? Double) ?? 0)
            let t = Segmenter.snap(value, to: known)
            // 吸附之后可能两条撞到同一秒，去重，否则用户会看到两个旗子重叠
            guard !seen.contains(t) else { continue }
            seen.insert(t)
            out.append(APIBookmark(t: t, note: String(note.prefix(40)), by: "ai"))
            if out.count >= 5 { break }
        }
        guard !out.isEmpty else { throw SummarizeFailure.unparsable(text) }
        out.sort { $0.t < $1.t }
        return out
    }
}

/// 把转写切成带时间戳的语义段。
///
/// 和 `Summarizer` 分开而不是合一次调用：
/// 摘要的提示词是调好的（用户认可了输出），把它和分段揉在一起，
/// 等于拿一个已验证的效果去赌一个没验证的。
struct Segmenter {
    var config: AIConfig
    /// 走服务端任务：分段要几十秒，直连时切到后台就断。
    var jobs: AIJobClient = AIJobClient()

    func segments(
        title: String,
        lines: [APITranscriptLine],
        durationSeconds: Int
    ) async throws -> SegmentOutcome {
        guard config.isConfigured else {
            throw SummarizeFailure.notConfigured
        }
        let blocks = TranscriptCompressor.plan(lines)
        guard !blocks.isEmpty else {
            throw SummarizeFailure.emptyReply
        }

        let messages: [[String: String]] = [
            ["role": "system", "content": Self.instructions],
            ["role": "user", "content": Self.userContent(
                title: title, duration: durationSeconds, blocks: blocks
            )],
        ]

        // 必须显式给输出上限。不给的话各家默认值不一样（硅基流动 512 上下），
        // 长视频要 8–9 段、每段标题 + 一句理解，输出会**正好卡在中间被截断**。
        // 12 段 × 约 100 token = 1200，给 2400 留一倍余量。
        let reply: (text: String, finishReason: String?)
        do {
            reply = try await jobs.runChatResult(messages: messages, config: config, maxTokens: 2400)
        } catch let failure as AIJobFailure {
            throw SummarizeFailure.from(failure)
        }

        // 先看有没有被截断，再解析。反过来的话，截断会伪装成「模型没按 JSON 回答」，
        // 而这两件事的处理方式完全相反：一个要调大上限，一个要改提示词。
        if reply.finishReason == "length" {
            throw SummarizeFailure.truncated
        }

        let (segments, stats) = try Self.parseDetailed(reply.text, transcript: lines)
        var outcome = stats
        outcome.blocks = blocks.count
        outcome.chars = blocks.reduce(0) { $0 + $1.text.count }
        return SegmentOutcome(segments: segments, stats: outcome)
    }

    // MARK: - 提示词

    private static let instructions = """
    你是「片记」的分段整理助手。用户会给你一条视频的转写，每行以 [秒] 开头。

    把整条内容按语义转折切成若干段，每段给一个标题和一句理解。
    只输出一个 JSON 对象，不要任何解释、不要 Markdown 代码块：
    {"segments":[{"t":0,"title":"…","summary":"…"}]}

    要求：
    - t 必须原样抄某一行的方括号数字，不要自己换算，不要加偏移。第一段用 0。
    - 段数按内容定：内容少就 4 段，不要为凑数硬拆；最多 9 段。
    - 段与段之间必须是真正的转折（换话题、换案例、下结论），不是按时间均分。
    - 标题不超过 14 字，用陈述句；不要写「第一部分」「接下来」这种编号。
    - summary 是 20 到 45 字的一句理解：这段讲了什么、为什么重要。
      不要把标题换个说法再写一遍，也不要复述原话。
    - 转写没有标点、可能有错别字，按上下文理解。不要纠正专有名词，也不要补上原文没有的数字。
    - 按时间顺序输出。
    """

    private static func userContent(
        title: String, duration: Int, blocks: [(t: Int, text: String)]
    ) -> String {
        var lines = ["标题：\(title)"]
        if duration > 0 {
            lines.append("时长：\(duration / 60) 分 \(duration % 60) 秒")
        }
        lines.append("转写：")
        for block in blocks {
            lines.append("[\(block.t)] \(block.text)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 解析

    static func parse(_ raw: String, transcript: [APITranscriptLine]) throws -> [APISegment] {
        try parseDetailed(raw, transcript: transcript).segments
    }

    /// 真解析。多回一份 `stats`：真机上判断分段质量只能靠这几个数，
    /// 而截图里用的永远是手写样本，证明不了提示词好不好。
    static func parseDetailed(
        _ raw: String, transcript: [APITranscriptLine]
    ) throws -> (segments: [APISegment], stats: SegmentStats) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            if let fence = text.range(of: "```", options: .backwards) {
                text = String(text[..<fence.lowerBound])
            }
        }
        // 同上：先捡完整对象，尾巴被截断时保住前面的段。
        // 分段比书签更怕全丢——没有分段，整条视频的导航就没了。
        var array: [Any] = JSONSalvage.objects(text, key: "segments")
        if array.isEmpty {
            guard let root = JSONSalvage.root(text),
                  let whole = root["segments"] as? [Any]
            else { throw SummarizeFailure.unparsable(text) }
            array = whole
        }

        // 模型给的 t 常常落在两个时间戳中间（比如给 137，而转写只有 130 和 152）。
        // 不修正而是吸附到最近的已知时间点：这样点一下就一定能跳到有内容的位置。
        let known = transcript.map(\.t).sorted()
        let knownSet = Set(known)
        var stats = SegmentStats(raw: array.count)
        var out: [APISegment] = []

        for one in array {
            guard let dict = one as? [String: Any] else { continue }
            let title = (dict["title"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty { continue }
            let value = (dict["t"] as? Int) ?? Int((dict["t"] as? Double) ?? 0)
            if knownSet.contains(value) {
                stats.exact += 1
            } else {
                stats.snapped += 1
            }
            let summary = (dict["summary"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(APISegment(
                title: String(title.prefix(30)),
                t: snap(value, to: known),
                summary: String(summary.prefix(80))
            ))
            if out.count >= 12 { break }
        }

        guard !out.isEmpty else { throw SummarizeFailure.unparsable(text) }
        out.sort { $0.t < $1.t }
        stats.firstT = out.first?.t ?? 0
        stats.lastT = out.last?.t ?? 0
        return (out, stats)
    }

    /// 吸附到最近的已知时间点。`known` 已排序，二分即可。
    static func snap(_ value: Int, to known: [Int]) -> Int {
        guard !known.isEmpty else { return max(0, value) }
        var low = 0
        var high = known.count - 1
        while low < high {
            let mid = (low + high) / 2
            if known[mid] < value { low = mid + 1 } else { high = mid }
        }
        // low 是第一个 >= value 的位置，比较它和前一个哪个更近
        if low > 0, abs(known[low - 1] - value) <= abs(known[low] - value) {
            return known[low - 1]
        }
        return known[low]
    }
}
