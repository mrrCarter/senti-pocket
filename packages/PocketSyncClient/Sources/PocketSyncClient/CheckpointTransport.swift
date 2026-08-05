import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PocketCall
import PocketContracts

/// Failures at the exact signed-checkpoint download boundary. Response bodies and requested identifiers are never
/// included in descriptions, so protected checkpoint content cannot leak through logs or user-facing error copy.
public enum CheckpointTransportError: LocalizedError, Equatable, Sendable {
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
        case .notConfigured: return "The Senti Pocket gateway is not configured for this build."
        case .notLoggedIn: return "Sign in before loading a protected checkpoint."
        case .invalidRequest: return "The checkpoint request was invalid."
        case .reauthenticationRequired: return "Your Senti authorization has expired."
        case .accessDenied: return "This account cannot access that checkpoint."
        case .rateLimited: return "Senti Pocket is receiving too many checkpoint requests."
        case .service: return "The Senti Pocket checkpoint service is unavailable."
        case .network: return "The checkpoint request could not reach Senti Pocket."
        case .invalidResponse: return "Senti Pocket returned an invalid network response."
        case .invalidData: return "Senti Pocket returned checkpoint data this app cannot safely verify."
        case .cancelled: return "The checkpoint request was cancelled."
        }
    }
}

/// Read-only seam for fetching one caller-named durable checkpoint. There is intentionally no "latest" overload:
/// omitting `checkpointId` would reintroduce selection drift between the checkpoint row and the Pocket surface. A raw
/// `PocketBundle` never crosses this API: only the fixed, non-injectable pinned-key verifier can mint the return type.
public protocol CheckpointTransport: Sendable {
    func fetchExactCheckpoint(
        sessionId: String,
        checkpointId: String
    ) async throws -> VerifiedBundle
}

/// Per-task delegate that refuses every redirect. A bearer for the configured gateway origin must never be replayed
/// to a redirect target, and a redirected response must never be accepted as the requested checkpoint.
final class CheckpointNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = CheckpointNoRedirectDelegate()

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

/// HTTPS implementation source-bound to pocket-gateway `GET /checkpoint?sessionId=...&checkpointId=...`.
///
/// The gateway origin is independent from the Senti API origin used by `HTTPSessionTransport`. The bearer is loaded
/// for every request, redirects are refused, and response bytes are streamed into a hard cap before JSON decoding.
/// A successful decode still cannot escape until PocketCall verifies semantic validity and the Ed25519 signature under
/// its fixed signing-key-id trust store. This makes bypassing verification a type error at every caller.
public final class HTTPCheckpointTransport: CheckpointTransport, @unchecked Sendable {
    /// The gateway caps canonical signed bytes at 512 KiB and total graph elements at 20,000. JSON can expand a single
    /// control byte to six ASCII bytes and repeats field names for every element, so the wire ceiling must be larger
    /// than the canonical ceiling. Eight MiB preserves that valid expansion while still bounding accumulation.
    static let maximumResponseBytes = 8 * 1_024 * 1_024
    /// `/checkpoint` performs bounded durable extraction before returning its first byte. Keep it inside the shared
    /// session's 60-second resource wall without weakening the 15-second default for ordinary interactive requests.
    static let requestTimeout: TimeInterval = 45

    private let gatewayBaseURL: URL?
    private let urlSession: URLSession
    private let tokenProvider: @Sendable () -> String?
    private let responseByteLimit: Int

    public convenience init(
        gatewayBaseURL: URL?,
        urlSession: URLSession,
        tokenProvider: @escaping @Sendable () -> String?
    ) {
        self.init(
            gatewayBaseURL: gatewayBaseURL,
            urlSession: urlSession,
            tokenProvider: tokenProvider,
            responseByteLimit: Self.maximumResponseBytes
        )
    }

    /// Internal bounded override keeps the production ceiling non-configurable while allowing small, fast cap tests.
    init(
        gatewayBaseURL: URL?,
        urlSession: URLSession,
        tokenProvider: @escaping @Sendable () -> String?,
        responseByteLimit: Int
    ) {
        precondition((1...Self.maximumResponseBytes).contains(responseByteLimit))
        self.gatewayBaseURL = Self.validOrigin(gatewayBaseURL)
        self.urlSession = urlSession
        self.tokenProvider = tokenProvider
        self.responseByteLimit = responseByteLimit
    }

    public func fetchExactCheckpoint(
        sessionId: String,
        checkpointId: String
    ) async throws -> VerifiedBundle {
        guard !Task.isCancelled else { throw CheckpointTransportError.cancelled }
        guard let gatewayBaseURL else { throw CheckpointTransportError.notConfigured }
        try Self.requireOpaqueIdentifier(sessionId)
        try Self.requireOpaqueIdentifier(checkpointId)
        guard let token = tokenProvider(), !token.isEmpty else {
            throw CheckpointTransportError.notLoggedIn
        }
        guard token.utf8.count <= 8_192,
              token.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else {
            throw CheckpointTransportError.invalidRequest
        }

        let url = try Self.makeURL(
            baseURL: gatewayBaseURL,
            sessionId: sessionId,
            checkpointId: checkpointId
        )
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: Self.requestTimeout
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (bytes, response) = try await urlSession.bytes(
                for: request,
                delegate: CheckpointNoRedirectDelegate.shared
            )
            try Task.checkCancellation()
            try requireCurrentToken(token)
            guard let http = response as? HTTPURLResponse,
                  response.url == request.url else {
                throw CheckpointTransportError.invalidResponse
            }
            try Self.validate(status: http)
            guard http.mimeType?.lowercased() == "application/json" else {
                throw CheckpointTransportError.invalidResponse
            }

            let data = try await Self.collect(
                bytes,
                response: response,
                maximumBytes: responseByteLimit
            )
            try Task.checkCancellation()
            try requireCurrentToken(token)

            let decoded: CheckpointResponse
            do {
                decoded = try Self.makeDecoder().decode(CheckpointResponse.self, from: data)
            } catch {
                throw CheckpointTransportError.invalidData
            }
            guard Self.byteExact(decoded.bundle.sessionId, sessionId),
                  Self.byteExact(decoded.bundle.checkpointId, checkpointId),
                  let verified = VerifiedBundle.verify(decoded.bundle) else {
                throw CheckpointTransportError.invalidData
            }
            try Task.checkCancellation()
            try requireCurrentToken(token)
            return verified
        } catch let error as CheckpointTransportError {
            throw error
        } catch is CancellationError {
            throw CheckpointTransportError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw CheckpointTransportError.cancelled
        } catch {
            throw CheckpointTransportError.network
        }
    }

    private struct CheckpointResponse: Decodable {
        let bundle: PocketBundle
    }

    private func requireCurrentToken(_ expected: String) throws {
        // A logout, login, or token rotation while suspended makes every eventual status/body stale. In particular,
        // an old 401 must not sign out the new principal and an old 200 must not publish into the new principal's UI.
        guard tokenProvider() == expected else {
            throw CheckpointTransportError.cancelled
        }
    }

    private static func collect(
        _ bytes: URLSession.AsyncBytes,
        response: URLResponse,
        maximumBytes: Int
    ) async throws -> Data {
        let expected = response.expectedContentLength
        if expected > Int64(maximumBytes) {
            throw CheckpointTransportError.invalidData
        }
        var data = Data()
        if expected > 0 {
            data.reserveCapacity(Int(expected))
        }
        for try await byte in bytes {
            guard data.count < maximumBytes else {
                throw CheckpointTransportError.invalidData
            }
            data.append(byte)
            if data.count % 4_096 == 0 {
                try Task.checkCancellation()
            }
        }
        return data
    }

    private static func validate(status response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200:
            return
        case 401:
            throw CheckpointTransportError.reauthenticationRequired
        case 403:
            throw CheckpointTransportError.accessDenied
        case 404:
            // The authoritative gateway uses 403 for membership and 503 for an unavailable checkpoint. A 404 means
            // this deployment does not expose the route; treating it as authz would hide a rollout/configuration bug.
            throw CheckpointTransportError.service(statusCode: response.statusCode)
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
                .flatMap(Int.init)
                .flatMap { (1...86_400).contains($0) ? $0 : nil }
            throw CheckpointTransportError.rateLimited(retryAfterSeconds: retryAfter)
        case 400..<500:
            throw CheckpointTransportError.invalidRequest
        case 500..<600:
            throw CheckpointTransportError.service(statusCode: response.statusCode)
        default:
            throw CheckpointTransportError.invalidResponse
        }
    }

    private static func makeURL(
        baseURL: URL,
        sessionId: String,
        checkpointId: String
    ) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw CheckpointTransportError.notConfigured
        }
        components.percentEncodedPath = "/checkpoint"
        components.queryItems = [
            URLQueryItem(name: "sessionId", value: sessionId),
            URLQueryItem(name: "checkpointId", value: checkpointId)
        ]
        guard let url = components.url else {
            throw CheckpointTransportError.invalidRequest
        }
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

    private static func requireOpaqueIdentifier(_ value: String) throws {
        guard !value.isEmpty,
              value.utf8.count <= PocketBundle.capId,
              value.trimmingCharacters(in: .whitespacesAndNewlines) == value,
              value.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw CheckpointTransportError.invalidRequest
        }
    }

    /// Internal for a direct KAV-style regression assertion; production callers still reach it only through fetch.
    static func byteExact(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    private final class ISO8601Parser: @unchecked Sendable {
        private let fractional: ISO8601DateFormatter
        private let whole: ISO8601DateFormatter

        init() {
            fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            whole = ISO8601DateFormatter()
            whole.formatOptions = [.withInternetDateTime]
        }

        func date(from value: String) -> Date? {
            fractional.date(from: value) ?? whole.date(from: value)
        }
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        // One request-local parser pair serves every Date in the bounded graph. Constructing two heavyweight
        // ISO8601DateFormatters per field would turn a valid high-evidence bundle into avoidable CPU amplification.
        let parser = ISO8601Parser()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = parser.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "invalid checkpoint timestamp"
            )
        }
        return decoder
    }
}
