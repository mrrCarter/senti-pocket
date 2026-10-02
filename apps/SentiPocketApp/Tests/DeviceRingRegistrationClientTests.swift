import XCTest
@testable import SentiPocketApp

/// Locks DeviceRingRegistrationClient — the device-side outbound-binding (authed POST /dial/register) that lets a ring
/// be ADDRESSED to this device. Uses a URLProtocol stub (the DialHydrationClientTests pattern) + the injectable
/// tokenProvider, so the POST is hermetic. The load-bearing test is `no humanId in the body` (warden gate #2:
/// the gateway derives humanId from auth; a body humanId would be a confused-deputy vector).
final class RegisterStubURLProtocol: URLProtocol {
    static let lock = NSLock()
    static var status: Int = 200
    static var networkError: URLError?
    static var lastRequest: URLRequest?
    static var lastBody: Data?
    static var responseBody = Data()
    static var responseBodyProvider: ((Data) -> Data)?
    static var responseProvider: ((Data) -> (status: Int, body: Data))?
    static var requestCount = 0
    static var requestedPaths: [String] = []
    static var requests: [(path: String, body: Data)] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.lastRequest = request
        let requestBody = Self.bodyData(request)
        Self.lastBody = requestBody
        Self.requestCount += 1
        Self.requestedPaths.append(request.url?.path ?? "")
        Self.requests.append((request.url?.path ?? "", requestBody))
        let fixedStatus = Self.status
        let err = Self.networkError
        let fixedResponseBody = Self.responseBody
        let responseBodyProvider = Self.responseBodyProvider
        let responseProvider = Self.responseProvider
        Self.lock.unlock()
        let provided = responseProvider?(requestBody)
        let status = provided?.status ?? fixedStatus
        let responseBody = provided?.body ?? responseBodyProvider?(requestBody) ?? fixedResponseBody

        if let err {
            client?.urlProtocol(self, didFailWithError: err)
            return
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    /// URLSession moves `httpBody` into `httpBodyStream` by the time a URLProtocol sees the request — read the stream.
    static func bodyData(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(); let bufSize = 4096; var buf = [UInt8](repeating: 0, count: bufSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buf, maxLength: bufSize)
            if read <= 0 { break }
            data.append(buf, count: read)
        }
        return data
    }
}

final class DeviceRingRegistrationClientTests: XCTestCase {

    private let base = URL(string: "https://gw.example.com")!
    private let now: Int64 = 1_770_000_000

    private func bindingResponse(
        sessionId: String = "6cf7e861",
        generation: String = "1",
        bindingId: String = String(repeating: "i", count: 24),
        bindingRevision: String = String(repeating: "r", count: 32)
    ) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "registered": true,
            "registryVersion": 2,
            "sessionId": sessionId,
            "platform": "apns",
            "installationGeneration": generation,
            "bindingId": bindingId,
            "bindingRevision": bindingRevision,
            "leaseExpiresAtSec": now + 600,
        ])
    }

    private func attempt(
        sessionId: String = "6cf7e861",
        generation: String = "1",
        voipToken: String = "aabbcc"
    ) -> DeviceRingRegistrationAttempt {
        DeviceRingRegistrationAttempt(
            installationId: String(repeating: "A", count: 43),
            installationGeneration: generation,
            sessionId: sessionId,
            tokenFingerprint: DeviceRingTokenFingerprint.make(voipToken)
        )
    }

    private func setResponseBody(_ data: Data) {
        RegisterStubURLProtocol.lock.lock()
        RegisterStubURLProtocol.responseBody = data
        RegisterStubURLProtocol.lock.unlock()
    }

    private func makeClient(
        token: String = "tok123",
        tokenProvider: (@Sendable () -> String?)? = nil,
        onReauthenticationRequired: @escaping @Sendable (String?) -> Void = { _ in }
    ) -> DeviceRingRegistrationClient {
        RegisterStubURLProtocol.lock.lock()
        RegisterStubURLProtocol.status = 200
        RegisterStubURLProtocol.networkError = nil
        RegisterStubURLProtocol.lastRequest = nil
        RegisterStubURLProtocol.lastBody = nil
        RegisterStubURLProtocol.responseBody = bindingResponse()
        RegisterStubURLProtocol.responseBodyProvider = nil
        RegisterStubURLProtocol.responseProvider = nil
        RegisterStubURLProtocol.requestCount = 0
        RegisterStubURLProtocol.requestedPaths = []
        RegisterStubURLProtocol.requests = []
        RegisterStubURLProtocol.lock.unlock()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [RegisterStubURLProtocol.self]
        let now = self.now
        return DeviceRingRegistrationClient(apiBaseURL: base,
                                             urlSession: URLSession(configuration: cfg),
                                             tokenProvider: tokenProvider ?? { token.isEmpty ? nil : token },
                                             onReauthenticationRequired: onReauthenticationRequired,
                                             nowEpochSec: { now })
    }

    private func setStatus(_ code: Int) {
        RegisterStubURLProtocol.lock.lock(); RegisterStubURLProtocol.status = code; RegisterStubURLProtocol.lock.unlock()
    }

    private func expect(_ client: DeviceRingRegistrationClient,
                        _ want: DeviceRingRegistrationError,
                        voipToken: String = "aabbcc", sessionId: String = "6cf7e861",
                        generation: String = "1",
                        file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await client.register(
                voipToken: voipToken,
                sessionId: sessionId,
                attempt: attempt(sessionId: sessionId, generation: generation, voipToken: voipToken)
            )
            XCTFail("expected \(want)", file: file, line: line)
        } catch let e as DeviceRingRegistrationError {
            XCTAssertEqual(e, want, file: file, line: line)
        } catch {
            XCTFail("wrong error type: \(error)", file: file, line: line)
        }
    }

    // MARK: - success: authed POST, correct body, NO humanId

    func test_register_success_posts_authed_body_without_humanId() async throws {
        let client = makeClient()
        let binding = try await client.register(
            voipToken: "aabbccddeeff",
            sessionId: "6cf7e861",
            attempt: attempt(voipToken: "aabbccddeeff"),
            platform: "apns"
        )

        let req = RegisterStubURLProtocol.lastRequest
        XCTAssertEqual(req?.httpMethod, "POST")
        XCTAssertEqual(req?.url?.path, "/dial/register")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Authorization"), "Bearer tok123")

        let body = try XCTUnwrap(RegisterStubURLProtocol.lastBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["voipToken"] as? String, "aabbccddeeff")
        XCTAssertEqual(json["sessionId"] as? String, "6cf7e861")
        XCTAssertEqual(json["platform"] as? String, "apns")
        XCTAssertEqual(json["registryVersion"] as? Int, 2)
        XCTAssertEqual(json["installationId"] as? String, String(repeating: "A", count: 43))
        XCTAssertEqual(json["installationGeneration"] as? String, "1")
        // THE load-bearing gate: the device NEVER sends humanId — the gateway derives it from the Bearer.
        XCTAssertNil(json["humanId"], "device must NOT send humanId (confused-deputy vector)")
        XCTAssertNil(json["human_id"])
        XCTAssertEqual(json.count, 6, "body is exactly the V2 install tuple; humanId and binding proof are server-owned")
        XCTAssertEqual(binding.bindingRevision, String(repeating: "r", count: 32))
        XCTAssertEqual(binding.tokenFingerprint, DeviceRingTokenFingerprint.make("aabbccddeeff"))
    }

    func test_platform_defaults_to_apns() async throws {
        let client = makeClient()
        setResponseBody(bindingResponse(sessionId: "s1"))
        _ = try await client.register(
            voipToken: "aa",
            sessionId: "s1",
            attempt: attempt(sessionId: "s1", voipToken: "aa")
        )
        let body = try XCTUnwrap(RegisterStubURLProtocol.lastBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        // gateway valid set is ['apns','fcm'] — iOS is APNs; 'ios' would 400 (relay 322300).
        XCTAssertEqual(json["platform"] as? String, "apns")
    }

    // MARK: - guards: never POST an unusable binding

    func test_missing_token_is_notLoggedIn_before_network() async {
        let client = makeClient(token: "")
        await expect(client, .notLoggedIn)
        XCTAssertNil(RegisterStubURLProtocol.lastRequest, "no token → no network")
    }

    func test_empty_voipToken_is_rejected_before_network() async {
        let client = makeClient()
        await expect(client, .rejected(400), voipToken: "")
        XCTAssertNil(RegisterStubURLProtocol.lastRequest, "empty token → no network")
    }

    func test_empty_sessionId_is_rejected_before_network() async {
        let client = makeClient()
        await expect(client, .rejected(400), sessionId: "")
        XCTAssertNil(RegisterStubURLProtocol.lastRequest, "empty session → no network")
    }

    // MARK: - status taxonomy

    func test_401_requires_reauthentication_and_signals_the_request_token() async {
        let signal = RegistrationAuthSignal()
        let client = makeClient(onReauthenticationRequired: { signal.record($0) })
        setStatus(401)
        await expect(client, .reauthenticationRequired)
        XCTAssertEqual(signal.tokens, ["tok123"])
    }

    func test_late_401_for_an_old_token_is_superseded_without_auth_signal() async {
        let token = RegistrationTokenSequence(["principal-A", "principal-B"])
        let signal = RegistrationAuthSignal()
        let client = makeClient(
            tokenProvider: { token.next() },
            onReauthenticationRequired: { signal.record($0) }
        )
        setStatus(401)

        await expect(client, .supersededAuthentication)

        XCTAssertEqual(signal.tokens, [])
    }

    func test_late_2xx_for_an_old_token_cannot_publish_a_binding_for_the_new_principal() async {
        let token = RegistrationTokenSequence(["principal-A", "principal-B"])
        let client = makeClient(tokenProvider: { token.next() })

        await expect(client, .supersededAuthentication)
    }

    func test_403_is_notAuthorized_nonmember_session() async {
        let client = makeClient(); setStatus(403)   // sessionId not one the human belongs to
        await expect(client, .notAuthorized)
    }

    func test_5xx_is_retryable() async {
        let client = makeClient(); setStatus(503)
        await expect(client, .retryable(503))
    }

    func test_other_4xx_is_rejected() async {
        let client = makeClient(); setStatus(422)
        await expect(client, .rejected(422))
    }

    func test_409_generation_conflict_is_recoverable_binding_conflict() async {
        let client = makeClient()
        setStatus(409)
        setResponseBody(Data(#"{"reason":"binding-generation-conflict"}"#.utf8))
        await expect(client, .bindingConflict)
    }

    func test_409_device_cap_is_not_a_generation_conflict() async {
        let client = makeClient()
        setStatus(409)
        setResponseBody(Data(#"{"reason":"device-cap-reached"}"#.utf8))
        await expect(client, .deviceCapacityReached)
    }

    func test_unknown_409_reason_is_rejected_without_generation_churn() async {
        let client = makeClient()
        setStatus(409)
        setResponseBody(Data(#"{"reason":"future-conflict"}"#.utf8))
        await expect(client, .rejected(409))
    }

    func test_legacy_or_mismatched_2xx_body_is_never_accepted_as_a_v2_binding() async {
        let client = makeClient()
        setResponseBody(Data("{}".utf8))
        await expect(client, .malformedResponse)

        setResponseBody(bindingResponse(generation: "2"))
        await expect(client, .malformedResponse, generation: "1")
    }

    func test_beginUnregister_snapshots_bearer_and_posts_the_exact_compare_delete() async throws {
        let client = makeClient()
        let cleanup = DeviceRingUnregistrationAttempt(
            installationId: String(repeating: "A", count: 43),
            installationGeneration: "2",
            previousInstallationGeneration: "1",
            sessionId: "6cf7e861",
            bindingId: String(repeating: "i", count: 24),
            bindingRevision: String(repeating: "r", count: 32)
        )

        let cleanupTask = try XCTUnwrap(client.beginUnregister(cleanup))
        let cleanupSucceeded = await cleanupTask.value
        XCTAssertTrue(cleanupSucceeded)
        let request = try XCTUnwrap(RegisterStubURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.path, "/dial/unregister")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok123")
        let body = try XCTUnwrap(RegisterStubURLProtocol.lastBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["registryVersion"] as? Int, 2)
        XCTAssertEqual(json["installationGeneration"] as? String, "2")
        XCTAssertEqual(json["previousInstallationGeneration"] as? String, "1")
        XCTAssertEqual(json["bindingId"] as? String, cleanup.bindingId)
        XCTAssertEqual(json["bindingRevision"] as? String, cleanup.bindingRevision)
        XCTAssertNil(json["humanId"])
        XCTAssertEqual(json.count, 7)
    }
}

private final class RegistrationAuthSignal: @unchecked Sendable {
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

private final class RegistrationTokenSequence: @unchecked Sendable {
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
