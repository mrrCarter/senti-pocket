import XCTest
import PocketContracts
@testable import SentiPocketApp

/// Feeds canned HTTP responses without a network, and captures the outgoing request for assertions.
final class DialStubURLProtocol: URLProtocol {
    static let lock = NSLock()
    static var responder: ((URLRequest) -> (HTTPURLResponse, Data))?
    static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.lastRequest = request; let responder = Self.responder; Self.lock.unlock()
        guard let responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let (resp, data) = responder(request)
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class DialSignalClientTests: XCTestCase {

    private let base = URL(string: "https://gw.example.com")!

    // A real-wire-shaped stored NeedCarterSignal (relay's KAV "go" case: kind {go:{}}, createdAt Unix seconds, evidenceSeqs []).
    private let goJSON = Data("""
    {"id":"need_2","kind":{"go":{}},"question":"GO on the deploy?","context":{"sessionId":"6cf7e861","whatWeNeed":"deploy go"},"confidence":1.0,"evidenceSeqs":[],"requestedBy":"detector","createdAt":1784370900}
    """.utf8)

    private func makeClient(token: String = "tok123", responder: @escaping (URLRequest) -> (HTTPURLResponse, Data)) -> DialSignalClient {
        DialStubURLProtocol.lock.lock(); DialStubURLProtocol.responder = responder; DialStubURLProtocol.lastRequest = nil; DialStubURLProtocol.lock.unlock()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [DialStubURLProtocol.self]
        return DialSignalClient(apiBaseURL: base, urlSession: URLSession(configuration: cfg), tokenProvider: { token })
    }
    private func http(_ url: URL, _ code: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
    }

    func test_fetchDial_decodes_full_signal_on_200() async throws {
        let client = makeClient { (self.http($0.url!, 200), self.goJSON) }
        let s = try await client.fetchDial(id: "need_2")
        XCTAssertEqual(s.id, "need_2")
        XCTAssertEqual(s.question, "GO on the deploy?")
        XCTAssertEqual(s.context.sessionId, "6cf7e861")
        XCTAssertNil(s.context.checkpointId)
        XCTAssertEqual(s.evidenceSeqs, [])
        XCTAssertEqual(s.createdAt, Date(timeIntervalSince1970: 1_784_370_900))  // Unix seconds, no skew
        guard case .go = s.kind else { return XCTFail("kind should decode as .go") }
    }

    func test_fetchDial_sends_bearer_and_id_query() async throws {
        let client = makeClient(token: "secret-tok") { (self.http($0.url!, 200), self.goJSON) }
        _ = try await client.fetchDial(id: "need_2")
        let req = DialStubURLProtocol.lastRequest
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Authorization"), "Bearer secret-tok")
        let comps = URLComponents(url: req!.url!, resolvingAgainstBaseURL: false)
        XCTAssertEqual(comps?.path, "/dial")
        XCTAssertEqual(comps?.queryItems?.first(where: { $0.name == "id" })?.value, "need_2")
        XCTAssertEqual(req?.httpMethod, "GET")
    }

    func test_fetchDial_throws_notFound_on_404() async {
        let client = makeClient { (self.http($0.url!, 404), Data("{}".utf8)) }
        await assertThrows(client, expected: .notFound)
    }

    func test_fetchDial_throws_http_on_403() async {
        let client = makeClient { (self.http($0.url!, 403), Data("{}".utf8)) }
        await assertThrows(client, expected: .http(403))
    }

    func test_fetchDial_throws_notLoggedIn_on_empty_token_without_hitting_network() async {
        let client = makeClient(token: "") { _ in XCTFail("must not hit the network with no token"); return (self.http(self.base, 200), Data()) }
        await assertThrows(client, expected: .notLoggedIn)
    }

    func test_fetchDial_throws_malformed_on_garbage_body() async {
        let client = makeClient { (self.http($0.url!, 200), Data("not json".utf8)) }
        await assertThrows(client, expected: .malformedResponse)
    }

    private func assertThrows(_ client: DialSignalClient, expected: DialSignalError, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await client.fetchDial(id: "need_2"); XCTFail("expected \(expected)", file: file, line: line) }
        catch let e as DialSignalError { XCTAssertEqual(e, expected, file: file, line: line) }
        catch { XCTFail("unexpected error \(error)", file: file, line: line) }
    }
}
