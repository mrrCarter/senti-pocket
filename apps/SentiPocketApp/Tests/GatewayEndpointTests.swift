import XCTest
@testable import SentiPocketApp
import PocketContracts

/// The centralized fail-closed gateway resolver (Pulse round-7 #1): every invalid form → nil (unavailable → ZERO wire
/// across the SESSION clients too); a valid config → the EXACT configured host only. No attacker-shapeable forms and no
/// hardcoded host default anywhere.
@MainActor
final class GatewayEndpointTests: XCTestCase {

    private let invalids: [String?] = [
        nil, "", "   ",
        "http://insecure.example",            // non-https
        "ftp://x.example",                    // non-https
        "https://",                           // no host
        "not a url with spaces",              // unparseable
        "https://user:pass@safe.example",     // userinfo + password
        "https://user@safe.example",          // userinfo
        "https://safe.example?token=x",       // query
        "https://safe.example#frag",          // fragment
    ]

    func test_resolve_rejects_every_invalid_form() {
        for bad in invalids {
            XCTAssertNil(GatewayEndpoint.resolve(bad), "must reject \(String(describing: bad))")
        }
    }

    func test_resolve_accepts_a_clean_https_host() {
        XCTAssertEqual(GatewayEndpoint.resolve("https://safe.example")?.host, "safe.example")
        XCTAssertEqual(GatewayEndpoint.resolve("  https://safe.example  ")?.host, "safe.example")     // trimmed
        XCTAssertEqual(GatewayEndpoint.resolve("https://safe.example/actions")?.host, "safe.example")  // a path is fine
    }

    /// Counts requests the session client attempts.
    final class CountingProtocol: URLProtocol {
        static var count = 0
        static func reset() { count = 0 }
        override class func canInit(with r: URLRequest) -> Bool { count += 1; return false }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
        override func startLoading() {}
        override func stopLoading() {}
    }
    /// Records where a session request went, then fails it.
    final class HostRecordingProtocol: URLProtocol {
        static var host: String?; static var count = 0
        static func reset() { host = nil; count = 0 }
        override class func canInit(with r: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
        override func startLoading() { Self.host = request.url?.host; Self.count += 1
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
        override func stopLoading() {}
    }
    private func proposal() -> (ActionProposal, GovernedWriteConfirmation) {
        let p = PocketWriteClient.makeHumanMessageProposal(sessionId: "6cf7e861", message: "hi")
        return (p, GovernedWriteConfirmation(proposalId: p.id, confirmedProposalHash: p.proposalHash, confirmedAt: Date()))
    }

    // Every invalid config → nil → the session WRITE client makes ZERO requests, even with a valid token.
    func test_invalid_config_makes_zero_session_requests_even_with_a_token() async {
        for bad in invalids {
            CountingProtocol.reset()
            let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [CountingProtocol.self]
            let client = PocketWriteClient(apiBaseURL: GatewayEndpoint.resolve(bad),   // nil for every invalid form
                                           urlSession: URLSession(configuration: cfg), tokenProvider: { "valid-token" })
            let (p, c) = proposal()
            _ = try? await client.execute(proposal: p, confirmation: c)
            XCTAssertEqual(CountingProtocol.count, 0, "invalid config \(String(describing: bad)) → zero session requests")
        }
    }

    // A valid config → the session write client sends to EXACTLY the configured host.
    func test_valid_config_sends_session_request_to_exactly_that_host() async {
        HostRecordingProtocol.reset()
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [HostRecordingProtocol.self]
        let client = PocketWriteClient(apiBaseURL: GatewayEndpoint.resolve("https://safe.example"),
                                       urlSession: URLSession(configuration: cfg), tokenProvider: { "valid-token" })
        let (p, c) = proposal()
        _ = try? await client.execute(proposal: p, confirmation: c)
        XCTAssertEqual(HostRecordingProtocol.count, 1, "a valid config makes exactly one session request")
        XCTAssertEqual(HostRecordingProtocol.host, "safe.example", "the session bearer goes to EXACTLY the configured host")
    }
}
