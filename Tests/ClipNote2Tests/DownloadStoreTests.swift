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

        let itemID = UUID()

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

        let itemID = UUID()
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

        let itemID = UUID()
        let first = DownloadStore(directory: directory)
        first.seedDownloading(itemID, value: 0.62)
        XCTAssertEqual(first.progressValue(for: itemID) ?? 0, 0.62, accuracy: 0.001)

        // 半截的下载不该在重启后还显示进度
        let second = DownloadStore(directory: directory)
        XCTAssertNil(second.progressValue(for: itemID))
        XCTAssertFalse(second.isDownloaded(itemID))
    }
}
