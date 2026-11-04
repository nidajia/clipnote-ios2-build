import SwiftUI

/// 脑图的一个节点。
///
/// 用嵌套结构而不是「父子 id 列表」：树的最大深度是 3、节点上限 40，
/// 扁平化只会换来一套 id 索引，读的时候还得重建树。
struct OutlineNode: Decodable, Hashable {
    var title: String
    var note: String
    var children: [OutlineNode]

    enum CodingKeys: String, CodingKey { case title, note, children }

    init(title: String, note: String = "", children: [OutlineNode] = []) {
        self.title = title
        self.note = note
        self.children = children
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        children = try c.decodeIfPresent([OutlineNode].self, forKey: .children) ?? []
    }

    /// 导出成 Markdown 大纲。脑图的价值有一半在「能贴到笔记软件里」。
    func markdown(level: Int = 0) -> String {
        let indent = String(repeating: "  ", count: level)
        var out = "\(indent)- \(title)"
        if !note.isEmpty { out += "：\(note)" }
        out += "\n"
        for child in children {
            out += child.markdown(level: level + 1)
        }
        return out
    }
}

/// 把内容重组成概念树。
///
/// 和分段的分工必须说清楚：
/// - 分段 = **按时间**线性切分，回答「这条讲了什么，顺序如何」
/// - 脑图 = **按概念**分层，回答「这些东西彼此是什么关系」
///
/// 所以输入不用原字幕：分段已经是对全片的压缩，再喂一遍原字幕
/// 只是多花钱，不会多出信息。用「摘要 + 分段标题和一句理解 + 标签」足够。
struct Outliner {
    var config: AIConfig
    var session: URLSession = .shared

    func outline(title: String, summary: String,
                 segments: [APISegment], labels: [String]) async throws -> [OutlineNode] {
        guard config.isConfigured, let endpoint = config.endpoint else {
            throw SummarizeFailure.notConfigured
        }
        guard !summary.isEmpty || !segments.isEmpty else {
            throw SummarizeFailure.emptyReply
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.key)", forHTTPHeaderField: "Authorization")

        let payload: [String: Any] = [
            "model": config.model,
            "temperature": 0.3,
            // 顶层 3–5 个分支 + 每个 2–4 个叶子，约 600 token，给一倍余量
            "max_tokens": 1600,
            "messages": [
                ["role": "system", "content": Self.instructions],
                ["role": "user", "content": Self.userContent(
                    title: title, summary: summary, segments: segments, labels: labels
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
            throw SummarizeFailure.http(http.statusCode,
                                        String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw SummarizeFailure.emptyReply }
        if let reason = choices.first?["finish_reason"] as? String, reason == "length" {
            throw SummarizeFailure.truncated
        }
        return try Self.parse(content)
    }

    private static let instructions = """
    你在帮用户把一条视频的内容整理成一张概念图（脑图）。
    只输出一个 JSON 对象，不要解释、不要 Markdown 代码块。
    格式：{"outline":[{"title":"分支名","note":"一句话说明","children":[{"title":"叶子","note":""}]}]}
    要求：
    - 顶层 3 到 5 个分支，每个分支 2 到 4 个叶子，最多两层。
    - **按概念归类，不要按时间顺序**。不要出现「开头」「第二部分」「最后」这种时间词。
    - 不要带时间戳、不要复述视频标题。
    - 分支名是名词短语（4-10 字），不要写成一句完整的话。
    - note 只在需要解释时写，能用标题说清就留空。
    - 如果视频里有关键数字或反例，把它放进对应叶子的 note。
    """

    private static func userContent(
        title: String, summary: String, segments: [APISegment], labels: [String]
    ) -> String {
        var parts = ["视频标题：\(title)"]
        if !labels.isEmpty { parts.append("标签：\(labels.joined(separator: "、"))") }
        if !summary.isEmpty { parts.append("摘要：\(summary)") }
        if !segments.isEmpty {
            let lines = segments.map { "· \($0.title)：\($0.summary)" }.joined(separator: "\n")
            parts.append("内容分段（按时间顺序，供你归类参考，不要在输出里体现顺序）：\n\(lines)")
        }
        return parts.joined(separator: "\n\n")
    }

    /// 解析模型输出。限制和和服务端保持一致，界面拿到的树一定可渲染。
    static func parse(_ raw: String) throws -> [OutlineNode] {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            if let fence = text.range(of: "```", options: .backwards) {
                text = String(text[..<fence.lowerBound])
            }
        }
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let array = root["outline"] as? [Any]
        else { throw SummarizeFailure.unparsable(text) }

        var budget = 40
        var nodes: [OutlineNode] = []
        for one in array {
            guard budget > 0, nodes.count < 6 else { break }
            if let node = build(one, depth: 0, budget: &budget) {
                nodes.append(node)
            }
        }
        guard !nodes.isEmpty else { throw SummarizeFailure.unparsable(text) }
        return nodes
    }

    private static func build(_ raw: Any, depth: Int, budget: inout Int) -> OutlineNode? {
        guard depth < 3, budget > 0, let dict = raw as? [String: Any] else { return nil }
        let title = (dict["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        budget -= 1

        var children: [OutlineNode] = []
        if depth + 1 < 3, let list = dict["children"] as? [Any] {
            for child in list {
                guard budget > 0, children.count < 6 else { break }
                if let node = build(child, depth: depth + 1, budget: &budget) {
                    children.append(node)
                }
            }
        }
        let note = (dict["note"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return OutlineNode(title: String(title.prefix(40)),
                           note: String(note.prefix(120)),
                           children: children)
    }
}
