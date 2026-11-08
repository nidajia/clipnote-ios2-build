import XCTest
@testable import ClipNote2

/// 笔记编辑器（P2）的三道闸门：就绪态、错误态、内容保存回环。
///
/// 为什么这三条值得写单测：编辑器返工过三次，三次都不是「编译不过」，
/// 而是运行到一半变成一块空白或永远转圈。这类问题只有把「消息协议」
/// 和「出的页面」都钉住，下次改配置才不会再悄悄坏掉。
final class NoteEditorTests: XCTestCase {

    // MARK: - 就绪态 / 错误态

    func testReadyEvent() {
        XCTAssertEqual(EditorEvent.parse(["type": "ready"]), .ready)
    }

    func testChangeCarriesMarkdownVerbatim() {
        let text = "## 标题\n\n正文 **粗体**\n\n- 甲"
        XCTAssertEqual(EditorEvent.parse(["type": "change", "value": text]), .change(text))
    }

    func testChangeWithoutValueIsIgnored() {
        // 没有 value 的 change 如果被当成空内容写回去，就等于把用户的笔记清空。
        XCTAssertEqual(EditorEvent.parse(["type": "change"]), .ignored)
    }

    func testErrorKeepsModelMessage() {
        XCTAssertEqual(
            EditorEvent.parse(["type": "error", "message": "初始化失败：PluginKey"]),
            .failure("初始化失败：PluginKey")
        )
    }

    func testErrorWithoutMessageGetsReadableDefault() {
        // 不能把空字符串交给界面——用户会看到「编辑器没能启动：」后面什么都没有。
        XCTAssertEqual(EditorEvent.parse(["type": "error"]), .failure("编辑器内部错误"))
    }

    func testTraceIsDegradedNotFailure() {
        // 降级只写日志：工具栏折叠没绕开时，富文本仍然可用，不该退回纯文本。
        XCTAssertEqual(
            EditorEvent.parse(["type": "trace", "message": "工具栏折叠未绕开"]),
            .degraded("工具栏折叠未绕开")
        )
    }

    func testUnknownAndMalformedAreIgnored() {
        XCTAssertEqual(EditorEvent.parse(["type": "whatever"]), .ignored)
        XCTAssertEqual(EditorEvent.parse("不是字典"), .ignored)
        XCTAssertEqual(EditorEvent.parse(["value": "没有 type"]), .ignored)
    }

    // MARK: - 出的页面是不是单栏

    func testBundledEditorIsSingleColumnWysiwyg() throws {
        let html = try Self.bundleHTML()

        // 生成物有 700KB 以上；突然变小多半是漏了内联脚本。
        XCTAssertGreaterThan(html.count, 400_000, "editor-bundle.html 不完整")

        XCTAssertTrue(html.contains("initialEditType: 'wysiwyg'"),
                      "编辑器必须初始化为单栏所见即所得")
        XCTAssertTrue(html.contains("hideModeSwitch: true"),
                      "单栏形态下不应该保留「编辑 / 预览」页签")
        XCTAssertTrue(html.contains("id=\"edge-fade\""),
                      "右缘渐隐层缺失，横向滑动就没有提示")
        XCTAssertTrue(html.contains("overflow-x: auto"),
                      "工具栏必须是横向滚动，而不是折行或被压缩")
        XCTAssertTrue(html.contains("body.no-collapse"),
                      "「⋯」只能在不折叠确认之后才隐藏，否则按钮会被藏死")
    }

    func testBundleIsBundledIntoApp() {
        // 页面文件必须真的在 app 包里，否则真机上就是「编辑器页面缺失」。
        XCTAssertNotNil(MarkdownWebView.bundleURL(),
                        "editor-bundle.html 没有随包分发")
    }

    // MARK: - 内容保存回环

    @MainActor
    func testNoteSurvivesSaveAndReload() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var received = ""
        StubURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/note") {
                if let body = request.httpBody,
                   let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                   let note = obj["note"] as? String {
                    received = note
                }
                return (200, ["Content-Type": "application/json"], Self.itemJSON(note: received))
            }
            return (200, ["Content-Type": "application/json"], Self.libraryJSON(note: received))
        }

        let store = LibraryStore(client: Self.makeClient(), cacheDirectory: dir)
        let text = "## 结论\n\n泡沫不在估值，而在 **现金流**。\n\n```\nburn = cash / months\n```"

        let ok = await store.saveNote(id: "a1", note: text)

        XCTAssertTrue(ok, "保存应当成功")
        XCTAssertEqual(received, text, "请求体里的笔记应与编辑器内容逐字一致（不能被裁剪或转义）")
        XCTAssertEqual(store.items.first?.note, text, "保存后列表里的笔记应更新——这就是回环")
    }

    @MainActor
    func testNoteClearingIsAllowed() async throws {
        // 清空笔记是合法操作，不该被「没有内容就不保存」的逻辑吞掉。
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var received: String? = nil
        StubURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/note") {
                if let body = request.httpBody,
                   let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                    received = obj["note"] as? String
                }
                return (200, ["Content-Type": "application/json"], Self.itemJSON(note: ""))
            }
            return (200, ["Content-Type": "application/json"], Self.libraryJSON(note: ""))
        }

        let store = LibraryStore(client: Self.makeClient(), cacheDirectory: dir)
        _ = await store.saveNote(id: "a1", note: "")

        XCTAssertEqual(received, "", "清空也要发出去")
        XCTAssertEqual(store.items.first?.note, "")
    }

    @MainActor
    func testSaveFailureReportsFalse() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        StubURLProtocol.handler = { _ in
            (500, ["Content-Type": "application/json"],
             Data(#"{"code":"BOOM","message":"服务端出错","retryable":true}"#.utf8))
        }

        let store = LibraryStore(client: Self.makeClient(), cacheDirectory: dir)
        let ok = await store.saveNote(id: "a1", note: "写了但存不上")

        XCTAssertFalse(ok, "存不上必须返回 false，界面才能提示「没存上」")
    }

    // MARK: -

    private static func bundleHTML() throws -> String {
        // 仓库根就是 ios2/（CI 检出后也是这个形状），所以从测试文件往上三层。
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ClipNote2Tests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ios2
        let url = root.appendingPathComponent("Sources/ClipNote2/Resources/editor-bundle.html")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func libraryJSON(note: String) -> Data {
        let payload: [String: Any] = [
            "libraryVersion": "lv_2",
            "count": 1,
            "generatedAt": 0,
            "items": [["id": "a1", "title": "标题", "note": note]],
        ]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }

    private static func itemJSON(note: String) -> Data {
        let payload: [String: Any] = ["id": "a1", "title": "标题", "note": note]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }

    private static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipnote-note-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func makeClient() -> ClipNoteClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return ClipNoteClient(
            baseURL: URL(string: "https://example.test")!,
            shareCode: "C1",
            session: URLSession(configuration: config)
        )
    }
}
