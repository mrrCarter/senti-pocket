// GatewayReasoningHTTPClient — the app's concrete HTTP client to relay's GATED reasoning gateway (POST /brief,
// POST /answer). Conforms to PocketReasoning's GatewayReasoningClient seam, so the unbound wire adapter gets a real
// unbound wire client; only VerifiedGatewayReasoningProvider may publish its output as .liveReasoned. App-shell lane:
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

/// A bearer scoped to the configured reasoning origin must never follow an HTTP redirect.
final class GatewayReasoningNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = GatewayReasoningNoRedirectDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

struct GatewayReasoningHTTPClient: GatewayReasoningClient {
    /// `/brief` and `/answer` are non-streaming: the gateway can spend up to 5s authenticating and 30s waiting for
    /// Gemma before the first response byte. Keep that healthy path inside the shared session's 60s resource wall
    /// without weakening the 15s default used by the app's ordinary interactive requests.
    private static let reasoningRequestTimeout: TimeInterval = 45
    /// The semantic plan/answer budget is 1 MiB. JSON escaping and field names can expand that representation, so
    /// use the same bounded 8 MiB wire ceiling as the exact-checkpoint transport and stream into it incrementally.
    static let maximumResponseBytes = 8 * 1_024 * 1_024

    private let apiBaseURL: URL
    private let urlSession: URLSession
    /// Injected so tests / offline can supply the token without a Keychain; defaults to the real session store.
    private let tokenProvider: @Sendable () -> String?
    /// The reasoning driver intentionally turns provider errors into an honest `.failed` phase. This side-channel
    /// also closes the authenticated app root when the gateway explicitly reports an expired bearer.
    private let onReauthenticationRequired: @Sendable (String?) -> Void
    private let responseByteLimit: Int

    init(apiBaseURL: URL,
         urlSession: URLSession = SentiHTTPTransportPolicy.liveSession,
         tokenProvider: @escaping @Sendable () -> String? = { SessionTokenStore.load() },
         onReauthenticationRequired: @escaping @Sendable (String?) -> Void = { _ in },
         responseByteLimit: Int = Self.maximumResponseBytes) {
        precondition((1...Self.maximumResponseBytes).contains(responseByteLimit))
        self.apiBaseURL = apiBaseURL
        self.urlSession = urlSession
        self.tokenProvider = tokenProvider
        self.onReauthenticationRequired = onReauthenticationRequired
        self.responseByteLimit = responseByteLimit
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
        try Task.checkCancellation()
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
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await urlSession.bytes(
                for: req,
                delegate: GatewayReasoningNoRedirectDelegate.shared
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            try requireCurrentToken(token)
            throw GatewayReasoningError.network(error.localizedDescription)
        }
        defer { bytes.task.cancel() }
        try Task.checkCancellation()
        try requireCurrentToken(token)
        guard let http = response as? HTTPURLResponse,
              response.url == req.url else {
            throw GatewayReasoningError.malformedResponse
        }
        if !(200..<300).contains(http.statusCode) {
            if http.statusCode == 401 {
                try requireCurrentToken(token)
                onReauthenticationRequired(token)
                throw GatewayReasoningError.reauthenticationRequired
            }
            throw GatewayReasoningError.http(http.statusCode)   // 401/403 auth, 501 backend-unconfigured, 503 no-checkpoint…
        }
        guard http.mimeType?.lowercased() == "application/json" else {
            throw GatewayReasoningError.malformedResponse
        }
        let data: Data
        do {
            data = try await Self.collect(bytes, response: response, maximumBytes: responseByteLimit)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            try requireCurrentToken(token)
            throw GatewayReasoningError.network(error.localizedDescription)
        } catch let error as GatewayReasoningError {
            try requireCurrentToken(token)
            throw error
        } catch {
            try requireCurrentToken(token)
            throw GatewayReasoningError.malformedResponse
        }
        try Task.checkCancellation()
        try requireCurrentToken(token)
        let decoded: Res
        do {
            decoded = try JSONDecoder().decode(Res.self, from: data)
        } catch {
            try requireCurrentToken(token)
            throw GatewayReasoningError.malformedResponse
        }
        try Task.checkCancellation()
        try requireCurrentToken(token)
        return decoded
    }

    private func requireCurrentToken(_ expectedToken: String) throws {
        guard UTF8ExactIdentity.matches(tokenProvider(), expectedToken) else {
            throw GatewayReasoningError.supersededAuthentication
        }
    }

    private static func collect(
        _ bytes: URLSession.AsyncBytes,
        response: URLResponse,
        maximumBytes: Int
    ) async throws -> Data {
        if response.expectedContentLength > Int64(maximumBytes) {
            throw GatewayReasoningError.malformedResponse
        }
        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(Int(response.expectedContentLength))
        }
        for try await byte in bytes {
            guard data.count < maximumBytes else {
                throw GatewayReasoningError.malformedResponse
            }
            data.append(byte)
            if data.count % 4_096 == 0 {
                try Task.checkCancellation()
            }
        }
        return data
    }
}
