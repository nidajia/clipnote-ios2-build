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
    /// 返回 false 表示「这条没有任何直达地址」。**不再降级成搜索**：
    /// 之前用标题去搜，标题被改过就跳到一条不相干的视频，比不跳更糟。
    /// 拿不到就老实说拿不到，由界面去解释原因。
    @discardableResult
    static func openVideo(_ item: Item) -> Bool {
        if item.platform == "bilibili", !item.videoId.isEmpty {
            let id = item.videoId
            open(scheme: "bilibili://video/\(id)",
                 web: "https://www.bilibili.com/video/\(id)")
            return true
        }
        if !item.sourceURL.isEmpty {
            open(scheme: nil, web: item.sourceURL)
            return true
        }
        return false
    }

    /// 作者主页。
    ///
    /// 只有拿到 `mid` 才跳——`bilibili://space/{mid}` 是**唯一不受改名影响**的地址。
    /// 曾经拿不到 mid 时退到「按名字搜索」，用户反馈是对的：UP 主一改名就找不到，
    /// 而且搜索页里第一个还不一定是同一个人。所以这条路删掉了。
    @discardableResult
    static func openAuthor(_ item: Item) -> Bool {
        if item.platform == "bilibili", !item.authorId.isEmpty {
            let mid = item.authorId
            open(scheme: "bilibili://space/\(mid)",
                 web: "https://space.bilibili.com/\(mid)")
            return true
        }
        return false
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
