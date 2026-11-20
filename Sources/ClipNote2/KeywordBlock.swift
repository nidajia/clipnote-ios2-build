import Foundation

/// 标题关键词屏蔽。
///
/// 只在本机生效，命中就整条不显示——「商业」里那些复盘、荐股、带货的
/// 只要加一个词就清干净，不必等模型分类。
enum KeywordBlock {
    /// 全角/半角、大小写、重音都归一，避免「AI」和「ＡＩ」被当成两个词。
    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive],
                     locale: Locale(identifier: "zh_CN"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func matches(_ title: String, keywords: [String]) -> Bool {
        let hay = normalize(title)
        guard !hay.isEmpty else { return false }
        return keywords.contains { keyword in
            let needle = normalize(keyword)
            return !needle.isEmpty && hay.contains(needle)
        }
    }

    static func filter<T>(_ items: [T], keywords: [String], title: (T) -> String) -> [T] {
        guard !keywords.isEmpty else { return items }
        return items.filter { !matches(title($0), keywords: keywords) }
    }

    /// 加一条。已存在（归一后相同）就不重复加，避免列表里出现两个「复盘」。
    static func adding(_ keyword: String, to list: [String]) -> [String] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return list }
        if list.contains(where: { normalize($0) == normalize(trimmed) }) { return list }
        return list + [trimmed]
    }

    /// 撤销用：删掉这一条。
    static func removing(_ keyword: String, from list: [String]) -> [String] {
        let target = normalize(keyword)
        return list.filter { normalize($0) != target }
    }

    /// 长按时给出的候选词：按标点把标题切开，取 2–12 字的片段。
    ///
    /// 不接分词器：这里只需要「让用户少打几个字」，切歪了也不会出错——
    /// 用户仍可在输入框里改成任何词。
    static func suggestions(from title: String) -> [String] {
        let separators = CharacterSet(charactersIn: "，。！？、：；|｜/\\-_·（）()【】[]「」“”\"'!?,:;")
        let parts = title.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { (2...12).contains($0.count) }
        var out: [String] = []
        for part in parts where !out.contains(part) {
            out.append(part)
            if out.count == 6 { break }
        }
        if out.isEmpty {
            let compact = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if compact.count >= 2 { out.append(String(compact.prefix(8))) }
        }
        return out
    }

    static func decode(_ raw: String) -> [String] {
        guard let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list
    }

    static func encode(_ list: [String]) -> String {
        guard let data = try? JSONEncoder().encode(list),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }
}
