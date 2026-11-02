import XCTest
@testable import ClipNote2

/// 拦下 URLSession 的请求，返回预设的响应。
///
/// `handler` 是测试内单线程串行写入的，不需要额外加锁。
final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, [String: String], Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let (status, headers, data) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// 客户端对「线上真实会发生的事」的处理。
///
/// 这几条不是假想：线上网关对每个路径都要求 `sharecode`（否则 403），
/// 未知路径会回落 200 + 首页 HTML。两条都已经在真实环境里踩过。
final class ClipNoteClientTests: XCTestCase {

    private let baseURL = URL(string: "https://example.test")!

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    private func makeClient(code: String = "C1") -> ClipNoteClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return ClipNoteClient(
            baseURL: baseURL,
            shareCode: code,
            session: URLSession(configuration: config)
        )
    }

    // MARK: - 请求形状

    func testBothShareCodeAndCodeAreSent() async throws {
        var seen: URL?
        StubURLProtocol.handler = { request in
            seen = request.url
            return (200, ["Content-Type": "application/json"], Data(#"{"items":[],"count":0,"libraryVersion":"lv_1"}"#.utf8))
        }

        _ = try await makeClient(code: "MYCODE").library()

        let url = try XCTUnwrap(seen)
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        // 两个参数都要带：sharecode 过网关，code 给服务端鉴权
        XCTAssertEqual(query.first { $0.name == "sharecode" }?.value, "MYCODE")
        XCTAssertEqual(query.first { $0.name == "code" }?.value, "MYCODE")
        XCTAssertEqual(url.path, "/api/v2/library")
    }

    // MARK: - 三种线上真实失败

    func testHTMLResponseIsRejected() async {
        // 线上对未知路径返回 200 + index.html。不校验 Content-Type 就会把 HTML 当 JSON 解。
        StubURLProtocol.handler = { _ in
            (200, ["Content-Type": "text/html; charset=utf-8"], Data("<!doctype html><html></html>".utf8))
        }

        do {
            _ = try await makeClient().library()
            XCTFail("HTML 不该被当成库数据")
        } catch let failure as ClipNoteClient.Failure {
            guard case .notJSON = failure else {
                return XCTFail("应归为 notJSON，实际 \(failure)")
            }
            XCTAssertFalse(failure.displayMessage.isEmpty)
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    func testForbiddenIsReportedAsGateway() async {
        StubURLProtocol.handler = { _ in
            (403, ["Content-Type": "text/plain"], Data("链接不完整".utf8))
        }

        do {
            _ = try await makeClient().library()
            XCTFail("403 应当失败")
        } catch let failure as ClipNoteClient.Failure {
            // 只断言「归类成 403」，不绑 snippet 的具体内容：
            // 那个字段是给排障用的，响应体里放什么都行，不该让测试跟着变。
            guard case .gatewayBlocked(let snippet) = failure else {
                return XCTFail("403 应当归类为 gatewayBlocked，实际是 \(failure)")
            }
            XCTAssertEqual(snippet, "链接不完整", "响应体要带出来，否则事后没法查")
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    func testServerErrorCarriesCodeAndMessage() async {
        StubURLProtocol.handler = { _ in
            (500, ["Content-Type": "application/json"],
             Data(#"{"code":"SYNC_READ","message":"快照读不出来","retryable":true}"#.utf8))
        }

        do {
            _ = try await makeClient().library()
            XCTFail("500 应当失败")
        } catch let failure as ClipNoteClient.Failure {
            guard case .http(let status, let code, let message) = failure else {
                return XCTFail("应归为 http，实际 \(failure)")
            }
            XCTAssertEqual(status, 500)
            XCTAssertEqual(code, "SYNC_READ")
            // 服务端的 message 要能透到界面上，而不是换成「未知错误」
            XCTAssertEqual(failure.displayMessage, "快照读不出来")
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    // MARK: - 播放地址

    func testPlaybackReturnsURL() async throws {
        StubURLProtocol.handler = { _ in
            (200, ["Content-Type": "application/json"],
             Data(#"{"url":"https://example.test/proxy?u=v.mp4","mimeType":"video/mp4","quality":"720P","bytes":130257119,"expiresAt":0}"#.utf8))
        }

        let payload = try await makeClient().playback(id: "mvrl0axm2j64w")
        XCTAssertEqual(payload?.url, "https://example.test/proxy?u=v.mp4")
        XCTAssertEqual(payload?.expiresAt, 0, "0 表示未知，客户端不做过期预判")
        XCTAssertEqual(payload?.quality, "720P")
        XCTAssertEqual(payload?.bytes, 130_257_119)
        // 按钮下面那行字要靠它拼出来：用户点下载之前要知道下多大。
        // 不断言具体数字：ByteCountFormatter 的进位方式随系统设置变，锁死会变成脆弱测试。
        let summary = try XCTUnwrap(payload?.sizeSummary)
        XCTAssertTrue(summary.hasPrefix("720P · 约 "), summary)
    }

    func testPlaybackWithoutQualityStillDecodes() async throws {
        // 服务端可能不给 quality/bytes（比如解析器没返回清晰度）。
        // 这时不能整条解不出来，只是少一行提示。
        StubURLProtocol.handler = { _ in
            (200, ["Content-Type": "application/json"],
             Data(#"{"url":"https://example.test/v.mp4","expiresAt":0}"#.utf8))
        }

        let payload = try await makeClient().playback(id: "x1")
        XCTAssertEqual(payload?.url, "https://example.test/v.mp4")
        XCTAssertEqual(payload?.sizeSummary, "")
    }

    func testPlaybackUnavailableReturnsNilInsteadOfThrowing() async throws {
        // 409 不是网络错误，是内容属性。笔记没有视频流，不该让界面报「加载失败」。
        StubURLProtocol.handler = { _ in
            (409, ["Content-Type": "application/json"],
             Data(#"{"code":"PLAYBACK_UNAVAILABLE","message":"该内容没有视频流","retryable":false}"#.utf8))
        }

        let payload = try await makeClient().playback(id: "note001")
        XCTAssertNil(payload)
    }

    // MARK: - 导入

    /// URLProtocol 里 `httpBody` 常常是 nil（URLSession 把它转成了 stream），
    /// 只读 httpBody 会得到一个「请求体为空」的假结论。
    private static func bodyData(_ request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    func testImportPostsRawTextAndDecodesNestedResult() async throws {
        var method: String?
        var path: String?
        var body: [String: Any]?

        StubURLProtocol.handler = { request in
            method = request.httpMethod
            path = request.url?.path
            if let data = Self.bodyData(request) {
                body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
            let json = """
            {"created": true,
             "item": {"id": "x1", "kind": "video", "title": "新导入",
                      "metaLine": "B 站 · 作者", "durationText": "12:34",
                      "durationSeconds": 754, "summary": "",
                      "playback": {"available": true}, "publishedAt": 0}}
            """
            return (200, ["Content-Type": "application/json"], Data(json.utf8))
        }

        let result = try await makeClient().importItem(url: "【标题】 https://b23.tv/x")
        XCTAssertEqual(method, "POST")
        XCTAssertEqual(path, "/api/v2/parse")
        // 分享文案原样上传：清洗各样分享格式是服务端的事，客户端不该内置
        XCTAssertEqual(body?["url"] as? String, "【标题】 https://b23.tv/x")
        XCTAssertTrue(result.created)
        XCTAssertEqual(result.item.title, "新导入")
    }

    func testImportDuplicateIsNotAnError() async throws {
        // created=false 是「库里已有」，用户要的结果已经成立，不该当失败弹红字
        StubURLProtocol.handler = { _ in
            (200, ["Content-Type": "application/json"],
             Data(#"{"created":false,"item":{"id":"x1","title":"已有的一条"}}"#.utf8))
        }
        let result = try await makeClient().importItem(url: "https://x")
        XCTAssertFalse(result.created)
        XCTAssertEqual(result.item.title, "已有的一条")
    }

    func testImportBadLinkSurfacesServerMessage() async {
        StubURLProtocol.handler = { _ in
            (422, ["Content-Type": "application/json"],
             Data(#"{"code":"BAD_URL","message":"没有识别到链接","retryable":false}"#.utf8))
        }
        do {
            _ = try await makeClient().importItem(url: "随便一段文字")
            XCTFail("应当失败")
        } catch let failure as ClipNoteClient.Failure {
            // 服务端那句人话要能透到界面上，不能换成「未知错误」
            XCTAssertEqual(failure.displayMessage, "没有识别到链接")
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    // MARK: - 删除与回收站

    func testLibraryDecodesTrashCount() async throws {
        StubURLProtocol.handler = { _ in
            (200, ["Content-Type": "application/json"],
             Data(#"{"items":[],"count":0,"libraryVersion":"lv_1","trashCount":3}"#.utf8))
        }
        let lib = try await makeClient().library()
        // 「我」页要显示「回收站 · 3 条」，不该为一行字再拉一次 /trash
        XCTAssertEqual(lib.trashCount, 3)
    }

    func testTrashDecodesDeletedAt() async throws {
        StubURLProtocol.handler = { _ in
            (200, ["Content-Type": "application/json"],
             Data(#"{"count":1,"items":[{"id":"x1","title":"删掉的","deletedAt":1793430625000}]}"#.utf8))
        }
        let trash = try await makeClient().trash()
        XCTAssertEqual(trash.count, 1)
        XCTAssertEqual(trash.items.first?.title, "删掉的")
        XCTAssertEqual(trash.items.first?.deletedAt, 1_793_430_625_000)
    }

    func testDeleteUsesPathActionAndEncodesID() async throws {
        var seen: String?
        StubURLProtocol.handler = { request in
            seen = request.url?.absoluteString
            return (200, ["Content-Type": "application/json"],
                    Data(#"{"id":"a/b","title":"删掉的"}"#.utf8))
        }
        _ = try await makeClient().deleteItem(id: "a/b")
        let url = try XCTUnwrap(seen)
        XCTAssertTrue(url.contains("/api/v2/items/a%2Fb/delete"), url)
    }

    func testPurgeReturnsOK() async throws {
        var seen: String?
        StubURLProtocol.handler = { request in
            seen = request.url?.absoluteString
            return (200, ["Content-Type": "application/json"], Data(#"{"ok":true,"id":"x1"}"#.utf8))
        }
        try await makeClient().purgeItem(id: "x1")
        XCTAssertTrue(seen?.contains("/purge") ?? false, seen ?? "")
    }

    func testPlaybackPathIsCorrectlyEncoded() async throws {
        var seen: String?
        StubURLProtocol.handler = { request in
            // 用 absoluteString 而不是 url.path：后者会解码 percent-encoding，
            // 正好看不出 id 里的斜杠有没有被正确转义
            seen = request.url?.absoluteString
            return (200, ["Content-Type": "application/json"],
                    Data(#"{"url":"https://example.test/v.mp4","expiresAt":0}"#.utf8))
        }

        _ = try await makeClient().playback(id: "a/b c")
        let url = try XCTUnwrap(seen)
        // id 里的斜杠必须被编码掉，否则会被服务端当成多一级路径
        XCTAssertTrue(url.contains("/api/v2/items/a%2Fb%20c/playback"), url)
    }
}
