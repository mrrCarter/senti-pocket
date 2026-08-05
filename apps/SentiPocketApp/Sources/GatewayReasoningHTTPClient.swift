// GatewayReasoningHTTPClient — the app's concrete HTTP client to relay's GATED reasoning gateway (POST /brief,
// POST /answer). Conforms to PocketReasoning's GatewayReasoningClient seam, so GatewayReasoningProvider gets a real
// online client (unblocks .liveReasoned reasoning on-screen — the online half of the bad-build fix). App-shell lane:
// this is the app's network client; relay owns the SERVER endpoints it calls (bf79a6fa /answer, 4b1feaa /brief).
//
// Request shapes are SOURCE-BOUND to handlers.mjs: /brief {sessionId, checkpointId?}, /answer {sessionId, question,
// checkpointId?}. Both are membership-gated (scope `sync`) → they carry the USER's bearer session token (Keychain).
// Response shapes = BriefWire / AnswerWire (already source-bound in PocketReasoning). A non-2xx / missing-token /
// unconfigured-backend (501) throws → the driver surfaces `.failed` honestly (never a fabricated brief).

import Foundation
import PocketReasoning

/// Bridges Sendable HTTP callbacks back to the app's main-actor authentication gate without retaining a stale
/// composition root. The handler can be installed after an app-lifetime client (DialHost) has been constructed.
final class AuthenticationExpiryRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let tokenProvider: @Sendable () -> String?
    private var handler: (@MainActor @Sendable () -> Void)?

    init(tokenProvider: @escaping @Sendable () -> String? = { SessionTokenStore.load() }) {
        self.tokenProvider = tokenProvider
    }

    func install(_ handler: @escaping @MainActor @Sendable () -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    /// Carry the bearer used by the failed request across the async actor hop. A late 401 from principal A must not
    /// invalidate principal B after a re-login; nil is reserved for a request that found no credential at its start.
    func signal(expectedToken: String?) {
        lock.lock()
        let handler = handler
        lock.unlock()
        guard let handler else { return }
        Task { @MainActor [tokenProvider] in
            guard tokenProvider() == expectedToken else { return }
            handler()
        }
    }
}

enum GatewayReasoningError: LocalizedError {
    case notLoggedIn
    case reauthenticationRequired
    case supersededAuthentication
    case http(Int)
    case network(String)
    case malformedResponse
    var errorDescription: String? {
        switch self {
        case .notLoggedIn:       return "Sign in to reason over your live session."
        case .reauthenticationRequired:
            return "Your Senti authorization expired. Sign in again to reason over this session."
        case .supersededAuthentication:
            return "The reasoning response belonged to an earlier sign-in and was ignored."
        case .http(let c):       return "The reasoning gateway returned HTTP \(c)."
        case .network(let m):    return "Reasoning gateway unreachable: \(m)"
        case .malformedResponse: return "The reasoning gateway returned an unexpected response."
        }
    }
}

struct GatewayReasoningHTTPClient: GatewayReasoningClient {
    /// `/brief` and `/answer` are non-streaming: the gateway can spend up to 5s authenticating and 30s waiting for
    /// Gemma before the first response byte. Keep that healthy path inside the shared session's 60s resource wall
    /// without weakening the 15s default used by the app's ordinary interactive requests.
    private static let reasoningRequestTimeout: TimeInterval = 45

    private let apiBaseURL: URL
    private let urlSession: URLSession
    /// Injected so tests / offline can supply the token without a Keychain; defaults to the real session store.
    private let tokenProvider: @Sendable () -> String?
    /// The reasoning driver intentionally turns provider errors into an honest `.failed` phase. This side-channel
    /// also closes the authenticated app root when the gateway explicitly reports an expired bearer.
    private let onReauthenticationRequired: @Sendable (String?) -> Void

    init(apiBaseURL: URL,
         urlSession: URLSession = SentiHTTPTransportPolicy.liveSession,
         tokenProvider: @escaping @Sendable () -> String? = { SessionTokenStore.load() },
         onReauthenticationRequired: @escaping @Sendable (String?) -> Void = { _ in }) {
        self.apiBaseURL = apiBaseURL
        self.urlSession = urlSession
        self.tokenProvider = tokenProvider
        self.onReauthenticationRequired = onReauthenticationRequired
    }

    private struct BriefRequest: Encodable { let sessionId: String; let checkpointId: String? }
    private struct AnswerRequest: Encodable { let sessionId: String; let question: String; let checkpointId: String? }

    func postBrief(sessionId: String, checkpointId: String?) async throws -> BriefWire {
        try await post(path: "/brief", body: BriefRequest(sessionId: sessionId, checkpointId: checkpointId))
    }

    func postAnswer(question: String, sessionId: String, checkpointId: String?) async throws -> AnswerWire {
        try await post(path: "/answer", body: AnswerRequest(sessionId: sessionId, question: question, checkpointId: checkpointId))
    }

    private func post<Req: Encodable, Res: Decodable>(path: String, body: Req) async throws -> Res {
        guard let token = tokenProvider(), !token.isEmpty else {
            onReauthenticationRequired(nil)
            throw GatewayReasoningError.notLoggedIn
        }
        guard let url = URL(string: path, relativeTo: apiBaseURL) else { throw GatewayReasoningError.network("bad url \(path)") }
        var req = URLRequest(url: url, timeoutInterval: Self.reasoningRequestTimeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")  // membership-gated (scope sync)
        req.httpBody = try JSONEncoder().encode(body)
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await urlSession.data(for: req) }
        catch { throw GatewayReasoningError.network(error.localizedDescription) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 401 {
                guard tokenProvider() == token else {
                    throw GatewayReasoningError.supersededAuthentication
                }
                onReauthenticationRequired(token)
                throw GatewayReasoningError.reauthenticationRequired
            }
            throw GatewayReasoningError.http(http.statusCode)   // 401/403 auth, 501 backend-unconfigured, 503 no-checkpoint…
        }
        do { return try JSONDecoder().decode(Res.self, from: data) }
        catch { throw GatewayReasoningError.malformedResponse }
    }
}
