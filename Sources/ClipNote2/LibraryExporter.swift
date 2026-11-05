import Foundation

/// 把整个库导出成一个 Markdown 文件。
///
/// 为什么必须做：摘要是 AI 产的、书签和笔记是用户写的，而它们**只存在这个服务里**。
/// 服务停了、共享码丢了、或者哪天想换工具，这些东西就一起没了。
/// 一个知识工具没有导出，等于把用户的内容质押在自己手里。
///
/// 为什么是单个 .md 而不是「每条一个文件打包 zip」：
/// - 单文件能在任何地方打开、搜索、粘进笔记软件，不需要解压
/// - zip 要额外依赖，收益只是「保留目录结构」，而几十条内容用标题分节足够
/// 条目过千时单文件会变大，但那是以后的问题，到时候可以改成分卷。
enum LibraryExporter {

    static let fileNameDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()

    static func fileName(now: Date = Date()) -> String {
        "片记导出-\(fileNameDateFormatter.string(from: now)).md"
    }

    /// 纯函数：给我一批条目，返回完整 Markdown。便于单测，不碰文件系统。
    static func markdown(items: [Item], now: Date = Date()) -> String {
        var out = """
        # 片记导出

        导出时间：\(fullTime(now))　共 \(items.count) 条

        标记说明：`AI` 表示模型生成的内容，`我` 表示你自己写的。二者不混在一起——\
        以后回看时，你会需要知道哪句话是自己判断过的。

        """

        // 目录：条目多时先看目录再跳转，比一直往下滚有用
        if items.count > 1 {
            out += "\n## 目录\n\n"
            for (index, item) in items.enumerated() {
                out += "\(index + 1). \(item.title)\n"
            }
            out += "\n"
        }

        for item in items {
            out += "\n---\n\n"
            out += "## \(item.title)\n\n"

            var meta: [String] = []
            if !item.author.isEmpty { meta.append(item.author) }
            if !item.platform.isEmpty {
                meta.append(item.platform == "bilibili" ? "B 站" : item.platform)
            }
            if !item.durationText.isEmpty { meta.append(item.durationText) }
            if !item.sourceURL.isEmpty { meta.append(item.sourceURL) }
            if !meta.isEmpty { out += "\(meta.joined(separator: " · "))\n\n" }

            if !item.labels.isEmpty {
                out += item.labels.map { "`\($0)`" }.joined(separator: " ") + "\n\n"
            }

            if !item.authorNote.isEmpty {
                out += "> 作者备注（我）：\(item.authorNote)\n\n"
            }

            if !item.aiSummary.isEmpty {
                out += "### 摘要（AI）\n\n\(item.aiSummary)\n\n"
                if !item.keyPoints.isEmpty {
                    for point in item.keyPoints {
                        out += "- \(point)\n"
                    }
                    out += "\n"
                }
            }

            if !item.note.isEmpty {
                out += "### 我的笔记（我）\n\n\(item.note)\n\n"
            }

            if !item.segments.isEmpty {
                out += "### 分段（AI）\n\n"
                for segment in item.segments {
                    out += "- **\(mmss(segment.t))** \(segment.title)"
                    if !segment.summary.isEmpty { out += "：\(segment.summary)" }
                    out += "\n"
                }
                out += "\n"
            }

            if !item.bookmarks.isEmpty {
                out += "### 书签（我）\n\n"
                for bookmark in item.bookmarks.sorted(by: { $0.t < $1.t }) {
                    out += "- **\(mmss(bookmark.t))** "
                    out += bookmark.note.isEmpty ? "（无备注）" : bookmark.note
                    if bookmark.by == "ai" { out += "（AI 建议）" }
                    out += "\n"
                }
                out += "\n"
            }

            if !item.outline.isEmpty {
                out += "### 脑图（AI）\n\n"
                for node in item.outline {
                    out += node.markdown()
                }
                out += "\n"
            }

            if !item.summary.isEmpty {
                out += "### 原简介\n\n\(item.summary)\n\n"
            }
        }

        return out
    }

    /// 写到临时目录并返回地址。失败返回 nil。
    static func write(items: [Item], now: Date = Date()) -> URL? {
        let text = markdown(items: items, now: now)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(fileName(now: now))
        do {
            try text.data(using: .utf8)?.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func mmss(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let m = s / 60
        let r = s % 60
        if m >= 60 {
            return String(format: "%d:%02d:%02d", m / 60, m % 60, r)
        }
        return String(format: "%02d:%02d", m, r)
    }

    private static func fullTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "zh_CN")
        return f.string(from: date)
    }
}
