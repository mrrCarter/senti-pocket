// DialHydrationClient — the app-shell HYDRATION SEAM for an incoming ring. It bridges the two halves that already
// live on master (DialReceive.receive → a DialReceiveState, and DialHydration.merge → a RenderableRing) with the ONE
// missing piece: the authenticated GET /dial?id= fetch. This is the receive→fetch→merge glue, and it is deliberately
// where the authed-fetch + hydration-security logic lives, so the CallKit answer path (forge's onAnswered) is a THIN
// call: `let ring = try await dialHydrationClient.hydrate(DialReceive.receive(pushData))` → DialOrchestrator.run(ring).
//
// SECURITY (warden's doorbell model): a LEAN push is a DOORBELL — governed content (message/options/evidence) is
// NEVER taken from the unauthenticated push. This client fetches the full NeedCarterSignal over the AUTHENTICATED,
// membership-gated GET /dial?id= and routes it THROUGH DialHydration.merge, which refuses a substituted signal
// (id/session/checkpoint must match the push core). The gateway collapses absent | expired | non-member to a uniform
// 410 (existence-oracle-safe), so this client treats every 410 identically as `.unavailable` — it never distinguishes.

import Foundation
import PocketContracts

enum DialHydrationClientError: LocalizedError, Equatable {
    case notLoggedIn
    case reauthenticationRequired
    case supersededAuthentication
    case unavailable                 // uniform 410 gone: absent | expired | not a member — NEVER distinguished
    case notAuthorized               // 403 (missing pocket:dial scope / session access)
    case notConfigured               // 501 (dial hydration not wired server-side)
    case network(String)
    case retryable(String)           // 500 / 503 / other 5xx — transient, safe to retry
    case rejected(String)            // 400 / other terminal 4xx — won't succeed on retry
    case malformedResponse
    case hydrationRefused(String)    // DialHydration.merge refused the fetched signal (substitution) — TERMINAL, never retry

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:          return "Sign in first — hydrating a ring needs your Senti session."
        case .reauthenticationRequired:
            return "Your Senti authorization expired. Sign in again before answering this ring."
        case .supersededAuthentication:
            return "The ring response belonged to an earlier sign-in and was ignored."
        case .unavailable:          return "This ring is no longer available."
        case .notAuthorized:        return "Not authorized to hydrate this ring."
        case .notConfigured:        return "Ring hydration isn't configured on the server."
        case .network(let m):       return "Ring hydration network error: \(m)"
        case .retryable(let m):     return "The gateway is busy hydrating the ring — will retry: \(m)"
        case .rejected(let m):      return "The gateway rejected the hydration: \(m)"
        case .malformedResponse:    return "The gateway returned an unexpected hydration response."
        case .hydrationRefused(let m): return "Refused: the fetched signal did not match the ring — \(m)"
        }
    }
}

@MainActor
final class DialHydrationClient {
    private let apiBaseURL: URL
    private let urlSession: URLSession
    private let tokenProvider: () -> String?
    private let onReauthenticationRequired: @Sendable (String?) -> Void

    /// `tokenProvider` defaults to the real Keychain session token (SessionTokenStore) but is injectable so the
    /// fetch is hermetically testable (adopted from forge's DialSignalClient #97 — the one improvement to fold in).
    init(apiBaseURL: URL,
         urlSession: URLSession = .shared,
         tokenProvider: @escaping () -> String? = { SessionTokenStore.load() },
         onReauthenticationRequired: @escaping @Sendable (String?) -> Void = { _ in }) {
        self.apiBaseURL = apiBaseURL
        self.urlSession = urlSession
        self.tokenProvider = tokenProvider
        self.onReauthenticationRequired = onReauthenticationRequired
    }

    /// The single seam. Hand it a decoded receive state, get a renderable ring:
    ///  • `.renderable(r)`     — a RICH push (fetch=false), already complete → returned as-is (NO fetch, nothing to hydrate).
    ///  • `.needsHydration`    — a LEAN push (fetch=true) → authed GET /dial?id= → decode signal → merge → RenderableRing.
    ///  • `.rejected(reason)`  — the push was malformed → throw (never fetch or ring on bad transport).
    func hydrate(_ state: DialReceiveState) async throws -> RenderableRing {
        switch state {
        case .renderable(let ring):
            return ring
        case .rejected(let reason):
            throw DialHydrationClientError.rejected(reason)
        case .needsHydration(let id, let core):
            return try await fetchAndMerge(id: id, core: core)
        }
    }

    /// Fetch the FULL NeedCarterSignal over the authenticated GET /dial?id= and merge it onto the push core. The merge
    /// is the security gate: a signal whose id/session/checkpoint doesn't match the push is refused, never rendered.
    private func fetchAndMerge(id: String, core: RingCore) async throws -> RenderableRing {
        guard let token = tokenProvider(), !token.isEmpty else {
            onReauthenticationRequired(nil)
            throw DialHydrationClientError.notLoggedIn
        }
        guard var comps = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: true) else {
            throw DialHydrationClientError.network("bad gateway base url")
        }
        comps.path = "/dial"
        comps.queryItems = [URLQueryItem(name: "id", value: id)]   // URLComponents percent-encodes the id
        guard let url = comps.url else { throw DialHydrationClientError.network("bad dial hydration url") }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response): (Data, URLResponse)
        do { (data, response) = try await urlSession.data(for: req) }
        catch { throw DialHydrationClientError.network(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw DialHydrationClientError.malformedResponse }

        switch http.statusCode {
        case 200:
            break
        case 401:
            guard tokenProvider() == token else {
                throw DialHydrationClientError.supersededAuthentication
            }
            onReauthenticationRequired(token)
            throw DialHydrationClientError.reauthenticationRequired
        case 403:
            throw DialHydrationClientError.notAuthorized
        case 410:
            throw DialHydrationClientError.unavailable                    // uniform gone — never reveal absent vs non-member vs expired
        case 501:
            throw DialHydrationClientError.notConfigured
        case 400:
            throw DialHydrationClientError.rejected(Self.reason(data) ?? "bad request")
        default:
            if (500..<600).contains(http.statusCode) {
                throw DialHydrationClientError.retryable(Self.reason(data) ?? "HTTP \(http.statusCode)")
            }
            throw DialHydrationClientError.rejected(Self.reason(data) ?? "HTTP \(http.statusCode)")
        }

        // The 200 body is the BARE stored NeedCarterSignal (json(200, signal)) — the exact object the shared KAV
        // (need-carter-signal-v1.json) locks and NeedCarterSignal's custom Codable decodes (Unix-epoch createdAt etc.).
        let signal: NeedCarterSignal
        do { signal = try JSONDecoder().decode(NeedCarterSignal.self, from: data) }
        catch { throw DialHydrationClientError.malformedResponse }

        // The security gate: bind the authed signal to the push core. A mismatch is a substitution → refuse (terminal).
        do {
            return try DialHydration.merge(core: core, fetched: signal)
        } catch let e as DialHydrationError {
            throw DialHydrationClientError.hydrationRefused(e.errorDescription ?? "signal did not match the ring")
        }
    }

    /// Decode the gateway's `{error, reason}` envelope for a human-readable failure (tolerant — never throws).
    private static func reason(_ data: Data) -> String? {
        struct Env: Decodable { let error: String?; let reason: String? }
        let env = try? JSONDecoder().decode(Env.self, from: data)
        return env?.reason ?? env?.error
    }
}
