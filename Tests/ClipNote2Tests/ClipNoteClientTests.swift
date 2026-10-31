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
            XCTAssertEqual(failure, .gatewayIncomplete)
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
             Data(#"{"url":"https://example.test/proxy?u=v.mp4","mimeType":"video/mp4","expiresAt":0}"#.utf8))
        }

        let payload = try await makeClient().playback(id: "mvrl0axm2j64w")
        XCTAssertEqual(payload?.url, "https://example.test/proxy?u=v.mp4")
        XCTAssertEqual(payload?.expiresAt, 0, "0 表示未知，客户端不做过期预判")
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
