import Foundation

/// 摘要模板。
///
/// 一个决定先说清楚：**模板只换「摘要」的结构，不动分段、书签、脑图。**
///
/// 为什么：换模板的成本应该只有一次模型调用。如果连带动其它三条链路，
/// 用户就没法比较「同一个视频在两种结构下有什么不同」——四条都变了，
/// 差别来自哪里说不清。而且分段要重新吸附时间戳，失败一次整页都空。
enum SummaryTemplate: String, CaseIterable, Identifiable {
    case brief = "brief"
    case argument = "argument"
    case timeline = "timeline"
    case action = "action"
    case question = "question"
    case custom = "custom"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .brief: return "速览"
        case .argument: return "论点拆解"
        case .timeline: return "时间线"
        case .action: return "行动清单"
        case .question: return "追问式"
        case .custom: return "自定义"
        }
    }

    /// 列表里那一行说明。必须写清「换完之后读起来有什么不同」，
    /// 否则用户只会看到五个形容词，不知道选哪个。
    var hint: String {
        switch self {
        case .brief: return "60–110 字概述 + 3–6 条要点，默认形态"
        case .argument: return "拆成「主张 / 论据 / 反驳」，适合观点类"
        case .timeline: return "按发生顺序排列，适合事件复盘"
        case .action: return "只留「能做什么」，适合教程与经验"
        case .question: return "把内容变成几个待回答的问题"
        case .custom: return "自己写要求，会作为额外指令拼进去"
        }
    }

    /// 拼进系统提示词的额外要求。空串表示用默认形态。
    var instruction: String {
        switch self {
        case .brief:
            return ""
        case .argument:
            return """
            输出结构改为「论点拆解」：
            - summary 用一句话点出核心主张（不超过 40 字），再跟一句它最主要的支撑理由。
            - keyPoints 每条以「主张：」「论据：」「反驳：」开头，让人一眼看出论证结构。
            """
        case .timeline:
            return """
            输出结构改为「时间线」：
            - summary 说明这是哪一段时期、围绕什么展开。
            - keyPoints 按发生顺序排列，每条以「先 / 随后 / 之后 / 最后」这类时间词开头。
            """
        case .action:
            return """
            输出结构改为「行动清单」：
            - summary 一句话概括「这套做法解决什么问题」。
            - keyPoints 每条都必须是**可执行的动作**（动词开头），不要复述观点。
            """
        case .question:
            return """
            输出结构改为「追问式」：
            - summary 说明这条内容试图回答什么。
            - keyPoints 改写成 3–6 个**待回答的问题**，以问号结尾。
            """
        case .custom:
            return ""
        }
    }

    /// 没配模型时，换模板没有实际效果——本地兜底用的是固定规则。
    var needsModel: Bool { true }
}

/// 记住选择。存 UserDefaults 而不是快照：
/// 这是「我习惯用哪种结构」的偏好，属于设备，不属于某一条内容。
enum SummaryTemplateStore {
    private static let key = "summary.template"

    static func load() -> SummaryTemplate {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let template = SummaryTemplate(rawValue: raw)
        else { return .brief }
        return template
    }

    static func save(_ template: SummaryTemplate) {
        UserDefaults.standard.set(template.rawValue, forKey: key)
    }

    private static let customKey = "summary.template.custom"

    static func loadCustomPrompt() -> String {
        UserDefaults.standard.string(forKey: customKey) ?? ""
    }

    static func saveCustomPrompt(_ text: String) {
        UserDefaults.standard.set(text, forKey: customKey)
    }
}
