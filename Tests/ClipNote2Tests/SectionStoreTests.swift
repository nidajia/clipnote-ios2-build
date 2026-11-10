import XCTest
@testable import ClipNote2

/// 6.1 分区的验收点。
///
/// 分区是**用户自己维护的结构**，坏法集中在三种：
/// 1. 只存在内存里，重启就没了（界面看不出来）；
/// 2. 分区删了，归属还指着它——筛选条上会凭空少几条；
/// 3. 和标签混在一起存——AI 打的标签会覆盖「我为什么存它」。
@MainActor
final class SectionStoreTests: XCTestCase {

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func item(_ id: String, title: String = "标题") -> Item {
        Item(id: id, title: title, metaLine: "B 站 · 某人", durationText: "10:00")
    }

    // MARK: - 持久化

    func testAssignmentSurvivesRelaunch() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = SectionStore(directory: directory)
        XCTAssertEqual(first.assign("study", to: ["a", "b"]), 2)

        // 模拟杀进程重启：状态必须来自磁盘，不能只在内存里对
        let second = SectionStore(directory: directory)
        XCTAssertEqual(second.sectionID(for: "a"), "study")
        XCTAssertEqual(second.sectionID(for: "b"), "study")
        XCTAssertEqual(second.section(for: "a")?.name, "学习")
    }

    func testCustomSectionSurvivesRelaunch() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = SectionStore(directory: directory)
        guard case .success(let made) = first.addSection(name: "资料") else {
            return XCTFail("新建分区应当成功")
        }
        first.assign(made.id, to: ["a"])

        let second = SectionStore(directory: directory)
        XCTAssertTrue(second.allSections.contains { $0.id == made.id && $0.name == "资料" })
        XCTAssertEqual(second.sectionID(for: "a"), made.id)
    }

    // MARK: - 归属

    func testUnassignRemovesKeyNotWritesEmpty() {
        let store = SectionStore(directory: try! makeDirectory())
        store.assign("study", to: ["a"])
        store.assign(nil, to: ["a"])
        XCTAssertNil(store.sectionID(for: "a"))
        // 移出分区要真删键：写空串会让这张表越滚越大，也分不清「没分过」
        XCTAssertEqual(store.assignment.count, 0)
    }

    func testAssignReturnsChangedCountAndSkipsNoOps() {
        let store = SectionStore(directory: try! makeDirectory())
        XCTAssertEqual(store.assign("study", to: ["a", "b"]), 2)
        // 已经在同一个分区里，重复点不该报「已移入 2 条」
        XCTAssertEqual(store.assign("study", to: ["a", "b"]), 0)
        XCTAssertEqual(store.assign("study", to: ["a", "c"]), 1)
    }

    func testAssignToUnknownSectionDoesNothing() {
        let store = SectionStore(directory: try! makeDirectory())
        XCTAssertEqual(store.assign("no-such-section", to: ["a"]), 0)
        XCTAssertNil(store.sectionID(for: "a"))
    }

    func testAssignmentPointingAtDeletedSectionReadsAsUnassigned() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 手改过 JSON 的情况：归属指向一个不存在的分区。
        // 不当作「未分区」的话，筛选条上会出现一个点进去永远是空的幽灵分区。
        let store = SectionStore(directory: directory)
        store.seed(assignment: ["a": "ghost"])
        XCTAssertNil(store.sectionID(for: "a"))
        XCTAssertNil(store.section(for: "a"))
    }

    func testDeleteCustomSectionClearsItsAssignments() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SectionStore(directory: directory)
        guard case .success(let made) = store.addSection(name: "临时") else {
            return XCTFail("新建应当成功")
        }
        store.assign(made.id, to: ["a", "b"])
        XCTAssertEqual(store.assignment.count, 2)

        XCTAssertTrue(store.deleteSection(made.id))
        XCTAssertNil(store.sectionID(for: "a"), "分区删了，归属必须跟着清掉，否则条目凭空消失")
        XCTAssertEqual(store.assignment.count, 0)
        XCTAssertTrue(store.deleteSection("study") == false, "内置分区不该能删")
    }

    func testForgetDropsDeletedItems() {
        let store = SectionStore(directory: try! makeDirectory())
        store.assign("study", to: ["a", "b", "c"])
        store.forget(["a", "c"])
        XCTAssertEqual(store.assignment.count, 1)
        XCTAssertNotNil(store.sectionID(for: "b"))
    }

    // MARK: - 分区本身

    func testBuiltinsAreAlwaysThereAndFirst() {
        let store = SectionStore(directory: try! makeDirectory())
        XCTAssertEqual(store.allSections.prefix(4).map(\.name), ["学习", "信息", "娱乐", "知识科普"])

        // 再新建一个，自定义的必须排在后面——筛选条的顺序要稳定，
        // 不能因为新建过东西就整体挪位置。
        _ = store.addSection(name: "资料")
        XCTAssertEqual(store.allSections.last?.name, "资料")
        XCTAssertEqual(store.allSections.count, 5)
    }

    func testNameValidation() {
        let store = SectionStore(directory: try! makeDirectory())

        XCTAssertEqual(store.addSection(name: "   "), .failure(.emptyName))
        XCTAssertEqual(store.addSection(name: String(repeating: "字", count: 9)), .failure(.tooLong))
        // 首尾空白要剪掉，否则「学习 」和「学习」会变成两个同名分区
        guard case .success = store.addSection(name: " 资料 ") else {
            return XCTFail("去掉空白后应当合法")
        }
        XCTAssertEqual(store.addSection(name: "资料"), .failure(.duplicate))
        XCTAssertEqual(store.addSection(name: "学习"), .failure(.duplicate), "内置名字也不该能重复")
    }

    func testCustomCountIsCapped() {
        let store = SectionStore(directory: try! makeDirectory())
        for index in 0..<SectionStore.maxCustomCount {
            XCTAssertEqual(store.addSection(name: "类\(index)").isSuccess, true)
        }
        XCTAssertEqual(store.addSection(name: "再多一个"), .failure(.tooMany))
    }

    func testMakeIDAvoidsCollision() {
        let first = SectionStore.makeID(from: "资料", taken: [])
        XCTAssertTrue(first.hasPrefix("s-"), "自定义分区 id 要有前缀，避免撞上内置的 study/info")
        XCTAssertEqual(SectionStore.makeID(from: "资料", taken: [first]), first + "-2")
    }

    // MARK: - 与筛选、搜索的接缝

    func testCountsForFilterBar() {
        let store = SectionStore(directory: try! makeDirectory())
        let items = [item("a"), item("b"), item("c")]
        store.assign("study", to: ["a"])

        XCTAssertEqual(store.count(in: "study", items: items), 1)
        XCTAssertEqual(store.count(in: nil, items: items), 2, "未分区 = 剩下那两条")
        XCTAssertEqual(store.count(in: "info", items: items), 0)
    }

    func testSectionNameIsSearchable() {
        // 输入框写着「搜索标题、作者、标签、分区、笔记」，
        // 那就必须真能搜到分区名。分区不在 Item 里，靠 extra 递进去。
        let target = item("a", title: "存储架构")
        XCTAssertTrue(LibrarySearch.matches(target, query: "学习", extra: ["学习"]))
        XCTAssertFalse(LibrarySearch.matches(target, query: "学习"))
    }
}

private extension Result where Success == LibrarySection, Failure == SectionEditError {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
