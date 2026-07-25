// SignInCoordinator — the app-shell composition that makes the native login LIVE, not just present (Atlas; closes the
// login-unwired gap warden verified at 322268). The machinery already existed — SentiNativeAuth.login() (the real
// device flow), PocketSignInView (the UI), SessionTokenStore (the Keychain), PocketSignInPhase/Intent — but NOTHING
// composed them, so the real PhoneRootView flow could never obtain a session token and every authed client
// (hydrate/reason/write) returned .notLoggedIn. This maps PocketProductIntent → the REAL SentiNativeAuth.login() and
// drives PocketSignInPhase, so SentiPocketApp can gate the authed surfaces behind sign-in.
//
// WARDEN GATE (322268):
//   1. gate-on-isLoggedIn — SentiPocketApp shows the authed flow ONLY when `isAuthenticated`; signed-out → sign-in.
//   2. real-login-no-fake — `login` runs the REAL device flow; we claim `.signedIn` ONLY if a real token actually
//      landed in the store (`isLoggedIn()` true after login). A login that returns without a stored token is NOT a
//      success — it becomes `.unavailable(.secureStorage)`. No debug bypass, no fabricated token, in any build.
//   3. live-verify — after wiring, the real flow obtains a token and the clients stop returning .notLoggedIn. That
//      run-the-app proof is a device/Mac step (forge), not a static claim.
//
// `login` is injected (not a hard SentiNativeAuth dependency) so (a) the composition site binds the real auth-API
// config, and (b) tests drive the state machine hermetically. `onAuthenticated` is the post-login hook the device
// VoIP-register wires into (a ring can only reach this device once its token is registered — needs the fresh Bearer).

import Foundation
import PocketUI

@MainActor
final class SignInCoordinator: ObservableObject {
    @Published private(set) var phase: PocketSignInPhase

    /// The REAL login (device flow → SessionTokenStore.save). Injected so the composition binds the auth-API config
    /// and tests stay hermetic. Throws on failure (NativeAuthError, mapped to a phase below).
    private let login: () async throws -> Void
    /// Truth source for "is a real token in the store" — defaults to the Keychain-backed SentiNativeAuth.isLoggedIn.
    private let isLoggedIn: () -> Bool
    /// Sign-out side effect — defaults to clearing the Keychain token.
    private let signOutAction: () -> Void

    /// Fired AFTER a login that leaves a real token in the store (and once at launch if already signed in is handled
    /// by the caller). The device VoIP-register hooks here — it needs the fresh Bearer to POST /dial/register.
    var onAuthenticated: (() -> Void)?

    private var loginTask: Task<Void, Never>?

    init(login: @escaping () async throws -> Void,
         // NB: default is the nonisolated `SessionTokenStore.load() != nil` (exactly what SentiNativeAuth.isLoggedIn
         // computes) — referencing the @MainActor `SentiNativeAuth.isLoggedIn` from this nonisolated default-arg
         // context is a concurrency error (caught on the Mac build).
         isLoggedIn: @escaping () -> Bool = { SessionTokenStore.load() != nil },
         signOut: @escaping () -> Void = { SessionTokenStore.delete() }) {
        self.login = login
        self.isLoggedIn = isLoggedIn
        self.signOutAction = signOut
        self.phase = isLoggedIn() ? .signedIn : .signedOut
    }

    /// The gate SentiPocketApp reads: the authed surfaces are reachable ONLY when this is true.
    var isAuthenticated: Bool { phase == .signedIn }

    /// Void-returning adapter for PocketSignInView's `send: (PocketProductIntent) -> Void` closure (drops the Task).
    func send(_ intent: PocketProductIntent) { handle(intent) }

    /// Map a presentation intent to the real auth flow. Returns the in-flight login Task (if any) so tests can await
    /// it; `@discardableResult` so the view's `send: (PocketProductIntent) -> Void` closure can ignore it.
    @discardableResult
    func handle(_ intent: PocketProductIntent) -> Task<Void, Never>? {
        switch intent {
        case .beginSignIn, .retryAuthentication:
            guard phase != .authorizing else { return nil }   // one login at a time; don't stack device flows
            return startLogin()
        case .cancelSignIn:
            loginTask?.cancel(); loginTask = nil
            phase = .signedOut
            return nil
        case .signOut:
            loginTask?.cancel(); loginTask = nil
            phase = .signingOut
            signOutAction()
            phase = .signedOut
            return nil
        default:
            return nil   // Sessions/activity intents belong to another surface
        }
    }

    private func startLogin() -> Task<Void, Never> {
        phase = .authorizing
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.login()
                if Task.isCancelled { return }
                // GATE #2: only a REAL stored token counts as signed-in — never fake success.
                if self.isLoggedIn() {
                    self.phase = .signedIn
                    self.onAuthenticated?()
                } else {
                    self.phase = .unavailable(.secureStorage)   // login returned but no token persisted
                }
            } catch {
                if Task.isCancelled { return }
                self.phase = Self.mappedPhase(for: error)
            }
        }
        loginTask = task
        return task
    }

    /// NativeAuthError → the credential-free PocketSignInPhase the UI renders. User-driven backouts return to the clean
    /// signed-out prompt; environmental failures surface an `.unavailable` reason.
    static func mappedPhase(for error: Error) -> PocketSignInPhase {
        guard let e = error as? NativeAuthError else { return .unavailable(.service) }
        switch e {
        case .network:                      return .unavailable(.network)
        case .userCancelledWeb, .rejected:  return .signedOut          // user cancelled / denied → clean retry
        case .timedOut, .rateLimited, .malformedResponse: return .unavailable(.service)
        }
    }
}
