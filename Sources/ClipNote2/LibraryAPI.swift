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

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, metaLine, durationText, durationSeconds
        case summary, cover, playback, publishedAt, source
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
        source: APISource? = nil
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
        // 缺 playback 时按 kind 推断，避免老版本服务端让整页解不出来
        playback = try c.decodeIfPresent(APIPlayback.self, forKey: .playback)
            ?? APIPlayback(available: kind == "video", reason: nil)
    }
}

struct APILibrary: Decodable, Equatable {
    var libraryVersion: String
    var count: Int
    var generatedAt: Int
    var items: [APILibraryItem]

    private enum CodingKeys: String, CodingKey {
        case libraryVersion, count, generatedAt, items
    }

    init(libraryVersion: String, count: Int, generatedAt: Int = 0, items: [APILibraryItem]) {
        self.libraryVersion = libraryVersion
        self.count = count
        self.generatedAt = generatedAt
        self.items = items
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decode([APILibraryItem].self, forKey: .items)
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
    /// 0 表示「未知」。客户端据此不做过期预判，只在真的 403 时重取。
    var expiresAt: Int
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
        /// 网关要求 query 带 sharecode，缺了会被拦在 `app.py` 之前
        case gatewayIncomplete
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
            case .gatewayIncomplete:
                return "服务端没有就绪（链接缺少共享码）。"
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
        try await get("/api/v2/library", as: APILibrary.self)
    }

    /// 取一条内容的播放地址。
    ///
    /// 409 = 条目在但没有视频流（笔记/图集）。这不是网络错误，是内容属性，
    /// 所以不归到 `Failure`，而是由调用方判断 `available`。
    func playback(id: String) async throws -> APIPlaybackPayload? {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
        do {
            return try await get("/api/v2/items/\(encoded)/playback", as: APIPlaybackPayload.self)
        } catch let failure as Failure {
            if case .http(let status, let code, _) = failure, status == 409, code == "PLAYBACK_UNAVAILABLE" {
                return nil
            }
            throw failure
        }
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

    private func send(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
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
                throw Failure.gatewayIncomplete
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

    private let client: ClipNoteClient?

    /// `client == nil` 表示不联网（截图与预览）。这时只能通过 `loadFixture` 供数。
    init(client: ClipNoteClient?) {
        self.client = client
    }

    // MARK: 加载

    func reload() async {
        guard let client else { return }
        phase = .loading
        do {
            let library = try await client.library()
            apply(library)
        } catch let failure as ClipNoteClient.Failure {
            phase = .failed(failure.displayMessage)
        } catch {
            phase = .failed("连不上服务端。")
        }
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
        phase = .loaded
    }

    func markFailed(_ message: String) {
        phase = .failed(message)
    }

    /// 取播放地址。返回 `nil` 表示「这类内容没有视频流」（服务端 409），不是错误。
    /// 截图模式下没有 client，一律返回 nil——于是播放键置灰，界面不会假装能播。
    func playbackURL(for id: String) async throws -> URL? {
        guard let client else { return nil }
        guard let payload = try await client.playback(id: id) else { return nil }
        return URL(string: payload.url)
    }

    private func apply(_ library: APILibrary) {
        version = library.libraryVersion
        items = library.items.map(Item.init(api:))
        phase = .loaded
    }
}
