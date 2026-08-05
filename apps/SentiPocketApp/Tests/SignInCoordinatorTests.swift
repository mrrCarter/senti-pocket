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
        var protectedStateClears = 0
        init(storedToken: Bool = false) { self.storedToken = storedToken }
    }

    @MainActor
    private final class AsyncGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            let current = waiters
            waiters.removeAll()
            current.forEach { $0.resume() }
        }
    }

    private func makeCoordinator(
        probe: LoginProbe,
        login: (() async throws -> Void)? = nil   // optional closures are already escaping — no @escaping here
    ) -> SignInCoordinator {
        let defaultLogin: () async throws -> Void = { probe.loginCalls += 1; probe.storedToken = true }
        let coord = SignInCoordinator(
            login: login ?? defaultLogin,
            isLoggedIn: { probe.storedToken },
            signOut: { probe.storedToken = false },
            clearProtectedLocalState: { probe.protectedStateClears += 1 })
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
        let probe = LoginProbe(storedToken: false)
        let coord = makeCoordinator(probe: probe)
        XCTAssertEqual(coord.phase, .signedOut)
        XCTAssertFalse(coord.isAuthenticated)
        XCTAssertEqual(probe.protectedStateClears, 1,
                       "a stale confirmed intent must not survive launch without its credential")
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
        await coord.handle(.signOut)?.value
        XCTAssertEqual(coord.phase, .signedOut)
        XCTAssertFalse(probe.storedToken, "sign-out cleared the stored token")
        XCTAssertEqual(probe.protectedStateClears, 1)
        XCTAssertFalse(coord.isAuthenticated)
    }

    func test_signOut_awaits_old_bearer_revoke_before_credential_delete() async {
        let probe = LoginProbe(storedToken: true)
        var events: [String] = []
        let coord = SignInCoordinator(
            login: {},
            isLoggedIn: { probe.storedToken },
            signOut: {
                events.append("delete")
                probe.storedToken = false
            },
            clearProtectedLocalState: {
                events.append("clear")
                probe.protectedStateClears += 1
            }
        )
        coord.onSignOutStarted = {
            XCTAssertTrue(probe.storedToken)
            events.append("close")
        }
        coord.onWillSignOut = {
            XCTAssertTrue(probe.storedToken, "the old bearer must still exist during exact registry DELETE")
            events.append("revoke")
        }

        await coord.handle(.signOut)?.value

        XCTAssertEqual(events, ["close", "clear", "revoke", "delete"])
        XCTAssertEqual(coord.phase, .signedOut)
    }

    func test_signOut_closes_authority_synchronously_before_handle_returns() async {
        let probe = LoginProbe(storedToken: true)
        let coord = makeCoordinator(probe: probe)
        var started = false
        coord.onSignOutStarted = { started = true }

        let task = coord.handle(.signOut)

        XCTAssertTrue(started)
        XCTAssertEqual(coord.phase, .signingOut)
        await task?.value
        XCTAssertEqual(coord.phase, .signedOut)
    }

    func test_failed_registry_revoke_retains_bearer_and_retry_never_starts_login() async {
        let probe = LoginProbe(storedToken: true)
        var revokeAttempts = 0
        var deleteCalls = 0
        let coord = SignInCoordinator(
            login: { probe.loginCalls += 1 },
            isLoggedIn: { probe.storedToken },
            signOut: {
                deleteCalls += 1
                probe.storedToken = false
            },
            clearProtectedLocalState: {}
        )
        coord.onWillSignOut = {
            revokeAttempts += 1
            if revokeAttempts == 1 {
                throw DeviceRingSignOutError.revocationIncomplete
            }
        }

        await coord.handle(.signOut)?.value
        XCTAssertEqual(coord.phase, .unavailable(.service))
        XCTAssertTrue(coord.isSignOutPending)
        XCTAssertTrue(probe.storedToken)
        XCTAssertEqual(deleteCalls, 0)

        await coord.handle(.retryAuthentication)?.value
        XCTAssertEqual(coord.phase, .signedOut)
        XCTAssertFalse(coord.isSignOutPending)
        XCTAssertFalse(probe.storedToken)
        XCTAssertEqual(revokeAttempts, 2)
        XCTAssertEqual(deleteCalls, 1)
        XCTAssertEqual(probe.loginCalls, 0, "retry must finish sign-out with the old bearer, never start login")
    }

    func test_401_during_signOut_reauthenticates_only_to_finish_exact_revoke() async {
        let probe = LoginProbe(storedToken: true)
        var coordinator: SignInCoordinator!
        var revokeAttempts = 0
        var authenticatedCallbacks = 0
        var deleteCalls = 0
        coordinator = SignInCoordinator(
            login: {
                probe.loginCalls += 1
                probe.storedToken = true
            },
            isLoggedIn: { probe.storedToken },
            signOut: {
                deleteCalls += 1
                probe.storedToken = false
            },
            clearProtectedLocalState: {}
        )
        coordinator.onAuthenticated = { authenticatedCallbacks += 1 }
        coordinator.onWillSignOut = {
            revokeAttempts += 1
            if revokeAttempts == 1 {
                coordinator.invalidateAuthentication()
                throw DeviceRingRegistrationError.reauthenticationRequired
            }
        }

        await coordinator.handle(.signOut)?.value
        XCTAssertEqual(coordinator.phase, .reauthenticationRequired)
        XCTAssertTrue(coordinator.isSignOutPending)
        XCTAssertFalse(probe.storedToken)
        XCTAssertEqual(deleteCalls, 1, "the rejected bearer is removed before cleanup reauthentication")

        await coordinator.handle(.retryAuthentication)?.value

        XCTAssertEqual(probe.loginCalls, 1)
        XCTAssertEqual(authenticatedCallbacks, 1, "fresh auth is given to the registrar only for revoke")
        XCTAssertEqual(revokeAttempts, 2)
        XCTAssertEqual(deleteCalls, 2, "the fresh cleanup bearer is deleted after exact revoke")
        XCTAssertFalse(coordinator.isSignOutPending)
        XCTAssertEqual(coordinator.phase, .signedOut)
        XCTAssertFalse(probe.storedToken)
    }

    func test_revocation_marker_failure_retains_bearer_for_retry() async {
        let probe = LoginProbe(storedToken: true)
        let coord = makeCoordinator(probe: probe)
        var shouldFail = true
        coord.onSignOutStarted = {
            if shouldFail {
                shouldFail = false
                throw DeviceRingSignOutError.secureState
            }
        }

        await coord.handle(.signOut)?.value
        XCTAssertEqual(coord.phase, .unavailable(.secureStorage))
        XCTAssertTrue(coord.isSignOutPending)
        XCTAssertTrue(probe.storedToken)

        await coord.handle(.retryAuthentication)?.value
        XCTAssertEqual(coord.phase, .signedOut)
        XCTAssertFalse(coord.isSignOutPending)
        XCTAssertFalse(probe.storedToken)
        XCTAssertEqual(probe.loginCalls, 0)
    }

    func test_signOut_keychain_delete_failure_never_claims_clean_signedOut() async {
        struct DeleteFailure: Error {}
        let probe = LoginProbe(storedToken: true)
        var shouldFail = true
        var loginCalls = 0
        let coord = SignInCoordinator(
            login: { loginCalls += 1 },
            isLoggedIn: { probe.storedToken },
            signOut: {
                if shouldFail {
                    shouldFail = false
                    throw DeleteFailure()
                }
                probe.storedToken = false
            },
            clearProtectedLocalState: {}
        )

        await coord.handle(.signOut)?.value

        XCTAssertEqual(coord.phase, .unavailable(.secureStorage))
        XCTAssertTrue(probe.storedToken)

        await coord.handle(.retryAuthentication)?.value
        XCTAssertEqual(coord.phase, .signedOut)
        XCTAssertFalse(probe.storedToken)
        XCTAssertEqual(loginCalls, 0)
    }

    func test_cancelSignIn_is_ignored_while_signingOut() async {
        let probe = LoginProbe(storedToken: true)
        let gate = AsyncGate()
        let coord = makeCoordinator(probe: probe)
        coord.onWillSignOut = { await gate.wait() }

        let task = coord.handle(.signOut)
        XCTAssertEqual(coord.phase, .signingOut)
        XCTAssertNil(coord.handle(.cancelSignIn))
        XCTAssertEqual(coord.phase, .signingOut)

        gate.open()
        await task?.value
        XCTAssertEqual(coord.phase, .signedOut)
        XCTAssertFalse(probe.storedToken)
    }

    func test_protected_api_401_clears_token_and_requires_reauthentication() {
        let probe = LoginProbe(storedToken: true)
        let coord = makeCoordinator(probe: probe)

        coord.invalidateAuthentication()

        XCTAssertEqual(coord.phase, .reauthenticationRequired)
        XCTAssertFalse(coord.isAuthenticated)
        XCTAssertFalse(probe.storedToken, "a rejected bearer must not remain in the credential store")
        XCTAssertEqual(probe.protectedStateClears, 1,
                       "a confirmed write must never survive into a potentially different account")
    }

    func test_protected_api_401_closes_runtime_authority_before_local_state_and_token() {
        let probe = LoginProbe(storedToken: true)
        var events: [String] = []
        let coord = SignInCoordinator(
            login: {},
            isLoggedIn: { probe.storedToken },
            signOut: {
                events.append("delete")
                probe.storedToken = false
            },
            clearProtectedLocalState: { events.append("clear") }
        )
        coord.onAuthenticationRevoked = { events.append("close") }

        coord.invalidateAuthentication()

        XCTAssertEqual(events, ["close", "clear", "delete"])
        XCTAssertEqual(coord.phase, .reauthenticationRequired)
    }

    func test_protected_api_401_keychain_delete_failure_stays_fail_closed() {
        struct DeleteFailure: Error {}
        let probe = LoginProbe(storedToken: true)
        let coord = SignInCoordinator(
            login: {},
            isLoggedIn: { probe.storedToken },
            signOut: { throw DeleteFailure() },
            clearProtectedLocalState: { probe.protectedStateClears += 1 }
        )

        coord.invalidateAuthentication()

        XCTAssertEqual(coord.phase, .unavailable(.secureStorage))
        XCTAssertFalse(coord.isAuthenticated)
        XCTAssertTrue(probe.storedToken)
        XCTAssertEqual(probe.protectedStateClears, 1)
    }

    func test_authentication_invalidation_is_ignored_when_not_signed_in() {
        let probe = LoginProbe()
        let coord = makeCoordinator(probe: probe)

        coord.invalidateAuthentication()

        XCTAssertEqual(coord.phase, .signedOut)
        XCTAssertFalse(probe.storedToken)
    }

    func test_stale_authentication_epoch_cannot_sign_out_a_later_login() async {
        let probe = LoginProbe(storedToken: true)
        let coord = makeCoordinator(probe: probe)
        let principalAEpoch = coord.authenticationEpoch

        await coord.handle(.signOut)?.value
        await coord.handle(.beginSignIn)?.value
        XCTAssertTrue(coord.isAuthenticated)
        XCTAssertNotEqual(coord.authenticationEpoch, principalAEpoch)

        coord.invalidateAuthentication(expectedEpoch: principalAEpoch)

        XCTAssertTrue(coord.isAuthenticated, "a delayed callback retained by principal A must not sign principal B out")
        XCTAssertTrue(probe.storedToken)
    }

    func test_beginSignIn_while_authorizing_is_ignored() async {
        let probe = LoginProbe()
        let gate = AsyncGate()
        let coord = makeCoordinator(probe: probe, login: {
            probe.loginCalls += 1
            await gate.wait()
            probe.storedToken = true
        })
        let first = coord.handle(.beginSignIn)
        XCTAssertEqual(coord.phase, .authorizing)
        let second = coord.handle(.beginSignIn)   // must be ignored while a login is in flight
        XCTAssertNil(second, "a second beginSignIn while authorizing must not start a second device flow")
        gate.open()
        await first?.value
        XCTAssertEqual(coord.phase, .signedIn)
        XCTAssertEqual(probe.loginCalls, 1, "only ONE device flow ran")
    }
}
