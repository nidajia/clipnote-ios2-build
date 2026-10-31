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
/// 真实封面上线后把 `coverTop/coverBottom` 换成 URL + AsyncImage 即可。
struct Item: Identifiable, Hashable {
    let id: UUID
    var kind: ItemKind
    var title: String
    var platform: String
    var author: String
    var duration: String
    var summary: String
    var isDownloaded: Bool
    /// 播放与下载的来源地址。第一包应当由服务端下发（经 /proxy 代理），
    /// 现在还没接上接口，演示数据指向一个公开示例视频。
    var mediaURL: URL?
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
        summary: String = "",
        isDownloaded: Bool,
        mediaURL: URL? = nil,
        coverTop: Color,
        coverBottom: Color
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.platform = platform
        self.author = author
        self.duration = duration
        self.summary = summary
        self.isDownloaded = isDownloaded
        self.mediaURL = mediaURL
        self.coverTop = coverTop
        self.coverBottom = coverBottom
    }
}

// MARK: - 演示数据

extension Item {
    /// 演示用的公开示例视频（约 2.5 MB，便于真机验证下载链路）
    static let demoMedia = URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4")

    /// 和画布 03 同一批标题，便于逐行比对
    static let demoLibrary: [Item] = [
        Item(title: "为什么大多数人的笔记系统最后都会废掉",
             platform: "B 站", author: "老蒋巨靠谱", duration: "12:34",
             summary: "收藏夹不是知识库。这条视频把「为什么你收藏了却从不回看」拆成三个层次：入口太多、没有回头路、缺少标记。最后给了一套只用两分钟就能跑起来的做法。",
             isDownloaded: true, mediaURL: demoMedia,
             coverTop: Color(red: 0.24, green: 0.30, blue: 0.44),
             coverBottom: Color(red: 0.11, green: 0.13, blue: 0.20)),

        Item(title: "一次讲清楚：为什么你收藏的视频从来不看第二遍",
             platform: "抖音", author: "视频号研究院", duration: "08:12",
             summary: "把「收藏」这个动作拆开看，它满足的是占有感而不是学习需求。视频给了两组对照实验的数据。",
             isDownloaded: false, mediaURL: demoMedia,
             coverTop: Color(red: 0.42, green: 0.23, blue: 0.23),
             coverBottom: Color(red: 0.16, green: 0.09, blue: 0.09)),

        Item(title: "我用三个月把 2000 条收藏整理成了 12 个主题",
             platform: "B 站", author: "硅谷堂", duration: "21:07",
             summary: "从 2000 条到 12 个主题的完整过程：怎么定主题、怎么处理跨主题的条目、怎么避免整理本身变成新的负担。",
             isDownloaded: true, mediaURL: demoMedia,
             coverTop: Color(red: 0.18, green: 0.35, blue: 0.29),
             coverBottom: Color(red: 0.09, green: 0.15, blue: 0.12)),

        Item(kind: .note, title: "笔记工具选型的三个真实标准",
             platform: "小红书", author: "顾屿", duration: "05:48",
             summary: "不看功能对比表，只看三件事：导出是否无损、搜索是否够快、离线是否可用。",
             isDownloaded: false,
             coverTop: Color(red: 0.35, green: 0.29, blue: 0.18),
             coverBottom: Color(red: 0.14, green: 0.11, blue: 0.07)),

        Item(title: "每天 10 分钟，把碎片信息变成可复用的知识",
             platform: "B 站", author: "刘飞", duration: "16:22",
             summary: "一套每天十分钟的固定动作：收进来、标一句、每周回看一次。重点在「每周回看」这一步。",
             isDownloaded: true, mediaURL: demoMedia,
             coverTop: Color(red: 0.23, green: 0.23, blue: 0.35),
             coverBottom: Color(red: 0.10, green: 0.10, blue: 0.15)),

        Item(title: "为什么「收藏夹吃灰」是设计问题",
             platform: "微信视频号", author: "少数派", duration: "09:35",
             summary: "把收藏夹设计成一个只进不出的仓库，用户就一定会忘记它。这是产品结构的问题，不是自制力的问题。",
             isDownloaded: false, mediaURL: demoMedia,
             coverTop: Color(red: 0.29, green: 0.18, blue: 0.35),
             coverBottom: Color(red: 0.12, green: 0.08, blue: 0.15)),

        Item(kind: .note, title: "深度工作：把注意力当成预算来管",
             platform: "B 站", author: "得意忘形", duration: "43:10",
             summary: "注意力像预算，用一点少一点。这期聊的是怎么给一天里最难的那两小时留出空档。",
             isDownloaded: true, mediaURL: demoMedia,
             coverTop: Color(red: 0.18, green: 0.29, blue: 0.35),
             coverBottom: Color(red: 0.07, green: 0.12, blue: 0.15))
    ]
}
