import XCTest
import PocketUI
@testable import SentiPocketApp

/// Locks SignInCoordinator — the composition that makes login LIVE. Drives the real state machine hermetically via an
/// injected fake login + a controllable "is a token stored" probe. The load-bearing test is warden's gate #2:
/// a login that returns WITHOUT a stored token is NOT signed-in (never fake success).
@MainActor
final class SignInCoordinatorTests: XCTestCase {

    /// MainActor-isolated mutable holder (reference type → safe to mutate from the injected closures).
    private final class LoginProbe {
        var storedToken: Bool
        var loginCalls = 0
        var authFired = 0
        init(storedToken: Bool = false) { self.storedToken = storedToken }
    }

    private func makeCoordinator(
        probe: LoginProbe,
        login: (@escaping () async throws -> Void)? = nil
    ) -> SignInCoordinator {
        let defaultLogin: () async throws -> Void = { probe.loginCalls += 1; probe.storedToken = true }
        let coord = SignInCoordinator(
            login: login ?? defaultLogin,
            isLoggedIn: { probe.storedToken },
            signOut: { probe.storedToken = false })
        coord.onAuthenticated = { probe.authFired += 1 }
        return coord
    }

    // MARK: - init reflects the stored token

    func test_init_is_signedIn_when_a_token_is_already_stored() {
        let coord = makeCoordinator(probe: LoginProbe(storedToken: true))
        XCTAssertEqual(coord.phase, .signedIn)
        XCTAssertTrue(coord.isAuthenticated)
    }

    func test_init_is_signedOut_when_no_token() {
        let coord = makeCoordinator(probe: LoginProbe(storedToken: false))
        XCTAssertEqual(coord.phase, .signedOut)
        XCTAssertFalse(coord.isAuthenticated)
    }

    // MARK: - the happy path: real login stores a token → signedIn + onAuthenticated

    func test_beginSignIn_success_signsIn_and_fires_onAuthenticated_once() async {
        let probe = LoginProbe()
        let coord = makeCoordinator(probe: probe)
        await coord.handle(.beginSignIn)?.value
        XCTAssertEqual(coord.phase, .signedIn)
        XCTAssertTrue(coord.isAuthenticated)
        XCTAssertEqual(probe.loginCalls, 1)
        XCTAssertEqual(probe.authFired, 1, "onAuthenticated fires exactly once on a real login")
    }

    // MARK: - GATE #2: login returned but NO token stored → NOT signed-in (never fake)

    func test_login_returns_without_a_stored_token_is_not_signedIn() async {
        let probe = LoginProbe()
        // login "succeeds" but leaves no token in the store (e.g., a Keychain write failure swallowed upstream).
        let coord = makeCoordinator(probe: probe, login: { /* no token stored */ })
        await coord.handle(.beginSignIn)?.value
        XCTAssertEqual(coord.phase, .unavailable(.secureStorage))
        XCTAssertFalse(coord.isAuthenticated)
        XCTAssertEqual(probe.authFired, 0, "no token → onAuthenticated must NOT fire")
    }

    // MARK: - error mapping

    func test_network_error_is_unavailable_network() async {
        let probe = LoginProbe()
        let coord = makeCoordinator(probe: probe, login: { throw NativeAuthError.network("down") })
        await coord.handle(.beginSignIn)?.value
        XCTAssertEqual(coord.phase, .unavailable(.network))
        XCTAssertFalse(coord.isAuthenticated)
    }

    func test_userCancelledWeb_returns_to_signedOut() async {
        let probe = LoginProbe()
        let coord = makeCoordinator(probe: probe, login: { throw NativeAuthError.userCancelledWeb })
        await coord.handle(.beginSignIn)?.value
        XCTAssertEqual(coord.phase, .signedOut, "a user cancel returns to the clean sign-in prompt")
    }

    func test_rejected_returns_to_signedOut() async {
        let probe = LoginProbe()
        let coord = makeCoordinator(probe: probe, login: { throw NativeAuthError.rejected })
        await coord.handle(.beginSignIn)?.value
        XCTAssertEqual(coord.phase, .signedOut)
    }

    func test_timedOut_is_unavailable_service() async {
        let probe = LoginProbe()
        let coord = makeCoordinator(probe: probe, login: { throw NativeAuthError.timedOut })
        await coord.handle(.beginSignIn)?.value
        XCTAssertEqual(coord.phase, .unavailable(.service))
    }

    // MARK: - sign-out + cancel

    func test_signOut_clears_the_token_and_returns_signedOut() async {
        let probe = LoginProbe(storedToken: true)
        let coord = makeCoordinator(probe: probe)
        XCTAssertEqual(coord.phase, .signedIn)
        coord.handle(.signOut)
        XCTAssertEqual(coord.phase, .signedOut)
        XCTAssertFalse(probe.storedToken, "sign-out cleared the stored token")
        XCTAssertFalse(coord.isAuthenticated)
    }

    func test_beginSignIn_while_authorizing_is_ignored() async {
        let probe = LoginProbe()
        // A login that never completes on its own, so we can observe the .authorizing window.
        let coord = makeCoordinator(probe: probe, login: {
            probe.loginCalls += 1
            try? await Task.sleep(nanoseconds: 50_000_000)
            probe.storedToken = true
        })
        let first = coord.handle(.beginSignIn)
        XCTAssertEqual(coord.phase, .authorizing)
        let second = coord.handle(.beginSignIn)   // must be ignored while a login is in flight
        XCTAssertNil(second, "a second beginSignIn while authorizing must not start a second device flow")
        await first?.value
        XCTAssertEqual(coord.phase, .signedIn)
        XCTAssertEqual(probe.loginCalls, 1, "only ONE device flow ran")
    }
}
