import Foundation

/// 「收藏评论」：某个时间点 + 一句自己的话，随时能改。
///
/// 纯逻辑放这里，是为了能在单元测试里直接验证时间解析和写回，
/// 不必起 SwiftUI 视图。
enum BookmarkComment {
    /// "12:30" / "1:02:03" / "90" → 秒。空串或非法返回 nil。
    ///
    /// 只接受右起两位的分组（90、12:30、1:02:03），因为这是播放器里
    /// 用户看到的写法；"1:2" 这种歧义格式一律拒绝，让用户改清楚。
    static func seconds(from text: String) -> Int? {
        let raw = text.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        if parts.count == 1 {
            guard let value = Int(parts[0]), value >= 0 else { return nil }
            return value
        }
        var total = 0
        for (index, part) in parts.enumerated() {
            let digitsOK = index == 0 ? (1...2).contains(part.count) : part.count == 2
            guard digitsOK, let value = Int(part), (0...59).contains(value) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// 把一次编辑写回列表：按原时间定位那条，改成新时间与新评论。
    ///
    /// 改到已占用的那一秒时，原来占位的那条会被替换掉——两条同秒的书签
    /// 在时间轴上叠成一个点，点哪个都跳同一处，留着只会让人困惑。
    static func applying(
        time: Int,
        note: String,
        originalTime: Int,
        to list: [APIBookmark]
    ) -> [APIBookmark] {
        let newTime = max(0, time)
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = list.filter { $0.t != originalTime && $0.t != newTime }
        out.append(APIBookmark(t: newTime, note: trimmed, by: "user"))
        return out.sorted { $0.t < $1.t }
    }

    /// 列表展示用的文案：没写评论时给一句提示，而不是留空。
    static func display(_ note: String) -> String {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "还没写评论" : trimmed
    }
}
