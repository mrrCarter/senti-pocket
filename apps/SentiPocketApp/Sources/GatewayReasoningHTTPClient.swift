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

enum GatewayReasoningError: LocalizedError {
    case notLoggedIn
    case http(Int)
    case network(String)
    case malformedResponse
    var errorDescription: String? {
        switch self {
        case .notLoggedIn:       return "Sign in to reason over your live session."
        case .http(let c):       return "The reasoning gateway returned HTTP \(c)."
        case .network(let m):    return "Reasoning gateway unreachable: \(m)"
        case .malformedResponse: return "The reasoning gateway returned an unexpected response."
        }
    }
}

struct GatewayReasoningHTTPClient: GatewayReasoningClient {
    private let apiBaseURL: URL
    private let urlSession: URLSession
    /// Injected so tests / offline can supply the token without a Keychain; defaults to the real session store.
    private let tokenProvider: @Sendable () -> String?

    init(apiBaseURL: URL,
         urlSession: URLSession = .shared,
         tokenProvider: @escaping @Sendable () -> String? = { SessionTokenStore.load() }) {
        self.apiBaseURL = apiBaseURL
        self.urlSession = urlSession
        self.tokenProvider = tokenProvider
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
        guard let token = tokenProvider(), !token.isEmpty else { throw GatewayReasoningError.notLoggedIn }
        guard let url = URL(string: path, relativeTo: apiBaseURL) else { throw GatewayReasoningError.network("bad url \(path)") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")  // membership-gated (scope sync)
        req.httpBody = try JSONEncoder().encode(body)
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await urlSession.data(for: req) }
        catch { throw GatewayReasoningError.network(error.localizedDescription) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw GatewayReasoningError.http(http.statusCode)   // 401/403 auth, 501 backend-unconfigured, 503 no-checkpoint…
        }
        do { return try JSONDecoder().decode(Res.self, from: data) }
        catch { throw GatewayReasoningError.malformedResponse }
    }
}
