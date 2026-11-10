import SwiftUI

/// 条目类型。由服务端下发，客户端只用于筛选与图标。
enum ItemKind: String {
    case video
    case note
}

/// 首页条目：**已经拿到手的展示数据**。
///
/// 与上一版最大的区别：这里不再有任何「拼装」行为。
/// `metaLine`、`durationText` 都是服务端给的成品字符串，
/// 客户端不拼平台名、不加分隔点、不做秒数换算（HANDOVER 硬约束 5）。
///
/// 也不再带 `isDownloaded`。「是否已下载」的唯一真相源是 `DownloadStore`；
/// 上一版这里留了一个演示用的布尔，和 DownloadStore 各说各话，
/// 正是要根除的那类问题。
struct Item: Identifiable, Hashable {
    /// 服务端 id，字符串。不是 UUID——用 UUID 会让「已下载」状态在重装、
    /// 换设备、重新同步之后全部对不上。
    let id: String
    var kind: ItemKind
    var title: String
    var metaLine: String
    var durationText: String
    /// 秒。`durationText` 是给眼睛看的（"16:57"），这个是给计算用的——
    /// 分段条的每块宽度按时间占比算，拿字符串没法算。
    var durationSeconds: Int = 0
    var summary: String
    /// AI 生成的摘要。和 `summary`（原简介）是两个东西，界面上也要分开显示。
    var aiSummary: String = ""
    var keyPoints: [String] = []
    var labels: [String] = []
    /// 分段总结。段数不固定，界面只能保证「至少 0 段」，不能假设 5 段。
    var segments: [APISegment] = []
    /// 用户自己标的时间点。和分段来源相反，展示上也必须能一眼区分。
    var bookmarks: [APIBookmark] = []
    /// 作者与原文地址。`authorId` 可能为空，跳主页要降级成搜索。
    var author: String = ""
    var authorId: String = ""
    var videoId: String = ""
    var sourceURL: String = ""
    var authorNote: String = ""
    /// 作者头像地址。可能为空（老数据），此时界面画首字母。
    var authorAvatar: String = ""
    /// 我的笔记。
    var note: String = ""
    /// 创建时间。笔记条目由用户新建，这个时间就是「我什么时候写的它」。
    var createdAt: Date?
    /// 最后修改时间。服务端每次写入都会更新，笔记页显示的是它。
    var updatedAt: Date?
    /// AI 脑图。
    var outline: [OutlineNode] = []
    /// 对某几句的批注。
    var annotations: [APIAnnotation] = []
    /// "bilibili" / "douyin" / ...。没有它就跳不了 App，只能开网页。
    var platform: String = ""
    var coverURL: URL?
    /// `false` 不是错误，是「这类内容没有视频流」（笔记、图集）
    var playbackAvailable: Bool
    var publishedAt: Date?

    /// 封面加载完成前的占位渐变。由 id 稳定派生，同一条永远同色，
    /// 截图因此可复现——这是能用截图当证据的前提。
    var coverTop: Color
    var coverBottom: Color

    init(api: APILibraryItem) {
        self.id = api.id
        self.kind = ItemKind(rawValue: api.kind) ?? .video
        self.title = api.title
        self.metaLine = api.metaLine
        self.durationText = api.durationText
        self.durationSeconds = api.durationSeconds
        self.summary = api.summary
        self.aiSummary = api.aiSummary
        self.keyPoints = api.keyPoints
        self.labels = api.labels
        self.segments = api.segments
        self.bookmarks = api.bookmarks
        self.author = api.author
        self.authorId = api.authorId
        self.videoId = api.videoId
        self.sourceURL = api.sourceURL
        self.authorNote = api.authorNote
        self.authorAvatar = api.authorAvatar
        self.note = api.note
        self.createdAt = api.createdAt > 0
            ? Date(timeIntervalSince1970: TimeInterval(api.createdAt) / 1000)
            : nil
        self.updatedAt = api.updatedAt > 0
            ? Date(timeIntervalSince1970: TimeInterval(api.updatedAt) / 1000)
            : nil
        self.outline = api.outline
        self.annotations = api.annotations
        self.platform = api.platform
        self.playbackAvailable = api.playback.available
        self.publishedAt = api.publishedAt > 0
            ? Date(timeIntervalSince1970: TimeInterval(api.publishedAt))
            : nil

        if let raw = api.cover?.url, let url = URL(string: raw), !raw.isEmpty {
            self.coverURL = url
        } else {
            self.coverURL = nil
        }

        let colors = Item.placeholderColors(for: id)
        self.coverTop = colors.top
        self.coverBottom = colors.bottom
    }

    /// 测试与预览用的直构入口，不经过服务端形状
    init(
        id: String,
        kind: ItemKind = .video,
        title: String,
        metaLine: String,
        durationText: String,
        durationSeconds: Int = 0,
        summary: String = "",
        aiSummary: String = "",
        keyPoints: [String] = [],
        labels: [String] = [],
        segments: [APISegment] = [],
        bookmarks: [APIBookmark] = [],
        author: String = "",
        authorId: String = "",
        videoId: String = "",
        sourceURL: String = "",
        authorNote: String = "",
        authorAvatar: String = "",
        note: String = "",
        outline: [OutlineNode] = [],
        annotations: [APIAnnotation] = [],
        platform: String = "",
        coverURL: URL? = nil,
        playbackAvailable: Bool = true,
        publishedAt: Date? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.metaLine = metaLine
        self.durationText = durationText
        self.durationSeconds = durationSeconds
        self.summary = summary
        self.aiSummary = aiSummary
        self.keyPoints = keyPoints
        self.labels = labels
        self.segments = segments
        self.bookmarks = bookmarks
        self.author = author
        self.authorId = authorId
        self.videoId = videoId
        self.sourceURL = sourceURL
        self.authorNote = authorNote
        self.authorAvatar = authorAvatar
        self.note = note
        self.outline = outline
        self.annotations = annotations
        self.platform = platform
        self.coverURL = coverURL
        self.playbackAvailable = playbackAvailable
        self.publishedAt = publishedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        let colors = Item.placeholderColors(for: id)
        self.coverTop = colors.top
        self.coverBottom = colors.bottom
    }
}

// MARK: - 占位色

extension Item {
    /// 由 id 派生一组深色渐变。
    ///
    /// 不用 `hashValue`：它每次进程启动带随机种子，同一张封面在不同次截图里
    /// 会变成不同颜色，图就不可比了。这里用 FNV-1a，跨进程稳定。
    static func placeholderColors(for id: String) -> (top: Color, bottom: Color) {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hue = Double(hash % 360) / 360.0
        return (
            Color(hue: hue, saturation: 0.30, brightness: 0.40),
            Color(hue: hue, saturation: 0.44, brightness: 0.15)
        )
    }
}

// MARK: - 样本库
//
// 只服务于截图与预览。运行时数据一律来自 `/api/v2/library`。
// 内容与画布 03 的七行一一对应，便于逐行比对。

extension Item {
    /// 样本库的原始 JSON。截图入口走的是与线上完全相同的解码器，
    /// 所以 CI 截图同时验证「解码对不对」和「渲染对不对」，且不依赖网络。
    static let sampleData: Data? = {
        guard let url = Bundle.main.url(forResource: "library-sample", withExtension: "json") else {
            return nil
        }
        return try? Data(contentsOf: url)
    }()

    static let sampleLibrary: [Item] = {
        guard let data = sampleData,
              let library = try? JSONDecoder().decode(APILibrary.self, from: data)
        else {
            return []
        }
        return library.items.map(Item.init(api:))
    }()
}
