import XCTest
@testable import ClipNote2

/// 用服务端的真实响应把「契约」焊在客户端模型上。
///
/// 这类测试的价值不在于「代码能跑」，而在于**改了会红**：
/// 服务端把 `metaLine` 改名、把 `durationText` 挪位置、把 `cover` 从对象改成字符串，
/// 任意一处都会让这里失败。失败发生在 CI 的 3 分钟里，而不是用户手机上的某次点播。
///
/// `Fixtures/library-real.json` 由 `Tools/fetch_fixture.py` 从线上抓取，**不是手抄的**。
/// 手抄的 fixture 只是某个人的记忆；抓下来的才是契约。
final class LibraryDecodingTests: XCTestCase {

    // MARK: - 工具

    private func fixtureData(_ name: String) throws -> Data {
        let bundle = Bundle(for: Self.self)
        let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: "json")
        return try Data(contentsOf: XCTUnwrap(url, "找不到 fixture: \(name).json"))
    }

    private func decodeReal() throws -> APILibrary {
        try JSONDecoder().decode(APILibrary.self, from: fixtureData("library-real"))
    }

    // MARK: - 真实响应

    func testRealResponseDecodesCompletely() throws {
        let library = try decodeReal()

        XCTAssertFalse(library.libraryVersion.isEmpty, "缺 libraryVersion 就无法判断是否需要重拉")
        XCTAssertEqual(library.count, library.items.count, "count 必须与 items 一致，否则服务端统计错了")
        XCTAssertFalse(library.items.isEmpty, "线上至少有一条，空库说明抓错了共享码")

        let item = try XCTUnwrap(library.items.first)

        // 这几个字段是「展示就绪」的核心：服务端给成品，客户端不加工
        XCTAssertFalse(item.id.isEmpty)
        XCTAssertEqual(item.kind, "video")
        XCTAssertFalse(item.title.isEmpty)
        XCTAssertFalse(item.metaLine.isEmpty, "metaLine 由服务端给，客户端不该自己拼")
        XCTAssertFalse(item.durationText.isEmpty, "durationText 由服务端格式化，客户端不该自己算")
        XCTAssertGreaterThan(item.durationSeconds, 0)

        // metaLine 里必须已经有平台与作者，且用的是中文平台名而不是 bilibili
        XCTAssertTrue(item.metaLine.contains("·"), item.metaLine)
        XCTAssertFalse(item.metaLine.contains("bilibili"), "平台名要本地化，不能把 slug 直接给用户")
    }

    func testRealCoverIsAbsoluteAndUsable() throws {
        let item = try XCTUnwrap(try decodeReal().items.first)
        let cover = try XCTUnwrap(item.cover)
        let raw = try XCTUnwrap(cover.url)

        // 封面必须是绝对地址：相对路径客户端拿去打不开
        XCTAssertTrue(raw.hasPrefix("https://"), raw)
        // 不能指到沙箱内网主机名——踩过一次，当时居然还能打开，很容易漏过去
        XCTAssertFalse(raw.contains("sandbox"), raw)
        XCTAssertEqual(raw.components(separatedBy: "/proxy?").count - 1, 1, "代理只能包一层：\(raw)")
    }

    func testRealResponseCarriesNoLocalState() throws {
        // 本地状态（是否下载、是否已看、进度）不该由服务端下发：
        // 那是设备自己的事，混进协议就会在两台设备之间打架。
        let data = try fixtureData("library-real")
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in ["isDownloaded", "mediaState", "progress", "lastPlayedAt"] {
            XCTAssertFalse(text.contains(forbidden), "服务端不该下发本地状态字段：\(forbidden)")
        }
    }

    // MARK: - 截图用的样本库

    func testSampleFixtureMatchesTheSameContract() throws {
        // 截图用的样本必须和线上同一套形状，否则截图证明不了真实数据的渲染。
        // 同时这条也验证了 library-sample.json 确实被打进了 App bundle——
        // 漏打包的话画廊会静静地变成空列表，而 CI 只看「测试绿」是发现不了的。
        let data = try XCTUnwrap(Item.sampleData, "library-sample.json 没打进 App bundle")
        let library = try JSONDecoder().decode(APILibrary.self, from: data)

        XCTAssertEqual(library.count, library.items.count)
        XCTAssertGreaterThanOrEqual(library.items.count, 6, "列表截图需要足够多的行")

        for item in library.items {
            XCTAssertFalse(item.id.isEmpty)
            XCTAssertFalse(item.title.isEmpty)
            XCTAssertFalse(item.metaLine.isEmpty)
            // 笔记没有视频，就谈不上时长。服务端给空串，客户端据此连「· 05:48」都不显示。
            if item.playback.available {
                XCTAssertFalse(item.durationText.isEmpty, "视频必须有时长：\(item.title)")
            } else {
                XCTAssertTrue(item.durationText.isEmpty, "笔记不该有时长：\(item.title)")
            }
        }

        // 至少各有一条：有视频流的、没有视频流的
        XCTAssertTrue(library.items.contains { $0.playback.available })
        XCTAssertTrue(library.items.contains { !$0.playback.available })
    }

    // MARK: - 容忍性
    //
    // 运行时求稳：服务端加字段、少给可选字段，客户端都不该崩。
    // 严格性由上面的契约测试负责。两者分工，不要混在一起。

    func testMinimalItemDecodesWithDefaults() throws {
        let json = """
        {"items": [{"id": "x1", "title": "只有必需字段"}], "libraryVersion": "lv_1", "count": 1}
        """
        let library = try JSONDecoder().decode(APILibrary.self, from: Data(json.utf8))
        let item = try XCTUnwrap(library.items.first)

        XCTAssertEqual(item.id, "x1")
        XCTAssertEqual(item.metaLine, "")
        XCTAssertEqual(item.durationText, "")
        XCTAssertEqual(item.summary, "")
        XCTAssertNil(item.cover)
        // 缺 playback 时按 kind 推断，而不是整页解不出来
        XCTAssertTrue(item.playback.available)
    }

    func testMissingTitleFailsLoudly() {
        // 标题是渲染必需项。宁可在这里炸，也不要在界面上显示一行空白。
        let json = """
        {"items": [{"id": "x1"}], "libraryVersion": "lv_1", "count": 1}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(APILibrary.self, from: Data(json.utf8)))
    }

    func testCountMismatchTrustsItems() throws {
        // 服务端统计错了不该让客户端少显示内容
        let json = """
        {"items": [{"id": "a", "title": "A"}, {"id": "b", "title": "B"}],
         "libraryVersion": "lv_1", "count": 99}
        """
        let library = try JSONDecoder().decode(APILibrary.self, from: Data(json.utf8))
        XCTAssertEqual(library.items.count, 2)
        XCTAssertEqual(library.count, 99, "原样保留，方便日志里看出服务端算错了")
    }

    // MARK: - 模型转换

    func testItemCarriesPresentationStringsVerbatim() throws {
        let api = APILibraryItem(
            id: "mvrl0axm2j64w",
            kind: "video",
            title: "标题",
            metaLine: "B 站 · 幽州-节度使",
            durationText: "16:57",
            durationSeconds: 1017,
            summary: "摘要"
        )
        let item = Item(api: api)

        // 一个字符都不该变：客户端没有资格重新格式化服务端给的成品
        XCTAssertEqual(item.metaLine, "B 站 · 幽州-节度使")
        XCTAssertEqual(item.durationText, "16:57")
        XCTAssertEqual(item.id, "mvrl0axm2j64w")
        XCTAssertTrue(item.playbackAvailable)
    }

    func testNoteIsNotPlayable() throws {
        let api = APILibraryItem(
            id: "n1",
            kind: "note",
            title: "一条笔记",
            playback: APIPlayback(available: false, reason: "NOTE")
        )
        XCTAssertFalse(Item(api: api).playbackAvailable)
    }

    func testPlaceholderColorIsStableAcrossCalls() {
        // 用 hashValue 会每次进程启动都变，同一张封面在不同次截图里颜色不同，
        // 图就不可比了。这条钉子钉的是「截图可复现」。
        let a = Item.placeholderColors(for: "mvrl0axm2j64w")
        let b = Item.placeholderColors(for: "mvrl0axm2j64w")
        XCTAssertEqual(a.top, b.top)
        XCTAssertEqual(a.bottom, b.bottom)

        // 不同 id 应该给出不同颜色，否则列表会退化成一片同色
        let c = Item.placeholderColors(for: "seed0000000002")
        XCTAssertNotEqual(a.top, c.top)
    }
}
