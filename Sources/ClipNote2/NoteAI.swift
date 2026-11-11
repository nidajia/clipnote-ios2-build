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
            允许（只在原文本身具备这种关系时才做）：
            - 原文用「、」或分行罗列了并列信息 → 整理成 `- ` 列表
            - 原文有一行明显是标题的短句 → 加 `## `
            - 原文已经有分隔线 → 保留
            严禁：
            - 改写、增删、纠正任何字词与标点（包括错别字）
            - **把一句话拆成一个独立段落**。一个自然段里有几句话，就仍然是一个自然段
            - 为了「看起来整齐」给句子之间加换行或空行
            - 加原文没有的标题、列表、分隔线来「凑结构」
            判断标准：整理后的 Markdown，去掉标记符号后必须与原文逐字相同。
            段落数最多比原文多 2 个；多出来的部分只能用列表或标题解释。
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
            1. 通读全文再动笔，覆盖每一段，不能只取开头的几行；
            2. 把同一主题的条目归到一个小标题下（原条目本身杂乱时尤其要做）；
            3. 合并重复表述，每条不超过 25 字；
            4. 只保留结论、专有名词、数字，不新增任何事实。
            目标长度：不超过原文的六成。
            """

        case .summary:
            return """
            任务：把全文归纳成**一段话**，100–160 字。
            必须覆盖全文每一段的核心，**尤其是最后一段**——观点和结论通常在那里，
            而它们最容易被漏掉。
            禁止：只复述开头第一句；罗列细节；加标题；用列表；引用原文长句；编造原文没有的事实。
            写完自检一次：如果读这段话只能知道开头讲了什么，就重写。
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

    /// 「段落」= 被空行分开的普通正文块。列表项、标题、表格不算——
    /// 整理排版把一坨并列信息变成列表是**对的**，不该被这条判成拆碎。
    static func paragraphCount(_ text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                guard !line.isEmpty else { return false }
                let heads: [Character] = ["#", "-", "*", ">", "|", "`"]
                guard let first = line.first, !heads.contains(first) else { return false }
                // 有序列表 "1. " 也算列表
                if let dot = line.firstIndex(of: "."), line[line.startIndex..<dot].allSatisfy(\.isNumber) {
                    return false
                }
                return true
            }
            .count
    }

    /// 排版被「一刀一段」了。
    ///
    /// 用户的原话是「相当于把每句话打个回车就结束了」。这种输出的特征是
    /// **普通段落数暴涨**：原文 1 段变 6 段，而列表和标题并没有增加。
    /// 提示词写得再严也会漏，所以这里用机器判一次。
    static func didOverSplit(_ result: String, from source: String) -> Bool {
        let after = paragraphCount(result)
        let before = paragraphCount(source)
        // 给两段的余量：拆一个长段成两段是合理的排版动作
        if after > before + 2 { return true }
        // 「一段长文变成三段以上」几乎一定是给了每句一个回车。
        // 阈值用 after > before + 2 判断不到这个最常见的形态：
        // 原文 1 段、结果 3 段时刚好卡在边界上，而那正是用户说的「纯糊弄」。
        return before <= 2 && after >= 3
    }

    /// 总结太短，多半只覆盖了开头。
    ///
    /// 原文两三百字、总结只有二十来字，基本就是「只总结了第一句」。
    /// 这不是长度洁癖：纪要的价值在于把全文的主线说出来。
    static func summaryTooThin(_ result: String, from source: String) -> Bool {
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard source.count >= 200 else { return false }
        return trimmed.count < 40
    }

    static func identicalMessage(length: Int) -> String {
        """
        模型这次没有改动内容（原文 \(length) 字），所以没有可采用的修改。\
        内容偏短时模型通常无从下手；想指定改法可以用「按指令改写」，\
        例如「把中医相关的几条归到一起」。
        """
    }
}

/// 这次处理的位置范围。`nil` 表示整篇。
///
/// 为什么要把位置一路带到「采用」：生成要几十秒，这期间用户可能点过正文、
/// 改过字。采用时若按「当前选区」写，结果会落到别的地方——而且不会报错。
struct NoteAIRange: Equatable {
    var from: Int
    var to: Int
    /// 生成时这个位置上的原文。回写前用它核对，对不上就不写。
    var text: String
}

/// 失败。
enum NoteAIFailure: Error, Equatable {
    case notConfigured
    case transport(String)
    case http(Int, String)
    /// 服务端已经把原因说清楚了（401、模型没回内容、任务过期…），原样展示。
    case service(String)
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
        case .service(let message):
            return message
        case .emptyReply:
            return "模型返回了空内容，换个说法再试一次"
        }
    }
}

extension NoteAIFailure {
    /// 任务层的失败翻成界面能直接显示的话。
    static func from(_ failure: AIJobFailure) -> NoteAIFailure {
        switch failure {
        case .notConfigured:
            return .notConfigured
        case .failed(let message):
            return .service(message)
        case .gone:
            return .service("这个任务已经过期了（服务端重启或超过一小时），重新发起一次。")
        case .timeout:
            return .service("等太久了，任务可能还卡在服务端。过一会儿再试。")
        case .transport(let message):
            // 这句已经说明了「任务交上去了、回来会接着等」，不要再套一层
            return .service(message)
        }
    }
}

// MARK: - 调用

struct NoteAssistant {
    var config: AIConfig
    /// 走服务端任务，不再直连模型：直连时一切到后台就断，用户只能干等。
    var jobs: AIJobClient = AIJobClient()

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
        guard config.isConfigured else { throw NoteAIFailure.notConfigured }

        var instruction = NotePrompt.instruction(for: action)
        if let nudge { instruction += "\n\n" + nudge }

        let messages: [[String: String]] = [
            ["role": "system", "content": NotePrompt.system],
            // 用 <note> 包住原文，而不是拿 `---` 分隔：
            // `---` 在 Markdown 里是分隔线，模型容易把后半段当成「要格式化的素材」。
            ["role": "user", "content": instruction
                + "\n\n<note>\n" + content + "\n</note>"],
        ]

        let text: String
        do {
            text = try await jobs.runChat(messages: messages, config: config)
        } catch let failure as AIJobFailure {
            throw NoteAIFailure.from(failure)
        } catch {
            throw NoteAIFailure.transport(error.localizedDescription)
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
