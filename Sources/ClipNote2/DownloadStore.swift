import Combine
import Foundation

/// 一条已下载记录。索引只存文件名与大小，真实文件放在 Documents。
struct DownloadRecord: Codable {
    var fileName: String
    var byteCount: Int64
    var finishedAt: Date
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

    private let directory: URL
    private let indexURL: URL
    private let downloader = FileDownloader()

    init(directory: URL? = nil) {
        let fm = FileManager.default
        let base = directory ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.directory = base
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        self.indexURL = base.appendingPathComponent("downloads.json")
        load()
        reconcile()
    }

    // MARK: - 查询

    func isDownloaded(_ id: UUID) -> Bool { records[key(id)] != nil }

    func localURL(for id: UUID) -> URL? {
        guard let record = records[key(id)] else { return nil }
        return directory.appendingPathComponent(record.fileName)
    }

    func byteCount(for id: UUID) -> Int64 { records[key(id)]?.byteCount ?? 0 }

    func progressValue(for id: UUID) -> Double? { progress[key(id)] }

    // MARK: - 动作

    func start(_ item: Item) {
        let k = key(item.id)
        guard let url = item.mediaURL, records[k] == nil, progress[k] == nil else { return }
        progress[k] = 0

        downloader.download(from: url) { [weak self] value in
            self?.progress[k] = value
        } onFinish: { [weak self] result in
            guard let self else { return }
            self.progress[k] = nil

            guard case .success(let temporary) = result else { return }
            let fileName = "\(k).mp4"
            let destination = self.directory.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: destination)
            do {
                try FileManager.default.moveItem(at: temporary, to: destination)
                let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
                let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                self.records[k] = DownloadRecord(fileName: fileName, byteCount: size, finishedAt: Date())
                self.save()
            } catch {
                // 移动失败就当这次下载没发生，不要把半截文件写进索引
            }
        }
    }

    func cancel(_ id: UUID) {
        downloader.cancelCurrent()
        progress[key(id)] = nil
    }

    // MARK: - 持久化

    private func key(_ id: UUID) -> String { id.uuidString }

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

    func seedDownloading(_ id: UUID, value: Double) {
        progress[key(id)] = value
    }

    func seedDownloaded(_ id: UUID, byteCount: Int64 = 48_200_000) {
        let fileName = "\(key(id)).mp4"
        let destination = directory.appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: destination.path) {
            try? Data(repeating: 0, count: 2048).write(to: destination)
        }
        records[key(id)] = DownloadRecord(fileName: fileName, byteCount: byteCount, finishedAt: Date())
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
