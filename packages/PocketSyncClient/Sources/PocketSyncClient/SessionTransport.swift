import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PocketContracts

enum SessionIdentifier {
    static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty,
              value != ".",
              value != "..",
              value.utf8.count <= 256 else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            let code = scalar.value
            return (0x41...0x5A).contains(code)
                || (0x61...0x7A).contains(code)
                || (0x30...0x39).contains(code)
                || code == 0x2D
                || code == 0x2E
                || code == 0x5F
                || code == 0x7E
        }
    }
}

/// Typed failures at the authenticated Senti sessions boundary. Response bodies are deliberately excluded so a
/// server error can never leak protected session content into logs or UI copy.
public enum SessionTransportError: LocalizedError, Equatable, Sendable {
    case notConfigured
    case notLoggedIn
    case invalidRequest
    case reauthenticationRequired
    case accessDenied
    case rateLimited(retryAfterSeconds: Int?)
    case service(statusCode: Int)
    case network
    case invalidResponse
    case invalidData
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "The Senti API is not configured for this build."
        case .notLoggedIn: return "Sign in before loading protected sessions."
        case .invalidRequest: return "The session request was invalid."
        case .reauthenticationRequired: return "Your Senti authorization has expired."
        case .accessDenied: return "This account cannot access that session."
        case .rateLimited: return "Senti is receiving too many session requests."
        case .service: return "The Senti sessions service is unavailable."
        case .network: return "The sessions request could not reach Senti."
        case .invalidResponse: return "Senti returned an invalid network response."
        case .invalidData: return "Senti returned session data this app cannot safely decode."
        case .cancelled: return "The sessions request was cancelled."
        }
    }
}

/// Read-only session API seam. Mutation/reaction/reply flows remain governed elsewhere.
public protocol SessionTransport: Sendable {
    func listSessions(includeArchived: Bool, limit: Int, cursor: String?) async throws -> SessionListPage
    func listEvents(
        sessionId: String,
        after: String?,
        fromSequence: Int64?,
        limit: Int
    ) async throws -> SessionEventForwardPage
    func listEventsBefore(
        sessionId: String,
        beforeSequence: Int64?,
        limit: Int
    ) async throws -> SessionEventBeforePage
    func listActions(
        sessionId: String,
        targetSequenceId: Int64?,
        targetActionId: String?,
        limit: Int
    ) async throws -> SessionActionPage
    func listCheckpoints(sessionId: String, limit: Int) async throws -> SessionCheckpointListPage
}

/// URLSession implementation source-bound to sentinelayer-api `routes/sessions.py`.
///
/// The endpoint is revalidated here even when the app already used its central resolver, so this standalone package
/// cannot be composed with HTTP, userinfo, path/query/fragment, or a missing host. The bearer is loaded per request;
/// sign-out therefore takes effect without rebuilding the transport.
public final class HTTPSessionTransport: SessionTransport, @unchecked Sendable {
    private let apiBaseURL: URL?
    private let urlSession: URLSession
    private let tokenProvider: @Sendable () -> String?

    public init(
        apiBaseURL: URL?,
        urlSession: URLSession = .shared,
        tokenProvider: @escaping @Sendable () -> String?
    ) {
        self.apiBaseURL = Self.validOrigin(apiBaseURL)
        self.urlSession = urlSession
        self.tokenProvider = tokenProvider
    }

    public func listSessions(
        includeArchived: Bool = false,
        limit: Int = 50,
        cursor: String? = nil
    ) async throws -> SessionListPage {
        try Self.requireLimit(limit, allowed: 1...200)
        try Self.requireBounded(cursor, maximum: 512)
        return try await get(
            SessionListPage.self,
            path: ["api", "v1", "sessions"],
            query: [
                URLQueryItem(name: "include_archived", value: includeArchived ? "true" : "false"),
                URLQueryItem(name: "limit", value: String(limit)),
                cursor.map { URLQueryItem(name: "cursor", value: $0) }
            ].compactMap { $0 },
            hideNotFound: false
        )
    }

    public func listEvents(
        sessionId: String,
        after: String? = nil,
        fromSequence: Int64? = nil,
        limit: Int = 50
    ) async throws -> SessionEventForwardPage {
        try Self.requireIdentifier(sessionId)
        try Self.requireLimit(limit, allowed: 1...200)
        try Self.requireBounded(after, maximum: 2_048)
        if let fromSequence, fromSequence < 0 { throw SessionTransportError.invalidRequest }
        return try await get(
            SessionEventForwardPage.self,
            path: ["api", "v1", "sessions", sessionId, "events"],
            query: [
                after.map { URLQueryItem(name: "after", value: $0) },
                fromSequence.map { URLQueryItem(name: "from_sequence", value: String($0)) },
                URLQueryItem(name: "limit", value: String(limit))
            ].compactMap { $0 }
        )
    }

    public func listEventsBefore(
        sessionId: String,
        beforeSequence: Int64? = nil,
        limit: Int = 50
    ) async throws -> SessionEventBeforePage {
        try Self.requireIdentifier(sessionId)
        try Self.requireLimit(limit, allowed: 1...200)
        if let beforeSequence, beforeSequence < 0 { throw SessionTransportError.invalidRequest }
        return try await get(
            SessionEventBeforePage.self,
            path: ["api", "v1", "sessions", sessionId, "events", "before"],
            query: [
                beforeSequence.map { URLQueryItem(name: "before_sequence", value: String($0)) },
                URLQueryItem(name: "limit", value: String(limit))
            ].compactMap { $0 }
        )
    }

    public func listActions(
        sessionId: String,
        targetSequenceId: Int64? = nil,
        targetActionId: String? = nil,
        limit: Int = 200
    ) async throws -> SessionActionPage {
        try Self.requireIdentifier(sessionId)
        try Self.requireLimit(limit, allowed: 1...500)
        if let targetSequenceId, targetSequenceId < 1 { throw SessionTransportError.invalidRequest }
        try Self.requireBounded(targetActionId, maximum: 128)
        if let targetActionId, UUID(uuidString: targetActionId) == nil {
            throw SessionTransportError.invalidRequest
        }
        return try await get(
            SessionActionPage.self,
            path: ["api", "v1", "sessions", sessionId, "actions"],
            query: [
                targetSequenceId.map { URLQueryItem(name: "targetSequenceId", value: String($0)) },
                targetActionId.map { URLQueryItem(name: "targetActionId", value: $0) },
                URLQueryItem(name: "limit", value: String(limit))
            ].compactMap { $0 }
        )
    }

    public func listCheckpoints(
        sessionId: String,
        limit: Int = 100
    ) async throws -> SessionCheckpointListPage {
        try Self.requireIdentifier(sessionId)
        try Self.requireLimit(limit, allowed: 1...200)
        return try await get(
            SessionCheckpointListPage.self,
            path: ["api", "v1", "sessions", sessionId, "checkpoints"],
            query: [URLQueryItem(name: "limit", value: String(limit))]
        )
    }

    private func get<Response: Decodable>(
        _ responseType: Response.Type,
        path: [String],
        query: [URLQueryItem],
        hideNotFound: Bool = true
    ) async throws -> Response {
        guard let apiBaseURL else { throw SessionTransportError.notConfigured }
        guard let token = tokenProvider(), !token.isEmpty else {
            throw SessionTransportError.notLoggedIn
        }
        guard token.utf8.count <= 8_192,
              token.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else {
            throw SessionTransportError.invalidRequest
        }
        let url = try Self.makeURL(baseURL: apiBaseURL, path: path, query: query)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch is CancellationError {
            throw SessionTransportError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw SessionTransportError.cancelled
        } catch {
            throw SessionTransportError.network
        }

        guard let http = response as? HTTPURLResponse else {
            throw SessionTransportError.invalidResponse
        }
        switch http.statusCode {
        case 200..<300:
            break
        case 401:
            throw SessionTransportError.reauthenticationRequired
        case 403:
            // Preserve the membership boundary: callers do not distinguish inaccessible from absent sessions.
            throw SessionTransportError.accessDenied
        case 404 where hideNotFound:
            // Preserve the membership boundary: callers do not distinguish inaccessible from absent sessions.
            throw SessionTransportError.accessDenied
        case 404:
            // A list-route 404 is a deployment/route failure, not evidence about a protected session.
            throw SessionTransportError.service(statusCode: http.statusCode)
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                .flatMap(Int.init)
                .flatMap { (1...86_400).contains($0) ? $0 : nil }
            throw SessionTransportError.rateLimited(
                retryAfterSeconds: retryAfter
            )
        case 400..<500:
            throw SessionTransportError.invalidRequest
        case 500..<600:
            throw SessionTransportError.service(statusCode: http.statusCode)
        default:
            throw SessionTransportError.invalidResponse
        }

        do {
            return try JSONDecoder().decode(responseType, from: data)
        } catch {
            throw SessionTransportError.invalidData
        }
    }

    private static func makeURL(
        baseURL: URL,
        path: [String],
        query: [URLQueryItem]
    ) throws -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encodedSegments = try path.map { segment -> String in
            guard !segment.isEmpty,
                  segment.rangeOfCharacter(from: .controlCharacters) == nil,
                  let encoded = segment.addingPercentEncoding(withAllowedCharacters: allowed),
                  !encoded.isEmpty else {
                throw SessionTransportError.invalidRequest
            }
            return encoded
        }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw SessionTransportError.notConfigured
        }
        components.percentEncodedPath = "/" + encodedSegments.joined(separator: "/")
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw SessionTransportError.invalidRequest }
        return url
    }

    private static func validOrigin(_ url: URL?) -> URL? {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty,
              let encodedHost = components.percentEncodedHost,
              !encodedHost.contains("%"),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/"
        else {
            return nil
        }
        return url
    }

    private static func requireIdentifier(_ value: String) throws {
        guard SessionIdentifier.isValid(value) else {
            throw SessionTransportError.invalidRequest
        }
    }

    private static func requireBounded(_ value: String?, maximum: Int) throws {
        guard let value else { return }
        guard !value.isEmpty, value.utf8.count <= maximum,
              value.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw SessionTransportError.invalidRequest
        }
    }

    private static func requireLimit(_ value: Int, allowed: ClosedRange<Int>) throws {
        guard allowed.contains(value) else { throw SessionTransportError.invalidRequest }
    }
}
