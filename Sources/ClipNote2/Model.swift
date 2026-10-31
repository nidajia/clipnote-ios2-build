import SwiftUI

/// 条目类型。真实实现里由服务端给出，客户端只负责展示与筛选。
enum ItemKind: String {
    case video
    case note
}

/// 首页条目。
///
/// 这里只承载「已经拿到手的展示数据」。平台名、时长格式、已下载判定这类规则
/// 一律由服务端决定，客户端不得内置（HANDOVER 硬约束 5）。
struct Item: Identifiable, Hashable {
    let id: UUID
    var kind: ItemKind
    var title: String
    var platform: String
    var author: String
    var duration: String
    var isDownloaded: Bool
    /// 真实封面到位前用渐变色占位；接上服务端后换成 URL + AsyncImage
    var coverTop: Color
    var coverBottom: Color

    var metaLine: String { "\(platform) · \(author)" }

    init(
        id: UUID = UUID(),
        kind: ItemKind = .video,
        title: String,
        platform: String,
        author: String,
        duration: String,
        isDownloaded: Bool,
        coverTop: Color,
        coverBottom: Color
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.platform = platform
        self.author = author
        self.duration = duration
        self.isDownloaded = isDownloaded
        self.coverTop = coverTop
        self.coverBottom = coverBottom
    }
}

// MARK: - 演示数据

extension Item {
    /// 和画布 03 同一批标题，便于逐行比对
    static let demoLibrary: [Item] = [
        Item(title: "为什么大多数人的笔记系统最后都会废掉",
             platform: "B 站", author: "老蒋巨靠谱", duration: "12:34", isDownloaded: true,
             coverTop: Color(red: 0.24, green: 0.30, blue: 0.44),
             coverBottom: Color(red: 0.11, green: 0.13, blue: 0.20)),

        Item(title: "一次讲清楚：为什么你收藏的视频从来不看第二遍",
             platform: "抖音", author: "视频号研究院", duration: "08:12", isDownloaded: false,
             coverTop: Color(red: 0.42, green: 0.23, blue: 0.23),
             coverBottom: Color(red: 0.16, green: 0.09, blue: 0.09)),

        Item(title: "我用三个月把 2000 条收藏整理成了 12 个主题",
             platform: "B 站", author: "硅谷堂", duration: "21:07", isDownloaded: true,
             coverTop: Color(red: 0.18, green: 0.35, blue: 0.29),
             coverBottom: Color(red: 0.09, green: 0.15, blue: 0.12)),

        Item(kind: .note, title: "笔记工具选型的三个真实标准",
             platform: "小红书", author: "顾屿", duration: "05:48", isDownloaded: false,
             coverTop: Color(red: 0.35, green: 0.29, blue: 0.18),
             coverBottom: Color(red: 0.14, green: 0.11, blue: 0.07)),

        Item(title: "每天 10 分钟，把碎片信息变成可复用的知识",
             platform: "B 站", author: "刘飞", duration: "16:22", isDownloaded: true,
             coverTop: Color(red: 0.23, green: 0.23, blue: 0.35),
             coverBottom: Color(red: 0.10, green: 0.10, blue: 0.15)),

        Item(title: "为什么「收藏夹吃灰」是设计问题",
             platform: "微信视频号", author: "少数派", duration: "09:35", isDownloaded: false,
             coverTop: Color(red: 0.29, green: 0.18, blue: 0.35),
             coverBottom: Color(red: 0.12, green: 0.08, blue: 0.15)),

        Item(kind: .note, title: "深度工作：把注意力当成预算来管",
             platform: "B 站", author: "得意忘形", duration: "43:10", isDownloaded: true,
             coverTop: Color(red: 0.18, green: 0.29, blue: 0.35),
             coverBottom: Color(red: 0.07, green: 0.12, blue: 0.15))
    ]
}
