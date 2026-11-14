import XCTest
@testable import ClipNote2

/// 引导页的两块逻辑：步骤状态怎么算、步骤事件是不是真的。
///
/// 这两块都容易「看着对」：步骤全绿但同步没成功、或者步骤按定时器走完而请求还在飞——
/// 截图里一模一样。所以要么测，要么别写。
final class OnboardingFlowTests: XCTestCase {

    // MARK: - 步骤状态

    func testWelcomeLeavesEveryStepPending() {
        for step in SyncStep.allCases {
            XCTAssertEqual(stepStatus(step, in: .welcome).isPending, true)
        }
    }

    func testSyncingMarksEarlierDoneAndCurrentRunning() {
        XCTAssertEqual(stepStatus(.connecting, in: .syncing(.connecting)).isRunning, true)
        XCTAssertEqual(stepStatus(.fetched, in: .syncing(.fetched)).isRunning, true)
        XCTAssertEqual(stepStatus(.connecting, in: .syncing(.fetched)).isDone, true)
        XCTAssertEqual(stepStatus(.ready, in: .syncing(.fetched)).isPending, true)
    }

    func testDoneMarksAllStepsDone() {
        for step in SyncStep.allCases {
            XCTAssertEqual(stepStatus(step, in: .done(count: 8, milliseconds: 620)).isDone, true)
        }
    }

    /// 失败落在哪一步，就只标那一步为红，后面仍是待办——
    /// 全标红会让人以为三步都试过了。
    func testFailureMarksOnlyTheFailingStep() {
        let phase = SyncPhase.failed(message: "连不上", step: .fetched)
        XCTAssertEqual(stepStatus(.connecting, in: phase).isDone, true)
        XCTAssertEqual(stepStatus(.fetched, in: phase).isFailed, true)
        XCTAssertEqual(stepStatus(.ready, in: phase).isPending, true)
    }

    // MARK: - 步骤是真实事件，不是定时器

    @MainActor
    func testReloadEmitsTheThreeRealStepsInOrder() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        StubURLProtocol.handler = { _ in
            (200, ["Content-Type": "application/json"],
             Data(#"{"libraryVersion":"lv_1","count":1,"generatedAt":0,"items":[{"id":"a1","title":"一条"}]}"#.utf8))
        }

        let store = LibraryStore(client: makeClient(), cacheDirectory: dir)
        var steps: [SyncStep] = []
        await store.reload { steps.append($0) }

        XCTAssertEqual(steps, [.connecting, .fetched, .ready])
        XCTAssertEqual(store.items.count, 1)
    }

    /// 请求就失败时，只有第一个步骤该发生——这正是「三步动画」和「三步事件」的区别。
    @MainActor
    func testFailedReloadOnlyReportsConnecting() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        StubURLProtocol.handler = { _ in
            (500, ["Content-Type": "application/json"],
             Data(#"{"code":"BOOM","message":"服务端出错","retryable":true}"#.utf8))
        }

        let store = LibraryStore(client: makeClient(), cacheDirectory: dir)
        var steps: [SyncStep] = []
        await store.reload { steps.append($0) }

        XCTAssertEqual(steps, [.connecting])
        if case .loaded = store.phase {
            XCTFail("失败不该被当成成功")
        }
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

private extension StepStatus {
    var isPending: Bool { if case .pending = self { return true }; return false }
    var isRunning: Bool { if case .running = self { return true }; return false }
    var isDone: Bool { if case .done = self { return true }; return false }
    var isFailed: Bool { if case .failed = self { return true }; return false }
}
