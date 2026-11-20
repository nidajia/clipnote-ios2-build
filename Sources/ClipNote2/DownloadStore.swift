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

struct DownloadHTTPError: LocalizedError {
    let statusCode: Int

    init?(response: HTTPURLResponse) {
        guard !(200..<300).contains(response.statusCode) else { return nil }
        statusCode = response.statusCode
    }

    var requiresFreshPlayback: Bool { statusCode == 401 || statusCode == 403 }

    var errorDescription: String? { "视频源返回 \(statusCode)，请重新获取地址。" }
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
    private var downloader: FileDownloader?
    /// 与界面提示分开；其他条目的失败不能覆盖当前条目的地址失效状态。
    private var stalePlaybackIDs = Set<String>()
    private let usesBackgroundSession: Bool
    /// 日志由外部注入；截图模式传 nil
    private weak var log: LogStore?

    init(directory: URL? = nil, log: LogStore? = nil) {
        let fm = FileManager.default
        let base = directory ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.directory = base
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        self.indexURL = base.appendingPathComponent("downloads.json")
        self.log = log
        self.usesBackgroundSession = directory == nil
        load()
        reconcile()
        recoverCompletedDownloads()
        // 生产实例启动即重连同名后台会话；测试/截图的临时目录不注册系统后台会话。
        if usesBackgroundSession { connectDownloader() }
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

    func requiresFreshPlayback(for id: String) -> Bool { stalePlaybackIDs.contains(id) }

    // MARK: - 动作

    /// 下载一条内容。
    ///
    /// `url` 由调用方按需从 `/api/v2/items/{id}/playback` 取，`DownloadStore` 不猜地址——
    /// 视频流地址会过期，缓存进模型里就会在几小时后悄悄失效。
    func start(_ id: String, url: URL) {
        let k = id
        guard records[k] == nil, progress[k] == nil else { return }
        // 调用方此时已拿到地址。取地址失败走不到这里，下一次仍应重新获取。
        stalePlaybackIDs.remove(k)
        progress[k] = 0
        if lastFailure?.id == k { lastFailure = nil }

        connectDownloader()
        downloader?.download(id: id, from: url)
    }

    private func connectDownloader() {
        guard downloader == nil else { return }
        downloader = FileDownloader(directory: directory, background: usesBackgroundSession,
            onProgress: { [weak self] id, value in self?.progress[id] = value },
            onFinish: { [weak self] id, result in self?.handleCompletion(id: id, result: result) })
        downloader?.onForegroundRetry = { [weak self] id in
            Task { @MainActor in
                self?.log?.info("download.foreground_retry",
                                "后台保存失败，改前台重下",
                                meta: ["id": id])
            }
        }
        downloader?.restore()
    }

    func handleCompletion(id: String, result: Result<DownloadReceipt, Error>) {
        progress[id] = nil
        switch result {
        case .success(let receipt):
            acceptReceipt(receipt)
        case .failure(let error):
            if (error as? URLError)?.code == .cancelled { return }
            let needsRefresh = (error as? DownloadHTTPError)?.requiresFreshPlayback == true
            if needsRefresh { stalePlaybackIDs.insert(id) }
            let message = needsRefresh
                ? "视频地址已过期或被拒绝，联网后重新下载。"
                : "下载失败：\(error.localizedDescription)"
            lastFailure = DownloadFailure(id: id, message: message)
            Task { @MainActor in log?.error("download.failed", message, meta: ["id": id]) }
        }
    }

    /// 系统结束下载时先写持久收据，再更新 UI。进程在两步之间被回收也能重放。
    private func recoverCompletedDownloads() {
        let folder = directory.appendingPathComponent("download-receipts")
        for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            guard url.pathExtension == "json", let data = try? Data(contentsOf: url),
                  let receipt = try? JSONDecoder().decode(DownloadReceipt.self, from: data) else { continue }
            acceptReceipt(receipt)
        }
    }

    private func acceptReceipt(_ receipt: DownloadReceipt) {
        let file = directory.appendingPathComponent(receipt.record.fileName)
        guard file.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
              receipt.receiptName == URL(fileURLWithPath: receipt.receiptName).lastPathComponent,
              FileManager.default.fileExists(atPath: file.path) else { return }
        let previous = records[receipt.id]
        records[receipt.id] = receipt.record
        if save() {
            try? FileManager.default.removeItem(at: receipt.url(in: directory))
            if let previous, previous.fileName != receipt.record.fileName {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(previous.fileName))
            }
        }
        Task { @MainActor in
            log?.info("download.finished", "下载完成", meta: ["id": receipt.id,
                                                              "bytes": "\(receipt.record.byteCount)"])
        }
    }

    /// 彻底删除条目时调用：把本地文件一起清掉。
    ///
    /// 不清的话会留下无人认领的 130 MB——用户以为删干净了，实际没有。
    func removeLocalFile(_ id: String) {
        guard let record = records[id] else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(record.fileName))
        records.removeValue(forKey: id)
        save()
    }

    func cancel(_ id: String) {
        downloader?.cancel(id)
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

    @discardableResult
    private func save() -> Bool {
        do {
            try JSONEncoder().encode(records).write(to: indexURL, options: .atomic)
            return true
        } catch {
            lastFailure = DownloadFailure(id: "index", message: "下载索引保存失败，重启后会重新恢复。")
            return false
        }
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

struct DownloadReceipt: Codable {
    var id: String
    var record: DownloadRecord
    var receiptName: String

    func url(in directory: URL) -> URL {
        directory.appendingPathComponent("download-receipts").appendingPathComponent(receiptName)
    }

    static func stage(id: String, temporary: URL, directory: URL) throws -> DownloadReceipt {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
        } catch {
            // 真机上见过这一支：系统已经把临时文件收走（后台会话跨容器时尤其常见）。
            // 把真实原因带给用户，比只显示「下载失败」有用。
            throw NSError(domain: "ClipNoteDownload", code: 403, userInfo: [
                NSLocalizedDescriptionKey: "下载到的临时文件读不到（\(error.localizedDescription)），请再下一次。"
            ])
        }
        let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard bytes > 64 * 1024 else {
            throw NSError(domain: "ClipNoteDownload", code: 422,
                          userInfo: [NSLocalizedDescriptionKey: "下载到的不是视频（只有 \(bytes) 字节），请重试。"])
        }
        let receipt = DownloadReceipt(id: id,
            record: DownloadRecord(fileName: "\(DownloadStore.fileStem(id))-\(UUID().uuidString).mp4",
                                   byteCount: bytes, finishedAt: Date()),
            receiptName: UUID().uuidString + ".json")
        let folder = directory.appendingPathComponent("download-receipts")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(receipt.record.fileName)
        do {
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            // 同一卷上 move 失败时再试一次 copy：部分系统版本在跨容器读取时
            // 只允许拷贝，不允许重命名。两次都失败就抛出可读原因。
            do {
                try FileManager.default.copyItem(at: temporary, to: destination)
                try? FileManager.default.removeItem(at: temporary)
            } catch let copyError {
                throw NSError(domain: "ClipNoteDownload", code: 500, userInfo: [
                    NSLocalizedDescriptionKey: "下载完成但存不进本机（\(copyError.localizedDescription)），请再下一次。"
                ])
            }
        }
        do { try JSONEncoder().encode(receipt).write(to: receipt.url(in: directory), options: .atomic) }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
        return receipt
    }
}

/// taskDescription 由 URLSession 持久化，系统回收进程后仍能把任务归回正确条目。
final class FileDownloader: NSObject, URLSessionDownloadDelegate {
    static let backgroundIdentifier = "com.clipnote.download"
    static var backgroundCompletion: (() -> Void)?

    private let directory: URL
    private let background: Bool
    private let onProgress: (String, Double) -> Void
    private let onFinish: (String, Result<DownloadReceipt, Error>) -> Void
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var cancelledBeforeRestore = Set<String>()
    private var closedTasks = Set<Int>()
    private var restored = false
    private var restoring = false
    private var pending: [String: URL] = [:]

    init(directory: URL, background: Bool,
         onProgress: @escaping (String, Double) -> Void,
         onFinish: @escaping (String, Result<DownloadReceipt, Error>) -> Void) {
        self.directory = directory
        self.background = background
        self.onProgress = onProgress
        self.onFinish = onFinish
        super.init()
    }

    private lazy var session: URLSession = {
        // 后台会话保持原样：它是「息屏也能下」的唯一实现，不能为了绕一个
        // 权限问题把它砍掉。真机上读不到临时文件时，下面还有一次前台重下兜底。
        let config = background
            ? URLSessionConfiguration.background(withIdentifier: Self.backgroundIdentifier)
            : URLSessionConfiguration.default
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = background
        // 所有任务表和 Store 状态在主队列操作，回调返回前已写完持久收据和索引。
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    /// 兜底用的前台会话。
    ///
    /// 后台会话把临时文件放在 nsurlsessiond 的容器里；未签名安装时本 App
    /// 可能读不到那份文件（日志原话：未能打开文件…没有查看它的权限）。
    /// 这种失败不该让用户看到「下载失败」，换前台会话用同一地址再下一次即可。
    private lazy var retrySession: URLSession = {
        let config = URLSessionConfiguration.default
        config.isDiscretionary = false
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 6 * 60 * 60
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    /// 已经走过一次前台重下的条目，避免权限问题导致无限循环。
    private var foregroundRetried = Set<String>()
    /// 换前台重下之前通知外面一声，便于留日志（Store 里写 download.foreground_retry）。
    var onForegroundRetry: ((String) -> Void)?

    func restore() {
        guard !restoring, !restored else { return }
        restoring = true
        session.getAllTasks { [weak self] recovered in
            DispatchQueue.main.async {
                guard let self else { return }
                for task in recovered {
                    guard let id = task.taskDescription, let download = task as? URLSessionDownloadTask else {
                        task.cancel() // 旧包没有归属标记的任务不能误绑定到任何条目。
                        continue
                    }
                    guard task.state != .completed, task.state != .canceling,
                          !self.closedTasks.contains(task.taskIdentifier) else { continue }
                    guard !self.cancelledBeforeRestore.contains(id) else {
                        self.closedTasks.insert(task.taskIdentifier)
                        task.cancel()
                        continue
                    }
                    self.tasks[id] = download
                    self.onProgress(id, max(0, Double(task.countOfBytesReceived) / Double(max(1, task.countOfBytesExpectedToReceive))))
                    if task.state == .suspended { task.resume() }
                }
                self.restored = true
                self.restoring = false
                let queued = self.pending
                self.pending = [:]
                for (id, url) in queued { self.download(id: id, from: url) }
            }
        }
    }

    func download(id: String, from url: URL) {
        guard restored else {
            pending[id] = url
            restore()
            return
        }
        guard tasks[id] == nil else { return }
        foregroundRetried.remove(id)
        let task = session.downloadTask(with: url)
        task.taskDescription = id
        tasks[id] = task
        task.resume()
    }

    func cancel(_ id: String) {
        pending[id] = nil
        if !restored { cancelledBeforeRestore.insert(id) }
        if let task = tasks.removeValue(forKey: id) {
            closedTasks.insert(task.taskIdentifier)
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription, !closedTasks.contains(downloadTask.taskIdentifier),
              tasks[id] == nil || tasks[id] === downloadTask,
              totalBytesExpectedToWrite > 0 else { return }
        onProgress(id, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription, !closedTasks.contains(downloadTask.taskIdentifier),
              tasks[id] == nil || tasks[id] === downloadTask else { return }
        closedTasks.insert(downloadTask.taskIdentifier)
        tasks[id] = nil
        do {
            guard let response = downloadTask.response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            if let error = DownloadHTTPError(response: response) { throw error }
            let receipt = try DownloadReceipt.stage(id: id, temporary: location, directory: directory)
            onFinish(id, .success(receipt))
        } catch {
            // 只有「读不到/存不进」这类本机权限问题才换前台重下；
            // 视频地址过期、HTTP 错误重下一次也是白下，直接报给用户。
            if Self.isLocalStorageFailure(error),
               !foregroundRetried.contains(id),
               let url = downloadTask.originalRequest?.url {
                foregroundRetried.insert(id)
                onForegroundRetry?(id)
                let retry = retrySession.downloadTask(with: url)
                retry.taskDescription = id
                tasks[id] = retry
                retry.resume()
                return
            }
            onFinish(id, .failure(error))
        }
    }

    /// 本机落盘失败（区别于网络/HTTP 失败）。
    private static func isLocalStorageFailure(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == "ClipNoteDownload" else { return false }
        return ns.code == 403 || ns.code == 500
    }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription, let error, !closedTasks.contains(task.taskIdentifier),
              tasks[id] == nil || tasks[id] === task else { return }
        closedTasks.insert(task.taskIdentifier)
        tasks[id] = nil
        if (error as? URLError)?.code != .cancelled,
           let response = task.response as? HTTPURLResponse,
           let httpError = DownloadHTTPError(response: response) {
            onFinish(id, .failure(httpError))
        } else {
            onFinish(id, .failure(error))
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = Self.backgroundCompletion
        Self.backgroundCompletion = nil
        handler?()
    }
}
