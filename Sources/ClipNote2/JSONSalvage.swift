import Foundation

/// 从模型输出里捡 JSON。
///
/// 为什么需要这一层：模型偶发会**少写半个对象**（输出上限、网络中断、或它自己断句），
/// 而 `JSONSerialization` 要求整段合法——一断就整段丢，前面写好的内容全部作废。
/// 真机日志里「模型没有按 JSON 回答（228 字）」十次有九次是这种尾巴问题。
///
/// 树和列表都可以降级：少一条书签仍然能用，全丢就完全不能用了。
enum JSONSalvage {

    /// 去掉 ```json 围栏。
    static func stripFence(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            if let fence = text.range(of: "```", options: .backwards) {
                text = String(text[..<fence.lowerBound])
            }
        }
        return text
    }

    /// 整段解析。失败返回 nil，交给 `objects` 兜底。
    static func root(_ text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end,
              let data = String(text[start...end]).data(using: .utf8)
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// 从 `"key": [ ... ]` 里逐个收集**完整**的对象，跳过被截断的尾巴。
    ///
    /// 扫描时区分「字符串内」与「字符串外」：note 里出现一个花括号
    /// 就会把深度算错，整棵树跟着错位。
    static func objects(_ text: String, key: String) -> [[String: Any]] {
        guard let keyRange = text.range(of: "\"\(key)\"") ?? text.range(of: key),
              let bracket = text[keyRange.upperBound...].firstIndex(of: "[")
        else { return [] }

        var depth = 0
        var inString = false
        var escaped = false
        var start: String.Index?
        var out: [[String: Any]] = []

        var i = text.index(after: bracket)
        while i < text.endIndex {
            let ch = text[i]

            if escaped {
                escaped = false
                i = text.index(after: i)
                continue
            }
            if inString {
                if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
                i = text.index(after: i)
                continue
            }

            switch ch {
            case "\"":
                inString = true
            case "{":
                if depth == 0 { start = i }
                depth += 1
            case "}":
                depth -= 1
                if depth == 0, let begin = start {
                    if let data = text[begin...i].data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        out.append(obj)
                    }
                    start = nil
                }
                if depth < 0 { depth = 0 }
            case "]":
                if depth == 0 { return out }   // 数组结束
            default:
                break
            }
            i = text.index(after: i)
        }
        return out                              // 被截断：返回已经收到的部分
    }
}
