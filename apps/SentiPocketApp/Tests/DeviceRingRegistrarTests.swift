import XCTest
@testable import SentiPocketApp

/// Locks DeviceRingRegistrar — the WHEN-to-register logic that ties SentiCallManager.onVoipToken +
/// SignInCoordinator.onAuthenticated to the POST /dial/register client. Covers both orderings (token-before-login and
/// token-after-login), rotation re-register, and the guards (never register without BOTH a token AND a Bearer).
/// Reuses RegisterStubURLProtocol (from DeviceRingRegistrationClientTests) to observe the actual POSTs.
@MainActor
final class DeviceRingRegistrarTests: XCTestCase {

    private let base = URL(string: "https://gw.example.com")!

    /// Controllable login state — captured only by the registrar's non-Sendable `isLoggedIn`, so no @Sendable issue.
    private final class Auth { var loggedIn: Bool; init(_ v: Bool) { loggedIn = v } }

    private final class InstallationMemory {
        var generation: UInt64 = 0
        var pending: DeviceRingRegistrationAttempt?
        var binding: DeviceRingBinding?
        var cleanups: [DeviceRingUnregistrationAttempt] = []

        var controller: DeviceRingInstallationController {
            DeviceRingInstallationController(
                beginRegistration: { sessionId, token, forceNew in
                    let fingerprint = DeviceRingTokenFingerprint.make(token)
                    if !forceNew, let pending = self.pending,
                       pending.sessionId == sessionId,
                       pending.tokenFingerprint == fingerprint {
                        return pending
                    }
                    self.generation += 1
                    let attempt = DeviceRingRegistrationAttempt(
                        installationId: String(repeating: "A", count: 43),
                        installationGeneration: String(self.generation),
                        sessionId: sessionId,
                        tokenFingerprint: fingerprint
                    )
                    self.pending = attempt
                    self.binding = nil
                    return attempt
                },
                commitRegistration: { attempt, binding in
                    guard self.pending == attempt else { throw DeviceRingBindingStoreError.corruptState }
                    self.binding = binding
                    self.pending = nil
                },
                beginRevocation: { supplied in
                    self.generation += 1
                    let current = supplied ?? self.binding
                    self.binding = nil
                    self.pending = nil
                    guard let current else { return nil }
                    let cleanup = DeviceRingUnregistrationAttempt(
                        installationId: String(repeating: "A", count: 43),
                        installationGeneration: String(self.generation),
                        previousInstallationGeneration: current.installationGeneration,
                        sessionId: current.sessionId,
                        bindingId: current.bindingId,
                        bindingRevision: current.bindingRevision
                    )
                    self.cleanups.append(cleanup)
                    return cleanup
                },
                completeUnregistration: { _ in },
                loadCurrentBinding: { self.binding }
            )
        }
    }

    private func makeRegistrar(
        loggedIn: Bool,
        sessionId: String = "6cf7e861",
        onBindingChanged: @escaping (DeviceRingBinding?) -> Void = { _ in }
    ) -> (DeviceRingRegistrar, Auth, InstallationMemory) {
        RegisterStubURLProtocol.lock.lock()
        RegisterStubURLProtocol.status = 200
        RegisterStubURLProtocol.networkError = nil
        RegisterStubURLProtocol.lastRequest = nil
        RegisterStubURLProtocol.lastBody = nil
        RegisterStubURLProtocol.requestCount = 0
        RegisterStubURLProtocol.requestedPaths = []
        RegisterStubURLProtocol.requests = []
        RegisterStubURLProtocol.responseProvider = nil
        RegisterStubURLProtocol.responseBodyProvider = { body in
            guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let sessionId = json["sessionId"] as? String,
                  let generation = json["installationGeneration"] as? String else {
                return Data("{}".utf8)
            }
            return (try? JSONSerialization.data(withJSONObject: [
                "registered": true,
                "registryVersion": 2,
                "sessionId": sessionId,
                "platform": "apns",
                "installationGeneration": generation,
                "bindingId": String(repeating: "i", count: 24),
                "bindingRevision": String(repeating: "r", count: 32),
                "leaseExpiresAtSec": Int64(Date().timeIntervalSince1970) + 600,
            ])) ?? Data("{}".utf8)
        }
        RegisterStubURLProtocol.lock.unlock()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [RegisterStubURLProtocol.self]
        let auth = Auth(loggedIn)
        // tokenProvider is only invoked when the registrar decides to POST (i.e. already logged in) → a constant token
        // is fine and keeps the @Sendable closure capture-free. The register DECISION is gated by `isLoggedIn` below.
        let client = DeviceRingRegistrationClient(apiBaseURL: base,
                                                  urlSession: URLSession(configuration: cfg),
                                                  tokenProvider: { "tok123" })
        let installation = InstallationMemory()
        let reg = DeviceRingRegistrar(
            client: client,
            sessionId: sessionId,
            isLoggedIn: { auth.loggedIn },
            installation: installation.controller,
            onBindingChanged: onBindingChanged
        )
        return (reg, auth, installation)
    }

    private func registerCount() -> Int {
        RegisterStubURLProtocol.lock.lock(); defer { RegisterStubURLProtocol.lock.unlock() }
        return RegisterStubURLProtocol.requestedPaths.filter { $0 == "/dial/register" }.count
    }

    private func lastRegisterBody() -> Data? {
        RegisterStubURLProtocol.lock.lock()
        defer { RegisterStubURLProtocol.lock.unlock() }
        return RegisterStubURLProtocol.requests.last { $0.path == "/dial/register" }?.body
    }

    // MARK: - token AFTER login → registers immediately

    func test_token_after_login_registers() async {
        let (reg, _, _) = makeRegistrar(loggedIn: true)
        await reg.tokenUpdated("aabbcc")?.value
        XCTAssertEqual(registerCount(), 1)
    }

    func test_generation_conflict_gets_one_forced_generation_recovery() async {
        let (reg, _, installation) = makeRegistrar(loggedIn: true)
        RegisterStubURLProtocol.lock.lock()
        RegisterStubURLProtocol.responseProvider = { body in
            guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let sessionId = json["sessionId"] as? String,
                  let generation = json["installationGeneration"] as? String else {
                return (400, Data())
            }
            if generation == "1" {
                return (409, Data(#"{"reason":"binding-superseded"}"#.utf8))
            }
            let response = try! JSONSerialization.data(withJSONObject: [
                "registered": true,
                "registryVersion": 2,
                "sessionId": sessionId,
                "platform": "apns",
                "installationGeneration": generation,
                "bindingId": String(repeating: "i", count: 24),
                "bindingRevision": String(repeating: "r", count: 32),
                "leaseExpiresAtSec": Int64(Date().timeIntervalSince1970) + 600,
            ])
            return (200, response)
        }
        RegisterStubURLProtocol.lock.unlock()

        await reg.tokenUpdated("aabbcc")?.value

        XCTAssertEqual(registerCount(), 2)
        XCTAssertEqual(installation.generation, 2)
        XCTAssertEqual(installation.binding?.installationGeneration, "2")
    }

    func test_device_capacity_conflict_does_not_retry_or_churn_generation() async {
        let (reg, _, installation) = makeRegistrar(loggedIn: true)
        RegisterStubURLProtocol.lock.lock()
        RegisterStubURLProtocol.status = 409
        RegisterStubURLProtocol.responseBodyProvider = nil
        RegisterStubURLProtocol.responseBody = Data(#"{"reason":"device-cap-reached"}"#.utf8)
        RegisterStubURLProtocol.lock.unlock()

        await reg.tokenUpdated("aabbcc")?.value

        XCTAssertEqual(registerCount(), 1)
        XCTAssertEqual(installation.generation, 1)
        XCTAssertNil(installation.binding)
    }

    func test_repeated_generation_conflict_is_bounded_to_one_recovery() async {
        let (reg, _, installation) = makeRegistrar(loggedIn: true)
        RegisterStubURLProtocol.lock.lock()
        RegisterStubURLProtocol.status = 409
        RegisterStubURLProtocol.responseBodyProvider = nil
        RegisterStubURLProtocol.responseBody = Data(#"{"reason":"binding-superseded"}"#.utf8)
        RegisterStubURLProtocol.lock.unlock()

        await reg.tokenUpdated("aabbcc")?.value

        XCTAssertEqual(registerCount(), 2, "one initial attempt plus one forced-generation recovery")
        XCTAssertEqual(installation.generation, 2)
        XCTAssertNil(installation.binding)
    }

    func test_renewal_clears_live_binding_before_network_result() async {
        var observed: [DeviceRingBinding?] = []
        let (reg, _, installation) = makeRegistrar(
            loggedIn: true,
            onBindingChanged: { observed.append($0) }
        )
        await reg.tokenUpdated("aabbcc")?.value
        XCTAssertNotNil(installation.binding)

        RegisterStubURLProtocol.lock.lock()
        RegisterStubURLProtocol.status = 503
        RegisterStubURLProtocol.lock.unlock()
        await reg.loginCompleted()?.value

        XCTAssertNil(installation.binding)
        guard !observed.isEmpty else {
            return XCTFail("registration must publish at least one binding transition")
        }
        XCTAssertNil(observed[observed.count - 1], "the live PushKit proof is revoked before a renewal suspends")
    }

    // MARK: - token BEFORE login → cached, no register; then login → registers

    func test_token_before_login_then_login_registers() async {
        let (reg, auth, _) = makeRegistrar(loggedIn: false)
        await reg.tokenUpdated("aabbcc")?.value          // not logged in → cached, no POST
        XCTAssertEqual(registerCount(), 0)
        auth.loggedIn = true
        await reg.loginCompleted()?.value                // now logged in + token cached → registers
        XCTAssertEqual(registerCount(), 1)
    }

    // MARK: - guards

    func test_login_without_a_cached_token_does_not_register() async {
        let (reg, _, _) = makeRegistrar(loggedIn: true)
        await reg.loginCompleted()?.value                // logged in but no token ever arrived
        XCTAssertEqual(registerCount(), 0)
    }

    func test_token_while_logged_out_does_not_register() async {
        let (reg, _, _) = makeRegistrar(loggedIn: false)
        await reg.tokenUpdated("aabbcc")?.value
        XCTAssertEqual(registerCount(), 0)
    }

    func test_invalidate_revokes_the_cached_token_before_a_later_login() async {
        let (reg, auth, _) = makeRegistrar(loggedIn: false)
        await reg.tokenUpdated("session-a-token")?.value
        reg.invalidate()
        auth.loggedIn = true

        await reg.loginCompleted()?.value

        XCTAssertEqual(registerCount(), 0, "a revoked session registrar must never bind its old cached token")
    }

    // MARK: - rotation → re-registers with the NEW token

    func test_rotation_reregisters_with_the_new_token() async throws {
        let (reg, _, installation) = makeRegistrar(loggedIn: true)
        await reg.tokenUpdated("oldtoken")?.value
        await reg.tokenUpdated("newtoken")?.value
        XCTAssertEqual(registerCount(), 2)
        let body = try XCTUnwrap(lastRegisterBody())
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["voipToken"] as? String, "newtoken", "the rotated token is the one registered")
        XCTAssertEqual(json["installationGeneration"] as? String, "3",
                       "token rotation persists a tombstone generation before the replacement binding")
        XCTAssertEqual(installation.cleanups.first?.installationGeneration, "2")
        XCTAssertEqual(installation.binding?.installationGeneration, "3")
    }

    func test_invalidate_clears_local_push_authority_before_best_effort_unregister() async {
        let (reg, _, installation) = makeRegistrar(loggedIn: true)
        await reg.tokenUpdated("aabbcc")?.value
        XCTAssertNotNil(installation.binding)

        reg.invalidate()

        XCTAssertNil(installation.binding, "local binding proof must clear synchronously")
        XCTAssertEqual(installation.cleanups.first?.previousInstallationGeneration, "1")
        XCTAssertEqual(installation.cleanups.first?.installationGeneration, "2")
        for _ in 0..<100 {
            RegisterStubURLProtocol.lock.lock()
            let sent = RegisterStubURLProtocol.requestedPaths.contains("/dial/unregister")
            RegisterStubURLProtocol.lock.unlock()
            if sent { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        RegisterStubURLProtocol.lock.lock()
        let unregisterCount = RegisterStubURLProtocol.requestedPaths.filter { $0 == "/dial/unregister" }.count
        RegisterStubURLProtocol.lock.unlock()
        XCTAssertEqual(unregisterCount, 1)
    }

    // MARK: - registers the app-primary sessionId + token (+ platform apns)

    func test_registers_sessionId_token_and_apns_platform() async throws {
        let (reg, _, _) = makeRegistrar(loggedIn: true, sessionId: "sess-9")
        await reg.tokenUpdated("aabbccddeeff")?.value
        let body = try XCTUnwrap(lastRegisterBody())
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["voipToken"] as? String, "aabbccddeeff")
        XCTAssertEqual(json["sessionId"] as? String, "sess-9")
        XCTAssertEqual(json["platform"] as? String, "apns")
        XCTAssertNil(json["humanId"], "device never sends humanId (gateway derives it from the Bearer)")
    }
}
