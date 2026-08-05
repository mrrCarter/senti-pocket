import Foundation
import XCTest
import PocketCall
import PocketContracts
import PocketReasoning
@testable import SentiPocketApp

private final class GatewayEndpointStubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var requestCountStorage = 0
    private static var lastHostStorage: String?
    private static var lastTimeoutIntervalStorage: TimeInterval?
    private static var stopLoadingCountStorage = 0
    private static var responseHeadersDeliveredCountStorage = 0
    private static var responseStatus: Int?
    private static var responseBody = Data()
    private static var responseHeaders = ["Content-Type": "application/json"]
    private static var responseURL: URL?
    private static var finishLoading = true
    private static var requestHook: (@Sendable () -> Void)?

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCountStorage
    }

    static var lastHost: String? {
        lock.lock()
        defer { lock.unlock() }
        return lastHostStorage
    }

    static var lastTimeoutInterval: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return lastTimeoutIntervalStorage
    }

    static var stopLoadingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return stopLoadingCountStorage
    }

    static var responseHeadersDeliveredCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return responseHeadersDeliveredCountStorage
    }

    static func reset() {
        lock.lock()
        requestCountStorage = 0
        lastHostStorage = nil
        lastTimeoutIntervalStorage = nil
        stopLoadingCountStorage = 0
        responseHeadersDeliveredCountStorage = 0
        responseStatus = nil
        responseBody = Data()
        responseHeaders = ["Content-Type": "application/json"]
        responseURL = nil
        finishLoading = true
        requestHook = nil
        lock.unlock()
    }

    static func respond(
        status: Int,
        body: Data = Data("{}".utf8),
        headers: [String: String] = ["Content-Type": "application/json"],
        responseURL: URL? = nil,
        finishLoading: Bool = true,
        requestHook: (@Sendable () -> Void)? = nil
    ) {
        lock.lock()
        responseStatus = status
        responseBody = body
        responseHeaders = headers
        self.responseURL = responseURL
        self.finishLoading = finishLoading
        self.requestHook = requestHook
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requestCountStorage += 1
        Self.lastHostStorage = request.url?.host
        Self.lastTimeoutIntervalStorage = request.timeoutInterval
        let status = Self.responseStatus
        let body = Self.responseBody
        let headers = Self.responseHeaders
        let responseURL = Self.responseURL
        let finishLoading = Self.finishLoading
        let requestHook = Self.requestHook
        Self.lock.unlock()
        requestHook?()
        if let status,
           let url = responseURL ?? request.url,
           let response = HTTPURLResponse(
               url: url,
               statusCode: status,
               httpVersion: "HTTP/1.1",
               headerFields: headers
            ) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            Self.lock.lock()
            Self.responseHeadersDeliveredCountStorage += 1
            Self.lock.unlock()
            if finishLoading {
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            }
            return
        }
        client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
    }

    override func stopLoading() {
        Self.lock.lock()
        Self.stopLoadingCountStorage += 1
        Self.lock.unlock()
    }
}

final class GatewayEndpointTests: XCTestCase {
    func test_phone_and_dial_session_identity_is_utf8_byte_exact() {
        let composed = "session-caf\u{00E9}"
        let decomposed = "session-cafe\u{0301}"
        XCTAssertEqual(composed, decomposed, "precondition: Swift String equality is Unicode-canonical")
        XCTAssertNotEqual(UTF8ExactIdentity(composed), UTF8ExactIdentity(decomposed))
        XCTAssertFalse(UTF8ExactIdentity.matches(Optional(composed), decomposed))

        let selection = DialSessionSelectionGate()
        selection.select(composed)
        XCTAssertTrue(selection.permits(composed))
        XCTAssertFalse(selection.permits(decomposed))
    }

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

    @MainActor
    func test_unselected_dial_is_rejected_before_hydration_request() async {
        let gate = DialSessionSelectionGate()
        gate.select("session-B")
        var hydrationCalls = 0
        let hydrator = SelectedSessionDialHydrator(
            selectionGate: gate,
            isBindingAuthorized: { _, _ in true },
            hydrate: { state in
                hydrationCalls += 1
                guard case .needsHydration(_, let core) = state else {
                    throw DialHostError.sessionNotSelected
                }
                return RenderableRing(
                    core: core,
                    message: "must not hydrate",
                    options: [],
                    evidenceSeqs: [],
                    confidence: nil
                )
            }
        )
        let core = RingCore(
            id: "dial-A",
            kind: "go",
            priority: "high",
            callerName: "Senti",
            sessionId: "session-A",
            checkpointId: nil,
            binding: DeviceRingBindingFence(
                id: "bind_0123456789abcdef0123456789abcdef",
                revision: 1
            )
        )

        do {
            _ = try await hydrator.hydrate(.needsHydration(id: core.id, core: core))
            XCTFail("an unselected session must fail before hydration")
        } catch DialHostError.sessionNotSelected {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(hydrationCalls, 0, "an old/unselected push must initiate zero authenticated hydration calls")
    }

    @MainActor
    func test_binding_revision_is_rechecked_after_hydration_to_close_answer_toctou() async {
        let gate = DialSessionSelectionGate()
        gate.select("session-A")
        var bindingIsCurrent = true
        let fence = DeviceRingBindingFence(
            id: "bind_0123456789abcdef0123456789abcdef",
            revision: 7
        )
        let core = RingCore(
            id: "dial-A",
            kind: "go",
            priority: "high",
            callerName: "Senti",
            sessionId: "session-A",
            checkpointId: nil,
            binding: fence
        )
        let hydrator = SelectedSessionDialHydrator(
            selectionGate: gate,
            isBindingAuthorized: { sessionId, candidate in
                bindingIsCurrent && sessionId == core.sessionId && candidate == fence
            },
            hydrate: { _ in
                bindingIsCurrent = false
                return RenderableRing(
                    core: core,
                    message: "must not run after rebind",
                    options: [],
                    evidenceSeqs: [],
                    confidence: nil
                )
            }
        )

        do {
            _ = try await hydrator.hydrate(.needsHydration(id: core.id, core: core))
            XCTFail("a binding replaced during hydration must fail before the governed flow")
        } catch DialHostError.sessionNotSelected {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
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

    @MainActor
    func test_write_401_invalidates_authentication_and_does_not_cross_account_boundary() async {
        OutboxStore.clear()
        defer {
            OutboxStore.clear()
            GatewayEndpointStubURLProtocol.reset()
        }
        GatewayEndpointStubURLProtocol.reset()
        GatewayEndpointStubURLProtocol.respond(
            status: 401,
            body: Data(#"{"error":"unauthorized"}"#.utf8)
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GatewayEndpointStubURLProtocol.self]
        var invalidationCount = 0
        let viewModel = PhoneWriteViewModel(
            sessionId: "session-A",
            client: PocketWriteClient(
                apiBaseURL: URL(string: "https://trusted-gateway.example"),
                urlSession: URLSession(configuration: configuration),
                tokenProvider: { "expired-token" }
            ),
            onReauthenticationRequired: { _ in invalidationCount += 1 }
        )

        viewModel.draft("Keep this confirmed intent for after sign-in")
        viewModel.confirm()
        // URLProtocol completes on a session-owned queue; zero-time yields can repeatedly resume
        // this MainActor test before that queue publishes the 401 transition on hosted simulators.
        for _ in 0..<100 {
            if invalidationCount == 1 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(invalidationCount, 1)
        guard case .refused(let message) = viewModel.state else {
            return XCTFail("an expired principal must make the old confirmation non-retryable")
        }
        XCTAssertTrue(message.contains("review"))
        XCTAssertNil(OutboxStore.load(), "a confirmed intent must not survive into a potentially different account")
    }

    func test_reasoning_401_signals_the_shared_authentication_gate() async {
        GatewayEndpointStubURLProtocol.reset()
        defer { GatewayEndpointStubURLProtocol.reset() }
        GatewayEndpointStubURLProtocol.respond(status: 401)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GatewayEndpointStubURLProtocol.self]
        let signal = LockedCounter()
        let client = GatewayReasoningHTTPClient(
            apiBaseURL: URL(string: "https://trusted-gateway.example")!,
            urlSession: URLSession(configuration: configuration),
            tokenProvider: { "expired-token" },
            onReauthenticationRequired: { _ in signal.increment() }
        )

        do {
            _ = try await client.postBrief(sessionId: "session-A", checkpointId: nil)
            XCTFail("a 401 must fail reasoning")
        } catch GatewayReasoningError.reauthenticationRequired {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(signal.value, 1)
    }

    func test_reasoning_request_uses_endpoint_specific_deadline_under_shared_resource_wall() async throws {
        GatewayEndpointStubURLProtocol.reset()
        defer { GatewayEndpointStubURLProtocol.reset() }
        GatewayEndpointStubURLProtocol.respond(
            status: 200,
            body: Data(
                #"{"segments":[],"grounded":false,"checkpointId":"cp-1","contractsVersion":"0.1.8"}"#.utf8
            )
        )
        let configuration = SentiHTTPTransportPolicy.makeConfiguration()
        configuration.protocolClasses = [GatewayEndpointStubURLProtocol.self]
        let client = GatewayReasoningHTTPClient(
            apiBaseURL: URL(string: "https://trusted-gateway.example")!,
            urlSession: URLSession(configuration: configuration),
            tokenProvider: { "valid-token" }
        )

        _ = try await client.postBrief(sessionId: "session-A", checkpointId: "cp-1")

        XCTAssertEqual(configuration.timeoutIntervalForRequest, 15, accuracy: 0.001)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 60, accuracy: 0.001)
        XCTAssertEqual(GatewayEndpointStubURLProtocol.lastTimeoutInterval ?? 0, 45, accuracy: 0.001)
        XCTAssertEqual(GatewayEndpointStubURLProtocol.requestCount, 1)
    }

    func test_reasoning_redirect_delegate_refuses_the_redirect_request() throws {
        let originalURL = try XCTUnwrap(URL(string: "https://trusted-gateway.example/brief"))
        let redirectedURL = try XCTUnwrap(URL(string: "https://attacker.example/brief"))
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: originalURL,
                statusCode: 307,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": redirectedURL.absoluteString]
            )
        )
        let completion = expectation(description: "redirect decision")
        var acceptedRedirect: URLRequest?

        GatewayReasoningNoRedirectDelegate.shared.urlSession(
            .shared,
            task: URLSession.shared.dataTask(with: originalURL),
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: redirectedURL)
        ) { request in
            acceptedRedirect = request
            completion.fulfill()
        }

        wait(for: [completion], timeout: 1)
        XCTAssertNil(acceptedRedirect, "the bearer-scoped request must never follow a redirect")
    }

    func test_reasoning_rejects_wrong_response_url_and_missing_or_wrong_json_mime() async {
        let validBody = Data(
            #"{"segments":[],"grounded":false,"checkpointId":"cp-1","contractsVersion":"0.1.8"}"#.utf8
        )
        let cases: [(URL?, [String: String])] = [
            (URL(string: "https://attacker.example/brief"), ["Content-Type": "application/json"]),
            (nil, [:]),
            (nil, ["Content-Type": "text/plain"]),
        ]

        for (responseURL, headers) in cases {
            GatewayEndpointStubURLProtocol.reset()
            GatewayEndpointStubURLProtocol.respond(
                status: 200,
                body: validBody,
                headers: headers,
                responseURL: responseURL
            )
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [GatewayEndpointStubURLProtocol.self]
            let client = GatewayReasoningHTTPClient(
                apiBaseURL: URL(string: "https://trusted-gateway.example")!,
                urlSession: URLSession(configuration: configuration),
                tokenProvider: { "valid-token" }
            )

            do {
                _ = try await client.postBrief(sessionId: "session-A", checkpointId: "cp-1")
                XCTFail("response URL and MIME must be admitted exactly")
            } catch GatewayReasoningError.malformedResponse {
                // expected
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
        GatewayEndpointStubURLProtocol.reset()
    }

    func test_already_cancelled_reasoning_reads_no_credential_and_starts_no_request() async {
        GatewayEndpointStubURLProtocol.reset()
        defer { GatewayEndpointStubURLProtocol.reset() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GatewayEndpointStubURLProtocol.self]
        let tokenReads = LockedCounter()
        let client = GatewayReasoningHTTPClient(
            apiBaseURL: URL(string: "https://trusted-gateway.example")!,
            urlSession: URLSession(configuration: configuration),
            tokenProvider: {
                tokenReads.increment()
                return "valid-token"
            }
        )
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.postBrief(sessionId: "session-A", checkpointId: "cp-1")
        }

        do {
            _ = try await task.value
            XCTFail("an already-cancelled operation must stop before reading authority")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(tokenReads.value, 0)
        XCTAssertEqual(GatewayEndpointStubURLProtocol.requestCount, 0)
    }

    func test_reasoning_cancellation_after_headers_cancels_the_underlying_stream() async {
        GatewayEndpointStubURLProtocol.reset()
        defer { GatewayEndpointStubURLProtocol.reset() }
        GatewayEndpointStubURLProtocol.respond(status: 200, finishLoading: false)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GatewayEndpointStubURLProtocol.self]
        let tokenReads = LockedCounter()
        let client = GatewayReasoningHTTPClient(
            apiBaseURL: URL(string: "https://trusted-gateway.example")!,
            urlSession: URLSession(configuration: configuration),
            tokenProvider: {
                tokenReads.increment()
                return "valid-token"
            }
        )
        let task = Task {
            try await client.postBrief(sessionId: "session-A", checkpointId: "cp-1")
        }
        for _ in 0..<100 {
            if GatewayEndpointStubURLProtocol.responseHeadersDeliveredCount == 1,
               tokenReads.value >= 2 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(
            GatewayEndpointStubURLProtocol.responseHeadersDeliveredCount,
            1,
            "the test must cancel only after the response headers were delivered"
        )
        XCTAssertGreaterThanOrEqual(
            tokenReads.value,
            2,
            "the client must resume from bytes(for:) and revalidate authority before cancellation"
        )
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("a cancelled response stream must not decode or publish")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        for _ in 0..<100 {
            if GatewayEndpointStubURLProtocol.stopLoadingCount > 0 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThan(GatewayEndpointStubURLProtocol.stopLoadingCount, 0)
    }

    func test_reasoning_response_enforces_the_exact_wire_cap() async throws {
        GatewayEndpointStubURLProtocol.reset()
        defer { GatewayEndpointStubURLProtocol.reset() }
        let body = Data(
            #"{"segments":[],"grounded":false,"checkpointId":"cp-1","contractsVersion":"0.1.8"}"#.utf8
        )
        GatewayEndpointStubURLProtocol.respond(
            status: 200,
            body: body
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GatewayEndpointStubURLProtocol.self]
        let exactClient = GatewayReasoningHTTPClient(
            apiBaseURL: URL(string: "https://trusted-gateway.example")!,
            urlSession: URLSession(configuration: configuration),
            tokenProvider: { "valid-token" },
            responseByteLimit: body.count
        )
        _ = try await exactClient.postBrief(sessionId: "session-A", checkpointId: "cp-1")

        GatewayEndpointStubURLProtocol.respond(status: 200, body: body)
        let undersizedClient = GatewayReasoningHTTPClient(
            apiBaseURL: URL(string: "https://trusted-gateway.example")!,
            urlSession: URLSession(configuration: configuration),
            tokenProvider: { "valid-token" },
            responseByteLimit: body.count - 1
        )
        do {
            _ = try await undersizedClient.postBrief(sessionId: "session-A", checkpointId: "cp-1")
            XCTFail("an oversized reasoning response must fail before decode")
        } catch GatewayReasoningError.malformedResponse {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_reasoning_rejects_declared_content_length_before_body_accumulation() async {
        GatewayEndpointStubURLProtocol.reset()
        defer { GatewayEndpointStubURLProtocol.reset() }
        GatewayEndpointStubURLProtocol.respond(
            status: 200,
            body: Data("{}".utf8),
            headers: [
                "Content-Type": "application/json",
                "Content-Length": "65",
            ]
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GatewayEndpointStubURLProtocol.self]
        let client = GatewayReasoningHTTPClient(
            apiBaseURL: URL(string: "https://trusted-gateway.example")!,
            urlSession: URLSession(configuration: configuration),
            tokenProvider: { "valid-token" },
            responseByteLimit: 64
        )

        do {
            _ = try await client.postBrief(sessionId: "session-A", checkpointId: "cp-1")
            XCTFail("declared body beyond the cap must fail before decode")
        } catch GatewayReasoningError.malformedResponse {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    @MainActor
    func test_late_write_401_from_old_principal_does_not_invalidate_or_clear_new_principal() async {
        OutboxStore.clear()
        GatewayEndpointStubURLProtocol.reset()
        defer {
            OutboxStore.clear()
            GatewayEndpointStubURLProtocol.reset()
        }
        let token = LockedTokenBox("principal-A")
        let proposalB = PocketWriteClient.makeHumanMessageProposal(
            sessionId: "session-B",
            message: "Principal B owns this outbox",
            at: Date(timeIntervalSince1970: 1_784_000_000)
        )
        let confirmationB = GovernedWriteConfirmation(
            proposalId: proposalB.id,
            confirmedProposalHash: proposalB.proposalHash,
            confirmedAt: Date(timeIntervalSince1970: 1_784_000_001)
        )
        let intentB = PersistedWriteIntent(proposal: proposalB, confirmation: confirmationB)
        GatewayEndpointStubURLProtocol.respond(
            status: 401,
            requestHook: {
                token.value = "principal-B"
                OutboxStore.save(intentB)
            }
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GatewayEndpointStubURLProtocol.self]
        var invalidationCount = 0
        let viewModel = PhoneWriteViewModel(
            sessionId: "session-A",
            client: PocketWriteClient(
                apiBaseURL: URL(string: "https://trusted-gateway.example"),
                urlSession: URLSession(configuration: configuration),
                tokenProvider: { token.value }
            ),
            onReauthenticationRequired: { _ in invalidationCount += 1 }
        )

        viewModel.draft("Principal A request")
        viewModel.confirm()
        // URLProtocol callbacks arrive on a session-owned queue. `Task.yield()` alone does not
        // guarantee that queue gets scheduled before this MainActor test resumes, especially on
        // a freshly booted CI simulator. Use a bounded number of real-time suspensions while
        // still failing closed if the stale-response transition never arrives.
        for _ in 0..<100 {
            if case .refused = viewModel.state { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        guard case .refused(let refusal) = viewModel.state else {
            return XCTFail("the stale response path must complete as a refusal")
        }
        XCTAssertTrue(refusal.contains("earlier sign-in"))
        XCTAssertEqual(invalidationCount, 0, "a stale A response must never sign principal B out")
        XCTAssertEqual(OutboxStore.load(), intentB, "a stale A response must never clear B's confirmed outbox")
    }

    func test_late_reasoning_401_from_old_principal_is_superseded_without_auth_signal() async {
        GatewayEndpointStubURLProtocol.reset()
        defer { GatewayEndpointStubURLProtocol.reset() }
        let token = LockedTokenBox("principal-A")
        GatewayEndpointStubURLProtocol.respond(
            status: 401,
            requestHook: { token.value = "principal-B" }
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GatewayEndpointStubURLProtocol.self]
        let signal = LockedCounter()
        let client = GatewayReasoningHTTPClient(
            apiBaseURL: URL(string: "https://trusted-gateway.example")!,
            urlSession: URLSession(configuration: configuration),
            tokenProvider: { token.value },
            onReauthenticationRequired: { _ in signal.increment() }
        )

        do {
            _ = try await client.postBrief(sessionId: "session-A", checkpointId: nil)
            XCTFail("the stale response must fail")
        } catch GatewayReasoningError.supersededAuthentication {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(signal.value, 0)
    }

    func test_late_reasoning_success_or_service_error_from_old_principal_is_superseded() async {
        let validBody = Data(
            #"{"segments":[],"grounded":false,"checkpointId":"cp-1","contractsVersion":"0.1.8"}"#.utf8
        )
        for (status, body) in [(200, validBody), (503, Data("{}".utf8))] {
            GatewayEndpointStubURLProtocol.reset()
            let token = LockedTokenBox("principal-A")
            GatewayEndpointStubURLProtocol.respond(
                status: status,
                body: body,
                requestHook: { token.value = "principal-B" }
            )
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [GatewayEndpointStubURLProtocol.self]
            let client = GatewayReasoningHTTPClient(
                apiBaseURL: URL(string: "https://trusted-gateway.example")!,
                urlSession: URLSession(configuration: configuration),
                tokenProvider: { token.value }
            )

            do {
                _ = try await client.postBrief(sessionId: "session-A", checkpointId: nil)
                XCTFail("status \(status) from an old principal must not escape")
            } catch GatewayReasoningError.supersededAuthentication {
                // expected
            } catch {
                XCTFail("unexpected error for status \(status): \(error)")
            }
        }
        GatewayEndpointStubURLProtocol.reset()
    }

    func test_malformed_reasoning_from_a_rotated_principal_is_superseded() async {
        GatewayEndpointStubURLProtocol.reset()
        defer { GatewayEndpointStubURLProtocol.reset() }
        GatewayEndpointStubURLProtocol.respond(status: 200, body: Data("{".utf8))
        let tokenSequence = LockedTokenSequence(
            initialValue: "principal-A",
            replacementValue: "principal-B",
            initialReadCount: 3
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GatewayEndpointStubURLProtocol.self]
        let client = GatewayReasoningHTTPClient(
            apiBaseURL: URL(string: "https://trusted-gateway.example")!,
            urlSession: URLSession(configuration: configuration),
            tokenProvider: { tokenSequence.next() }
        )

        do {
            _ = try await client.postBrief(sessionId: "session-A", checkpointId: "cp-1")
            XCTFail("a stale malformed response must not publish principal A's error into principal B")
        } catch GatewayReasoningError.supersededAuthentication {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(tokenSequence.readCount, 4)
    }

    @MainActor
    func test_voice_confirm_after_selection_revocation_never_arms_a_write() async {
        OutboxStore.clear()
        GatewayEndpointStubURLProtocol.reset()
        defer {
            OutboxStore.clear()
            GatewayEndpointStubURLProtocol.reset()
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GatewayEndpointStubURLProtocol.self]
        var isAuthorized = true
        let viewModel = PhoneWriteViewModel(
            sessionId: "session-A",
            client: PocketWriteClient(
                apiBaseURL: URL(string: "https://trusted-gateway.example"),
                urlSession: URLSession(configuration: configuration),
                tokenProvider: { "valid-token" }
            ),
            isWriteAuthorized: { isAuthorized }
        )
        let adapter = PhoneWriteAdapter(
            viewModel,
            isWriteAuthorized: { isAuthorized }
        )
        await adapter.draft("Late speech result must not post")
        guard case .confirming = viewModel.state else {
            return XCTFail("precondition: the authorized draft must be armed")
        }

        isAuthorized = false
        let result = await adapter.confirmAndPost()

        guard case .refused(let reason) = result else {
            return XCTFail("a late confirm after revocation must be refused")
        }
        XCTAssertTrue(reason.contains("changed"))
        XCTAssertEqual(GatewayEndpointStubURLProtocol.requestCount, 0)
        XCTAssertNil(OutboxStore.load(), "revoked voice confirmation must queue nothing")
    }

    #if canImport(CallKit) && canImport(PushKit)
    @MainActor
    func test_same_session_binding_aba_cannot_revive_a_hydrated_write() async {
        OutboxStore.clear()
        GatewayEndpointStubURLProtocol.reset()
        defer {
            OutboxStore.clear()
            GatewayEndpointStubURLProtocol.reset()
        }
        let sessionId = "session-A"
        let bindingA = DeviceRingBindingFence(
            id: "bind_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            revision: 1
        )
        let bindingB = DeviceRingBindingFence(
            id: "bind_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            revision: 2
        )
        let hydratedCoreA = RingCore(
            id: "dial-A",
            kind: "go",
            priority: "high",
            callerName: "Senti",
            sessionId: sessionId,
            checkpointId: nil,
            binding: bindingA
        )
        let selectionGate = DialSessionSelectionGate()
        selectionGate.select(sessionId)
        var currentBinding: DeviceRingBindingFence? = bindingA
        let isWriteAuthorized: @MainActor () -> Bool = {
            selectionGate.permits(hydratedCoreA.sessionId)
                && hydratedCoreA.binding == currentBinding
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GatewayEndpointStubURLProtocol.self]
        let viewModel = PhoneWriteViewModel(
            sessionId: sessionId,
            client: PocketWriteClient(
                apiBaseURL: URL(string: "https://trusted-gateway.example"),
                urlSession: URLSession(configuration: configuration),
                tokenProvider: { "principal-B-token" }
            ),
            isWriteAuthorized: isWriteAuthorized
        )
        let adapter = PhoneWriteAdapter(viewModel, isWriteAuthorized: isWriteAuthorized)
        await adapter.draft("Do not let principal B post principal A's hydrated answer")
        guard case .confirming = viewModel.state else {
            return XCTFail("precondition: binding A should authorize the hydrated draft")
        }

        selectionGate.select(nil)
        currentBinding = nil
        selectionGate.select(sessionId)
        currentBinding = bindingB
        let result = await adapter.confirmAndPost()

        guard case .refused(let reason) = result else {
            return XCTFail("same-session binding ABA must refuse the old hydrated flow")
        }
        XCTAssertTrue(reason.contains("changed"))
        XCTAssertEqual(GatewayEndpointStubURLProtocol.requestCount, 0)
        XCTAssertNil(OutboxStore.load(), "principal A's intent must not enter principal B's outbox")
    }
    #endif

    @MainActor
    func test_revocation_between_confirm_and_send_task_starts_no_request() async {
        OutboxStore.clear()
        GatewayEndpointStubURLProtocol.reset()
        defer {
            OutboxStore.clear()
            GatewayEndpointStubURLProtocol.reset()
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GatewayEndpointStubURLProtocol.self]
        var isAuthorized = true
        let viewModel = PhoneWriteViewModel(
            sessionId: "session-A",
            client: PocketWriteClient(
                apiBaseURL: URL(string: "https://trusted-gateway.example"),
                urlSession: URLSession(configuration: configuration),
                tokenProvider: { "valid-token" }
            ),
            isWriteAuthorized: { isAuthorized }
        )

        viewModel.draft("Fence the executor-turn gap")
        viewModel.confirm()
        isAuthorized = false
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(GatewayEndpointStubURLProtocol.requestCount, 0)
        guard case .pending(let message) = viewModel.state else {
            return XCTFail("the confirmed intent should remain session-bound and retryable, never posted")
        }
        XCTAssertTrue(message.contains("session-A"))
        XCTAssertEqual(OutboxStore.load()?.proposal.targetSessionId, "session-A")
    }

    @MainActor
    func test_hangup_after_explicit_confirmation_retains_one_durable_operation() async {
        OutboxStore.clear()
        GatewayEndpointStubURLProtocol.reset()
        defer {
            OutboxStore.clear()
            GatewayEndpointStubURLProtocol.reset()
        }
        let cancellation = LockedCancellationBox()
        GatewayEndpointStubURLProtocol.respond(
            status: 503,
            body: Data("{\"reason\":\"temporarily busy\"}".utf8),
            requestHook: { cancellation.cancel() }
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GatewayEndpointStubURLProtocol.self]
        let viewModel = PhoneWriteViewModel(
            sessionId: "session-A",
            client: PocketWriteClient(
                apiBaseURL: URL(string: "https://trusted-gateway.example"),
                urlSession: URLSession(configuration: configuration),
                tokenProvider: { "valid-token" }
            )
        )
        let adapter = PhoneWriteAdapter(viewModel)
        await adapter.draft("This explicitly confirmed operation must survive hangup")

        let callTask = Task { @MainActor in
            await adapter.confirmAndPost()
        }
        cancellation.install { callTask.cancel() }
        let result = await callTask.value
        guard case .pending = result else {
            return XCTFail("post-confirm hangup must report a durable pending operation, got \(result)")
        }
        for _ in 0..<50 {
            if case .pending = viewModel.state { break }
            await Task.yield()
        }

        XCTAssertEqual(GatewayEndpointStubURLProtocol.requestCount, 1, "the committed operation starts at most once")
        guard case .pending = viewModel.state else {
            return XCTFail("the transient result must settle as retryable pending")
        }
        XCTAssertEqual(OutboxStore.load()?.proposal.targetSessionId, "session-A",
                       "hangup after commit must not erase the reconciliation record")
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private final class LockedTokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: String

    init(_ value: String) {
        storedValue = value
    }

    var value: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }
}

private final class LockedTokenSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let initialValue: String
    private let replacementValue: String
    private let initialReadCount: Int
    private var storedReadCount = 0

    init(initialValue: String, replacementValue: String, initialReadCount: Int) {
        self.initialValue = initialValue
        self.replacementValue = replacementValue
        self.initialReadCount = initialReadCount
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedReadCount
    }

    func next() -> String {
        lock.lock()
        storedReadCount += 1
        let value = storedReadCount <= initialReadCount ? initialValue : replacementValue
        lock.unlock()
        return value
    }
}

private final class LockedCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?

    func install(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        self.action = action
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let action = self.action
        lock.unlock()
        action?()
    }
}
