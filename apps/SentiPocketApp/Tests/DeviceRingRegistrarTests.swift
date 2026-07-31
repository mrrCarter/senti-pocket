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

    private func makeRegistrar(loggedIn: Bool, sessionId: String = "6cf7e861") -> (DeviceRingRegistrar, Auth) {
        RegisterStubURLProtocol.lock.lock()
        RegisterStubURLProtocol.status = 200
        RegisterStubURLProtocol.networkError = nil
        RegisterStubURLProtocol.lastRequest = nil
        RegisterStubURLProtocol.lastBody = nil
        RegisterStubURLProtocol.requestCount = 0
        RegisterStubURLProtocol.lock.unlock()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [RegisterStubURLProtocol.self]
        let auth = Auth(loggedIn)
        // tokenProvider is only invoked when the registrar decides to POST (i.e. already logged in) → a constant token
        // is fine and keeps the @Sendable closure capture-free. The register DECISION is gated by `isLoggedIn` below.
        let client = DeviceRingRegistrationClient(apiBaseURL: base,
                                                  urlSession: URLSession(configuration: cfg),
                                                  tokenProvider: { "tok123" })
        let reg = DeviceRingRegistrar(client: client, sessionId: sessionId, isLoggedIn: { auth.loggedIn })
        return (reg, auth)
    }

    private func registerCount() -> Int {
        RegisterStubURLProtocol.lock.lock(); defer { RegisterStubURLProtocol.lock.unlock() }
        return RegisterStubURLProtocol.requestCount
    }

    // MARK: - token AFTER login → registers immediately

    func test_token_after_login_registers() async {
        let (reg, _) = makeRegistrar(loggedIn: true)
        await reg.tokenUpdated("aabbcc")?.value
        XCTAssertEqual(registerCount(), 1)
    }

    // MARK: - token BEFORE login → cached, no register; then login → registers

    func test_token_before_login_then_login_registers() async {
        let (reg, auth) = makeRegistrar(loggedIn: false)
        await reg.tokenUpdated("aabbcc")?.value          // not logged in → cached, no POST
        XCTAssertEqual(registerCount(), 0)
        auth.loggedIn = true
        await reg.loginCompleted()?.value                // now logged in + token cached → registers
        XCTAssertEqual(registerCount(), 1)
    }

    // MARK: - guards

    func test_login_without_a_cached_token_does_not_register() async {
        let (reg, _) = makeRegistrar(loggedIn: true)
        await reg.loginCompleted()?.value                // logged in but no token ever arrived
        XCTAssertEqual(registerCount(), 0)
    }

    func test_token_while_logged_out_does_not_register() async {
        let (reg, _) = makeRegistrar(loggedIn: false)
        await reg.tokenUpdated("aabbcc")?.value
        XCTAssertEqual(registerCount(), 0)
    }

    func test_invalidate_revokes_the_cached_token_before_a_later_login() async {
        let (reg, auth) = makeRegistrar(loggedIn: false)
        await reg.tokenUpdated("session-a-token")?.value
        reg.invalidate()
        auth.loggedIn = true

        await reg.loginCompleted()?.value

        XCTAssertEqual(registerCount(), 0, "a revoked session registrar must never bind its old cached token")
    }

    // MARK: - rotation → re-registers with the NEW token

    func test_rotation_reregisters_with_the_new_token() async throws {
        let (reg, _) = makeRegistrar(loggedIn: true)
        await reg.tokenUpdated("oldtoken")?.value
        await reg.tokenUpdated("newtoken")?.value
        XCTAssertEqual(registerCount(), 2)
        let body = try XCTUnwrap(RegisterStubURLProtocol.lastBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["voipToken"] as? String, "newtoken", "the rotated token is the one registered")
    }

    // MARK: - registers the app-primary sessionId + token (+ platform apns)

    func test_registers_sessionId_token_and_apns_platform() async throws {
        let (reg, _) = makeRegistrar(loggedIn: true, sessionId: "sess-9")
        await reg.tokenUpdated("aabbccddeeff")?.value
        let body = try XCTUnwrap(RegisterStubURLProtocol.lastBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["voipToken"] as? String, "aabbccddeeff")
        XCTAssertEqual(json["sessionId"] as? String, "sess-9")
        XCTAssertEqual(json["platform"] as? String, "apns")
        XCTAssertNil(json["humanId"], "device never sends humanId (gateway derives it from the Bearer)")
    }
}
