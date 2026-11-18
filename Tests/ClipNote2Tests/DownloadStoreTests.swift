import XCTest
@testable import ClipNote2

/// 验收第 ⑤ 条：「杀进程重启后，已下载状态与本地文件仍然有效」。
///
/// 这条最容易假通过——只要把状态放在内存里，UI 看起来一样对，
/// 重启就露馅。这里用「新建实例」模拟重启，断言状态确实来自磁盘。
final class DownloadStoreTests: XCTestCase {

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testDownloadedStateSurvivesRelaunch() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 服务端 id 是字符串，不是 UUID。用 UUID 会让状态在重新同步后对不上。
        let itemID = "mvrl0axm2j64w"

        // 第一次运行：种一条已下载记录（会落盘 + 建文件）
        let first = DownloadStore(directory: directory)
        first.seedDownloaded(itemID, byteCount: 1024)
        XCTAssertTrue(first.isDownloaded(itemID))
        XCTAssertEqual(first.byteCount(for: itemID), 1024)

        // 模拟杀进程重启
        let second = DownloadStore(directory: directory)
        XCTAssertTrue(second.isDownloaded(itemID), "重启后应仍为已下载")
        XCTAssertEqual(second.byteCount(for: itemID), 1024)
        XCTAssertNotNil(second.localURL(for: itemID))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: second.localURL(for: itemID)!.path),
            "文件应当还在磁盘上"
        )
    }

    func testIndexIsReconciledWhenFileDisappears() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let itemID = "seed0000000002"
        let first = DownloadStore(directory: directory)
        first.seedDownloaded(itemID)
        let fileURL = try XCTUnwrap(first.localURL(for: itemID))

        // 文件被系统清掉（存储紧张时 iOS 会这么干）
        try FileManager.default.removeItem(at: fileURL)

        let second = DownloadStore(directory: directory)
        XCTAssertFalse(second.isDownloaded(itemID), "文件不在了就不能再显示已下载")
    }

    func testProgressIsNotPersisted() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let itemID = "seed0000000003"
        let first = DownloadStore(directory: directory)
        first.seedDownloading(itemID, value: 0.62)
        XCTAssertEqual(first.progressValue(for: itemID) ?? 0, 0.62, accuracy: 0.001)

        // 半截的下载不该在重启后还显示进度
        let second = DownloadStore(directory: directory)
        XCTAssertNil(second.progressValue(for: itemID))
        XCTAssertFalse(second.isDownloaded(itemID))
    }

    /// 服务端 id 可能带 `/` 之类的路径字符，直接当文件名会写到别的目录去
    func testFileNameIsSafeForPathLikeIdentifiers() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let weird = "a/b/../c"
        let store = DownloadStore(directory: directory)
        store.seedDownloaded(weird, byteCount: 1)

        let url = try XCTUnwrap(store.localURL(for: weird))
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path,
                       directory.standardizedFileURL.path,
                       "文件必须落在下载目录内，不能被路径字符带出去")
        XCTAssertFalse(url.lastPathComponent.contains("/"))
    }

    func testFinishedReceiptRecoversAfterProcessDiesBeforeIndexWrite() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let temporary = directory.appendingPathComponent("system-temporary")
        try Data(repeating: 1, count: 100_000).write(to: temporary)
        let receipt = try DownloadReceipt.stage(id: "exact/item/id", temporary: temporary, directory: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.url(in: directory).path))
        let recovered = DownloadStore(directory: directory)
        XCTAssertTrue(recovered.isDownloaded("exact/item/id"))
        XCTAssertEqual(recovered.byteCount(for: "exact/item/id"), 100_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.url(in: directory).path))
        XCTAssertTrue(DownloadStore(directory: directory).isDownloaded("exact/item/id"))
    }
    func testTwoReceiptsRecoverToTheirOwnItems() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for (id, size) in [("first", 80_000), ("second", 120_000)] {
            let temporary = directory.appendingPathComponent(id)
            try Data(repeating: 1, count: size).write(to: temporary)
            _ = try DownloadReceipt.stage(id: id, temporary: temporary, directory: directory)
        }
        let recovered = DownloadStore(directory: directory)
        XCTAssertEqual(recovered.downloadedCount, 2)
        XCTAssertEqual(recovered.byteCount(for: "first"), 80_000)
        XCTAssertEqual(recovered.byteCount(for: "second"), 120_000)
        XCTAssertNotEqual(recovered.localURL(for: "first"), recovered.localURL(for: "second"))
    }
    func testSmallErrorBodyNeverBecomesDownloadedVideo() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let temporary = directory.appendingPathComponent("error")
        try Data("<html>403</html>".utf8).write(to: temporary)
        XCTAssertThrowsError(try DownloadReceipt.stage(id: "failed", temporary: temporary, directory: directory))
        XCTAssertFalse(DownloadStore(directory: directory).isDownloaded("failed"))
    }
    @MainActor
    func testOnlyHTTP401And403RequireFreshPlaybackForTheFailedItem() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStore(directory: directory)
        let url = URL(string: "https://example.test/video")!

        for status in [401, 403, 500] {
            let id = "http-\(status)"
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status,
                                                        httpVersion: nil, headerFields: nil))
            let error = try XCTUnwrap(DownloadHTTPError(response: response))
            store.seedDownloading(id, value: 0.5)
            store.handleCompletion(id: id, result: .failure(error))
            XCTAssertNil(store.progressValue(for: id), "失败应结束任务，不会自动重试")
            XCTAssertEqual(store.lastFailure?.id, id)
        }

        let unrelated = NSError(domain: "OtherError", code: 403,
                                userInfo: [NSLocalizedDescriptionKey: "视频地址已过期或被拒绝，联网后重新下载。"])
        store.handleCompletion(id: "other", result: .failure(unrelated))
        XCTAssertTrue(store.requiresFreshPlayback(for: "http-401"))
        XCTAssertTrue(store.requiresFreshPlayback(for: "http-403"))
        XCTAssertFalse(store.requiresFreshPlayback(for: "http-500"))
        XCTAssertFalse(store.requiresFreshPlayback(for: "other"))
    }

    @MainActor
    func testConcurrentCallbacksRouteByTaskAndFinishOnlyOnce() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var progress: [String: Double] = [:]
        var failures: [String] = []
        let downloader = FileDownloader(directory: directory, background: false,
            onProgress: { progress[$0] = $1 }, onFinish: { id, _ in failures.append(id) })
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let first = session.downloadTask(with: URL(string: "https://example.test/first")!)
        let second = session.downloadTask(with: URL(string: "https://example.test/second")!)
        first.taskDescription = "first"; second.taskDescription = "second"
        downloader.urlSession(session, downloadTask: first, didWriteData: 10, totalBytesWritten: 10, totalBytesExpectedToWrite: 100)
        downloader.urlSession(session, downloadTask: second, didWriteData: 75, totalBytesWritten: 75, totalBytesExpectedToWrite: 100)
        XCTAssertEqual(progress["first"], 0.1)
        XCTAssertEqual(progress["second"], 0.75)
        downloader.urlSession(session, task: first, didCompleteWithError: URLError(.timedOut))
        downloader.urlSession(session, task: first, didCompleteWithError: URLError(.timedOut))
        XCTAssertEqual(failures, ["first"])
        downloader.urlSession(session, downloadTask: second, didWriteData: 10, totalBytesWritten: 85, totalBytesExpectedToWrite: 100)
        XCTAssertEqual(progress["second"], 0.85)
    }
}
