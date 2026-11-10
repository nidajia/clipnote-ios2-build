import Foundation

/// 新笔记的骨架。
///
/// 为什么不是空白页：这个 App 里「笔记」是纪要，不是随手涂鸦。
/// 打开就是一张白纸时，用户要自己想「我该写什么结构」，很多人就什么都不写了。
/// Obsidian / Notion 的新页面也有标题位，我们把它显式化成大标题 + 三个小标题。
///
/// 三个小标题是**可删的占位**，不是强制字段：它们是提示，不是表单。
enum NoteTemplate {

    static let headings = ["背景", "要点", "结论"]

    /// 大标题 + 三个小标题。
    ///
    /// 标题写进正文，是因为 Markdown 里没有独立的「笔记标题」字段——
    /// 列表页显示的是条目 `title`，正文里要能对应上，否则点进来会像两条东西。
    static func body(title: String) -> String {
        var text = "# \(title)\n"
        for heading in headings {
            text += "\n## \(heading)\n"
        }
        return text
    }

    /// 正文第一行如果是 `# 标题`，就取它当标题。
    /// 用于「标题跟着正文改」这类场景的兜底，不用于覆盖用户输入的标题。
    static func title(in body: String) -> String? {
        for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("# ") else { continue }
            let value = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
