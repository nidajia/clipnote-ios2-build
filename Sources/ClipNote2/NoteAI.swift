import Foundation

/// 笔记内的 AI 动作：三个固定动作 + 自由指令。
///
/// 为什么固定三个：用户面对空白输入框时，最常要的就是这三件事。
/// 自由指令是兜底，不是主要入口——把它放第一位会让多数人不知道写什么。
enum NoteAIAction: Equatable {
    /// 整理排版。**一个字都不许改**，这是这个动作的定义。
    case tidy
    /// 补充细节。只能基于笔记已有信息展开，不得引入外部事实。
    case expand
    /// 精简成要点。
    case outline
    /// 总结成一段。碎片式笔记最缺这个：把散落的条目收成一段能复述的话。
    case summary
    /// 自由指令。
    case custom(String)

    var title: String {
        switch self {
        case .tidy: return "整理排版"
        case .expand: return "补充细节"
        case .outline: return "精简成要点"
        case .summary: return "总结成段"
        case .custom: return "按指令改写"
        }
    }

    /// 会不会引入原文没有的内容。此类结果必须在预览卡上标明。
    var mayAddContent: Bool {
        switch self {
        case .tidy, .outline, .summary: return false
        case .expand, .custom: return true
        }
    }

    /// 只有「整理排版」的承诺强到可以用机器校验。
    var mustKeepText: Bool {
        if case .tidy = self { return true }
        return false
    }
}

// MARK: - 提示词

enum NotePrompt {
    /// 所有动作共用的系统提示。
    ///
    /// 里面写死了两件我们自己的约定：高亮的 `=={x}` 语法，以及「只输出正文」。
    /// 模型很爱把整段内容套进 ``` 里，那会直接毁掉笔记的首行结构。
    static let system = """
    你是一名中文笔记编辑。只输出 Markdown 正文本身。
    不要任何解释、前言、结语，不要给整段内容套代码围栏。

    格式约定（必须遵守）：
    - 高亮写成 ==文字==（默认黄）或 =={g}文字==（可用 y/g/b/p/o/u 六色），不要写成 HTML 或 <mark>。
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
        case .expand:
            // 规格（产品路线 2.3）：只能基于笔记本身已有的信息展开，禁止引入外部事实。
            // 上一版写成「可补充背景/定义/例子」，等于放开了编造的口子，已改回。
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
            要求：覆盖主要主题；不加标题、不用列表、不引用原文长句；
            不新增原文没有的事实；如果原文本身只有一个主题，就直接写那一件事。
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
    /// 与原文相比，可见文字是否被改动过。只对「整理排版」有意义，但所有动作都算。
    let textChanged: Bool

    /// 模型经常把结果套在 ``` 里返回。留着会直接把笔记首行变成代码块。
    static func cleanReply(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
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
}

/// 结果质量检查。
///
/// 为什么需要它：模型经常会「原样返回」。上一版把这种结果当成成功，
/// 弹出一张和原文一模一样的预览卡，用户点「采用」后什么都没变，
/// 只会认为功能坏了。没有改动就该说没有改动。
enum NoteAIQuality {
    /// 除了首尾空白，和原文逐字相同。
    static func isIdentical(_ result: String, to source: String) -> Bool {
        result.trimmingCharacters(in: .whitespacesAndNewlines)
            == source.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 要求压缩，结果却没比原文短。
    static func didNotCompress(_ result: String, from source: String) -> Bool {
        result.count >= source.count
    }

    static let identicalMessage = """
    模型这次没有改动内容，所以没有可采用的修改。\
    这条笔记可能已经很精简了；想指定改法可以用「按指令改写」，\
    例如「把中医相关的几条归到一起」。
    """
}

enum NoteAIFailure: Error, Equatable {    case notConfigured
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

    func run(action: NoteAIAction, content: String) async throws -> NoteAIResult {
        guard config.isConfigured, let endpoint = config.endpoint else {
            throw NoteAIFailure.notConfigured
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.key)", forHTTPHeaderField: "Authorization")

        let payload: [String: Any] = [
            "model": config.model,
            // 排版与摘要类任务要稳定，不要发挥
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": NotePrompt.system],
                // 用 <note> 包住原文，而不是拿 `---` 分隔：
                // `---` 在 Markdown 里是分隔线，模型容易把后半段当成「要格式化的素材」，
                // 于是原样吐回来。标签边界对模型更明确。
                ["role": "user", "content": NotePrompt.instruction(for: action)
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

        let markdown = NoteAIResult.cleanReply(text)
        guard !markdown.isEmpty else { throw NoteAIFailure.emptyReply }

        return NoteAIResult(
            markdown: markdown,
            textChanged: MarkdownPlainText.extract(markdown) != MarkdownPlainText.extract(content)
        )
    }
}

// MARK: - 文字保真校验

/// 从 Markdown 里抽出「人眼看到的字」，用来判断一次改写有没有偷偷改字。
///
/// 只覆盖我们自己会产出的语法，不追求通用 Markdown 完备性——
/// 它的唯一用途是给「整理排版」做机器校验，覆盖范围与产出范围一致才可靠。
enum MarkdownPlainText {
    static func extract(_ markdown: String) -> String {
        var text = markdown.replacingOccurrences(of: "\r\n", with: "\n")

        // 表格分隔行整行丢掉（| --- | --- |）
        text = text
            .components(separatedBy: "\n")
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("|") else { return true }
                let cells = trimmed.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                return !cells.allSatisfy { $0.isEmpty || $0.allSatisfy { $0 == "-" || $0 == ":" } }
            }
            .joined(separator: "\n")

        // 代码围栏本身不是文字，内容留着
        text = text.replacingOccurrences(of: "```", with: "")

        // 图片没有可见文字
        text = replacing(#"!\[[^\]]*\]\([^\)]*\)"#, in: text, with: "")
        // 链接保留文字
        text = replacing(#"\[([^\]]*)\]\([^\)]*\)"#, in: text, with: "$1")
        // 高亮只留文字
        text = replacing(#"==\{[a-z]\}"#, in: text, with: "")
        text = text.replacingOccurrences(of: "==", with: "")
        // 行内标记
        for token in ["**", "__", "~~", "`", "*", "_"] {
            text = text.replacingOccurrences(of: token, with: "")
        }
        // 表格竖线
        text = text.replacingOccurrences(of: "|", with: " ")

        // 行首标记
        text = replacing(#"(?m)^\s{0,3}#{1,6}\s+"#, in: text, with: "")
        text = replacing(#"(?m)^\s{0,3}>\s?"#, in: text, with: "")
        text = replacing(#"(?m)^\s*[-*+]\s+(\[[ xX]\]\s+)?"#, in: text, with: "")
        text = replacing(#"(?m)^\s*\d+\.\s+"#, in: text, with: "")
        text = replacing(#"(?m)^\s*(-{3,}|\*{3,}|_{3,})\s*$"#, in: text, with: "")

        // 空白不影响「是不是同一段文字」：换行位置变了不算改字
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
