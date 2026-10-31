import Combine
import Foundation

/// 一条已下载记录。索引只存文件名与大小，真实文件放在 Documents。
struct DownloadRecord: Codable {
    var fileName: String
    var byteCount: Int64
    var finishedAt: Date
}

/// 下载失败的原因，按条目 id 归位，便于界面显示在对应位置。
struct DownloadFailure: Identifiable, Equatable {
    var id: String
    var message: String
}

/// 下载与本地文件索引。
///
/// 核心约束：**状态只依赖磁盘**。杀进程重启后 `records` 由 `downloads.json`
/// 恢复，并且必须与真实文件对账——文件被系统清掉时索引也要清掉，
/// 否则会出现「显示已下载、点开却播不了」。
///
/// 未标 `@MainActor`：URLSession 的回调在后台队列，所有状态变更都显式
/// 切回主队列。标注了反而要在闭包里到处 assumeIsolated，得不偿失。
final class DownloadStore: ObservableObject {
    @Published private(set) var records: [String: DownloadRecord] = [:]
    @Published private(set) var progress: [String: Double] = [:]
    /// 最近一次下载失败的原因。
    ///
    /// 没有它，失败是**完全静默**的：进度条消失，什么都没变，
    /// 用户只会以为「点了没反应」。这是最差的一种失败方式。
    @Published private(set) var lastFailure: DownloadFailure?

    private let directory: URL
    private let indexURL: URL
    private let downloader = FileDownloader()
    /// 日志由外部注入；截图模式传 nil
    private weak var log: LogStore?

    init(directory: URL? = nil, log: LogStore? = nil) {
        let fm = FileManager.default
        let base = directory ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.directory = base
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        self.indexURL = base.appendingPathComponent("downloads.json")
        self.log = log
        load()
        reconcile()
    }

    // MARK: - 查询

    func isDownloaded(_ id: String) -> Bool { records[id] != nil }

    func localURL(for id: String) -> URL? {
        guard let record = records[id] else { return nil }
        return directory.appendingPathComponent(record.fileName)
    }

    func byteCount(for id: String) -> Int64 { records[id]?.byteCount ?? 0 }

    /// 「我 · 下载与存储」用
    var downloadedCount: Int { records.count }

    var totalBytes: Int64 { records.values.reduce(0) { $0 + $1.byteCount } }

    func progressValue(for id: String) -> Double? { progress[id] }

    // MARK: - 动作

    /// 下载一条内容。
    ///
    /// `url` 由调用方按需从 `/api/v2/items/{id}/playback` 取，`DownloadStore` 不猜地址——
    /// 视频流地址会过期，缓存进模型里就会在几小时后悄悄失效。
    func start(_ id: String, url: URL) {
        let k = id
        guard records[k] == nil, progress[k] == nil else { return }
        progress[k] = 0
        if lastFailure?.id == k { lastFailure = nil }

        downloader.download(from: url) { [weak self] value in
            self?.progress[k] = value
        } onFinish: { [weak self] result in
            guard let self else { return }
            self.progress[k] = nil

            switch result {
            case .failure(let error):
                let code = (error as NSError).code
                // 403 是签名过期，重试同一个地址不会好。这句话要能看懂。
                let message = code == 403 || code == -1011
                    ? "视频源拒绝了请求，地址大概已过期。服务端还没接重新解析。"
                    : (error as NSError).localizedDescription
                self.lastFailure = DownloadFailure(id: k, message: message)
                let logger = self.log
                Task { @MainActor in
                    logger?.error("download.failed", message, meta: [
                        "id": k, "code": "\(code)",
                    ])
                }
                return

            case .success(let temporary):
                let fileName = "\(Self.fileStem(k)).mp4"
                let destination = self.directory.appendingPathComponent(fileName)
                try? FileManager.default.removeItem(at: destination)
                do {
                    try FileManager.default.moveItem(at: temporary, to: destination)
                    let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
                    let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                    self.records[k] = DownloadRecord(fileName: fileName, byteCount: size, finishedAt: Date())
                    self.save()
                    let logger = self.log
                    Task { @MainActor in
                        logger?.info("download.finished", "下载完成", meta: [
                            "id": k, "bytes": "\(size)",
                        ])
                    }
                } catch {
                    // 移动失败就当这次下载没发生，不要把半截文件写进索引
                    self.lastFailure = DownloadFailure(id: k, message: "保存文件失败：\(error.localizedDescription)")
                }
            }
        }
    }

    func cancel(_ id: String) {
        downloader.cancelCurrent()
        progress[id] = nil
    }

    // MARK: - 持久化

    /// 服务端 id 直接当索引键：它是稳定的，重装、换设备、重新同步之后都一样。
    /// 上一版用 `UUID()`，每次重建条目就换一把钥匙，已下载状态永远对不上。
    ///
    /// 文件名要单独处理：id 可能含 `/` 等路径字符，不能直接当文件名。
    static func fileStem(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = id.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        return String(cleaned).isEmpty ? "item" : String(cleaned)
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([String: DownloadRecord].self, from: data)
        else { return }
        records = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// 索引与磁盘对账。只在数量变化时回写，避免每次启动都写盘。
    private func reconcile() {
        let fm = FileManager.default
        let alive = records.filter {
            fm.fileExists(atPath: directory.appendingPathComponent($0.value.fileName).path)
        }
        if alive.count != records.count {
            records = alive
            save()
        }
    }

    // MARK: - 截图与测试用

    func seedDownloading(_ id: String, value: Double) {
        progress[id] = value
    }

    func seedDownloaded(_ id: String, byteCount: Int64 = 48_200_000) {
        let fileName = "\(Self.fileStem(id)).mp4"
        let destination = directory.appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: destination.path) {
            try? Data(repeating: 0, count: 2048).write(to: destination)
        }
        records[id] = DownloadRecord(fileName: fileName, byteCount: byteCount, finishedAt: Date())
        save()
    }
}

// MARK: - 真实下载

/// 把 URLSession 的进度与结果收敛成两个回调。
///
/// `didFinishDownloadingTo` 给的临时文件在该回调返回后就会被系统删掉，
/// 所以必须先搬走再回调。
final class FileDownloader: NSObject, URLSessionDownloadDelegate {

    private lazy var session: URLSession = URLSession(
        configuration: .default,
        delegate: self,
        delegateQueue: nil
    )

    private var task: URLSessionDownloadTask?
    private var onProgress: ((Double) -> Void)?
    private var onFinish: ((Result<URL, Error>) -> Void)?
    private var settled = false

    func download(
        from url: URL,
        onProgress: @escaping (Double) -> Void,
        onFinish: @escaping (Result<URL, Error>) -> Void
    ) {
        self.onProgress = onProgress
        self.onFinish = onFinish
        settled = false
        let task = session.downloadTask(with: url)
        self.task = task
        task.resume()
    }

    func cancelCurrent() {
        task?.cancel()
        task = nil
        settled = true
        onProgress = nil
        onFinish = nil
    }

    private func settle(_ result: Result<URL, Error>) {
        guard !settled else { return }
        settled = true
        let handler = onFinish
        onFinish = nil
        DispatchQueue.main.async { handler?(result) }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let value = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let handler = onProgress
        DispatchQueue.main.async { handler?(value) }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("cn-\(UUID().uuidString).mp4")
        do {
            try FileManager.default.moveItem(at: location, to: temporary)
            settle(.success(temporary))
        } catch {
            settle(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { settle(.failure(error)) }
    }
}
