import Foundation

// MARK: - 服务端形状
//
// 这一层只做解码，不含任何业务规则。
// 特别地：**不要在这里拼 metaLine、不要换算时长、不要判断平台**——
// 服务端已经给出成品字符串（见 API-V2.md §2「展示就绪」）。
// 上一版之所以会有 323 处硬编码和三次字段漂移，就是从「顺手拼一下」开始的。
//
// 解码策略是**容忍式**的：可选字段缺失给默认值，服务端加字段不会让客户端崩。
// 严格性由测试负责——`LibraryDecodingTests` 断言真实 fixture 里每个字段都在、
// 值都对。两者分工明确：运行时求稳，测试求严。

/// 封面。`url` 为空表示没有封面，客户端用占位色块。
struct APICover: Decodable, Equatable {
    var url: String?
}

/// 播放能力。`available == false` 不是错误，是「这类内容没有视频流」。
struct APIPlayback: Decodable, Equatable {
    var available: Bool
    /// 服务端给出的原因（如 `NOTE`、`IMAGE_SET`）。客户端**不**对取值做文案映射，
    /// 只在 `available == false` 时置灰播放键。
    var reason: String?
}

struct APISource: Decodable, Equatable {
    var platform: String?
}

/// 一段总结。`t` 是这段开始的时间（秒），用来和播放器对齐。
/// 对某一句话的批注。
///
/// 和 `APIBookmark` 的区别不是字段多少，而是**意图**：
/// 书签是「记住这一刻」（备注可以空），批注是「对这句有话说」（必须有内容）。
/// 所以 `quote` 存的是当时的原话——半年后只有自己的话、没有原文，是读不懂的。
struct APIAnnotation: Decodable, Equatable, Hashable {
    var t: Int
    var quote: String
    var note: String

    private enum CodingKeys: String, CodingKey { case t, quote, note }

    init(t: Int, quote: String = "", note: String) {
        self.t = t
        self.quote = quote
        self.note = note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = (try? c.decodeIfPresent(Int.self, forKey: .t)) ?? 0
        quote = (try? c.decodeIfPresent(String.self, forKey: .quote)) ?? ""
        note = (try? c.decodeIfPresent(String.self, forKey: .note)) ?? ""
    }
}

struct APISegment: Decodable, Equatable, Hashable, Identifiable {
    var title: String
    var t: Int
    var summary: String

    /// 只用于列表 diff。**不能当成唯一键**：模型偶尔会给两段同一个时间，
    /// 吸附之后更可能撞上。界面里一律按 offset 遍历，不拿它当 ForEach 的 id。
    var id: String { "\(t)-\(title)" }

    private enum CodingKeys: String, CodingKey { case title, t, summary }

    init(title: String, t: Int, summary: String = "") {
        self.title = title
        self.t = t
        self.summary = summary
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        t = try c.decodeIfPresent(Int.self, forKey: .t) ?? 0
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
    }
}

/// 一个书签。和 `APISegment` 长得像（都带秒），但语义相反：
/// 分段是 AI 切出来的目录，书签是人在时间轴上插的旗子。
/// 所以书签**允许没有备注**——只标记「这里值得回看」也是有效的信息。
struct APIBookmark: Decodable, Equatable, Hashable {
    var t: Int
    var note: String
    /// "user" 或 "ai"。AI 只是**提议**，进库的每一条都经过了用户确认。
    var by: String

    private enum CodingKeys: String, CodingKey { case t, note, by }

    init(t: Int, note: String = "", by: String = "user") {
        self.t = t
        self.note = note
        self.by = by
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = try c.decodeIfPresent(Int.self, forKey: .t) ?? 0
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        by = try c.decodeIfPresent(String.self, forKey: .by) ?? "user"
    }
}

// MARK: - 转写
//
// 服务端只回三种 source，客户端只认这三种分支：
//   subtitle —— lines 直接可用
//   audio    —— 没字幕但有音轨，客户端自己去转写（本版未接）
//   none     —— 都没有，reason 说明为什么

struct APITranscriptLine: Decodable, Equatable {
    var t: Int
    var text: String
}

struct APITranscript: Decodable, Equatable {
    var source: String
    var lines: [APITranscriptLine]
    /// 字幕末句时间 / 视频总时长。B 站的 AI 字幕偶尔会中途断掉，
    /// 小于 0.8 时界面要如实写「只覆盖到第 X 分钟」。
    var coverage: Double
    var durationSeconds: Int
    var partial: Bool
    var reason: String
    /// source == "audio" 时才有
    var audio: APIAudio?

    private enum CodingKeys: String, CodingKey {
        case source, lines, coverage, durationSeconds, partial, reason, audio
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "none"
        lines = try c.decodeIfPresent([APITranscriptLine].self, forKey: .lines) ?? []
        coverage = try c.decodeIfPresent(Double.self, forKey: .coverage) ?? 0
        durationSeconds = try c.decodeIfPresent(Int.self, forKey: .durationSeconds) ?? 0
        partial = try c.decodeIfPresent(Bool.self, forKey: .partial) ?? false
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        audio = try c.decodeIfPresent(APIAudio.self, forKey: .audio)
    }
}

struct APIAudio: Decodable, Equatable {
    var url: String
}

/// 图片上传的响应。只有两个字段是我们关心的：
/// 成不成、以及写进 Markdown 的那个地址。
struct APIUploadResult: Decodable {
    let ok: Bool
    let url: String
}

struct APILibraryItem: Decodable, Equatable, Identifiable {
    var id: String
    var kind: String
    var title: String
    var metaLine: String
    var durationText: String
    var durationSeconds: Int
    var summary: String
    var cover: APICover?
    var playback: APIPlayback
    var publishedAt: Int
    var source: APISource?
    /// AI 生成的摘要 / 要点 / 标签。老条目没有，一律空。
    var aiSummary: String = ""
    var keyPoints: [String] = []
    var labels: [String] = []
    /// 分段总结：摘要的下一层，每段带开始时间（秒）。
    /// 段数不固定（5±3），所以界面不能假设「一定有 5 段」。
    var segments: [APISegment] = []
    var segmentsAt: Int = 0
    var bookmarks: [APIBookmark] = []
    var bookmarksAt: Int = 0
    /// 作者。`authorId` 可能为空（老数据没有 mid），跳主页要降级成搜索。
    var author: String = ""
    var authorId: String = ""
    var videoId: String = ""
    var sourceURL: String = ""
    var authorNote: String = ""
    var authorNoteAt: Int = 0
    var authorAvatar: String = ""
    /// 我的笔记。详情页只露预览，编辑在独立页。
    var note: String = ""
    var noteAt: Int = 0
    /// 创建与最后修改时间（毫秒，服务端时钟）。
    var createdAt: Int = 0
    var updatedAt: Int = 0
    /// 图集。抖音图文作品才有；视频条目是空数组。
    /// 有它就意味着「这条内容没有视频流」，详情页要走图片浏览而不是播放器。
    var images: [String] = []
    /// AI 脑图。树形，服务端限 3 层 / 40 节点。
    var outline: [OutlineNode] = []
    var outlineAt: Int = 0
    var annotations: [APIAnnotation] = []
    var annotationsAt: Int = 0
    /// "bilibili" / "douyin" / ...。跳 App 要用它选 scheme。
    var platform: String = ""
    /// 软删时间戳（毫秒）。只在回收站里有值，列表里一律为 nil。
    var deletedAt: Int?

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, metaLine, durationText, durationSeconds
        case summary, cover, playback, publishedAt, source, deletedAt
        case aiSummary, keyPoints, labels, segments, segmentsAt
        case bookmarks, bookmarksAt
        case author, authorId, videoId, sourceURL, authorNote, authorNoteAt
        case authorAvatar, note, noteAt, outline, outlineAt
        case createdAt, updatedAt
        case annotations, annotationsAt
        case images
    }

    init(
        id: String,
        kind: String = "video",
        title: String,
        metaLine: String = "",
        durationText: String = "",
        durationSeconds: Int = 0,
        summary: String = "",
        cover: APICover? = nil,
        playback: APIPlayback = APIPlayback(available: true, reason: nil),
        publishedAt: Int = 0,
        source: APISource? = nil,
        deletedAt: Int? = nil,
        segments: [APISegment] = []
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.metaLine = metaLine
        self.durationText = durationText
        self.durationSeconds = durationSeconds
        self.summary = summary
        self.cover = cover
        self.playback = playback
        self.publishedAt = publishedAt
        self.source = source
        self.deletedAt = deletedAt
        self.segments = segments
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // 两个真正必需的字段：没有 id 无法持久化状态，没有 title 无法渲染。
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)

        let kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "video"
        self.kind = kind
        metaLine = try c.decodeIfPresent(String.self, forKey: .metaLine) ?? ""
        durationText = try c.decodeIfPresent(String.self, forKey: .durationText) ?? ""
        durationSeconds = try c.decodeIfPresent(Int.self, forKey: .durationSeconds) ?? 0
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        cover = try c.decodeIfPresent(APICover.self, forKey: .cover)
        publishedAt = try c.decodeIfPresent(Int.self, forKey: .publishedAt) ?? 0
        source = try c.decodeIfPresent(APISource.self, forKey: .source)
        deletedAt = try c.decodeIfPresent(Int.self, forKey: .deletedAt)
        aiSummary = try c.decodeIfPresent(String.self, forKey: .aiSummary) ?? ""
        keyPoints = try c.decodeIfPresent([String].self, forKey: .keyPoints) ?? []
        labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? []
        segments = try c.decodeIfPresent([APISegment].self, forKey: .segments) ?? []
        segmentsAt = try c.decodeIfPresent(Int.self, forKey: .segmentsAt) ?? 0
        bookmarks = try c.decodeIfPresent([APIBookmark].self, forKey: .bookmarks) ?? []
        bookmarksAt = try c.decodeIfPresent(Int.self, forKey: .bookmarksAt) ?? 0
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        authorId = try c.decodeIfPresent(String.self, forKey: .authorId) ?? ""
        videoId = try c.decodeIfPresent(String.self, forKey: .videoId) ?? ""
        sourceURL = try c.decodeIfPresent(String.self, forKey: .sourceURL) ?? ""
        authorNote = try c.decodeIfPresent(String.self, forKey: .authorNote) ?? ""
        authorAvatar = try c.decodeIfPresent(String.self, forKey: .authorAvatar) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        outline = try c.decodeIfPresent([OutlineNode].self, forKey: .outline) ?? []
        annotations = (try? c.decodeIfPresent([APIAnnotation].self, forKey: .annotations)) ?? []
        noteAt = try c.decodeIfPresent(Int.self, forKey: .noteAt) ?? 0
        createdAt = try c.decodeIfPresent(Int.self, forKey: .createdAt) ?? 0
        updatedAt = try c.decodeIfPresent(Int.self, forKey: .updatedAt) ?? 0
        images = try c.decodeIfPresent([String].self, forKey: .images) ?? []
        authorNoteAt = try c.decodeIfPresent(Int.self, forKey: .authorNoteAt) ?? 0
        platform = (try c.decodeIfPresent(APISource.self, forKey: .source))?.platform ?? ""
        // 缺 playback 时按 kind 推断，避免老版本服务端让整页解不出来
        playback = try c.decodeIfPresent(APIPlayback.self, forKey: .playback)
            ?? APIPlayback(available: kind == "video", reason: nil)
    }
}

struct APILibrary: Decodable, Equatable {
    var libraryVersion: String
    var count: Int
    var generatedAt: Int
    /// 回收站里有多少条。「我」页要显示「回收站 · 3 条」，
    /// 为一行字再拉一次 /trash 不值得。
    var trashCount: Int
    var items: [APILibraryItem]

    private enum CodingKeys: String, CodingKey {
        case libraryVersion, count, generatedAt, trashCount, items
    }

    init(libraryVersion: String, count: Int, generatedAt: Int = 0,
         trashCount: Int = 0, items: [APILibraryItem]) {
        self.libraryVersion = libraryVersion
        self.count = count
        self.generatedAt = generatedAt
        self.trashCount = trashCount
        self.items = items
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decode([APILibraryItem].self, forKey: .items)
        trashCount = try c.decodeIfPresent(Int.self, forKey: .trashCount) ?? 0
        // 服务端给的 count 与 items 长度理应一致；不一致时以实际数组为准，
        // 「契约是否一致」交给测试断言，不在运行时抛错。
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? items.count
        libraryVersion = try c.decodeIfPresent(String.self, forKey: .libraryVersion) ?? ""
        generatedAt = try c.decodeIfPresent(Int.self, forKey: .generatedAt) ?? 0
    }
}

/// 播放地址。**不放进 library**：视频流地址几小时后会过期，
/// 缓存进模型就会在某次点播时悄悄失效。只在真正要播/要下载时取一次。
struct APIPlaybackPayload: Decodable, Equatable {
    var url: String
    var mimeType: String?
    /// 服务端实际给的清晰度，如 "720P"
    var quality: String?
    /// 文件体积。用来在按钮下面写「720P · 约 124 MB」——
    /// 用户点「下载到本地」之前有权知道自己要花多少流量。
    var bytes: Int?
    /// 0 表示「未知」。客户端据此不做过期预判，只在真的 403 时重取。
    var expiresAt: Int

    private enum CodingKeys: String, CodingKey {
        case url, mimeType, quality, bytes, expiresAt
    }

    init(url: String, mimeType: String? = nil, quality: String? = nil,
         bytes: Int? = nil, expiresAt: Int = 0) {
        self.url = url
        self.mimeType = mimeType
        self.quality = quality
        self.bytes = bytes
        self.expiresAt = expiresAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType)
        quality = try c.decodeIfPresent(String.self, forKey: .quality)
        bytes = try c.decodeIfPresent(Int.self, forKey: .bytes)
        expiresAt = try c.decodeIfPresent(Int.self, forKey: .expiresAt) ?? 0
    }

    /// 「720P · 约 124 MB」，缺哪项就少写哪项
    var sizeSummary: String {
        var parts: [String] = []
        if let quality, !quality.isEmpty { parts.append(quality) }
        if let bytes, bytes > 0 {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useMB, .useGB]
            formatter.countStyle = .file
            formatter.allowsNonnumericFormatting = false
            parts.append("约 " + formatter.string(fromByteCount: Int64(bytes)))
        }
        return parts.joined(separator: " · ")
    }
}

/// 导入结果。
///
/// `created` 是「这次操作」的属性，`item` 是数据，所以嵌套而不是混在一起。
/// `created == false` 表示库里已有同一条——不是失败，用户要的结果已经成立。
struct APIImportResult: Decodable, Equatable {
    var created: Bool
    var item: APILibraryItem
}

/// 只有 ok 的成功响应（彻底删除这类）
struct APIOkResponse: Decodable, Equatable {
    var ok: Bool
}

/// 回收站列表
struct APITrash: Decodable, Equatable {
    var count: Int
    var items: [APILibraryItem]

    private enum CodingKeys: String, CodingKey { case count, items }

    init(count: Int, items: [APILibraryItem]) {
        self.count = count
        self.items = items
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decode([APILibraryItem].self, forKey: .items)
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? items.count
    }
}

/// 服务端的错误体：`{code, message, retryable}`。
/// `retryable` 语义：true = 同一请求重试有意义；false = 换参数或换路径，重试无效。
struct APIErrorBody: Decodable, Equatable {
    var code: String
    var message: String
    var retryable: Bool?
}

// MARK: - 客户端

/// 只负责「发请求 + 解包 + 把失败归类」，不缓存、不重试、不碰界面状态。
struct ClipNoteClient {

    enum Failure: Error, Equatable {
        /// 网关直接返回 403。**不是**我们的服务端——服务端鉴权失败是 401。
        /// 之前这里叫 `gatewayIncomplete` 并显示「链接缺少共享码」，
        /// 真机上出过一次：明明带了码，却被这句话带偏了半天。403 就是 403。
        case gatewayBlocked(snippet: String?)
        /// 其它非 2xx；带服务端错误体时一并带出
        case http(status: Int, code: String?, message: String?)
        /// 200 但返回的不是 JSON。线上未知路径会回落首页 HTML，就是这个坑。
        case notJSON(contentType: String?)
        /// JSON 但解不出来：字段类型不对或结构变了
        case malformed(String)
        /// 网络层失败（离线、超时、TLS）
        case transport(String)

        /// 给人看的一句话。不暴露状态码给最终用户，但保留在日志里。
        var displayMessage: String {
            switch self {
            case .gatewayBlocked:
                return "网关拒绝了这次请求（403），稍后会自动重试。"
            case .http(let status, _, let message):
                if let message, !message.isEmpty { return message }
                return "服务端返回 \(status)。"
            case .notJSON:
                return "服务端返回的不是数据。多半是线上版本还没更新。"
            case .malformed:
                return "数据格式不对，可能是服务端版本不匹配。"
            case .transport(let detail):
                return "连不上服务端。\(detail)"
            }
        }

        /// 值不值得隔一秒再试一次。
        ///
        /// 只有「重试有可能变好」的才算：网关 403（实测是瞬时的）、连接层失败、
        /// 5xx / 429。「不是 JSON」「解不出来」重试一百次也一样。
        var isTransient: Bool {
            switch self {
            case .gatewayBlocked, .transport:
                return true
            case .http(let status, _, _):
                return status >= 500 || status == 429
            case .notJSON, .malformed:
                return false
            }
        }

        /// 日志里用的分类。给人看的是 `displayMessage`，给检索的是这个。
        var logKind: String {
            switch self {
            case .gatewayBlocked: return "gateway-403"
            case .http(let status, _, _): return "http-\(status)"
            case .notJSON: return "not-json"
            case .malformed: return "malformed"
            case .transport: return "transport"
            }
        }
    }

    var baseURL: URL
    /// 同一个码既过网关（`sharecode`）又给服务端鉴权（`code`）。
    /// 这不是设计冗余，是两层各要一份，见 API-V2.md §1。
    var shareCode: String
    var session: URLSession

    static let production = ClipNoteClient(
        baseURL: URL(string: "https://clipnote.app.workbuddy.host")!,
        shareCode: "E2ZVITFINI",
        session: .shared
    )

    /// 拼 URL 用字符串拼接而不是 `appendingPathComponent`：
    /// 后者会把 `items/{id}/playback` 这类多段路径当成单个组件处理，行为随系统版本漂。
    func url(path: String) -> URL? {
        guard var components = URLComponents(string: baseURL.absoluteString + path) else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "sharecode", value: shareCode),
            URLQueryItem(name: "code", value: shareCode)
        ]
        return components.url
    }

    func library() async throws -> APILibrary {
        try await libraryPayload().library
    }

    /// 拉库，并把**原始字节**一并交回。
    ///
    /// 本地缓存要存服务端原样，不能存我们编码回去的模型：
    /// 模型一改（字段增删、重命名），缓存就成了第二个真相源，
    /// 而它比线上那份旧——这类 bug 只有真机联网才看得见。
    func libraryPayload() async throws -> (library: APILibrary, data: Data) {
        guard let url = url(path: "/api/v2/library") else {
            throw Failure.transport("地址拼不出来")
        }
        let (data, response) = try await send(url)
        try validate(response: response, data: data)
        do {
            return (try JSONDecoder().decode(APILibrary.self, from: data), data)
        } catch {
            throw Failure.malformed(String(describing: error))
        }
    }

    /// 取一条内容的播放地址。
    ///
    /// 409 = 条目在但没有视频流（笔记/图集）。这不是网络错误，是内容属性，
    /// 所以不归到 `Failure`，而是由调用方判断 `available`。
    func playback(id: String) async throws -> APIPlaybackPayload? {
        do {
            return try await get("/api/v2/items/\(encode(id))/playback", as: APIPlaybackPayload.self)
        } catch let failure as Failure {
            if case .http(let status, let code, _) = failure, status == 409, code == "PLAYBACK_UNAVAILABLE" {
                return nil
            }
            throw failure
        }
    }

    /// 取一条内容的转写原料（字幕）。
    ///
    /// 服务端会现网去 B 站取字幕，约 0.1–0.6 秒。**不做缓存**：
    /// 缓存得住正文，缓存不住「这条视频昨天刚补了字幕」。
    func transcript(id: String) async throws -> APITranscript {
        try await get("/api/v2/items/\(encode(id))/transcript", as: APITranscript.self)
    }

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        guard let url = url(path: path) else { throw Failure.transport("地址拼不出来") }
        let (data, response) = try await send(url)
        try validate(response: response, data: data)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw Failure.malformed(String(describing: error))
        }
    }

    /// 导入一条链接。
    ///
    /// 服务端会真的去解析（B 站约 1–2 秒），所以超时给到 30 秒。
    /// 客户端**不做 URL 清洗**——用户粘的常常是「【标题】 https://b23.tv/xxx」
    /// 这种分享文案，各家格式不一样，清洗规则属于服务端。
    func importItem(url link: String) async throws -> APIImportResult {
        try await post("/api/v2/parse", body: ["url": link], as: APIImportResult.self)
    }

    /// 删除（软删）。条目进回收站，文件仍在本机。
    func deleteItem(id: String) async throws -> APILibraryItem {
        try await post("/api/v2/items/\(encode(id))/delete", body: [:], as: APILibraryItem.self)
    }

    /// 从回收站恢复
    func restoreItem(id: String) async throws -> APILibraryItem {
        try await post("/api/v2/items/\(encode(id))/restore", body: [:], as: APILibraryItem.self)
    }

    /// 彻底删除。不可恢复，所以只在回收站里给这个操作。
    func purgeItem(id: String) async throws {
        _ = try await post("/api/v2/items/\(encode(id))/purge", body: [:], as: APIOkResponse.self)
    }

    /// 把手机上生成的摘要写回快照。
    ///
    /// 生成在客户端（用户自己的 key），存却在服务端——两端才看得见同一份，
    /// 换设备也不丢。
    func saveSummary(id: String, result: SummaryResult, by model: String) async throws -> APILibraryItem {
        try await post(
            "/api/v2/items/\(encode(id))/summary",
            body: [
                "summary": result.summary,
                "keyPoints": result.keyPoints,
                "labels": result.labels,
                "by": model,
            ],
            as: APILibraryItem.self
        )
    }

    /// 写回分段。和摘要一样：生成在手机上，存却在服务端。
    func saveSegments(id: String, segments: [APISegment], by model: String) async throws -> APILibraryItem {
        try await post(
            "/api/v2/items/\(encode(id))/segments",
            body: [
                "segments": segments.map { ["title": $0.title, "t": $0.t, "summary": $0.summary] },
                "by": model,
            ],
            as: APILibraryItem.self
        )
    }

    /// 写回书签。整体替换：书签少，整存整取不用为「删第几个」设计语义。
    func saveBookmarks(id: String, bookmarks: [APIBookmark]) async throws -> APILibraryItem {
        try await post(
            "/api/v2/items/\(encode(id))/bookmarks",
            body: [
                "bookmarks": bookmarks.map { ["t": $0.t, "note": $0.note, "by": $0.by] },
            ],
            as: APILibraryItem.self
        )
    }

    /// 作者备注。空字符串是合法的（等于清空），服务端会用 `authorNoteAt` 区分
    /// 「从没写过」和「写过又删了」。
    func saveAuthorNote(id: String, note: String) async throws -> APILibraryItem {
        try await post(
            "/api/v2/items/\(encode(id))/author-note",
            body: ["note": note],
            as: APILibraryItem.self
        )
    }

    /// 保存我的笔记。
    func saveNote(id: String, note: String) async throws -> APILibraryItem {
        try await post("/api/v2/items/\(encode(id))/note",
                       body: ["note": note], as: APILibraryItem.self)
    }

    /// 提交一个后台任务。服务端立刻返回任务号，真正的模型调用在服务端跑——
    /// 这样用户切出 App 也不影响（见 AIJobClient 里的说明）。
    func createAIJob(_ body: [String: Any]) async throws -> AIJobSnapshot {
        try await post("/api/v2/ai/jobs", body: body, as: AIJobSnapshot.self)
    }

    /// 查任务状态。`404 + JOB_GONE` 表示过期或服务端重启过，调用方该提示重试。
    func aiJob(id: String) async throws -> AIJobSnapshot {
        try await get("/api/v2/ai/jobs/\(encode(id))", as: AIJobSnapshot.self)
    }

    /// 新建一条笔记。服务端只开放 note 这一种 kind。
    func createNote(title: String, note: String) async throws -> APILibraryItem {
        try await post("/api/v2/items", body: ["title": title, "note": note],
                       as: APILibraryItem.self)
    }

    /// 上传一张笔记配图，返回可直接写进 Markdown 的绝对地址。
    ///
    /// 走 base64 而不是 multipart：服务端只用标准库，解析 multipart 要自己写边界处理，
    /// 而这里一次只有一张图，base64 的 33% 膨胀在压缩后可以忽略。
    func uploadImage(jpeg data: Data) async throws -> String {
        let result = try await post("/api/v2/upload",
                                    body: ["data": data.base64EncodedString()],
                                    as: APIUploadResult.self)
        guard !result.url.isEmpty else {
            throw Failure.malformed("上传成功但没有返回地址")
        }
        return result.url
    }

    /// 保存脑图。
    func saveOutline(id: String, outline: [OutlineNode]) async throws -> APILibraryItem {        // 手写编码：OutlineNode 是 Decodable-only（只需要读服务端的），
        // 为了一个写接口给它加 Encodable 会连带影响所有解码路径。
        let encoded = outline.map(Self.encodeNode)
        return try await post("/api/v2/items/\(encode(id))/outline",
                              body: ["outline": encoded], as: APILibraryItem.self)
    }

    static func encodeNode(_ node: OutlineNode) -> [String: Any] {
        ["title": node.title,
         "note": node.note,
         "children": node.children.map(encodeNode)]
    }

    /// 整体替换一条内容的批注。
    func saveAnnotations(id: String, annotations: [APIAnnotation]) async throws -> APILibraryItem {
        let payload = annotations.map { ["t": $0.t, "quote": $0.quote, "note": $0.note] as [String: Any] }
        return try await post("/api/v2/items/\(encode(id))/annotations",
                              body: ["annotations": payload], as: APILibraryItem.self)
    }

    /// 给老条目补原始链接：解析 URL、核对标题后回填 bvid 与作者 id。
    ///
    /// 服务端会在标题不匹配时返回 409，`displayMessage` 会把那句话原样带上来——
    /// 用户需要看到「链接里是 X，和这条不是同一个视频」，而不是一句「失败」。
    func relink(id: String, url: String) async throws -> APILibraryItem {
        try await post("/api/v2/items/\(encode(id))/relink",
                       body: ["url": url], as: APILibraryItem.self)
    }

    struct APIBatchResult: Decodable {
        var done: Int
        var notFound: [String]
        /// purge 时被拒绝的条目（不在回收站里的那些）
        var skipped: [String]
    }

    /// 批量处理：delete / restore / purge。一次请求、服务端一次写盘。
    func batch(action: String, ids: [String]) async throws -> APIBatchResult {
        try await post("/api/v2/batch",
                       body: ["action": action, "ids": ids],
                       as: APIBatchResult.self)
    }

    /// 回收站列表
    func trash() async throws -> APITrash {
        try await get("/api/v2/trash", as: APITrash.self)
    }

    private func encode(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
    }

    /// 上报日志。
    ///
    /// 失败就丢掉：日志上报本身再产生日志，就成了递归。
    /// 网络不通时这条本来最可能失败——而那时本地文件还在。
    func uploadLog(_ entry: LogEntry) async {
        await uploadLogs([entry])
    }

    /// 批量上报。服务端 `/api/log` 接受数组，能省掉几十次往返。
    func uploadLogs(_ entries: [LogEntry]) async {
        guard !entries.isEmpty else { return }
        guard var components = URLComponents(
            string: baseURL.absoluteString + "/api/log"
        ) else { return }
        // 网关要求 sharecode
        components.queryItems = [URLQueryItem(name: "sharecode", value: shareCode)]
        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [[String: Any]] = entries.map { entry in
            [
                "app": "clipnote-ios",
                "level": entry.level.rawValue,
                "message": "[\(entry.key)] \(entry.message)",
                "stack": "",
                "meta": entry.meta.merging(["key": entry.key]) { _, new in new },
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        request.httpBody = data

        _ = try? await session.data(for: request)
    }

    private func post<T: Decodable>(
        _ path: String,
        body: [String: Any],
        as type: T.Type
    ) async throws -> T {
        guard let url = url(path: path) else { throw Failure.transport("地址拼不出来") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // 解析是同步阻塞的（服务端上限 8 秒），客户端要比它宽
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw Failure.transport("请求体序列化失败")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw Failure.transport("不是 HTTP 响应")
            }
            try validate(response: http, data: data)
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw Failure.malformed(String(describing: error))
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.transport(error.localizedDescription)
        }
    }

    private func send(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // 共享码也是缓存键的一部分；不额外处理，第一包不缓存响应
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw Failure.transport("不是 HTTP 响应")
            }
            return (data, http)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.transport(error.localizedDescription)
        }
    }

    private func validate(response: HTTPURLResponse, data: Data) throws {
        let contentType = response.value(forHTTPHeaderField: "Content-Type")

        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 403 {
                let snippet = String(data: data.prefix(160), encoding: .utf8)
                throw Failure.gatewayBlocked(snippet: snippet)
            }
            let body = try? JSONDecoder().decode(APIErrorBody.self, from: data)
            throw Failure.http(status: response.statusCode, code: body?.code, message: body?.message)
        }

        // 关键：线上对未知路径返回 200 + 首页 HTML。不校验会把 HTML 当 JSON 解，
        // 报出一堆看不懂的解码错误——这正是「静默失败」最典型的样子。
        guard let contentType, contentType.lowercased().contains("json") else {
            throw Failure.notJSON(contentType: contentType)
        }
    }
}

// MARK: - 载入状态

/// 一次同步里真实存在的三个时刻。
///
/// 之所以只有三个：我们的同步就是一次 `GET /api/v2/library`，
/// 能观测到的边界只有「请求发出 / 响应解出 / 状态写入」。
/// 再拆细就只能靠编了——那正是引导页最容易变成假动画的地方。
enum SyncStep: Int, CaseIterable, Equatable {
    case connecting
    case fetched
    case ready
}

/// 库的加载状态机。界面只读它，不自己判断「有没有数据」。
@MainActor
final class LibraryStore: ObservableObject {

    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var items: [Item] = []
    @Published private(set) var version: String = ""
    /// 回收站条数。跟着 library 一起回来，不用为一行字单独请求。
    @Published private(set) var trashCount: Int = 0
    /// 本次进程里上一次成功同步的时刻。
    ///
    /// 不能再用「phase == .idle」判断要不要补一次同步了：有缓存时启动就是
    /// `.loaded`，那样会变成「有缓存就永不刷新」。用这个时间戳才问得对。
    @Published private(set) var lastSyncAt: Date?

    private let client: ClipNoteClient?
    /// 日志由外部注入：截图模式传 nil，避免往真实日志文件里写假事件
    private weak var log: LogStore?
    /// 上一次成功的库快照。放 Caches：系统可以回收，丢了也只是多一次联网。
    private let cacheURL: URL?

    /// `client == nil` 表示不联网（截图与预览）。这时只能通过 `loadFixture` 供数。
    /// `cacheDirectory` 只给测试用，正常传 nil 走 Caches。
    init(client: ClipNoteClient?, log: LogStore? = nil, cacheDirectory: URL? = nil) {
        self.client = client
        self.log = log

        let dir = cacheDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        self.cacheURL = dir?.appendingPathComponent("library-cache.json")

        // 启动先把上次的列表摆出来。
        //
        // 为什么要这么做：真机上第二次启动时，界面会整屏停在「正在同步云端快照」，
        // 而用户装的视频明明在本地。同步是「更新」，不是「获取」——
        // 有旧数据就先显示旧数据，刷新在后台悄悄做。
        if let url = cacheURL,
           let data = try? Data(contentsOf: url),
           let cached = try? JSONDecoder().decode(APILibrary.self, from: data) {
            apply(cached)
            phase = .loaded
        }
    }

    /// 截图/预览模式：没有网络层。界面据此避免把「没配 client」显示成「取不到地址」。
    var isOffline: Bool { client == nil }

    // MARK: 加载

    func reload() async {
        await reload(onStep: nil)
    }

    /// 同步。`onStep` 是可选的进度回调，只为引导页的步骤行服务。
    ///
    /// 三步对应三个**真实发生**的时刻，不是定时器：
    /// `connecting` 在请求发出前，`fetched` 在响应解出来之后，
    /// `ready` 在写入本地状态之后。后两步通常在同一帧完成——
    /// 界面上会一起打勾，那是事实。
    ///
    /// 类本身就是 `@MainActor`，步骤回调与最终的 `.done` 在同一个 actor 上，
    /// 不会出现「已经完成，又被晚到的回调改回进行中」。
    func reload(onStep: ((SyncStep) -> Void)?) async {
        guard let client else { return }

        // 有缓存就不要切到全屏加载态：那会把已经能看的列表整块换掉，
        // 而这次刷新很可能只是慢一拍。没数据时才需要那块转圈。
        if items.isEmpty { phase = .loading }

        let started = Date()
        onStep?(.connecting)

        var attempt = 0
        while true {
            do {
                let payload = try await client.libraryPayload()
                onStep?(.fetched)
                apply(payload.library)
                lastSyncAt = Date()
                saveCache(payload.data)
                onStep?(.ready)
                log?.info("library.loaded", "同步完成 \(payload.library.items.count) 条", meta: [
                    "count": "\(payload.library.items.count)",
                    "version": payload.library.libraryVersion,
                    "ms": ms(since: started),
                    "attempt": "\(attempt + 1)",
                ])
                return

            } catch let failure as ClipNoteClient.Failure {
                // 网关 403、超时、5xx 这类是瞬时的，值得隔一秒再试一次。
                // 实测真机上就遇到过一次 403，而一分钟后同样的请求是 200。
                if attempt == 0, failure.isTransient {
                    attempt += 1
                    log?.warn("library.retry", "第一次失败，1.2 秒后重试", meta: [
                        "kind": failure.logKind,
                    ])
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    continue
                }
                handleFailure(failure, started: started, phaseMessage: failure.displayMessage)
                return

            } catch {
                handleFailure(nil, started: started, phaseMessage: "连不上服务端。")
                return
            }
        }
    }

    /// 失败时的两种收场，取决于**手上有没有东西可显示**。
    private func handleFailure(
        _ failure: ClipNoteClient.Failure?,
        started: Date,
        phaseMessage: String
    ) {
        let kind = failure?.logKind ?? "unknown"
        let detail = failure?.displayMessage ?? phaseMessage

        if items.isEmpty {
            // 没缓存：只能给失败页 + 重试
            phase = .failed(phaseMessage)
            log?.error("network.failed", detail, meta: [
                "path": "/api/v2/library", "kind": kind, "ms": ms(since: started),
            ])
        } else {
            // 有缓存：界面一动不动。用户看到的是上次的列表，
            // 而不是一块报错——他要看的东西还在那儿。
            log?.warn("library.refresh_failed", "刷新失败，继续显示上次的列表", meta: [
                "path": "/api/v2/library", "kind": kind,
                "ms": ms(since: started), "cached": "\(items.count)",
            ])
        }
    }

    private func saveCache(_ data: Data) {
        guard let cacheURL else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private func ms(since start: Date) -> String {
        "\(Int(Date().timeIntervalSince(start) * 1000))"
    }

    /// 截图与测试入口：直接从一份 JSON 解码，走的是与线上完全相同的解码路径。
    /// 这样 CI 截图同时验证「解码对不对」和「渲染对不对」，且不依赖网络。
    func loadFixture(_ data: Data) throws {
        let library = try JSONDecoder().decode(APILibrary.self, from: data)
        apply(library)
    }

    /// 供空态截图用
    func applyEmpty(version: String = "lv_empty") {
        self.version = version
        items = []
        trashCount = 0
        phase = .loaded
    }

    func markFailed(_ message: String) {
        phase = .failed(message)
    }

    /// 取播放地址。返回 `nil` 表示「这类内容没有视频流」（服务端 409），不是错误。
    /// 截图模式下没有 client，一律返回 nil——于是播放键置灰，界面不会假装能播。
    func playback(for id: String) async throws -> APIPlaybackPayload? {
        guard let client else { return nil }
        let started = Date()
        do {
            let payload = try await client.playback(id: id)
            if payload == nil {
                log?.warn("playback.unavailable", "该内容没有视频流", meta: [
                    "id": id, "ms": ms(since: started),
                ])
            }
            return payload
        } catch let failure as ClipNoteClient.Failure {
            log?.error("network.failed", failure.displayMessage, meta: [
                "path": "/api/v2/items/playback",
                "kind": failure.logKind,
                "id": id,
                "ms": ms(since: started),
            ])
            throw failure
        }
    }

    /// 导入一条链接，成功后立刻刷新列表——用户要看到「刚才那条出现了」。
    @discardableResult
    func importItem(url link: String) async throws -> APIImportResult {
        guard let client else { throw ClipNoteClient.Failure.transport("截图模式没有网络层") }
        let started = Date()
        do {
            let result = try await client.importItem(url: link)
            // 刷新而不是把 result.item 插进去：created == false 时列表里已经有这条，
            // 插进去就重复了。多花一次请求，换「列表永远等于服务端」这条确定性。
            await reload()
            log?.info("import.created", result.created ? "导入成功" : "库里已有这条", meta: [
                "created": result.created ? "1" : "0",
                "id": result.item.id,
                "ms": ms(since: started),
            ])
            return result
        } catch let failure as ClipNoteClient.Failure {
            log?.error("import.failed", failure.displayMessage, meta: [
                "kind": failure.logKind,
                "ms": ms(since: started),
            ])
            throw failure
        }
    }

    // MARK: 删除与回收站

    /// 删除（软删）。成功后刷新列表——那条应当立刻从眼前消失。
    /// 返回是否成功：界面要据此决定提示「已移到回收站」还是「删除失败」。
    @discardableResult
    func delete(_ item: Item) async -> Bool {
        guard let client else { return false }
        let started = Date()
        do {
            _ = try await client.deleteItem(id: item.id)
            await reload()
            log?.info("item.deleted", "已移到回收站", meta: [
                "id": item.id, "ms": ms(since: started),
            ])
            return true
        } catch let failure as ClipNoteClient.Failure {
            log?.error("item.delete_failed", failure.displayMessage, meta: [
                "id": item.id, "kind": failure.logKind,
            ])
            return false
        } catch {
            log?.error("item.delete_failed", error.localizedDescription, meta: ["id": item.id])
            return false
        }
    }

    func restore(id: String) async {
        guard let client else { return }
        do {
            _ = try await client.restoreItem(id: id)
            await reload()
            log?.info("item.restored", "已从回收站恢复", meta: ["id": id])
        } catch {
            log?.error("item.restore_failed", "恢复失败", meta: ["id": id])
        }
    }

    /// 彻底删除。返回是否成功——调用方只在成功后才删本地文件，
    /// 否则会出现「条目还在列表里但文件没了」。
    @discardableResult
    func purge(id: String) async -> Bool {
        guard let client else { return false }
        do {
            try await client.purgeItem(id: id)
            await reload()
            log?.info("item.purged", "已彻底删除", meta: ["id": id])
            return true
        } catch {
            log?.error("item.purge_failed", "彻底删除失败", meta: ["id": id])
            return false
        }
    }

    /// 保存 AI 摘要。返回是否成功——界面据此决定「已生成」还是「生成成功但没存上」。
    @discardableResult
    func saveSummary(id: String, result: SummaryResult, by model: String) async -> Bool {
        guard let client else { return false }
        do {
            _ = try await client.saveSummary(id: id, result: result, by: model)
            await reload()
            log?.info("summary.saved", "摘要已写回快照", meta: ["id": id, "by": model])
            return true
        } catch {
            log?.error("summary.save_failed", "摘要保存失败", meta: ["id": id])
            return false
        }
    }

    /// 取转写原料。截图模式下没有 client，抛错而不是返回空——
    /// 让调用方走「失败」分支，而不是假装「这条没有字幕」。
    func transcript(for id: String) async throws -> APITranscript {
        guard let client else { throw ClipNoteClient.Failure.transport("截图模式没有网络层") }
        let started = Date()
        do {
            let payload = try await client.transcript(id: id)
            log?.info("transcript.fetched", "取到转写原料", meta: [
                "id": id,
                "source": payload.source,
                "lines": String(payload.lines.count),
                "ms": ms(since: started),
            ])
            return payload
        } catch let failure as ClipNoteClient.Failure {
            log?.error("transcript.failed", failure.displayMessage, meta: [
                "id": id, "kind": failure.logKind, "ms": ms(since: started),
            ])
            throw failure
        }
    }

    /// 保存分段。返回是否成功。
    @discardableResult
    func saveSegments(id: String, segments: [APISegment], by model: String) async -> Bool {
        guard let client else { return false }
        do {
            _ = try await client.saveSegments(id: id, segments: segments, by: model)
            await reload()
            log?.info("segments.saved", "分段已写回快照", meta: [
                "id": id, "count": String(segments.count), "by": model,
            ])
            return true
        } catch {
            log?.error("segments.save_failed", "分段保存失败", meta: ["id": id])
            return false
        }
    }

    /// 截图/预览用：把摘要直接塞进内存里的条目，不经过网络与服务端。
    func seedSummary(id: String, summary: String, keyPoints: [String], labels: [String]) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].aiSummary = summary
        items[index].keyPoints = keyPoints
        items[index].labels = labels
    }

    /// 截图/预览用：同上，塞分段。
    func seedSegments(id: String, segments: [APISegment]) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].segments = segments
    }

    /// 截图/预览用：塞标签，好让标签页有真实分布可拍
    func seedLabels(id: String, labels: [String]) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].labels = labels
    }

    /// 截图/预览用：塞脑图。
    func seedOutline(id: String, outline: [OutlineNode]) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].outline = outline
    }

    /// 截图/预览用：塞笔记。
    func seedNote(id: String, note: String, at: Date = Date()) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].note = note
        // 时间一起种：写笔记本来就会更新它，截图里也要能看出「什么时候改的」
        items[index].noteAt = at
        items[index].updatedAt = at
        if items[index].createdAt == nil { items[index].createdAt = at }
    }

    /// 截图/预览用：塞书签。
    func seedBookmarks(id: String, bookmarks: [APIBookmark]) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].bookmarks = bookmarks
    }

    /// 保存书签。返回是否成功。
    @discardableResult
    func saveBookmarks(id: String, bookmarks: [APIBookmark]) async -> Bool {
        guard let client else { return false }
        do {
            _ = try await client.saveBookmarks(id: id, bookmarks: bookmarks)
            await reload()
            log?.info("bookmarks.saved", "书签已保存", meta: [
                "id": id, "count": String(bookmarks.count),
            ])
            return true
        } catch {
            log?.error("bookmarks.failed", "书签保存失败", meta: ["id": id])
            return false
        }
    }

    /// 保存作者备注。返回是否成功。
    @discardableResult
    func saveAuthorNote(id: String, note: String) async -> Bool {
        guard let client else { return false }
        do {
            _ = try await client.saveAuthorNote(id: id, note: note)
            await reload()
            log?.info("author.note_saved", "作者备注已保存", meta: ["id": id])
            return true
        } catch {
            log?.error("author.note_failed", "作者备注保存失败", meta: ["id": id])
            return false
        }
    }

    /// 截图/预览用：塞作者与原文链接。
    func seedAuthor(id: String, author: String, authorId: String,
                    videoId: String, note: String = "", avatar: String = "") {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].author = author
        items[index].authorId = authorId
        items[index].videoId = videoId
        items[index].platform = "bilibili"
        items[index].sourceURL = videoId.isEmpty
            ? "" : "https://www.bilibili.com/video/\(videoId)"
        items[index].authorNote = note
        items[index].authorAvatar = avatar
    }

    /// 保存笔记。返回是否成功。
    @discardableResult
    func saveNote(id: String, note: String) async -> Bool {
        guard let client else { return false }
        do {
            _ = try await client.saveNote(id: id, note: note)
            // 先本地回写，再拉全库。
            // reload() 失败时会保留旧数据——那样「刚保存的笔记」在首页搜索里
            // 根本查不到，用户只会认为没存上。本地先落一份，搜索立刻可用。
            if let index = items.firstIndex(where: { $0.id == id }) {
                items[index].note = note
            }
            await reload()
            log?.info("note.saved", "笔记已保存", meta: [
                "id": id, "chars": String(note.count),
            ])
            return true
        } catch {
            log?.error("note.failed", "笔记保存失败", meta: ["id": id])
            return false
        }
    }

    /// 新建笔记并立刻插到本地列表最前面。
    ///
    /// 返回建好的条目：调用方要马上 push 到编辑器。等 `reload()` 再去找的话，
    /// 网络慢的时候用户会先看到一个空状态，然后才出现「刚建的那条」。
    func createNote(title: String) async -> Result<Item, NoteCreateFailure> {
        guard let client else { return .failure(.message("没有配置服务地址")) }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.message("标题不能为空")) }
        do {
            let api = try await client.createNote(title: trimmed,
                                                  note: NoteTemplate.body(title: trimmed))
            let fresh = Item(api: api)
            items.insert(fresh, at: 0)
            log?.info("note.created", "新建笔记", meta: [
                "id": api.id, "chars": String(api.note.count),
            ])
            await reload()
            return .success(fresh)
        } catch {
            let readable = (error as? ClipNoteClient.Failure)?.displayMessage ?? "\(error)"
            log?.error("note.create_failed", readable)
            return .failure(.message(readable))
        }
    }

    /// 保存脑图。返回是否成功。
    @discardableResult
    func saveOutline(id: String, outline: [OutlineNode]) async -> Bool {
        guard let client else { return false }
        do {
            _ = try await client.saveOutline(id: id, outline: outline)
            await reload()
            log?.info("outline.saved", "脑图已保存", meta: ["id": id])
            return true
        } catch {
            log?.error("outline.failed", "脑图保存失败", meta: ["id": id])
            return false
        }
    }

    /// 补链接。成功返回 nil，失败返回给人看的一句话。
    func relink(id: String, url: String) async -> String? {
        guard let client else { return "还没有连上服务端。" }
        do {
            _ = try await client.relink(id: id, url: url)
            await reload()
            log?.info("link.relinked", "补上原始链接", meta: ["id": id])
            return nil
        } catch let failure as ClipNoteClient.Failure {
            log?.error("link.relink_failed", failure.displayMessage, meta: ["id": id])
            return failure.displayMessage
        } catch {
            return error.localizedDescription
        }
    }

    /// 保存批注（整体替换）。成功返回 nil。
    func saveAnnotations(id: String, annotations: [APIAnnotation]) async -> String? {
        guard let client else { return "还没有连上服务端。" }
        do {
            _ = try await client.saveAnnotations(id: id, annotations: annotations)
            await reload()
            log?.info("annotation.saved", "批注已保存", meta: [
                "id": id, "count": String(annotations.count),
            ])
            return nil
        } catch let failure as ClipNoteClient.Failure {
            log?.error("annotation.failed", failure.displayMessage, meta: ["id": id])
            return failure.displayMessage
        } catch {
            return error.localizedDescription
        }
    }

    /// 批量处理。返回实际处理条数；失败返回 nil。
    func batch(_ action: String, ids: [String]) async -> Int? {
        guard let client, !ids.isEmpty else { return nil }
        do {
            let result = try await client.batch(action: action, ids: ids)
            await reload()
            log?.info("batch.done", "批量 \(action)", meta: [
                "count": String(result.done),
                "missing": String(result.notFound.count),
                "skipped": String(result.skipped.count),
            ])
            return result.done
        } catch {
            log?.error("batch.failed", "批量 \(action) 失败", meta: ["count": String(ids.count)])
            return nil
        }
    }

    /// 批量移到回收站。
    func batchDelete(ids: [String]) async -> Int? {
        await batch("delete", ids: ids)
    }

    func loadTrash() async throws -> [APILibraryItem] {
        guard let client else { return [] }
        return try await client.trash().items
    }

    private func apply(_ library: APILibrary) {
        version = library.libraryVersion
        items = library.items.map(Item.init(api:))
        trashCount = library.trashCount
        phase = .loaded
    }
}
