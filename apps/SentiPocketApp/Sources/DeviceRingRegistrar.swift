// DeviceRingRegistrar — decides WHEN to register this device's APNs VoIP token with the gateway (Atlas; PR 2, onto the
// now-live login #103). A ring can only be ADDRESSED to this device once the gateway knows its VoIP token
// (POST /dial/register), and that POST needs the session Bearer — so registration must happen when BOTH are present.
// This caches the latest token and (re)registers on EITHER trigger:
//   • tokenUpdated  — SentiCallManager.onVoipToken fired (the APNs token arrived at launch or ROTATED)
//   • loginCompleted — SignInCoordinator.onAuthenticated fired (login just persisted a Bearer)
// So it's correct whether the token arrives BEFORE login (cached → registered on loginCompleted) or AFTER
// (registered immediately since we're already logged in). The gateway upsert is idempotent, so a double-fire is safe.
//
// It attaches one coordinator-authorized selected sessionId (the gateway membership-gates it, warden gate #3) and
// drives the DeviceRingRegistrationClient, which enforces the rest of warden's 5-gate (authed Bearer, no
// spoofable humanId, apns platform). Registration is best-effort: a transient failure is retried by the next trigger.
// The current gateway has no unregister/lease operation, so invalidate() revokes local authority only; receive-time
// selection gating in SentiCallManager keeps any late push generic and non-actionable until that server contract lands.

import Foundation

@MainActor
final class DeviceRingRegistrar {
    private let client: DeviceRingRegistrationClient
    private let sessionId: String
    private let isLoggedIn: () -> Bool
    private var latestToken: String?
    private var inFlight: Task<Void, Never>?

    init(client: DeviceRingRegistrationClient,
         sessionId: String,
         isLoggedIn: @escaping () -> Bool = { SessionTokenStore.load() != nil }) {
        self.client = client
        self.sessionId = sessionId
        self.isLoggedIn = isLoggedIn
    }

    /// The APNs VoIP token arrived or ROTATED (SentiCallManager.onVoipToken). Cache it, then register if we have a Bearer.
    /// Returns the in-flight register Task (for tests); call sites discard it.
    @discardableResult
    func tokenUpdated(_ token: String) -> Task<Void, Never>? {
        latestToken = token
        return registerIfReady()
    }

    /// Login just persisted a Bearer (SignInCoordinator.onAuthenticated). Register the cached token (if one arrived).
    @discardableResult
    func loginCompleted() -> Task<Void, Never>? {
        return registerIfReady()
    }

    /// Register ONLY when a non-empty token is cached AND we're logged in (a Bearer exists). Returns the in-flight Task
    /// (for tests); `@discardableResult` for the call sites. Supersedes any prior in-flight register (idempotent upsert).
    @discardableResult
    func registerIfReady() -> Task<Void, Never>? {
        guard let token = latestToken, !token.isEmpty, isLoggedIn() else { return nil }
        inFlight?.cancel()
        let client = self.client              // capture value types into the Task (no self retained inside)
        let sessionId = self.sessionId
        let task = Task {
            // Best-effort: the client carries the Bearer + enforces no-humanId/apns; a transient failure is retried by
            // the next tokenUpdated/loginCompleted trigger. The upsert is idempotent, so re-registering is harmless.
            // `_ =` discards the Void? from `try?` so the closure is Task<Void, Never>, not Task<Void?, Never>.
            _ = try? await client.register(voipToken: token, sessionId: sessionId)
        }
        inFlight = task
        return task
    }

    /// A session selection or authentication transition revokes this fixed-session registrar immediately.
    func invalidate() {
        inFlight?.cancel()
        inFlight = nil
        latestToken = nil
    }

    deinit {
        inFlight?.cancel()
    }
}
