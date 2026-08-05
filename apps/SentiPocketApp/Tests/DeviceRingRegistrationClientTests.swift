import XCTest
@testable import SentiPocketApp

final class RegisterStubURLProtocol: URLProtocol {
    static let lock = NSLock()
    static var status = 200
    static var responseBody = Data()
    static var responseHeaders: [String: String] = ["Content-Type": "application/json"]
    static var networkError: URLError?
    static var requests: [URLRequest] = []
    static var bodies: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        Self.bodies.append(Self.bodyData(request))
        let status = Self.status
        let body = Self.responseBody
        let headers = Self.responseHeaders
        let error = Self.networkError
        Self.lock.unlock()

        if let error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset(
        status: Int = 200,
        body: Data = Data(),
        headers: [String: String] = ["Content-Type": "application/json"]
    ) {
        lock.lock()
        Self.status = status
        responseBody = body
        responseHeaders = headers
        networkError = nil
        requests = []
        bodies = []
        lock.unlock()
    }

    static func bodyData(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class RegistrationBearerProbe: @unchecked Sendable {
    private let lock = NSLock()
    var value: String?
    private(set) var signaled: [String?] = []

    init(_ value: String?) { self.value = value }

    func load() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func signal(_ value: String?) {
        lock.lock()
        signaled.append(value)
        lock.unlock()
    }
}

private final class RegistrationClockProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval?]

    init(_ values: [TimeInterval?]) { self.values = values }

    func now() -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return values.isEmpty ? nil : values.removeFirst()
    }
}

final class DeviceRingRegistrationClientTests: XCTestCase {
    private let baseURL = URL(string: "https://gw.example.com")!
    private let installationId = "UVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVE"
    private let idempotencyKey = "01234567-89ab-4def-8123-456789abcdef"
    private let bindingId = "bind_0123456789abcdef0123456789abcdef"
    private let claimId = "claim_0123456789abcdef0123456789abcdef"
    private let ownerHandle = DeviceRingFingerprint.digest("owner-a")
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    private func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func successBody(sessionId: String = "session-a", platform: String = "apns") -> Data {
        json([
            "registered": true,
            "registrationVersion": 2,
            "ownerVersion": 1,
            "ownerHandle": ownerHandle,
            "sessionId": sessionId,
            "platform": platform,
            "bindingId": bindingId,
            "bindingRevision": 3,
            "tokenClaimId": claimId,
            "tokenClaimRevision": 5,
            "expiresAt": "2027-01-22T08:00:00.000Z",
            "serverTime": "2027-01-15T08:00:00.000Z",
            "idempotent": false,
        ])
    }

    private func cleanupSuccessBody(
        idempotencyKey: String? = nil,
        sessionId: String = "session-a",
        platform: String = "apns"
    ) -> Data {
        json([
            "registrationVersion": 2,
            "ownerVersion": 1,
            "ownerHandle": ownerHandle,
            "idempotencyKey": idempotencyKey ?? self.idempotencyKey,
            "sessionId": sessionId,
            "platform": platform,
            "registered": false,
            "authorized": false,
            "cleanupComplete": true,
            "serverTime": "2027-01-15T08:00:00.000Z",
        ])
    }

    private func recoveryBody(
        reason: String,
        expiresAt: String,
        sessionId: String = "session-a"
    ) -> Data {
        let error = reason == "registration-expired"
            ? "registration lease expired"
            : "registration committed but current authorization is missing"
        return json([
            "registered": false,
            "committed": true,
            "authorized": false,
            "revocationRequired": true,
            "reason": reason,
            "error": error,
            "registrationVersion": 2,
            "ownerVersion": 1,
            "ownerHandle": ownerHandle,
            "sessionId": sessionId,
            "platform": "apns",
            "bindingId": bindingId,
            "bindingRevision": 3,
            "tokenClaimId": claimId,
            "tokenClaimRevision": 5,
            "expiresAt": expiresAt,
            "serverTime": "2027-01-15T08:00:00.000Z",
            "idempotent": true,
        ])
    }

    private func deniedBeforeCommitBody(sessionId: String = "session-a") -> Data {
        json([
            "registered": false,
            "committed": false,
            "authorized": false,
            "revocationRequired": false,
            "reason": "registration-denied-before-commit",
            "error": "registration operation was denied before commit",
            "registrationVersion": 2,
            "ownerVersion": 1,
            "ownerHandle": ownerHandle,
            "sessionId": sessionId,
            "platform": "apns",
            "idempotent": true,
        ])
    }

    private func revocationReceipt(expiresAt: String) -> DeviceRingRevocationReceipt {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return DeviceRingRevocationReceipt(
            ownerVersion: DeviceRingRegistryOwnerContext.version,
            ownerHandle: ownerHandle,
            sessionId: "session-a",
            platform: "apns",
            bindingId: bindingId,
            bindingRevision: 3,
            tokenClaimId: claimId,
            tokenClaimRevision: 5,
            expiresAt: formatter.date(from: expiresAt)!,
            serverTime: formatter.date(from: "2027-01-15T08:00:00.000Z")!,
            idempotent: true
        )
    }

    private func makeClient(
        bearer: RegistrationBearerProbe = RegistrationBearerProbe("bearer-a"),
        continuousNow: @escaping @Sendable () -> TimeInterval? = { 10_000 }
    ) -> DeviceRingRegistrationClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RegisterStubURLProtocol.self]
        let now = fixedNow
        return DeviceRingRegistrationClient(
            apiBaseURL: baseURL,
            urlSession: URLSession(configuration: configuration),
            currentBearerProvider: bearer.load,
            onReauthenticationRequired: bearer.signal,
            wallNow: { now },
            continuousNow: continuousNow
        )
    }

    private func request(
        expectedBindingId: String? = nil,
        expectedBindingRevision: Int? = nil,
        expectedTokenClaimId: String? = nil,
        expectedTokenClaimRevision: Int? = nil
    ) -> DeviceRingRegistrationRequest {
        DeviceRingRegistrationRequest(
            ownerHandle: ownerHandle,
            installationId: installationId,
            idempotencyKey: idempotencyKey,
            voipToken: "aabbcc",
            sessionId: "session-a",
            expectedBindingId: expectedBindingId,
            expectedBindingRevision: expectedBindingRevision,
            expectedTokenClaimId: expectedTokenClaimId,
            expectedTokenClaimRevision: expectedTokenClaimRevision
        )
    }

    private func cleanupRequest(
        idempotencyKey: String? = nil,
        tokenDigest: String? = nil,
        sessionId: String = "session-a",
        platform: String = "apns"
    ) -> DeviceRingRegistrationCleanupRequest {
        DeviceRingRegistrationCleanupRequest(
            ownerHandle: ownerHandle,
            installationId: installationId,
            idempotencyKey: idempotencyKey ?? self.idempotencyKey,
            tokenDigest: tokenDigest ?? DeviceRingFingerprint.digest("aabbcc"),
            sessionId: sessionId,
            platform: platform
        )
    }

    private func expect(
        _ wanted: DeviceRingRegistrationError,
        client: DeviceRingRegistrationClient,
        request: DeviceRingRegistrationRequest? = nil,
        bearer: String = "bearer-a",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await client.register(request ?? self.request(), bearerToken: bearer)
            XCTFail("expected \(wanted)", file: file, line: line)
        } catch let error as DeviceRingRegistrationError {
            XCTAssertEqual(error, wanted, file: file, line: line)
        } catch {
            XCTFail("wrong error \(error)", file: file, line: line)
        }
    }

    private func expectCleanup(
        _ wanted: DeviceRingRegistrationError,
        client: DeviceRingRegistrationClient,
        request: DeviceRingRegistrationCleanupRequest? = nil,
        bearer: String = "bearer-a",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await client.cleanupRegistration(
                request ?? self.cleanupRequest(),
                bearerToken: bearer
            )
            XCTFail("expected \(wanted)", file: file, line: line)
        } catch let error as DeviceRingRegistrationError {
            XCTAssertEqual(error, wanted, file: file, line: line)
        } catch {
            XCTFail("wrong error \(error)", file: file, line: line)
        }
    }

    func test_owner_context_uses_auth_only_get_and_strict_versioned_response() async throws {
        RegisterStubURLProtocol.reset(body: json([
            "registrationVersion": 2,
            "ownerVersion": 1,
            "ownerHandle": ownerHandle,
            "serverTime": "2027-01-15T08:00:00.000Z",
        ]))
        let context = try await makeClient().ownerContext(bearerToken: "bearer-a")
        XCTAssertEqual(context.ownerVersion, 1)
        XCTAssertEqual(context.ownerHandle, ownerHandle)
        let sent = try XCTUnwrap(RegisterStubURLProtocol.requests.last)
        XCTAssertEqual(sent.httpMethod, "GET")
        XCTAssertEqual(sent.url?.path, "/dial/register/context")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer bearer-a")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Pragma"), "no-cache")
        XCTAssertEqual(sent.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(sent.timeoutInterval, 8)
        XCTAssertNil(sent.httpBody)
        XCTAssertTrue(RegisterStubURLProtocol.bodies.last?.isEmpty == true)

        let invalidResponses: [[String: Any]] = [
            ["registrationVersion": 2, "ownerVersion": 2, "ownerHandle": ownerHandle, "serverTime": "2027-01-15T08:00:00.000Z"],
            ["registrationVersion": 2, "ownerVersion": 1, "ownerHandle": String(repeating: "A", count: 42) + "B", "serverTime": "2027-01-15T08:00:00.000Z"],
            ["registrationVersion": 2, "ownerVersion": 1, "ownerHandle": ownerHandle, "serverTime": "bad", "future": true],
        ]
        for body in invalidResponses {
            RegisterStubURLProtocol.reset(body: json(body))
            do {
                _ = try await makeClient().ownerContext(bearerToken: "bearer-a")
                XCTFail("malformed owner context must fail closed")
            } catch let error as DeviceRingRegistrationError {
                XCTAssertEqual(error, .malformedResponse)
            }
        }
    }

    func test_registry_owner_conflict_is_exact_and_typed() async {
        RegisterStubURLProtocol.reset(status: 409, body: json([
            "error": "registry owner does not match authenticated principal",
            "reason": "registry-owner-conflict",
        ]))
        await expect(.ownerConflict, client: makeClient())

        RegisterStubURLProtocol.reset(status: 409, body: json([
            "error": "different wording",
            "reason": "registry-owner-conflict",
        ]))
        await expect(.malformedResponse, client: makeClient())
    }

    func test_register_posts_exact_v2_body_without_human_identity() async throws {
        RegisterStubURLProtocol.reset(body: successBody())
        let receipt = try await makeClient().register(request(), bearerToken: "bearer-a")

        let sent = try XCTUnwrap(RegisterStubURLProtocol.requests.last)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.url?.path, "/dial/register")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer bearer-a")
        let body = try XCTUnwrap(RegisterStubURLProtocol.bodies.last)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set([
            "registrationVersion", "ownerVersion", "ownerHandle", "installationId", "idempotencyKey",
            "voipToken", "sessionId", "platform",
        ]))
        XCTAssertNil(object["humanId"])
        XCTAssertEqual(object["registrationVersion"] as? Int, 2)
        XCTAssertEqual(receipt.bindingId, bindingId)
        XCTAssertEqual(receipt.tokenClaimId, claimId)
        XCTAssertEqual(receipt.authorizedLeaseDuration, 7 * 24 * 60 * 60)
    }

    func test_register_emits_expected_fence_pairs_atomically() async throws {
        RegisterStubURLProtocol.reset(body: successBody())
        let request = request(
            expectedBindingId: bindingId,
            expectedBindingRevision: 3,
            expectedTokenClaimId: claimId,
            expectedTokenClaimRevision: 5
        )
        _ = try await makeClient().register(request, bearerToken: "bearer-a")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(RegisterStubURLProtocol.bodies.last)) as? [String: Any]
        )
        XCTAssertEqual(object["expectedBindingId"] as? String, bindingId)
        XCTAssertEqual(object["expectedBindingRevision"] as? Int, 3)
        XCTAssertEqual(object["expectedTokenClaimId"] as? String, claimId)
        XCTAssertEqual(object["expectedTokenClaimRevision"] as? Int, 5)

        RegisterStubURLProtocol.reset(body: successBody())
        await expect(
            .rejected(400),
            client: makeClient(),
            request: self.request(expectedBindingId: bindingId),
            bearer: "bearer-a"
        )
        XCTAssertTrue(RegisterStubURLProtocol.requests.isEmpty)
    }

    func test_success_body_is_strictly_bound_to_request_and_future_lease() async {
        var body = try! JSONSerialization.jsonObject(with: successBody()) as! [String: Any]
        body["sessionId"] = "other"
        RegisterStubURLProtocol.reset(body: json(body))
        await expect(.malformedResponse, client: makeClient())

        body["sessionId"] = "session-a"
        body["ownerHandle"] = DeviceRingFingerprint.digest("owner-b")
        RegisterStubURLProtocol.reset(body: json(body))
        await expect(.malformedResponse, client: makeClient())

        body["ownerHandle"] = ownerHandle
        body["bindingRevision"] = 9_007_199_254_740_992
        RegisterStubURLProtocol.reset(body: json(body))
        await expect(.malformedResponse, client: makeClient())

        body["bindingRevision"] = 3
        body["expiresAt"] = "2020-01-01T00:00:00Z"
        RegisterStubURLProtocol.reset(body: json(body))
        await expect(.malformedResponse, client: makeClient())

        body["expiresAt"] = "2027-01-22T08:00:01Z"
        RegisterStubURLProtocol.reset(body: json(body))
        await expect(.malformedResponse, client: makeClient())

        body["expiresAt"] = "2027-01-22T08:00:00Z"
        body.removeValue(forKey: "serverTime")
        RegisterStubURLProtocol.reset(body: json(body))
        await expect(.malformedResponse, client: makeClient())

        body["serverTime"] = "2027-01-15T08:00:00Z"
        body["future"] = true
        RegisterStubURLProtocol.reset(body: json(body))
        await expect(.malformedResponse, client: makeClient())
    }

    func test_receipt_subtracts_round_trip_and_unavailable_or_regressing_clock_fails_closed() async throws {
        let measured = RegistrationClockProbe([10_000, 10_002])
        RegisterStubURLProtocol.reset(body: successBody())
        let receipt = try await makeClient(continuousNow: measured.now).register(
            request(),
            bearerToken: "bearer-a"
        )
        XCTAssertEqual(receipt.authorizedLeaseDuration, 604_798)
        XCTAssertEqual(receipt.continuousTimeAtReceipt, 10_002)

        let unavailable = RegistrationClockProbe([nil])
        RegisterStubURLProtocol.reset(body: successBody())
        await expect(
            .malformedResponse,
            client: makeClient(continuousNow: unavailable.now)
        )
        XCTAssertTrue(RegisterStubURLProtocol.requests.isEmpty)

        let regressing = RegistrationClockProbe([10_000, 9_999])
        RegisterStubURLProtocol.reset(body: successBody())
        await expect(
            .malformedResponse,
            client: makeClient(continuousNow: regressing.now)
        )
    }

    func test_binding_and_token_claim_conflicts_decode_explicit_fences_and_null() async {
        RegisterStubURLProtocol.reset(
            status: 409,
            body: json([
                "reason": "binding-conflict",
                "ownerVersion": 1,
                "ownerHandle": ownerHandle,
                "currentBinding": [
                    "bindingId": bindingId,
                    "bindingRevision": 7,
                    "expiresAt": "2099-01-02T03:04:05Z",
                ],
            ])
        )
        await expect(
            .bindingConflict(DeviceRingServerBindingFence(
                bindingId: bindingId,
                bindingRevision: 7,
                expiresAt: ISO8601DateFormatter().date(from: "2099-01-02T03:04:05Z")!
            )),
            client: makeClient()
        )

        RegisterStubURLProtocol.reset(
            status: 409,
            body: json([
                "reason": "token-claim-conflict",
                "ownerVersion": 1,
                "ownerHandle": ownerHandle,
                "currentTokenClaim": NSNull(),
            ])
        )
        await expect(.tokenClaimConflict(nil), client: makeClient())
    }

    func test_denied_before_commit_is_strict_terminal_no_authority_proof() async {
        RegisterStubURLProtocol.reset(status: 409, body: deniedBeforeCommitBody())
        await expect(.registrationDeniedBeforeCommit, client: makeClient())

        var body = try! JSONSerialization.jsonObject(with: deniedBeforeCommitBody()) as! [String: Any]
        let deniedMutations: [(inout [String: Any]) -> Void] = [
            { $0["sessionId"] = "session-b" },
            { $0["ownerHandle"] = DeviceRingFingerprint.digest("owner-b") },
            { $0["registered"] = 0 },
            { $0["idempotent"] = 1 },
            { $0["committed"] = true },
            { $0["revocationRequired"] = true },
            { $0["future"] = true },
        ]
        for mutation in deniedMutations {
            body = try! JSONSerialization.jsonObject(with: deniedBeforeCommitBody()) as! [String: Any]
            mutation(&body)
            RegisterStubURLProtocol.reset(status: 409, body: json(body))
            await expect(.malformedResponse, client: makeClient())
        }
    }

    func test_committed_unauthorized_and_expired_receipts_decode_as_revocation_only() async {
        let activeExpiry = "2027-01-22T08:00:00.000Z"
        RegisterStubURLProtocol.reset(
            status: 409,
            body: recoveryBody(
                reason: "registration-committed-but-unauthorized",
                expiresAt: activeExpiry
            )
        )
        await expect(
            .registrationCommittedButUnauthorized(revocationReceipt(expiresAt: activeExpiry)),
            client: makeClient()
        )

        let expiredAt = "2027-01-14T08:00:00.000Z"
        RegisterStubURLProtocol.reset(
            status: 410,
            body: recoveryBody(reason: "registration-expired", expiresAt: expiredAt)
        )
        await expect(
            .registrationExpired(revocationReceipt(expiresAt: expiredAt)),
            client: makeClient()
        )
    }

    func test_revocation_receipts_are_strictly_bound_and_never_accept_future_fields() async {
        var body = try! JSONSerialization.jsonObject(with: recoveryBody(
            reason: "registration-committed-but-unauthorized",
            expiresAt: "2027-01-22T08:00:00.000Z"
        )) as! [String: Any]
        body["sessionId"] = "session-b"
        RegisterStubURLProtocol.reset(status: 409, body: json(body))
        await expect(.malformedResponse, client: makeClient())

        body["sessionId"] = "session-a"
        body["committed"] = 1
        RegisterStubURLProtocol.reset(status: 409, body: json(body))
        await expect(.malformedResponse, client: makeClient())

        body["committed"] = true
        body["future"] = true
        RegisterStubURLProtocol.reset(status: 409, body: json(body))
        await expect(.malformedResponse, client: makeClient())

        body.removeValue(forKey: "future")
        body["authorized"] = true
        RegisterStubURLProtocol.reset(status: 409, body: json(body))
        await expect(.malformedResponse, client: makeClient())

        body["authorized"] = false
        body["error"] = "future wording"
        RegisterStubURLProtocol.reset(status: 409, body: json(body))
        await expect(.malformedResponse, client: makeClient())

        RegisterStubURLProtocol.reset(
            status: 410,
            body: recoveryBody(
                reason: "registration-expired",
                expiresAt: "2027-01-22T08:00:00.000Z"
            )
        )
        await expect(.malformedResponse, client: makeClient())
    }

    func test_unknown_or_malformed_conflict_fails_closed() async {
        RegisterStubURLProtocol.reset(status: 409, body: json(["reason": "future-conflict"]))
        await expect(.malformedResponse, client: makeClient())
        RegisterStubURLProtocol.reset(status: 409, body: json(["reason": "binding-conflict"]))
        await expect(.malformedResponse, client: makeClient())

        RegisterStubURLProtocol.reset(
            status: 409,
            body: json([
                "reason": "binding-conflict",
                "ownerVersion": 1,
                "ownerHandle": ownerHandle,
                "currentBinding": [
                    "bindingId": bindingId,
                    "bindingRevision": 7,
                    "expiresAt": "2099-01-02T03:04:05Z",
                    "future": true,
                ],
            ])
        )
        await expect(.malformedResponse, client: makeClient())

        RegisterStubURLProtocol.reset(
            status: 409,
            body: json([
                "reason": "token-claim-conflict",
                "ownerVersion": 1,
                "ownerHandle": ownerHandle,
                "currentTokenClaim": NSNull(),
                "future": true,
            ])
        )
        await expect(.malformedResponse, client: makeClient())
    }

    func test_current_401_signals_but_stale_401_does_not() async {
        let current = RegistrationBearerProbe("bearer-a")
        RegisterStubURLProtocol.reset(status: 401, body: json(["error": "expired"]))
        await expect(.reauthenticationRequired, client: makeClient(bearer: current))
        XCTAssertEqual(current.signaled, ["bearer-a"])

        let stale = RegistrationBearerProbe("bearer-b")
        RegisterStubURLProtocol.reset(status: 401, body: json(["error": "expired"]))
        await expect(.supersededAuthentication, client: makeClient(bearer: stale))
        XCTAssertTrue(stale.signaled.isEmpty)
    }

    func test_network_and_status_taxonomy() async {
        RegisterStubURLProtocol.reset(status: 503, body: json(["reason": "busy"]))
        await expect(.retryable(503), client: makeClient())
        RegisterStubURLProtocol.reset(status: 426, body: json(["reason": "v2"]))
        await expect(.clientUpgradeRequired, client: makeClient())
        RegisterStubURLProtocol.reset(status: 501, body: json(["reason": "off"]))
        await expect(.notConfigured, client: makeClient())
        RegisterStubURLProtocol.reset(
            status: 429,
            body: json([
                "error": "registration operation rate limited",
                "reason": "operation-rate-limited",
            ]),
            headers: ["Content-Type": "application/json", "Retry-After": "60"]
        )
        await expect(.retryable(429), client: makeClient())
        RegisterStubURLProtocol.reset(status: 429, body: json(["reason": "operation-rate-limited"]))
        await expect(.malformedResponse, client: makeClient())
        RegisterStubURLProtocol.reset()
        RegisterStubURLProtocol.networkError = URLError(.notConnectedToInternet)
        do {
            _ = try await makeClient().register(request(), bearerToken: "bearer-a")
            XCTFail("expected network error")
        } catch let error as DeviceRingRegistrationError {
            guard case .network = error else { return XCTFail("wrong error \(error)") }
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func test_cleanup_posts_exact_digest_only_body_and_accepts_only_bound_nonauthorizing_success() async throws {
        RegisterStubURLProtocol.reset(body: cleanupSuccessBody())
        let request = cleanupRequest()
        try await makeClient().cleanupRegistration(request, bearerToken: "old-bearer")

        let sent = try XCTUnwrap(RegisterStubURLProtocol.requests.last)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.url?.path, "/dial/register/reconcile")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer old-bearer")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(RegisterStubURLProtocol.bodies.last)) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), Set([
            "registrationVersion", "ownerVersion", "ownerHandle", "installationId", "idempotencyKey", "tokenDigest", "sessionId", "platform",
        ]))
        XCTAssertEqual(object["tokenDigest"] as? String, request.tokenDigest)
        XCTAssertNil(object["voipToken"])
        XCTAssertNil(object["bindingId"])
        XCTAssertNil(object["expectedBindingId"])

        var response = try XCTUnwrap(
            JSONSerialization.jsonObject(with: cleanupSuccessBody()) as? [String: Any]
        )
        let responseMutations: [(inout [String: Any]) -> Void] = [
            { $0["idempotencyKey"] = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" },
            { $0["ownerHandle"] = DeviceRingFingerprint.digest("owner-b") },
            { $0["registered"] = true },
            { $0["authorized"] = true },
            { $0["cleanupComplete"] = false },
            { $0["serverTime"] = "not-a-date" },
            { $0["bindingId"] = self.bindingId },
            { $0["future"] = true },
        ]
        for mutation in responseMutations {
            response = try XCTUnwrap(
                JSONSerialization.jsonObject(with: cleanupSuccessBody()) as? [String: Any]
            )
            mutation(&response)
            RegisterStubURLProtocol.reset(body: json(response))
            await expectCleanup(.malformedResponse, client: makeClient())
        }
    }

    func test_cleanup_rejects_noncanonical_digest_before_network_and_keeps_429_retryable() async {
        RegisterStubURLProtocol.reset(body: cleanupSuccessBody())
        await expectCleanup(
            .rejected(400),
            client: makeClient(),
            request: cleanupRequest(tokenDigest: String(repeating: "A", count: 42) + "B")
        )
        XCTAssertTrue(RegisterStubURLProtocol.requests.isEmpty)

        RegisterStubURLProtocol.reset(
            status: 429,
            body: json([
                "error": "registration operation rate limited",
                "reason": "operation-rate-limited",
            ]),
            headers: ["Content-Type": "application/json", "Retry-After": "60"]
        )
        await expectCleanup(.retryable(429), client: makeClient())
    }

    func test_unregister_uses_delete_exact_tuple_and_strict_success() async throws {
        RegisterStubURLProtocol.reset(body: json([
            "unregistered": true,
            "registrationVersion": 2,
            "ownerVersion": 1,
            "ownerHandle": ownerHandle,
            "sessionId": "session-a",
        ]))
        let request = DeviceRingUnregistrationRequest(
            ownerHandle: ownerHandle,
            installationId: installationId,
            sessionId: "session-a",
            bindingId: bindingId,
            bindingRevision: 7
        )
        try await makeClient().unregister(request, bearerToken: "old-bearer")

        let sent = try XCTUnwrap(RegisterStubURLProtocol.requests.last)
        XCTAssertEqual(sent.httpMethod, "DELETE")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer old-bearer")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(RegisterStubURLProtocol.bodies.last)) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), Set([
            "registrationVersion", "ownerVersion", "ownerHandle", "installationId", "sessionId", "bindingId", "bindingRevision",
        ]))

        RegisterStubURLProtocol.reset(body: json([
            "unregistered": true,
            "registrationVersion": 2,
            "ownerVersion": 1,
            "ownerHandle": ownerHandle,
            "sessionId": "session-a",
            "future": true,
        ]))
        do {
            try await makeClient().unregister(request, bearerToken: "old-bearer")
            XCTFail("unknown DELETE success fields must fail closed")
        } catch let error as DeviceRingRegistrationError {
            XCTAssertEqual(error, .malformedResponse)
        }
    }
}
