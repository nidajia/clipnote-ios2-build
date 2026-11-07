import Foundation

/// 列表搜索。
///
/// 抽成独立函数不只是为了测试：原来的判断写在视图的 computed property 里，
/// 而输入框的占位文案写的是「搜索标题、要点、标签」，
/// 实际却只匹配 `title` 和 `metaLine`——**要点、标签、笔记、书签全都搜不到**。
/// 承诺和实现分居两处，改一处不会提醒改另一处，所以必须合并到一处。
enum LibrarySearch {

    /// 参与匹配的字段。顺序按「用户更可能记得的」排。
    private static func haystacks(_ item: Item) -> [String] {
        var fields: [String] = [
            item.title,
            item.author,
            item.metaLine,
            item.labels.joined(separator: " "),
            item.keyPoints.joined(separator: " "),
            item.aiSummary,
            item.note,
            item.summary,
            item.authorNote,
        ]
        fields += item.bookmarks.map(\.note)
        fields += item.segments.map { "\($0.title) \($0.summary)" }
        return fields
    }

    /// 多个关键词按「都要命中」处理：`AI 泡沫` 匹配同时含这两词的条目。
    ///
    /// 单串匹配会把「AI 泡沫」当成一个整体，而标题里通常写作「AI泡沫」，
    /// 中间有没有空格用户是记不住的。
    /// 切词。分开暴露是为了字幕搜索共用同一套规则——
    /// 条目搜索和字幕搜索对「多个词」的解释必须一致，否则同一句话在两个地方结果不同。
    static func terms(_ query: String) -> [String] {
        query.split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    static func matches(_ item: Item, query: String) -> Bool {
        let terms = terms(query)
        guard !terms.isEmpty else { return true }

        let fields = haystacks(item)
        return terms.allSatisfy { term in
            fields.contains { $0.localizedCaseInsensitiveContains(term) }
        }
    }
}
