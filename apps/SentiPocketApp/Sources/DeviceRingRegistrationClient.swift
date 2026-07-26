// DeviceRingRegistrationClient — the DEVICE-SIDE outbound-binding for DIALS (Atlas; closes the gap warden verified
// at 322177). A ring can only be ADDRESSED to this device if the gateway knows its APNs VoIP token, so on login (and
// on every APNs token rotation) the app registers {voipToken, sessionId, platform} over the AUTHENTICATED
// POST /dial/register. Without this the whole push→receiveState→hydrate→orchestrate flow is undeliverable in the
// background — SentiCallManager.onVoipToken fires the token but, until this client is wired, it's discarded.
//
// SECURITY (warden's pre-flight gate on the confused-deputy model, same shape as /dial/ring-owner):
//   1. AUTHED — the POST carries the device's SESSION BEARER (SessionTokenStore). An unauthenticated register would
//      let anyone plant a token against someone else's rings.
//   2. NO SPOOFABLE humanId — the body is {voipToken, sessionId, platform} ONLY. The gateway derives humanId from the
//      auth context (dial-registry.mjs), NEVER from the body; sending a body humanId would be a confused-deputy vector.
//   3. sessionId MUST be one the human belongs to — the gateway membership-gates it (a non-member sessionId → 403).
//   4. ROTATION — this client is STATELESS; the CALLER re-invokes it on login AND on every onVoipToken (the gateway
//      upsert is idempotent), so a rotated APNs token re-binds without a duplicate.
//   5. token shape — lowercase hex (the PKPushRegistry token.map { %02x } join, already correct at SentiCallKit L131).
//
// Wire is SOURCE-CONFIRMED by relay (handlers.mjs handleDialRegister L576 + dial-registry.mjs L49-57, 322300):
//   • POST /dial/register; body {voipToken, sessionId, platform} EXACTLY (a body humanId is ignored — gate #2).
//   • SCOPE: the bearer MUST carry `pocket:dial` (same as GET /dial?id=) — else 403; this is a login-scope requirement
//     the SignInCoordinator's token must satisfy, not something this client can add.
//   • platform: valid = ['apns','fcm'] (NOT 'ios'); iOS sends 'apns' (server defaults 'apns' if omitted).
//   • sessionId must be a MEMBER session of the human (gateway isMember check) — a non-member → 403.
//   • 413 if the voipToken exceeds the byte cap; 501 if the deviceRegistry backend isn't wired (deploy, not client).

import Foundation

enum DeviceRingRegistrationError: LocalizedError, Equatable {
    case notLoggedIn                 // no session bearer yet → defer; register once login lands
    case notAuthorized               // 401 / 403 — bad/absent auth, or sessionId isn't one the human belongs to
    case retryable(Int)              // 5xx — transient; safe to re-register later
    case rejected(Int)               // other non-2xx 4xx — won't succeed on retry (bad request)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:      return "Sign in first — registering this device for rings needs your Senti session."
        case .notAuthorized:    return "Not authorized to register this device for that session."
        case .retryable(let c): return "The gateway couldn't register the device (HTTP \(c)) — will retry."
        case .rejected(let c):  return "The gateway rejected the device registration (HTTP \(c))."
        case .network(let m):   return "Device-registration network error: \(m)"
        }
    }
}

/// Registers THIS device's APNs VoIP token with the gateway so a ring can target it. Stateless: the caller owns WHEN
/// to register (on login + on every onVoipToken). Injectable `urlSession`/`tokenProvider` so the POST is hermetic.
struct DeviceRingRegistrationClient {
    private let apiBaseURL: URL
    private let urlSession: URLSession
    private let tokenProvider: @Sendable () -> String?

    init(apiBaseURL: URL,
         urlSession: URLSession = .shared,
         tokenProvider: @escaping @Sendable () -> String? = { SessionTokenStore.load() }) {
        self.apiBaseURL = apiBaseURL
        self.urlSession = urlSession
        self.tokenProvider = tokenProvider
    }

    /// The body — {voipToken, sessionId, platform} ONLY. NO humanId (warden gate #2: the gateway derives it from auth;
    /// a body humanId would be a confused-deputy vector to bind THIS token against ANOTHER human's rings).
    private struct RegisterRequest: Encodable {
        let voipToken: String
        let sessionId: String
        let platform: String
    }

    /// Bind {voipToken, sessionId, platform} to the human (from the Bearer) at the gateway. `platform` defaults to
    /// "apns" — the gateway's valid set is ['apns','fcm'] (relay 322300), and iOS/PushKit is always APNs; an invalid
    /// platform → 400. Throws the taxonomy above; a 2xx is success (idempotent upsert — no body is required or read back).
    func register(voipToken: String, sessionId: String, platform: String = "apns") async throws {
        guard let token = tokenProvider(), !token.isEmpty else { throw DeviceRingRegistrationError.notLoggedIn }
        guard !voipToken.isEmpty, !sessionId.isEmpty else {
            throw DeviceRingRegistrationError.rejected(400)   // never POST an empty binding
        }
        guard let url = URL(string: "/dial/register", relativeTo: apiBaseURL) else {
            throw DeviceRingRegistrationError.network("bad register url")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")   // authed; humanId derived server-side
        req.httpBody = try JSONEncoder().encode(RegisterRequest(voipToken: voipToken, sessionId: sessionId, platform: platform))

        let response: URLResponse
        do { (_, response) = try await urlSession.data(for: req) }
        catch { throw DeviceRingRegistrationError.network(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw DeviceRingRegistrationError.network("no HTTP response") }

        switch http.statusCode {
        case 200..<300:
            return                                            // idempotent upsert ok — nothing to decode
        case 401, 403:
            throw DeviceRingRegistrationError.notAuthorized   // bad auth OR sessionId not one the human belongs to
        case 500..<600:
            throw DeviceRingRegistrationError.retryable(http.statusCode)
        default:
            throw DeviceRingRegistrationError.rejected(http.statusCode)
        }
    }
}
