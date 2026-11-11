import XCTest
@testable import ClipNote2

/// 4.1 的状态：分区负责「放哪」，状态负责「到哪一步了」。
/// 两者正交，不能互相覆盖。
final class StatusStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("status-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> StatusStore {
        StatusStore(directory: directory)
    }

    private func item(_ id: String) -> Item {
        Item(id: id, title: id, metaLine: "", durationText: "")
    }

    func testSetAndRead() {
        let store = makeStore()
        XCTAssertNil(store.status(for: "a"))
        XCTAssertEqual(store.set(.doing, for: ["a"]), 1)
        XCTAssertEqual(store.status(for: "a"), .doing)
    }

    func testSameStatusDoesNotCountAsChange() {
        let store = makeStore()
        store.set(.done, for: ["a"])
        XCTAssertEqual(store.set(.done, for: ["a"]), 0, "重复点同一个状态不该弹提示")
    }

    func testClearRemovesEntry() {
        let store = makeStore()
        store.set(.done, for: ["a"])
        XCTAssertEqual(store.set(nil, for: ["a"]), 1)
        XCTAssertNil(store.status(for: "a"))
        XCTAssertEqual(store.assignedCount, 0, "清除要真删键，不能留空值")
    }

    func testPersistsAcrossInstances() {
        let first = makeStore()
        first.set(.doing, for: ["a", "b"])
        let second = makeStore()
        XCTAssertEqual(second.status(for: "a"), .doing)
        XCTAssertEqual(second.status(for: "b"), .doing)
    }

    func testForgetAfterDelete() {
        let store = makeStore()
        store.set(.done, for: ["a", "b"])
        store.forget("a")
        XCTAssertNil(store.status(for: "a"))
        XCTAssertEqual(store.status(for: "b"), .done, "只清被删的那条")
    }

    func testCountByStatus() {
        let store = makeStore()
        let items = [item("a"), item("b"), item("c")]
        store.set(.done, for: ["a", "b"])
        XCTAssertEqual(store.count(.done, items: items), 2)
        XCTAssertEqual(store.count(.doing, items: items), 0)
    }

    func testCorruptFileIsBackedUpNotSilentlyLost() throws {
        let store = makeStore()
        store.set(.done, for: ["a"])
        // 弄坏文件，再开一次
        try Data("not json".utf8).write(to: directory.appendingPathComponent("statuses.json"))
        let broken = makeStore()
        XCTAssertNil(broken.status(for: "a"))
        let backup = directory.appendingPathComponent("statuses.corrupt.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path),
                      "坏文件要留一份，别静默清零")
    }
}

/// 任务轮询：切到后台时轮询会断，那不是失败。
final class AIJobClientTests: XCTestCase {

    func testPollsUntilDone() async throws {
        var polls = 0
        var client = AIJobClient()
        client.pollInterval = 0.001
        client.transport = AIJobTransport(
            create: { _ in AIJobSnapshot(id: "j1", kind: "chat", status: "queued") },
            status: { _ in
                polls += 1
                return polls < 3
                    ? AIJobSnapshot(id: "j1", kind: "chat", status: "running")
                    : AIJobSnapshot(id: "j1", kind: "chat", status: "done", text: "结果")
            }
        )
        let text = try await client.runChat(
            messages: [["role": "user", "content": "x"]],
            config: AIConfig(base: "https://example.test/v1", model: "m", key: "k")
        )
        XCTAssertEqual(text, "结果")
        XCTAssertEqual(polls, 3)
    }

    func testTransientPollingFailureIsTolerated() async throws {
        var polls = 0
        var client = AIJobClient()
        client.pollInterval = 0.001
        client.transport = AIJobTransport(
            create: { _ in AIJobSnapshot(id: "j1", kind: "chat", status: "running") },
            status: { _ in
                polls += 1
                if polls == 1 {
                    // 切到后台那一刻的典型表现：连接被掐掉
                    throw ClipNoteClient.Failure.transport("网络连接已断开")
                }
                return AIJobSnapshot(id: "j1", kind: "chat", status: "done", text: "拿到了")
            }
        )
        let text = try await client.runChat(
            messages: [["role": "user", "content": "x"]],
            config: AIConfig(base: "https://example.test/v1", model: "m", key: "k")
        )
        XCTAssertEqual(text, "拿到了", "断一次就放弃的话，切出去再回来永远是失败")
    }

    func testJobGoneIsReportedAsRetryable() async {
        var client = AIJobClient()
        client.pollInterval = 0.001
        client.transport = AIJobTransport(
            create: { _ in AIJobSnapshot(id: "j1", kind: "chat", status: "running") },
            status: { _ in
                throw ClipNoteClient.Failure.http(status: 404, code: "JOB_GONE", message: "过期了")
            }
        )
        do {
            _ = try await client.runChat(
                messages: [["role": "user", "content": "x"]],
                config: AIConfig(base: "https://example.test/v1", model: "m", key: "k")
            )
            XCTFail("任务过期要抛错，不能让用户一直等")
        } catch let failure as AIJobFailure {
            XCTAssertEqual(failure, .gone)
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    func testFailedJobCarriesServerMessage() async {
        var client = AIJobClient()
        client.pollInterval = 0.001
        client.transport = AIJobTransport(
            create: { _ in
                AIJobSnapshot(id: "j1", kind: "chat", status: "failed",
                              error: AIJobErrorBody(code: "UPSTREAM_401",
                                                    message: "模型服务拒绝了 Key（401）"))
            },
            status: { _ in AIJobFailure.timeout }
        )
        do {
            _ = try await client.runChat(
                messages: [["role": "user", "content": "x"]],
                config: AIConfig(base: "https://example.test/v1", model: "m", key: "k")
            )
            XCTFail("失败任务要抛错")
        } catch let failure as AIJobFailure {
            XCTAssertEqual(failure.errorDescription, "模型服务拒绝了 Key（401）")
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    /// 「先选择，再干活」：面板要把范围和来源说清楚，用户才知道自己点了什么。
    func testPreflightTextNamesScopeAndSize() {
        let whole = NoteAIPreflight(action: .tidy, text: String(repeating: "字", count: 42),
                                    range: nil, kind: "doc")
        XCTAssertEqual(whole.scopeText, "全文 · 42 字")

        let selected = NoteAIPreflight(action: .tidy, text: "甲乙丙",
                                       range: NoteAIRange(from: 1, to: 4, text: "甲乙丙"),
                                       kind: "saved")
        XCTAssertTrue(selected.scopeText.contains("选区"))
        XCTAssertTrue(selected.scopeText.contains("3 字"))
        XCTAssertTrue(selected.scopeText.contains("刚才选中"), "用记住的选区时要说明，否则用户会以为它选了全文")
    }
}
