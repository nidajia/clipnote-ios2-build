import XCTest
@testable import ClipNote2

/// 日志的三条底线：
/// 1. 共享码不能出现在日志里（它会被上报到服务端）
/// 2. 环形上限要真的生效（否则文件会无限涨）
/// 3. 重启后日志还在（否则最需要它的那一刻它不存在）
@MainActor
final class LogStoreTests: XCTestCase {

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 收集上报批次
    @MainActor
    final class Recorder {
        var batches: [[LogEntry]] = []
        func add(_ entries: [LogEntry]) { batches.append(entries) }
    }

    // MARK: - 脱敏

    func testShareCodeIsRedacted() {
        let raw = "GET https://c.example.com/api/v2/library?sharecode=E2ZVITFINI&code=E2ZVITFINI 失败"
        let out = LogRedaction.apply(raw)
        XCTAssertFalse(out.contains("E2ZVITFINI"), out)
        XCTAssertTrue(out.contains("sharecode=<redacted>"), out)
        XCTAssertTrue(out.contains("code=<redacted>"), out)
    }

    func testRedactionAlsoCoversTokenAndCookie() {
        let raw = "cookie=SESSDATA%3Dabc; token=xyz"
        let out = LogRedaction.apply(raw)
        XCTAssertFalse(out.contains("SESSDATA"), out)
        XCTAssertFalse(out.contains("xyz"), out)
    }

    func testEntryRedactsMessageAndMeta() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = LogStore(directory: dir)
        store.error("network.failed",
                    "请求 https://x/api/v2/library?code=SECRET123 失败",
                    meta: ["url": "https://x/?sharecode=SECRET123"])
        let entry = try XCTUnwrap(store.entries.last)
        XCTAssertFalse(entry.message.contains("SECRET123"), entry.message)
        XCTAssertFalse((entry.meta["url"] ?? "").contains("SECRET123"), entry.meta["url"] ?? "")
    }

    // MARK: - 环形上限

    func testRingBufferStopsAtLimit() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = LogStore(directory: dir)
        for i in 0..<205 {
            store.info("test.bulk", "第 \(i) 条")
        }
        XCTAssertEqual(store.count, 200, "上限 200，多出来的要从头部丢掉")
        // 保留的应该是最后 200 条，也就是从第 5 条开始
        XCTAssertEqual(store.entries.first?.message, "第 5 条")
        XCTAssertEqual(store.entries.last?.message, "第 204 条")
    }

    // MARK: - 持久化

    func testLogsSurviveRelaunch() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = LogStore(directory: dir)
        first.info("app.launch", "启动", meta: ["version": "8.0.0 (1)"])
        first.error("network.failed", "连不上服务端。")

        // 模拟杀进程重启
        let second = LogStore(directory: dir)
        XCTAssertEqual(second.count, 2, "重启后日志应当还在——否则最需要它的那一刻它不存在")
        XCTAssertEqual(second.errorCount, 1)
        XCTAssertEqual(second.entries.last?.key, "network.failed")
    }

    func testClearRemovesEverything() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = LogStore(directory: dir)
        first.info("a", "1")
        first.info("b", "2")
        first.clear()
        XCTAssertEqual(first.count, 0)

        let second = LogStore(directory: dir)
        XCTAssertEqual(second.count, 0, "清空要落到文件上，不能只是清内存")
    }

    // MARK: - 上报时机

    func testErrorUploadsButInfoDoesNot() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = Recorder()
        let store = LogStore(directory: dir) { entries in
            await recorder.add(entries)
        }

        store.info("app.launch", "启动")
        store.warn("playback.unavailable", "没有视频流")
        // 等一小会儿，确认 info/warn 没有触发上报
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(recorder.batches.isEmpty, "info/warn 不该自动上报，否则服务端会被噪音淹掉")

        store.error("network.failed", "超时")
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(recorder.batches.count, 1, "error 应当自动上报")
        XCTAssertEqual(recorder.batches.first?.first?.key, "network.failed")
    }

    func testUploadAllSendsEverythingIncludingInfo() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = Recorder()
        let store = LogStore(directory: dir) { entries in
            await recorder.add(entries)
        }
        store.info("app.launch", "启动")
        store.info("library.loaded", "同步完成 8 条")

        let sent = await store.uploadAll()
        XCTAssertEqual(sent, 2, "手动上报要把 info 也带上——「最后一次成功同步」只能靠它")
        XCTAssertEqual(recorder.batches.last?.count, 2)
    }

    func testUploadWithoutChannelReturnsZero() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = LogStore(directory: dir, uploader: nil)
        store.info("a", "1")
        let sent = await store.uploadAll()
        XCTAssertEqual(sent, 0, "截图模式没有上报通道，应该老实返回 0")
    }
}
