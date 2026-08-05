import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PocketCall
import PocketContracts
import XCTest
@testable import PocketSyncClient

private final class CheckpointTransportURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
    private static var requests: [URLRequest] = []

    static func reset(handler: @escaping (URLRequest) -> (HTTPURLResponse, Data)) {
        lock.lock()
        self.handler = handler
        requests = []
        lock.unlock()
    }

    static func capturedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let handler = Self.handler
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class SuspendedCheckpointURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var onStart: (() -> Void)?

    static func reset(onStart: @escaping () -> Void) {
        lock.lock()
        self.onStart = onStart
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let onStart = Self.onStart
        Self.lock.unlock()
        onStart?()
        // Intentionally remain suspended until the test cancels the URLSession task.
    }

    override func stopLoading() {}
}

final class CheckpointHTTPTransportTests: XCTestCase {
    private struct BundleKAV: Decodable {
        struct KnownAnswer: Decodable {
            let signatureBase64url: String
        }

        let kav: KnownAnswer
    }

    private struct WireEnvelope: Encodable {
        let bundle: PocketBundle
    }

    private func http(
        _ request: URLRequest,
        status: Int,
        headers: [String: String] = [:],
        responseURL: URL? = nil
    ) -> HTTPURLResponse {
        var allHeaders = ["Content-Type": "application/json"]
        for (key, value) in headers {
            allHeaders[key] = value
        }
        return HTTPURLResponse(
            url: responseURL ?? request.url!,
            statusCode: status,
            httpVersion: "HTTP/2",
            headerFields: allHeaders
        )!
    }

    private func makeTransport(
        origin: URL? = URL(string: "https://gateway.example.test")!,
        token: @escaping @Sendable () -> String? = { "session-token" },
        responseByteLimit: Int = HTTPCheckpointTransport.maximumResponseBytes,
        handler: @escaping (URLRequest) -> (HTTPURLResponse, Data)
    ) -> HTTPCheckpointTransport {
        CheckpointTransportURLProtocol.reset(handler: handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CheckpointTransportURLProtocol.self]
        return HTTPCheckpointTransport(
            gatewayBaseURL: origin,
            urlSession: URLSession(configuration: configuration),
            tokenProvider: token,
            responseByteLimit: responseByteLimit
        )
    }

    private func bundle(
        sessionId: String = "sess_demo_1",
        checkpointId: String = "cp_demo_1",
        sequenceStart: Int = 100,
        sequenceEnd: Int = 200,
        headline: String = "demo briefing",
        signingKeyId: String = "pocket-demo-phase-a"
    ) throws -> PocketBundle {
        let timestamp = Date(timeIntervalSince1970: 1_752_835_200)
        let evidence = EvidenceRef(
            id: "ev1",
            sessionId: sessionId,
            sequence: 150,
            agentId: "agent-a",
            snippet: "snippet",
            ts: timestamp
        )
        let summary = CheckpointSummary(
            checkpointId: checkpointId,
            headline: headline,
            summaryBaselineSchema: PocketBundle.expectedSummarySchema,
            grade: "A",
            perAgent: [
                AgentSummary(
                    agentId: "agent-a",
                    summary: "did the thing",
                    claims: [
                        Claim(
                            id: "c1",
                            text: "a fact",
                            kind: .fact,
                            evidenceIds: [evidence.id]
                        )
                    ],
                    evidence: [evidence]
                )
            ],
            risks: ["r1"],
            blockers: ["b1"]
        )
        return PocketBundle(
            contractsVersion: PocketContracts.version,
            checkpointId: checkpointId,
            sessionId: sessionId,
            sequenceStart: sequenceStart,
            sequenceEnd: sequenceEnd,
            summary: summary,
            evidence: [evidence],
            createdAt: timestamp,
            signature: try loadBundleKAVSignature(),
            signingKeyId: signingKeyId
        )
    }

    private func loadBundleKAVSignature() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../PocketContracts/Tests/PocketContractsTests/Fixtures/bundle_kav.json")
            .standardizedFileURL
        return try JSONDecoder().decode(BundleKAV.self, from: Data(contentsOf: url)).kav.signatureBase64url
    }

    private func body(_ bundle: PocketBundle) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return try encoder.encode(WireEnvelope(bundle: bundle))
    }

    func test_fetches_exact_checkpoint_with_bearer_no_store_and_verified_result() async throws {
        let expected = try bundle()
        XCTAssertNotNil(VerifiedBundle.verify(expected), "the committed KAV must mint the transport's return type")
        let expectedBody = try body(expected)
        let transport = makeTransport { request in
            (self.http(request, status: 200), expectedBody)
        }

        let result = try await transport.fetchExactCheckpoint(
            sessionId: "sess_demo_1",
            checkpointId: "cp_demo_1"
        )

        XCTAssertEqual(result.bundle, expected)
        let request = try XCTUnwrap(CheckpointTransportURLProtocol.capturedRequests().first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/checkpoint")
        XCTAssertNil(request.httpBody)
        let query = try XCTUnwrap(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
        )
        XCTAssertEqual(query.map(\.name), ["sessionId", "checkpointId"])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") }), [
            "sessionId": "sess_demo_1",
            "checkpointId": "cp_demo_1"
        ])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request.timeoutInterval, HTTPCheckpointTransport.requestTimeout)
    }

    func test_invalid_configuration_input_and_auth_fail_before_network() async {
        let invalidOrigins: [URL?] = [
            nil,
            URL(string: "http://gateway.example.test"),
            URL(string: "https://user@gateway.example.test"),
            URL(string: "https://gateway.example.test/prefix"),
            URL(string: "https://%67ateway.example.test")
        ]
        for origin in invalidOrigins {
            let tokenReads = LockedCheckpointCounter()
            let transport = makeTransport(origin: origin, token: {
                tokenReads.increment()
                return "must-not-be-read"
            }) { request in
                (self.http(request, status: 200), Data())
            }
            await expect(.notConfigured) {
                try await transport.fetchExactCheckpoint(sessionId: "session-A", checkpointId: "checkpoint-A")
            }
            XCTAssertEqual(tokenReads.value, 0)
            XCTAssertTrue(CheckpointTransportURLProtocol.capturedRequests().isEmpty)
        }

        for (sessionId, checkpointId) in [
            ("", "checkpoint-A"),
            (" session-A", "checkpoint-A"),
            ("session-A", ""),
            ("session-A", "checkpoint-A "),
            (String(repeating: "s", count: PocketBundle.capId + 1), "checkpoint-A")
        ] {
            let tokenReads = LockedCheckpointCounter()
            let transport = makeTransport(token: {
                tokenReads.increment()
                return "must-not-be-read"
            }) { request in
                (self.http(request, status: 200), Data())
            }
            await expect(.invalidRequest) {
                try await transport.fetchExactCheckpoint(sessionId: sessionId, checkpointId: checkpointId)
            }
            XCTAssertEqual(tokenReads.value, 0)
            XCTAssertTrue(CheckpointTransportURLProtocol.capturedRequests().isEmpty)
        }

        for (token, expected) in [
            (nil, CheckpointTransportError.notLoggedIn),
            ("", .notLoggedIn),
            ("token\r\nX-Injected: true", .invalidRequest)
        ] {
            let transport = makeTransport(token: { token }) { request in
                (self.http(request, status: 200), Data())
            }
            await expect(expected) {
                try await transport.fetchExactCheckpoint(sessionId: "session-A", checkpointId: "checkpoint-A")
            }
            XCTAssertTrue(CheckpointTransportURLProtocol.capturedRequests().isEmpty)
        }
    }

    func test_status_taxonomy_is_body_agnostic_and_matches_gateway_contract() async {
        let cases: [(Int, [String: String], CheckpointTransportError)] = [
            (401, [:], .reauthenticationRequired),
            (403, [:], .accessDenied),
            (404, [:], .service(statusCode: 404)),
            (429, ["Retry-After": "17"], .rateLimited(retryAfterSeconds: 17)),
            (503, [:], .service(statusCode: 503)),
            (204, [:], .invalidResponse),
            (302, [:], .invalidResponse)
        ]
        for (status, headers, expected) in cases {
            let transport = makeTransport { request in
                (
                    self.http(request, status: status, headers: headers),
                    Data(#"{"private":"must-not-surface"}"#.utf8)
                )
            }
            await expect(expected) {
                try await transport.fetchExactCheckpoint(sessionId: "session-A", checkpointId: "checkpoint-A")
            }
        }
    }

    func test_rejects_wrong_origin_content_type_identity_semantics_and_json() async throws {
        let valid = try bundle()
        let validBody = try body(valid)
        let wrongOrigin = makeTransport { _ in
            (
                HTTPURLResponse(
                    url: URL(string: "https://other.example.test/checkpoint")!,
                    statusCode: 200,
                    httpVersion: "HTTP/2",
                    headerFields: ["Content-Type": "application/json"]
                )!,
                validBody
            )
        }
        await expect(.invalidResponse) {
            try await wrongOrigin.fetchExactCheckpoint(sessionId: "sess_demo_1", checkpointId: "cp_demo_1")
        }

        let wrongContentType = makeTransport { request in
            (
                self.http(request, status: 200, headers: ["Content-Type": "text/html"]),
                validBody
            )
        }
        await expect(.invalidResponse) {
            try await wrongContentType.fetchExactCheckpoint(sessionId: "sess_demo_1", checkpointId: "cp_demo_1")
        }

        let invalidBundles: [PocketBundle] = [
            try bundle(sessionId: "sess_other"),
            try bundle(checkpointId: "cp_other"),
            try bundle(sequenceStart: 201, sequenceEnd: 200),
            try bundle(headline: "tampered briefing"),
            try bundle(signingKeyId: "unknown-signing-key")
        ]
        for invalid in invalidBundles {
            let invalidBody = try body(invalid)
            let transport = makeTransport { request in
                (self.http(request, status: 200), invalidBody)
            }
            await expect(.invalidData) {
                try await transport.fetchExactCheckpoint(sessionId: "sess_demo_1", checkpointId: "cp_demo_1")
            }
        }

        let malformed = makeTransport { request in
            (self.http(request, status: 200), Data(#"{"bundle":null}"#.utf8))
        }
        await expect(.invalidData) {
            try await malformed.fetchExactCheckpoint(sessionId: "sess_demo_1", checkpointId: "cp_demo_1")
        }
    }

    func test_identity_match_is_exact_utf8_not_unicode_canonical_equivalence() {
        let composed = "caf\u{00E9}"
        let decomposed = "cafe\u{0301}"
        XCTAssertEqual(composed, decomposed)
        XCTAssertFalse(HTTPCheckpointTransport.byteExact(composed, decomposed))
    }

    func test_streaming_response_cap_rejects_declared_and_actual_overflow() async {
        let declared = makeTransport(responseByteLimit: 64) { request in
            (
                self.http(request, status: 200, headers: ["Content-Length": "65"]),
                Data()
            )
        }
        await expect(.invalidData) {
            try await declared.fetchExactCheckpoint(sessionId: "session-A", checkpointId: "checkpoint-A")
        }

        let actual = makeTransport(responseByteLimit: 64) { request in
            (self.http(request, status: 200), Data(repeating: 0x7B, count: 65))
        }
        await expect(.invalidData) {
            try await actual.fetchExactCheckpoint(sessionId: "session-A", checkpointId: "checkpoint-A")
        }
    }

    func test_token_rotation_cancels_both_success_and_old_unauthorized_responses() async throws {
        let validBody = try body(try bundle())
        for status in [200, 401] {
            let token = LockedCheckpointToken("principal-A")
            let transport = makeTransport(token: { token.value }) { request in
                token.set("principal-B")
                return (self.http(request, status: status), validBody)
            }
            await expect(.cancelled) {
                try await transport.fetchExactCheckpoint(sessionId: "sess_demo_1", checkpointId: "cp_demo_1")
            }
        }
    }

    func test_task_cancellation_maps_to_cancelled() async {
        let started = expectation(description: "checkpoint request started")
        SuspendedCheckpointURLProtocol.reset { started.fulfill() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SuspendedCheckpointURLProtocol.self]
        let transport = HTTPCheckpointTransport(
            gatewayBaseURL: URL(string: "https://gateway.example.test")!,
            urlSession: URLSession(configuration: configuration),
            tokenProvider: { "session-token" }
        )
        let task = Task {
            try await transport.fetchExactCheckpoint(sessionId: "session-A", checkpointId: "checkpoint-A")
        }
        await fulfillment(of: [started], timeout: 2)

        task.cancel()

        await expect(.cancelled) {
            try await task.value
        }
    }

    func test_already_cancelled_task_fails_before_auth_or_network() async {
        let tokenReads = LockedCheckpointCounter()
        let transport = makeTransport(token: {
            tokenReads.increment()
            return "must-not-be-read"
        }) { request in
            XCTFail("an already-cancelled fetch must not reach the network")
            return (self.http(request, status: 500), Data())
        }
        let task = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            return try await transport.fetchExactCheckpoint(
                sessionId: "session-A",
                checkpointId: "checkpoint-A"
            )
        }
        task.cancel()

        await expect(.cancelled) {
            try await task.value
        }
        XCTAssertEqual(tokenReads.value, 0)
        XCTAssertTrue(CheckpointTransportURLProtocol.capturedRequests().isEmpty)
    }

    func test_redirect_delegate_refuses_redirect_target() {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://gateway.example.test/checkpoint")!)
        defer { task.cancel() }
        let response = HTTPURLResponse(
            url: task.originalRequest!.url!,
            statusCode: 307,
            httpVersion: "HTTP/2",
            headerFields: ["Location": "https://other.example.test/checkpoint"]
        )!
        let redirectedRequest = URLRequest(url: URL(string: "https://other.example.test/checkpoint")!)
        var accepted: URLRequest?

        CheckpointNoRedirectDelegate.shared.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: redirectedRequest,
            completionHandler: { accepted = $0 }
        )

        XCTAssertNil(accepted)
    }

    private func expect<T>(
        _ expected: CheckpointTransportError,
        operation: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as CheckpointTransportError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }
}

private final class LockedCheckpointToken: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String

    init(_ value: String) {
        storage = value
    }

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ value: String) {
        lock.lock()
        storage = value
        lock.unlock()
    }
}

private final class LockedCheckpointCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}
