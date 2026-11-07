import Foundation

/// 字幕命中。
struct TranscriptHit: Equatable {
    var t: Int
    var text: String
}

/// 在本机缓存里找字幕命中。
///
/// 为什么要单独一层：条目搜索匹配的是「标题/标签/笔记」这类短字段，
/// 而字幕是几百上千句连续文本——两者的匹配方式一样（多词全中），
/// 但**命中之后要做的事不同**：字段命中只要打开条目，
/// 字幕命中必须告诉用户「第几分几秒」并且能落到那一句。
enum TranscriptIndex {

    /// 一段字幕里所有命中的句子，按时间顺序，最多 `limit` 条。
    ///
    /// 命中判定和条目搜索同一套规则：多个词要**都出现**（可以分布在同一句里）。
    static func hits(in lines: [TranscriptLine], query: String, limit: Int = 3) -> [TranscriptHit] {
        let terms = LibrarySearch.terms(query)
        guard !terms.isEmpty else { return [] }

        var out: [TranscriptHit] = []
        for line in lines {
            let ok = terms.allSatisfy { line.text.localizedCaseInsensitiveContains($0) }
            if ok {
                out.append(TranscriptHit(t: line.t, text: line.text))
                if out.count >= limit { break }
            }
        }
        return out
    }

    /// 一次性把若干条目的字幕从本机读出来。
    ///
    /// 只读**已缓存**的：搜索是键盘上每敲一下就重算的路径，
    /// 不该在这条路径上触发任何网络请求。
    static func load(itemIds: [String], store: LocalTranscriptStore = .shared) -> [String: [TranscriptLine]] {
        var out: [String: [TranscriptLine]] = [:]
        for id in itemIds {
            if let cached = store.load(id: id), !cached.lines.isEmpty {
                out[id] = cached.lines
            }
        }
        return out
    }
}
