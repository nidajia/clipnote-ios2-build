import Combine
import Foundation

/// 一条运行日志。
///
/// 只记「用户会感觉到、但看不出原因」的事：
/// 失败全记，成功只记四个节点（同步完成 / 播放开始 / 下载完成 / 导入完成）。
/// 每一条成功的网络请求都记的话，一天几十条，真正的问题会被埋掉。
struct LogEntry: Codable, Identifiable, Equatable {
    enum Level: String, Codable, Comparable {
        case info, warn, error

        /// 用于筛选与排序
        private var rank: Int {
            switch self {
            case .info: return 0
            case .warn: return 1
            case .error: return 2
            }
        }

        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rank < rhs.rank }

        var label: String {
            switch self {
            case .info: return "信息"
            case .warn: return "警告"
            case .error: return "错误"
            }
        }
    }

    var id: String = UUID().uuidString
    var ts: Date = Date()
    var level: Level
    /// 事件键，如 `network.failed`。英文键名便于检索，界面上另给中文摘要。
    var key: String
    var message: String
    var meta: [String: String] = [:]
}

// MARK: - 脱敏

enum LogRedaction {
    /// 日志里**绝不能出现共享码**。
    ///
    /// `sharecode` 是用户的同步凭证，一旦写进日志、又被上报到服务端，
    /// 就等于把它抄在一个可能被很多人读到的地方。
    /// 这里把所有 `xxx=<值>` 形式的敏感查询参数替换掉，
    /// 只保留「有没有码」这个信息（放在 meta 里）。
    static func apply(_ text: String) -> String {
        var result = text
        for name in ["sharecode", "code", "token", "cookie"] {
            result = result.replacingOccurrences(
                of: "\(name)=[^&\\s\"']+",
                with: "\(name)=<redacted>",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return result
    }

    static func entry(_ entry: LogEntry) -> LogEntry {
        var copy = entry
        copy.message = apply(entry.message)
        copy.meta = entry.meta.mapValues(apply)
        return copy
    }
}

// MARK: - 日志仓库

/// 日志以**本地为准**。
///
/// 真机出问题时网络往往也不通——如果日志只存在服务端，那最需要它的那一刻
/// 恰好是它不存在的时候。所以本地环形文件是唯一可靠的落点，
/// 服务端只是「方便看」。
///
/// `error` 级会顺手上报一次（fire-and-forget）；`info` 只留本地，
/// 等用户在「我 · 运行日志」里手动上报。
@MainActor
final class LogStore: ObservableObject {
    @Published private(set) var entries: [LogEntry] = []

    /// 环形上限。200 条大约 60 KB，够看清一次故障的前后文。
    private let limit = 200
    private let fileURL: URL
    /// 批量上报签名：自动上报传一条，手动上报传全部
    private let uploader: (@Sendable ([LogEntry]) async -> Void)?

    init(directory: URL? = nil, uploader: (@Sendable ([LogEntry]) async -> Void)? = nil) {
        let fm = FileManager.default
        // 放 Caches：日志不该占用 iCloud 备份空间，被系统清掉也可接受
        let base = directory
            ?? fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("clipnote-log.json")
        self.uploader = uploader
        load()
    }

    var count: Int { entries.count }
    var errorCount: Int { entries.filter { $0.level == .error }.count }

    /// 最新的在前
    var newestFirst: [LogEntry] { Array(entries.reversed()) }

    // MARK: 写入

    func info(_ key: String, _ message: String, meta: [String: String] = [:]) {
        append(LogEntry(level: .info, key: key, message: message, meta: meta))
    }

    func warn(_ key: String, _ message: String, meta: [String: String] = [:]) {
        append(LogEntry(level: .warn, key: key, message: message, meta: meta))
    }

    func error(_ key: String, _ message: String, meta: [String: String] = [:]) {
        append(LogEntry(level: .error, key: key, message: message, meta: meta))
    }

    /// 把本地全部日志推上去。返回成功推上去的条数（0 表示没配上报通道）。
    ///
    /// 手动上报的价值在于 **info 也在里面**：error 会自动走，
    /// 但「最后一次成功同步是什么时候」这种判断只能靠 info。
    func uploadAll() async -> Int {
        guard let uploader, !entries.isEmpty else { return 0 }
        let snapshot = entries
        await uploader(snapshot)
        return snapshot.count
    }

    func clear() {
        entries = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func append(_ entry: LogEntry) {
        let safe = LogRedaction.entry(entry)
        entries.append(safe)
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
        // 整体重写而不是追加：
        // 追加行是 JSONL、整体是 JSON 数组，两种格式读的时候只能解一种。
        // 一天几十次写入、每次 60 KB，这点 IO 不值得为它引入格式歧义。
        persist()

        // error 自动上报；info/warn 留在本地，等用户手动上报
        if safe.level == .error, let uploader {
            Task { await uploader([safe]) }
        }
    }

    // MARK: 持久化

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder.logDecoder.decode([LogEntry].self, from: data)
        else { return }
        entries = Array(decoded.suffix(limit))
    }

    private func persist() {
        guard let data = try? JSONEncoder.logEncoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - 编解码

private extension JSONEncoder {
    static let logEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = []
        return encoder
    }()
}

private extension JSONDecoder {
    static let logDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
