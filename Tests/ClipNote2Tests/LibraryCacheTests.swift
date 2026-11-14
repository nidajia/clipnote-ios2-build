import XCTest
@testable import ClipNote2

/// 本地缓存与失败收场。
///
/// 这几条对应真机上真实发生过的两件事：
/// 1. 第二次启动整屏停在「正在同步云端快照」，而视频明明在本地；
/// 2. 同步被网关 403 挡了一次，界面就再也没恢复。
final class LibraryCacheTests: XCTestCase {

    private static let oneItemJSON = #"""
    {"libraryVersion":"lv_1","count":1,"generatedAt":0,
     "items":[{"id":"a1","title":"缓存里的一条"}]}
    """#

    // MARK: - 缓存

    @MainActor
    func testLoadsCacheOnInit() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(Self.oneItemJSON.utf8).write(to: dir.appendingPathComponent("library-cache.json"))

        let store = LibraryStore(client: nil, cacheDirectory: dir)

        // 还没联网，列表就已经在了——启动不该等云端
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.title, "缓存里的一条")
        XCTAssertEqual(store.phase, .loaded)
    }

    @MainActor
    func testSavesCacheAfterSuccessfulReload() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        StubURLProtocol.handler = { _ in
            (200, ["Content-Type": "application/json"], Data(Self.oneItemJSON.utf8))
        }

        let store = LibraryStore(client: makeClient(), cacheDirectory: dir)
        await store.reload()

        XCTAssertEqual(store.items.count, 1)
        let cached = try Data(contentsOf: dir.appendingPathComponent("library-cache.json"))
        let lib = try JSONDecoder().decode(APILibrary.self, from: cached)
        XCTAssertEqual(lib.items.first?.id, "a1")
    }

    // MARK: - 失败收场

    @MainActor
    func testKeepsCachedListWhenRefreshFails() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(Self.oneItemJSON.utf8).write(to: dir.appendingPathComponent("library-cache.json"))

        StubURLProtocol.handler = { _ in
            (500, ["Content-Type": "application/json"],
             Data(#"{"code":"BOOM","message":"服务端出错","retryable":true}"#.utf8))
        }

        let store = LibraryStore(client: makeClient(), cacheDirectory: dir)
        await store.reload()

        // 界面不该变成失败页：用户要看的东西还在
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.phase, .loaded)
    }

    @MainActor
    func testWithoutCacheFailureFallsBackToEmptyFailure() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        StubURLProtocol.handler = { _ in
            (500, ["Content-Type": "application/json"],
             Data(#"{"code":"BOOM","message":"服务端出错","retryable":true}"#.utf8))
        }

        let store = LibraryStore(client: makeClient(), cacheDirectory: dir)
        await store.reload()

        XCTAssertTrue(store.items.isEmpty)
        if case .failed = store.phase {} else {
            XCTFail("没有缓存时应该落到失败态，实际是 \(store.phase)")
        }
    }

    // MARK: - 重试

    @MainActor
    func testRetriesOnceOnGateway403ThenSucceeds() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 第一次 403（真机遇到的就是这个），第二次 200
        var calls = 0
        StubURLProtocol.handler = { _ in
            calls += 1
            if calls == 1 {
                return (403, ["Content-Type": "text/html"], Data("<html>blocked</html>".utf8))
            }
            return (200, ["Content-Type": "application/json"], Data(Self.oneItemJSON.utf8))
        }

        let store = LibraryStore(client: makeClient(), cacheDirectory: dir)
        await store.reload()

        // 3 次：第 1 次 403、第 2 次重试 200、第 3 次是成功后再拉一次失败列表。
        // 之前只写 2 次，但 reload 成功后新增了「顺手拉失败列表」，这里没跟上。
        XCTAssertEqual(calls, 3, "403 是瞬时失败，应该自动再试一次")
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.phase, .loaded)
    }

    @MainActor
    func testDoesNotRetryOnMalformedBody() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var calls = 0
        StubURLProtocol.handler = { _ in
            calls += 1
            // 200 但不是 JSON：重试一百次也一样，不该再打一次
            return (200, ["Content-Type": "text/html"], Data("<html>首页</html>".utf8))
        }

        let store = LibraryStore(client: makeClient(), cacheDirectory: dir)
        await store.reload()

        XCTAssertEqual(calls, 1)
    }

    // MARK: -

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipnote-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeClient() -> ClipNoteClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return ClipNoteClient(
            baseURL: URL(string: "https://example.test")!,
            shareCode: "C1",
            session: URLSession(configuration: config)
        )
    }
}
