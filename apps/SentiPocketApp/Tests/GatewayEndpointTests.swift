import Foundation
import XCTest
import PocketContracts
@testable import SentiPocketApp

private final class GatewayEndpointStubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private(set) static var requestCount = 0
    private(set) static var lastHost: String?

    static func reset() {
        lock.lock()
        requestCount = 0
        lastHost = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requestCount += 1
        Self.lastHost = request.url?.host
        Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
    }

    override func stopLoading() {}
}

final class GatewayEndpointTests: XCTestCase {
    func test_accepts_only_an_explicit_https_origin() {
        let url = GatewayEndpoint.resolve("  HTTPS://gateway.example.com:8443/  ")

        XCTAssertEqual(url?.scheme, "https")
        XCTAssertEqual(url?.host, "gateway.example.com")
        XCTAssertEqual(url?.port, 8443)
        XCTAssertEqual(url?.path, "")
    }

    func test_rejects_ambiguous_or_untrusted_destinations() {
        XCTAssertNil(GatewayEndpoint.resolve(nil))

        let rejected = [
            "",
            "   ",
            "http://gateway.example.com",
            "https://",
            "not a url",
            "$(SENTI_GATEWAY_URL)",
            "https://user@gateway.example.com",
            "https://user:password@gateway.example.com",
            "https://gateway.example.com/api",
            "https://gateway.example.com?tenant=other",
            "https://gateway.example.com#other",
            "https://gateway.example.com /",
            "https://gateway.example.com\\@other.example",
            "https://%67ateway.example.com",
            "https://gateway.example.com:65536",
            "file:///tmp/gateway"
        ]

        for rawValue in rejected {
            XCTAssertNil(GatewayEndpoint.resolve(rawValue), "must reject \(rawValue)")
        }
    }

    func test_first_nonempty_configuration_is_authoritative_and_invalid_override_fails_closed() {
        let validFallback: [String: Any] = [
            "SENTI_API_URL": "  ",
            "SENTI_GATEWAY_URL": "https://gateway.example.com"
        ]
        XCTAssertEqual(
            GatewayEndpoint.resolve(
                infoDictionary: validFallback,
                keys: ["SENTI_API_URL", "SENTI_GATEWAY_URL"]
            )?.host,
            "gateway.example.com"
        )

        let invalidOverride: [String: Any] = [
            "SENTI_API_URL": "http://api.example.com",
            "SENTI_GATEWAY_URL": "https://gateway.example.com"
        ]
        XCTAssertNil(
            GatewayEndpoint.resolve(
                infoDictionary: invalidOverride,
                keys: ["SENTI_API_URL", "SENTI_GATEWAY_URL"]
            ),
            "an invalid explicit auth override must not silently redirect credentials to the fallback key"
        )

        let wrongTypeOverride: [String: Any] = [
            "SENTI_API_URL": 7,
            "SENTI_GATEWAY_URL": "https://gateway.example.com"
        ]
        XCTAssertNil(
            GatewayEndpoint.resolve(
                infoDictionary: wrongTypeOverride,
                keys: ["SENTI_API_URL", "SENTI_GATEWAY_URL"]
            ),
            "a non-string explicit override is malformed configuration, not an absent key"
        )
    }

    @MainActor
    func test_unconfigured_write_fails_before_token_or_network() async {
        GatewayEndpointStubURLProtocol.reset()
        var tokenReads = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GatewayEndpointStubURLProtocol.self]
        let client = PocketWriteClient(
            apiBaseURL: nil,
            urlSession: URLSession(configuration: configuration),
            tokenProvider: {
                tokenReads += 1
                return "must-not-be-read"
            }
        )
        let proposal = PocketWriteClient.makeHumanMessageProposal(
            sessionId: "6cf7e861",
            message: "Do not send without a configured gateway"
        )
        let confirmation = GovernedWriteConfirmation(
            proposalId: proposal.id,
            confirmedProposalHash: proposal.proposalHash,
            confirmedAt: Date()
        )

        do {
            _ = try await client.execute(proposal: proposal, confirmation: confirmation)
            XCTFail("an unconfigured write must fail")
        } catch let error as PocketWriteError {
            XCTAssertEqual(error, .notConfigured)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(tokenReads, 0, "configuration must fail before reading a credential")
        XCTAssertEqual(GatewayEndpointStubURLProtocol.requestCount, 0, "configuration must fail before network I/O")
    }

    @MainActor
    func test_unconfigured_write_is_terminal_not_offline_pending() async {
        OutboxStore.clear()
        defer { OutboxStore.clear() }
        let viewModel = PhoneWriteViewModel(
            sessionId: "6cf7e861",
            client: PocketWriteClient(apiBaseURL: nil, tokenProvider: { "must-not-be-used" })
        )

        viewModel.draft("Do not queue a build configuration error")
        viewModel.confirm()
        for _ in 0..<20 {
            if case .refused = viewModel.state { break }
            await Task.yield()
        }

        guard case .refused(let message) = viewModel.state else {
            return XCTFail("missing gateway configuration must be a terminal refusal, got \(viewModel.state)")
        }
        XCTAssertTrue(message.contains("not configured"))
        XCTAssertNil(OutboxStore.load(), "a terminal build configuration error must not remain queued as offline work")
    }

    #if canImport(CallKit) && canImport(PushKit)
    @MainActor
    func test_unconfigured_dial_host_does_not_start_callkit_or_pushkit() {
        let host = DialHost(gatewayURL: nil)

        XCTAssertNil(host.callManager)
    }
    #endif

    @MainActor
    func test_valid_configuration_starts_the_request_at_the_configured_host() async {
        GatewayEndpointStubURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GatewayEndpointStubURLProtocol.self]
        let client = PocketWriteClient(
            apiBaseURL: GatewayEndpoint.resolve("https://trusted-gateway.example"),
            urlSession: URLSession(configuration: configuration),
            tokenProvider: { "test-token" }
        )
        let proposal = PocketWriteClient.makeHumanMessageProposal(
            sessionId: "6cf7e861",
            message: "Use only the configured gateway"
        )
        let confirmation = GovernedWriteConfirmation(
            proposalId: proposal.id,
            confirmedProposalHash: proposal.proposalHash,
            confirmedAt: Date()
        )

        _ = try? await client.execute(proposal: proposal, confirmation: confirmation)

        XCTAssertEqual(GatewayEndpointStubURLProtocol.requestCount, 1)
        XCTAssertEqual(GatewayEndpointStubURLProtocol.lastHost, "trusted-gateway.example")
    }
}
