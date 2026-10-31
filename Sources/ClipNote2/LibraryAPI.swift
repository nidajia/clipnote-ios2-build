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
    /// 软删时间戳（毫秒）。只在回收站里有值，列表里一律为 nil。
    var deletedAt: Int?

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, metaLine, durationText, durationSeconds
        case summary, cover, playback, publishedAt, source, deletedAt
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
        deletedAt: Int? = nil
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

        /// 日志里用的分类。给人看的是 `displayMessage`，给检索的是这个。
        var logKind: String {
            switch self {
            case .gatewayIncomplete: return "gateway"
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
        try await get("/api/v2/library", as: APILibrary.self)
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
        request.timeoutInterval = 20
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
    /// 回收站条数。跟着 library 一起回来，不用为一行字单独请求。
    @Published private(set) var trashCount: Int = 0

    private let client: ClipNoteClient?
    /// 日志由外部注入：截图模式传 nil，避免往真实日志文件里写假事件
    private weak var log: LogStore?

    /// `client == nil` 表示不联网（截图与预览）。这时只能通过 `loadFixture` 供数。
    init(client: ClipNoteClient?, log: LogStore? = nil) {
        self.client = client
        self.log = log
    }

    /// 截图/预览模式：没有网络层。界面据此避免把「没配 client」显示成「取不到地址」。
    var isOffline: Bool { client == nil }

    // MARK: 加载

    func reload() async {
        guard let client else { return }
        phase = .loading
        let started = Date()
        do {
            let library = try await client.library()
            apply(library)
            log?.info("library.loaded", "同步完成 \(library.items.count) 条", meta: [
                "count": "\(library.items.count)",
                "version": library.libraryVersion,
                "ms": ms(since: started),
            ])
        } catch let failure as ClipNoteClient.Failure {
            phase = .failed(failure.displayMessage)
            log?.error("network.failed", failure.displayMessage, meta: [
                "path": "/api/v2/library",
                "kind": failure.logKind,
                "ms": ms(since: started),
            ])
        } catch {
            phase = .failed("连不上服务端。")
            log?.error("network.failed", error.localizedDescription, meta: [
                "path": "/api/v2/library",
                "kind": "unknown",
                "ms": ms(since: started),
            ])
        }
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
