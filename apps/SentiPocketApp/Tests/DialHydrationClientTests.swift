import XCTest
import PocketContracts
@testable import SentiPocketApp

/// Locks DialHydrationClient — the single authed-fetch seam (`hydrate(_:) -> RenderableRing`) the crew converged on
/// (warden + relay: 410-correct + contract-complete). Uses a URLProtocol stub (forge's DialSignalClient #97 pattern)
/// + the injectable tokenProvider, so the fetch is hermetic. Covers: RICH passthrough (no fetch), LEAN fetch+merge,
/// the full status taxonomy (410→unavailable / 401→reauthentication / 5xx→retryable), substitution refusal, no-token.
final class HydrationStubURLProtocol: URLProtocol {
    static let lock = NSLock()
    static var responder: ((URLRequest) -> (HTTPURLResponse, Data))?
    static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.lastRequest = request; let responder = Self.responder; Self.lock.unlock()
        guard let responder else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        let (resp, data) = responder(request)
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class DialHydrationClientTests: XCTestCase {

    private let base = URL(string: "https://gw.example.com")!

    // A real-wire stored NeedCarterSignal whose id/session/checkpoint MATCH the push core below (so merge succeeds).
    private let signalJSON = Data("""
    {"id":"need_1","kind":{"decisionYours":{}},"question":"Ship it?","context":{"sessionId":"6cf7e861","checkpointId":"cp_9","whatWeNeed":"go"},"confidence":0.9,"evidenceSeqs":[315038],"requestedBy":"claude-warden","createdAt":1784370900}
    """.utf8)

    private func core(id: String = "need_1", sessionId: String = "6cf7e861", checkpointId: String? = "cp_9") -> RingCore {
        RingCore(id: id, kind: "decisionYours", priority: "high",
                 callerName: "Senti · claude-warden needs your decision", sessionId: sessionId, checkpointId: checkpointId)
    }

    private func makeClient(token: String = "tok123",
                             tokenProvider: (() -> String?)? = nil,
                             onReauthenticationRequired: @escaping @Sendable (String?) -> Void = { _ in },
                             responder: @escaping (URLRequest) -> (HTTPURLResponse, Data)) -> DialHydrationClient {
        HydrationStubURLProtocol.lock.lock()
        HydrationStubURLProtocol.responder = responder
        HydrationStubURLProtocol.lastRequest = nil
        HydrationStubURLProtocol.lock.unlock()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [HydrationStubURLProtocol.self]
        return DialHydrationClient(
            apiBaseURL: base,
            urlSession: URLSession(configuration: cfg),
            tokenProvider: tokenProvider ?? { token.isEmpty ? nil : token },
            onReauthenticationRequired: onReauthenticationRequired
        )
    }

    private func http(_ url: URL, _ code: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
    }

    /// Assert hydrate throws a specific (associated-value-free) DialHydrationClientError.
    private func expect(_ client: DialHydrationClient, _ state: DialReceiveState, _ want: DialHydrationClientError,
                        file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await client.hydrate(state); XCTFail("expected \(want)", file: file, line: line) }
        catch let e as DialHydrationClientError { XCTAssertEqual(e, want, file: file, line: line) }
        catch { XCTFail("wrong error type: \(error)", file: file, line: line) }
    }

    // MARK: - RICH passthrough: no fetch at all

    func test_renderable_is_returned_as_is_without_fetching() async throws {
        let ring = RenderableRing(core: core(), message: "FYI", options: [], evidenceSeqs: [7], confidence: 0.5)
        let client = makeClient { (self.http($0.url!, 200), self.signalJSON) }
        let out = try await client.hydrate(.renderable(ring))
        XCTAssertEqual(out, ring)
        XCTAssertNil(HydrationStubURLProtocol.lastRequest, "a RICH push must NOT hit the network")
    }

    // MARK: - LEAN fetch + merge: governed content from the authed fetch, bound to the push core

    func test_needsHydration_fetches_and_merges_governed_content() async throws {
        let client = makeClient { (self.http($0.url!, 200), self.signalJSON) }
        let out = try await client.hydrate(.needsHydration(id: "need_1", core: core()))
        XCTAssertEqual(out.core.id, "need_1")
        XCTAssertEqual(out.message, "Ship it?")               // governed content — from the AUTHED fetch only
        XCTAssertEqual(out.options, [])                       // decisionYours → no options
        XCTAssertEqual(out.evidenceSeqs, [315038])
        XCTAssertEqual(out.core.checkpointId, "cp_9")
        XCTAssertEqual(out.confidence ?? -1, 0.9, accuracy: 1e-9)
        // sanity: it was an authed GET to /dial?id=
        let req = HydrationStubURLProtocol.lastRequest
        XCTAssertEqual(req?.httpMethod, "GET")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Authorization"), "Bearer tok123")
        XCTAssertEqual(req?.url?.path, "/dial")
    }

    // MARK: - status taxonomy (the contract relay owns)

    func test_gone_410_is_unavailable() async {
        let client = makeClient { (self.http($0.url!, 410), Data(#"{"error":"dial signal unavailable","reason":"gone"}"#.utf8)) }
        await expect(client, .needsHydration(id: "need_1", core: core()), .unavailable)  // uniform gone — never distinguished
    }

    func test_401_requires_reauthentication_and_signals_the_request_token() async {
        let signal = HydrationAuthSignal()
        let client = makeClient(
            onReauthenticationRequired: { signal.record($0) },
            responder: { (self.http($0.url!, 401), Data("{}".utf8)) }
        )
        await expect(client, .needsHydration(id: "need_1", core: core()), .reauthenticationRequired)
        XCTAssertEqual(signal.tokens, ["tok123"])
    }

    func test_late_401_for_an_old_token_is_superseded_without_auth_signal() async {
        let token = HydrationTokenSequence(["principal-A", "principal-B"])
        let signal = HydrationAuthSignal()
        let client = makeClient(
            tokenProvider: { token.next() },
            onReauthenticationRequired: { signal.record($0) },
            responder: { (self.http($0.url!, 401), Data("{}".utf8)) }
        )

        await expect(
            client,
            .needsHydration(id: "need_1", core: core()),
            .supersededAuthentication
        )
        XCTAssertEqual(signal.tokens, [])
    }

    func test_5xx_is_retryable() async {
        let client = makeClient { (self.http($0.url!, 503), Data(#"{"error":"lookup failed","retryable":true}"#.utf8)) }
        await expect(client, .needsHydration(id: "need_1", core: core()), .retryable("lookup failed"))
    }

    func test_missing_token_is_notLoggedIn_before_any_network() async {
        let client = makeClient(token: "") { (self.http($0.url!, 200), self.signalJSON) }
        await expect(client, .needsHydration(id: "need_1", core: core()), .notLoggedIn)
        XCTAssertNil(HydrationStubURLProtocol.lastRequest, "no token → no network")
    }

    // MARK: - the security gate: a substituted fetch is refused (terminal)

    func test_substituted_signal_is_refused() async {
        // 200, but the fetched signal's id != the push core's id → DialHydration.merge refuses → .hydrationRefused.
        let hijack = Data("""
        {"id":"need_HIJACK","kind":{"decisionYours":{}},"question":"approve wire?","context":{"sessionId":"6cf7e861","checkpointId":"cp_9","whatWeNeed":"go"},"confidence":0.9,"evidenceSeqs":[],"requestedBy":"x","createdAt":1784370900}
        """.utf8)
        let client = makeClient { (self.http($0.url!, 200), hijack) }
        do {
            _ = try await client.hydrate(.needsHydration(id: "need_1", core: core()))
            XCTFail("a substituted signal must be refused")
        } catch let e as DialHydrationClientError {
            guard case .hydrationRefused = e else { return XCTFail("expected hydrationRefused, got \(e)") }
        } catch { XCTFail("wrong error type: \(error)") }
    }

    // MARK: - malformed transport never rings

    func test_rejected_state_throws_never_fetches() async {
        let client = makeClient { (self.http($0.url!, 200), self.signalJSON) }
        await expect(client, .rejected(reason: "bad version"), .rejected("bad version"))
        XCTAssertNil(HydrationStubURLProtocol.lastRequest, "a rejected push must NOT hit the network")
    }
}

private final class HydrationAuthSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var storedTokens: [String?] = []

    var tokens: [String?] {
        lock.lock()
        defer { lock.unlock() }
        return storedTokens
    }

    func record(_ token: String?) {
        lock.lock()
        storedTokens.append(token)
        lock.unlock()
    }
}

private final class HydrationTokenSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let values: [String]
    private var index = 0

    init(_ values: [String]) {
        self.values = values
    }

    func next() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !values.isEmpty else { return nil }
        let value = values[min(index, values.count - 1)]
        index += 1
        return value
    }
}
