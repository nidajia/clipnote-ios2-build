import Foundation

/// 笔记内的 AI 动作。
///
/// 「补充细节」带一个 Bool 而不是拆成两个枚举：模式是同一个动作的参数，
/// 拆开会让人以为它们是两件事。
enum NoteAIAction: Equatable {
    /// 整理排版。**一个字都不许改**，这是这个动作的定义。
    case tidy
    /// 补充细节。`external` 为假时只依据原文；为真时允许查外部资料并标注。
    case expand(external: Bool)
    /// 精简成要点。
    case outline
    /// 总结成一段。
    case summary
    /// 翻译（中↔英互换）。
    case translate
    /// 补全续写：只记得前半句、半截谚语时用。
    case complete
    /// 说法核实：只出报告，不改正文。
    case verify
    /// 自由指令。
    case custom(String)

    var title: String {
        switch self {
        case .tidy: return "整理排版"
        case .expand(let external): return external ? "补充细节（查资料）" : "补充细节"
        case .outline: return "精简要点"
        case .summary: return "总结成段"
        case .translate: return "翻译"
        case .complete: return "补全续写"
        case .verify: return "说法核实"
        case .custom: return "按指令改写"
        }
    }

    /// 只出报告、不写回正文。核实类结果写回笔记没有意义——
    /// 用户要的是「我理解得对不对」，不是把评判混进自己的笔记。
    var isReport: Bool {
        if case .verify = self { return true }
        return false
    }

    /// 会不会引入原文没有的内容。此类结果必须在预览卡上标明。
    var mayAddContent: Bool {
        switch self {
        case .tidy, .outline, .summary, .translate: return false
        case .expand, .complete, .verify, .custom: return true
        }
    }

    /// 只有「整理排版」的承诺强到可以用机器校验。
    var mustKeepText: Bool {
        if case .tidy = self { return true }
        return false
    }

    /// 结果里是否可能带「依据」段落。
    var wantsBasis: Bool {
        switch self {
        case .complete, .verify: return true
        default: return false
        }
    }
}

// MARK: - 提示词

enum NotePrompt {
    static let basisMarker = "<!--依据-->"

    /// 所有动作共用的系统提示。
    static let system = """
    你是一名中文笔记编辑。只输出 Markdown 正文本身。
    不要解释、不要前言、不要给整段内容套代码围栏。

    格式约定（必须遵守）：
    - 高亮写成 ==文字==（默认黄）或 =={g}文字==（可用 y/g/b/p/o/u 六色），不要写成 HTML。
    - 只用这些结构：# 标题、- 或 1. 列表、- [ ] 任务项、> 引用、| 表格 |、``` 代码块 ```。
    - 原样保留链接 [文字](url)、图片 ![](url)、已有高亮。
    """

    static func instruction(for action: NoteAIAction) -> String {
        switch action {
        case .tidy:
            return """
            任务：只整理排版，**一个字都不许增删改**。
            允许：调整标题层级、拆分或合并段落、加列表符号、加分隔线、把并列信息整理成表格。
            禁止：改写措辞、纠正错别字、补充内容、删除内容、调整标点。
            """

        case .expand(let external):
            if external {
                return """
                任务：把原文里没写透的地方展开。
                允许查阅你已有的知识补充背景、定义、出处、数据，但**每一处外部补充后面**
                必须紧跟一个「（外部）」标记，方便用户识别和删除。
                原文已有的句子不得改写或删除。如果某条已经写完整，就保持原样。
                """
            }
            return """
            任务：把原文里没写透的地方展开，但**只能用原文已有的信息**。
            做法：把零散条目改写成一句完整的话；补出原文已经隐含的因果、条件、指代；
            合并互相重复的表述。
            严格禁止：引入原文没有的事实、外部背景、名词解释、书名作者、数据、例子。
            如果某条目本身已经写完整，就保持原样——不要为了凑长度而加水词。
            """

        case .outline:
            return """
            任务：把原文压成要点，要求**看得出明显变短**。
            做法：
            1. 把同一主题的条目归到一个小标题下（原条目本身杂乱时尤其要做）；
            2. 合并重复表述，每条不超过 25 字；
            3. 只保留结论、专有名词、数字，不新增任何事实。
            目标长度：不超过原文的六成。
            """

        case .summary:
            return """
            任务：把全文归纳成**一段话**，不超过 120 字。
            要求：覆盖主要主题；不加标题、不用列表、不引用原文长句；不新增原文没有的事实。
            """

        case .translate:
            return """
            任务：把内容翻成另一种语言——原文主要是中文就译成英文，主要是英文就译成中文。
            要求：逐句对应，不增删内容，不做解释；
            保留原有的 Markdown 结构（标题、列表、引用、表格）与高亮 ==…== 语法；
            专有名词、书名、代码保持原样。
            """

        case .complete:
            return """
            任务：用户只写出了前半句或半截谚语/术语，请补全成完整的一句。
            做法：保留用户已经写出的部分（可修正明显的错别字），补上缺失的后半段。
            如果对出处或原句没有把握，就在正文后用单独一行写 \(basisMarker)，
            再写一句说明你的依据与把握程度。正文里不要夹解释。
            """

        case .verify:
            return """
            任务：逐条检查里面的说法、术语、谚语理解得对不对。
            **不要改写原文**，只输出一份报告：
            每条占一行，格式为「✓ 正确 — 理由」「✗ 错误 — 错在哪」或「? 不确定 — 为什么」。
            最多 8 条，按重要程度排。报告不要用表格。
            """

        case .custom(let text):
            return """
            任务：按用户指令改写。指令：\(text)
            除了指令要求的改动，不要顺手改别的。不得编造原文没有的事实。
            """
        }
    }
}

// MARK: - 结果

struct NoteAIResult: Equatable {
    let markdown: String
    /// 模型附带的依据说明（见 `NotePrompt.basisMarker`）。
    let basis: String?
    /// 与原文相比，可见文字是否被改动过。
    let textChanged: Bool

    /// 模型经常把结果套在 ``` 里返回。留着会直接把笔记首行变成代码块。
    /// 另外弱模型会连 `<note>` 包裹一起吐回来——那不是用户的内容，必须剥掉。
    static func cleanReply(_ raw: String) -> String {
        var text = raw
            .replacingOccurrences(of: "<note>", with: "")
            .replacingOccurrences(of: "</note>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("```") else { return text }
        var lines = text.components(separatedBy: "\n")
        if let first = lines.first, first.hasPrefix("```") {
            lines.removeFirst()
        }
        if let last = lines.last,
           last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            lines.removeLast()
        }
        text = lines.joined(separator: "\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 拆出「依据」段。没有标记时原样返回正文。
    static func splitBasis(_ text: String) -> (body: String, basis: String?) {
        guard let range = text.range(of: NotePrompt.basisMarker) else {
            return (text, nil)
        }
        let body = String(text[text.startIndex..<range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let basis = String(text[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (body, basis.isEmpty ? nil : basis)
    }
}

/// 结果质量检查。
///
/// 模型经常「原样返回」。上一版把这种结果当成成功，弹一张和原文一样的预览卡，
/// 用户点「采用」后什么都没变，只会认为功能坏了。
enum NoteAIQuality {
    static func isIdentical(_ result: String, to source: String) -> Bool {
        result.trimmingCharacters(in: .whitespacesAndNewlines)
            == source.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func didNotCompress(_ result: String, from source: String) -> Bool {
        result.count >= source.count
    }

    /// 这条内容短到模型没法做出有意义的改动。
    ///
    /// 短笔记是「原样返回」最常见的原因：一句「好」，精简要点只能还你「好」。
    /// 与其让用户怀疑功能坏了，不如在发请求之前就说清楚。
    static func isTooShortFor(_ action: NoteAIAction, content: String) -> Bool {
        let length = content.trimmingCharacters(in: .whitespacesAndNewlines).count
        switch action {
        case .tidy:
            return length < 4
        case .outline, .summary, .translate, .complete:
            return length < 15
        case .expand, .verify, .custom:
            return length < 8
        }
    }

    static func identicalMessage(length: Int) -> String {
        """
        模型这次没有改动内容（原文 \(length) 字），所以没有可采用的修改。\
        内容偏短时模型通常无从下手；想指定改法可以用「按指令改写」，\
        例如「把中医相关的几条归到一起」。
        """
    }
}

/// 失败。
enum NoteAIFailure: Error, Equatable {
    case notConfigured
    case transport(String)
    case http(Int, String)
    case emptyReply

    var displayMessage: String {
        switch self {
        case .notConfigured:
            return "还没配置模型。去「我 · AI 设置」填好服务地址、模型和 Key 就能用。"
        case .transport(let detail):
            return "连不上模型服务：\(detail)"
        case .http(let status, let snippet):
            let tail = snippet.isEmpty ? "" : "：\(snippet)"
            return "模型服务返回 \(status)\(tail)"
        case .emptyReply:
            return "模型返回了空内容，换个说法再试一次"
        }
    }
}

// MARK: - 调用

struct NoteAssistant {
    var config: AIConfig
    var session: URLSession = .shared
    var timeout: TimeInterval = 60

    /// 模型原样返回时追加的一句。弱模型第一轮经常「照抄原文」，
    /// 明确指出它没做事，通常第二次就动起来了。
    static let retryNudge = "注意：你上一次把原文原样返回了，这次没有完成任务。请务必真正改写，不要复述原文。"

    func run(action: NoteAIAction, content: String) async throws -> NoteAIResult {
        let first = try await send(action: action, content: content, nudge: nil)
        guard NoteAIQuality.isIdentical(first.markdown, to: content) else {
            return first
        }
        // 不把「没改动」直接甩给用户：先自动重试一次。
        return try await send(action: action, content: content, nudge: Self.retryNudge)
    }

    private func send(
        action: NoteAIAction,
        content: String,
        nudge: String?
    ) async throws -> NoteAIResult {
        guard config.isConfigured, let endpoint = config.endpoint else {
            throw NoteAIFailure.notConfigured
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.key)", forHTTPHeaderField: "Authorization")

        var instruction = NotePrompt.instruction(for: action)
        if let nudge { instruction += "\n\n" + nudge }

        let payload: [String: Any] = [
            "model": config.model,
            // 排版与摘要类任务要稳定，不要发挥
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": NotePrompt.system],
                // 用 <note> 包住原文，而不是拿 `---` 分隔：
                // `---` 在 Markdown 里是分隔线，模型容易把后半段当成「要格式化的素材」。
                ["role": "user", "content": instruction
                    + "\n\n<note>\n" + content + "\n</note>"],
            ],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            throw NoteAIFailure.transport("请求体拼不出来")
        }
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw NoteAIFailure.transport(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let snippet = String(data: data.prefix(160), encoding: .utf8) ?? ""
            throw NoteAIFailure.http(http.statusCode, snippet)
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String
        else {
            throw NoteAIFailure.emptyReply
        }

        let cleaned = NoteAIResult.cleanReply(text)
        let (markdown, basis) = NoteAIResult.splitBasis(cleaned)
        guard !markdown.isEmpty else { throw NoteAIFailure.emptyReply }

        return NoteAIResult(
            markdown: markdown,
            basis: basis,
            textChanged: MarkdownPlainText.extract(markdown) != MarkdownPlainText.extract(content)
        )
    }
}

// MARK: - 文字保真校验

/// 从 Markdown 里抽出「人眼看到的字」，用来判断一次改写有没有偷偷改字。
///
/// 只覆盖我们自己会产出的语法——它的用途是给「整理排版」做机器校验，
/// 覆盖范围与产出范围一致才可靠。
enum MarkdownPlainText {
    static func extract(_ markdown: String) -> String {
        var text = markdown.replacingOccurrences(of: "\r\n", with: "\n")

        text = text
            .components(separatedBy: "\n")
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("|") else { return true }
                let cells = trimmed.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                return !cells.allSatisfy { $0.isEmpty || $0.allSatisfy { $0 == "-" || $0 == ":" } }
            }
            .joined(separator: "\n")

        text = text.replacingOccurrences(of: "```", with: "")
        text = replacing(#"!\[[^\]]*\]\([^\)]*\)"#, in: text, with: "")
        text = replacing(#"\[([^\]]*)\]\([^\)]*\)"#, in: text, with: "$1")
        text = replacing(#"==\{[a-z]\}"#, in: text, with: "")
        text = text.replacingOccurrences(of: "==", with: "")
        for token in ["**", "__", "~~", "`", "*", "_"] {
            text = text.replacingOccurrences(of: token, with: "")
        }
        text = text.replacingOccurrences(of: "|", with: " ")

        text = replacing(#"(?m)^\s{0,3}#{1,6}\s+"#, in: text, with: "")
        text = replacing(#"(?m)^\s{0,3}>\s?"#, in: text, with: "")
        text = replacing(#"(?m)^\s*[-*+]\s+(\[[ xX]\]\s+)?"#, in: text, with: "")
        text = replacing(#"(?m)^\s*\d+\.\s+"#, in: text, with: "")
        text = replacing(#"(?m)^\s*(-{3,}|\*{3,}|_{3,})\s*$"#, in: text, with: "")

        return text
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
    }

    private static func replacing(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
