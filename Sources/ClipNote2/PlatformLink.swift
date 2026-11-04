import UIKit

/// 打开「对应 App」的那一下。
///
/// **不用 `canOpenURL` 判断**：iOS 要求把自定义 scheme 声明进
/// `LSApplicationQueriesSchemes`，`canOpenURL` 才会返回 true；漏声明就永远是 false，
/// 结果就是「明明装了 B 站，点作者还是跳不过去」，而且没有任何报错。
/// 改用 `open` 的完成回调——系统自己知道有没有 App 接得住，
/// 接不住我们再退到网页，这条路径不需要任何声明。
enum PlatformLink {

    static func open(scheme: String?, web: String?) {
        if let scheme, let appURL = URL(string: scheme) {
            UIApplication.shared.open(appURL, options: [:]) { accepted in
                guard !accepted else { return }
                openWeb(web)
            }
            return
        }
        openWeb(web)
    }

    private static func openWeb(_ string: String?) {
        guard let string, let url = URL(string: string) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - 具体平台

    /// 原视频。优先 App 内打开，退到网页。
    ///
    /// 第三种降级是给**存量数据**的：Web 端导入的条目快照里没有 bvid，也没有原链接，
    /// 只有一个标题。这种情况下不留空白、也不藏入口——用标题搜一次，
    /// 用户能在结果里看到那条视频。空着会让人以为功能坏了。
    static func openVideo(_ item: Item) {
        if item.platform == "bilibili", !item.videoId.isEmpty {
            let id = item.videoId
            open(scheme: "bilibili://video/\(id)",
                 web: "https://www.bilibili.com/video/\(id)")
            return
        }
        if !item.sourceURL.isEmpty {
            open(scheme: nil, web: item.sourceURL)
            return
        }
        if item.platform == "bilibili", !item.title.isEmpty {
            let keyword = item.title.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed
            ) ?? ""
            open(scheme: "bilibili://search?keyword=\(keyword)",
                 web: "https://search.bilibili.com/all?keyword=\(keyword)")
            return
        }
        open(scheme: nil, web: item.sourceURL.isEmpty ? nil : item.sourceURL)
    }

    /// 作者主页。
    ///
    /// 三级降级：有 mid 就进主页；只有名字就进搜索；连名字都没有就回原链接。
    /// 藏掉入口是最差的选择——用户点了没反应会以为坏了。
    static func openAuthor(_ item: Item) {
        let name = item.displayAuthor
        if item.platform == "bilibili" {
            if !item.authorId.isEmpty {
                let mid = item.authorId
                open(scheme: "bilibili://space/\(mid)",
                     web: "https://space.bilibili.com/\(mid)")
                return
            }
            if !name.isEmpty {
                let keyword = name.addingPercentEncoding(
                    withAllowedCharacters: .urlQueryAllowed
                ) ?? ""
                open(scheme: "bilibili://search?keyword=\(keyword)",
                     web: "https://search.bilibili.com/all?keyword=\(keyword)")
                return
            }
        }
        open(scheme: nil, web: item.sourceURL.isEmpty ? nil : item.sourceURL)
    }
}

extension Item {
    /// 作者名。
    ///
    /// 新导入的条目有 `author` 字段；**存量条目没有**——它们是 Web 端导进来的，
    /// 快照里只有 `metaLine`，格式是「平台 · 作者」。不给这条兜底，
    /// 那四条就会整块消失，用户以为功能没做。
    var displayAuthor: String {
        if !author.isEmpty { return author }
        let parts = metaLine
            .split(separator: "·")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard parts.count >= 2 else { return "" }
        return parts.last ?? ""
    }
}

/// 作者备注的草稿。
///
/// **这里没有调模型，是有意的。** 我们手上只有「这个作者的一条视频」，
/// 让模型据此给作者写备注，它只能把摘要换个主语再说一遍——
/// 那句话你没有任何理由保留。等同一个作者出现第二条、第三条，
/// 才有真正 AI 才写得出的东西（「你收藏的他的三条都在讲分布式存储」）。
/// 所以第一版只做「从已有摘要拼一句」的草稿，零成本、瞬时、可改。
enum AuthorNoteDraft {
    static func make(from item: Item) -> String {
        var parts: [String] = []
        let text = item.aiSummary.isEmpty ? item.summary : item.aiSummary
        if let first = text.split(separator: "。").first, !first.isEmpty {
            parts.append("这条讲的是：\(first)。")
        }
        if !item.labels.isEmpty {
            parts.append("标签：\(item.labels.prefix(3).joined(separator: "、"))。")
        }
        return parts.joined()
    }
}
