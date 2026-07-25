// DialSignalClient — the app's authed GET /dial?id= client (Forge). When a LEAN ring is answered, the phone
// hydrates the full governed signal over the MEMBERSHIP-GATED authed GET (relay's PR-B2 dial-signal-store):
// `GET /dial?id=<dialId>` → the full stored NeedCarterSignal. This is the CONSUMER half of the LEAN-push model —
// governed content (message/options/evidenceSeqs) is fetched here under the user's bearer token, NEVER from the
// unauthenticated push. App-shell network lane: relay owns the SERVER route (handleDialFetch); this is the app's client.
//
// Auth mirrors the other app clients (GatewayReasoningHTTPClient / PocketWriteClient): bearer = SessionTokenStore.load()
// (Keychain) as `Authorization: Bearer`. A missing/absent signal (404) is surfaced distinctly (`.notFound`) so the
// answered-call flow can END the call gracefully rather than treat an expired ring as a generic network error.

import Foundation
import PocketContracts

enum DialSignalError: LocalizedError, Equatable {
    case notLoggedIn
    case notFound
    case http(Int)
    case network(String)
    case malformedResponse
    var errorDescription: String? {
        switch self {
        case .notLoggedIn:       return "Sign in to answer this call."
        case .notFound:          return "This decision is no longer available."
        case .http(let c):       return "The dial gateway returned HTTP \(c)."
        case .network(let m):    return "Dial gateway unreachable: \(m)"
        case .malformedResponse: return "The dial gateway returned an unexpected response."
        }
    }
}

struct DialSignalClient {
    private let apiBaseURL: URL
    private let urlSession: URLSession
    /// Injected so tests supply the token without a Keychain; defaults to the real session store.
    private let tokenProvider: @Sendable () -> String?

    init(apiBaseURL: URL,
         urlSession: URLSession = .shared,
         tokenProvider: @escaping @Sendable () -> String? = { SessionTokenStore.load() }) {
        self.apiBaseURL = apiBaseURL
        self.urlSession = urlSession
        self.tokenProvider = tokenProvider
    }

    /// `GET /dial?id=<dialId>` → the full stored NeedCarterSignal (membership-gated, authed). Throws `.notFound`
    /// on 404 (no such / expired ring), `.notLoggedIn` on a missing token, `.http` on other non-2xx.
    func fetchDial(id dialId: String) async throws -> NeedCarterSignal {
        guard let token = tokenProvider(), !token.isEmpty else { throw DialSignalError.notLoggedIn }
        guard var comps = URLComponents(url: apiBaseURL.appendingPathComponent("dial"), resolvingAgainstBaseURL: false) else {
            throw DialSignalError.network("bad base url")
        }
        comps.queryItems = [URLQueryItem(name: "id", value: dialId)]
        guard let url = comps.url else { throw DialSignalError.network("bad url") }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")  // membership-gated (scope pocket:dial)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await urlSession.data(for: req) }
        catch { throw DialSignalError.network(error.localizedDescription) }
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 { throw DialSignalError.notFound }
            guard (200..<300).contains(http.statusCode) else { throw DialSignalError.http(http.statusCode) }
        }
        do { return try JSONDecoder().decode(NeedCarterSignal.self, from: data) }
        catch { throw DialSignalError.malformedResponse }
    }
}
