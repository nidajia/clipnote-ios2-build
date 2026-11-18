import XCTest
@testable import ClipNote2

final class LibrarySaveTests: XCTestCase {
    override func tearDown() { StubURLProtocol.handler = nil; super.tearDown() }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let json = #"{"libraryVersion":"old","count":1,"generatedAt":0,"items":[{"id":"a1","title":"条目","note":"旧笔记","noteAt":1000,"updatedAt":2000,"aiSummary":"旧总结","segments":[{"t":10,"title":"旧导航","summary":"保留"}]}]}"#
        try Data(json.utf8).write(to: url.appendingPathComponent("library-cache.json"))
        return url
    }
    private func client() -> ClipNoteClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return ClipNoteClient(baseURL: URL(string: "https://example.test")!, shareCode: "test",
                              session: URLSession(configuration: config))
    }
    private var saved: Data {
        Data(#"{"id":"a1","title":"条目","aiSummary":"新总结","summaryV":2,"summaryAt":1234,"keyPoints":["新要点"],"labels":["科技"],"chapters":[{"t":0,"title":"章节","detail":"解读","expand":"追问"}],"segments":[{"t":10,"title":"旧导航","summary":"保留"}]}"#.utf8)
    }
    @MainActor
    func testSavedSummarySurvivesFailedReloadAndRelaunchWithoutChangingSegments() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let response = saved
        var writes: [String] = []
        StubURLProtocol.handler = { request in
            if request.httpMethod == "POST" {
                writes.append(request.url!.path)
                return (200, ["Content-Type": "application/json"], response)
            }
            return (500, ["Content-Type": "application/json"], Data(#"{"message":"offline"}"#.utf8))
        }
        let store = LibraryStore(client: client(), cacheDirectory: dir)
        let result = SummaryResult(summary: "新总结", keyPoints: ["新要点"], labels: ["科技"],
                                   chapters: [APIChapter(t: 0, title: "章节", detail: "解读", expand: "追问")])
        let ok = await store.saveSummary(id: "a1", result: result, by: "test")
        XCTAssertTrue(ok)
        XCTAssertEqual(writes, ["/api/v2/items/a1/summary"])
        XCTAssertEqual(store.items.first?.aiSummary, "新总结")
        XCTAssertEqual(store.items.first?.chapters.first?.t, 0)
        XCTAssertEqual(store.items.first?.segments.first?.title, "旧导航")
        let relaunched = LibraryStore(client: nil, cacheDirectory: dir)
        XCTAssertEqual(relaunched.items.first?.aiSummary, "新总结")
        XCTAssertEqual(relaunched.items.first?.chapters.first?.expand, "追问")
        XCTAssertEqual(relaunched.items.first?.segments.first?.t, 10)
    }
    @MainActor
    func testFailedSaveKeepsOldMemoryAndDisk() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = try Data(contentsOf: dir.appendingPathComponent("library-cache.json"))
        StubURLProtocol.handler = { _ in (500, ["Content-Type": "application/json"], Data(#"{"message":"failed"}"#.utf8)) }
        let store = LibraryStore(client: client(), cacheDirectory: dir)
        let ok = await store.saveSummary(id: "a1", result: SummaryResult(summary: "不能显示成已保存", keyPoints: [], labels: []), by: "test")
        XCTAssertFalse(ok)
        XCTAssertEqual(store.items.first?.aiSummary, "旧总结")
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("library-cache.json")), original)
    }
    @MainActor
    func testSavedNoteAndServerTimestampsSurviveFailedReloadAndRelaunch() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        StubURLProtocol.handler = { request in
            if request.httpMethod == "POST", request.url?.path == "/api/v2/items/a1/note" {
                return (200, ["Content-Type": "application/json"],
                        Data(#"{"id":"a1","title":"条目","note":"服务端确认的正文","noteAt":1234,"updatedAt":2345}"#.utf8))
            }
            return (503, ["Content-Type": "application/json"], Data(#"{"message":"offline"}"#.utf8))
        }
        let store = LibraryStore(client: client(), cacheDirectory: dir)
        let revision = try XCTUnwrap(store.items.first).noteRevision
        XCTAssertEqual(revision, 1000)
        let result = await store.saveNote(id: "a1", note: "客户端请求的正文", baseNoteAt: revision)
        XCTAssertEqual(result, .saved(noteAt: 1234))
        XCTAssertNil(store.lastSyncAt, "POST 成功不等于全库刷新成功")
        let relaunched = LibraryStore(client: nil, cacheDirectory: dir)
        for one in [store, relaunched] {
            let item = try XCTUnwrap(one.items.first)
            XCTAssertEqual(item.note, "服务端确认的正文")
            XCTAssertEqual(item.noteAt, Date(timeIntervalSince1970: 1.234))
            XCTAssertEqual(item.updatedAt, Date(timeIntervalSince1970: 2.345))
            XCTAssertEqual(item.aiSummary, "旧总结")
            XCTAssertEqual(item.segments.first?.t, 10)
        }
    }

    @MainActor
    func testSaveNoteCreatesCacheWhenNoSnapshotExists() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.removeItem(at: dir.appendingPathComponent("library-cache.json"))
        StubURLProtocol.handler = { request in
            if request.httpMethod == "POST", request.url?.path == "/api/v2/items/a1/note" {
                return (200, ["Content-Type": "application/json"],
                        Data(#"{"id":"a1","kind":"note","title":"尚未同步","note":"","noteAt":3000,"updatedAt":4000}"#.utf8))
            }
            return (404, ["Content-Type": "application/json"], Data(#"{"message":"refresh failed"}"#.utf8))
        }
        let store = LibraryStore(client: client(), cacheDirectory: dir)
        let result = await store.saveNote(id: "a1", note: "", baseNoteAt: 0)
        XCTAssertEqual(result, .saved(noteAt: 3000))
        XCTAssertEqual(store.items.first?.noteRevision, 3000)
        XCTAssertEqual(store.items.first?.id, "a1")
        let relaunched = LibraryStore(client: nil, cacheDirectory: dir)
        let item = try XCTUnwrap(relaunched.items.first)
        XCTAssertEqual(item.title, "尚未同步")
        XCTAssertEqual(item.note, "")
        XCTAssertEqual(item.noteAt, Date(timeIntervalSince1970: 3))
        XCTAssertEqual(item.updatedAt, Date(timeIntervalSince1970: 4))
    }

    @MainActor
    func testSavedSegmentsDoNotRewriteSummaryDuringFailedReload() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let response = saved
        var writes: [String] = []
        StubURLProtocol.handler = { request in
            if request.httpMethod == "POST" { writes.append(request.url!.path); return (200, ["Content-Type": "application/json"], response) }
            return (500, ["Content-Type": "application/json"], Data(#"{"message":"offline"}"#.utf8))
        }
        let store = LibraryStore(client: client(), cacheDirectory: dir)
        let ok = await store.saveSegments(id: "a1", segments: [APISegment(title: "旧导航", t: 10, summary: "保留")], by: "test")
        XCTAssertTrue(ok)
        XCTAssertEqual(writes, ["/api/v2/items/a1/segments"])
        XCTAssertEqual(store.items.first?.aiSummary, "新总结", "只接受服务端已保存结果，不另外写总结端点")
        XCTAssertEqual(LibraryStore(client: nil, cacheDirectory: dir).items.first?.segments.first?.t, 10)
    }
}
