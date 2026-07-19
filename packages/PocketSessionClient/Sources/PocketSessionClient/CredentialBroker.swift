import Foundation
import PocketContracts

// STEP 2 (behavior) for the ratified contract (docs/auth-fetch-contract.md @ 15c83561, V11).
// The INTERNAL broker: sole owner of the credential + generation + execution + status classification.
// Neither the credential/generation nor any HTTPURLResponse ever leaves the actor (R1/R2). `perform` returns
// only Data. Not public; only the module's transport/repository call it.
actor CredentialBroker {

    // MARK: - Private atomic authority (§4c distinguishing signal)

    /// The committed pair — credential AND subject namespace bound to ONE generation. A usable, unexpired pair
    /// with no tombstone is the ONLY thing that authorizes a fetch or the CancellationError/retry path. The raw
    /// credential string never leaves the actor.
    private struct Authority {
        let credential: String            // opaque bearer; never logged / never returned
        let subjectId: String             // resolved via /auth/mcp-subject; keys the cache namespace (digest elsewhere)
        let generation: UInt64
        let expiresAt: Date
        func isUsable(now: Date, skew: TimeInterval) -> Bool { expiresAt.addingTimeInterval(-skew) > now }
    }

    private var authority: Authority?     // nil ⇒ signed out
    private var currentGeneration: UInt64 = 0
    private var tombstone = false         // set FIRST during sign-out (with a generation advance) before wipe awaits
    private let skew: TimeInterval = 60   // §4b: never use a credential within 60s of expiry for network
    private let executor: SessionExecuting

    init(executor: SessionExecuting) { self.executor = executor }

    // MARK: - Lifecycle (signIn commits atomically; signOut tombstones + advances generation before wipe)

    /// Atomic commit of {credential + subject namespace} at a NEW generation (§4a). Called only after a
    /// successful token exchange + mcp-subject resolution; on any earlier failure this is never reached.
    func commit(credential: String, subjectId: String, expiresAt: Date) {
        currentGeneration &+= 1
        tombstone = false
        authority = Authority(credential: credential, subjectId: subjectId,
                              generation: currentGeneration, expiresAt: expiresAt)
    }

    /// §4b/R6' sign-out: write the tombstone AND advance the generation FIRST — both before awaiting either
    /// deletion — so any in-flight request under the old generation compares unequal at classification and
    /// returns no Data during the wipe window. (Keychain/filesystem deletion + `.wipePending` are the
    /// repository/keystore's concern; the broker's job is to make the credential immediately unusable.)
    func beginSignOutTombstone() {
        tombstone = true
        currentGeneration &+= 1
        authority = nil
    }

    // MARK: - perform (§4c: generation compare BEFORE any status/body observation)

    func perform(_ spec: SessionRequestSpec) async throws -> Data {
        let now = Date()
        // 1. Snapshot the private authority at request start. No usable pair ⇒ fail closed.
        guard let start = authority, !tombstone, start.isUsable(now: now, skew: skew) else {
            throw AuthError.reauthenticationRequired
        }
        let captured = start.generation
        // 2. Build the credential-bearing request from the typed spec (fixed origin/path/query; §2/§5).
        let request = try Self.buildRequest(spec, credential: start.credential)
        // 3. Execute; the raw response returns to the broker only.
        let (data, response) = try await executor.execute(request)
        // 4. §4c: compare captured generation against the PRIVATE authority BEFORE observing/classifying the
        //    response status OR body. On mismatch: ZERO status/body observation (a stale 401 is never classified).
        if tombstone || authority?.generation != captured {
            if let live = authority, !tombstone, live.isUsable(now: Date(), skew: skew) {
                throw CancellationError()               // superseded by a valid newer committed pair — retryable
            } else {
                throw AuthError.reauthenticationRequired  // superseded by sign-out (tombstone / no committed pair)
            }
        }
        // 5. Generation EQUAL ⇒ only now may status/body be observed and classified (§4b).
        switch response.statusCode {
        case 200..<300:
            return data
        case 401:
            // Possible revocation (the AS has no revocation endpoint) — invalidate the generation; the
            // repository suppresses the subject cache on catching this. Fail closed to re-auth (R4').
            currentGeneration &+= 1
            authority = nil
            throw AuthError.reauthenticationRequired
        case 403:
            throw TransportError.accessDenied           // authz denied; repository suppresses the target cache
        default:
            throw TransportError.server(status: response.statusCode, code: nil,
                                        requestId: response.value(forHTTPHeaderField: "x-request-id"))
        }
    }

    // MARK: - §5 request construction (fixed origin/method/path/query; the ONLY place a URL is built)

    private static let origin = URL(string: "https://api.sentinelayer.com")!   // scheme+host+443, no userinfo

    static func buildRequest(_ spec: SessionRequestSpec, credential: String) throws -> URLRequest {
        var comps = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        var query: [URLQueryItem] = []
        switch spec {
        case let .listSessions(includeArchived, cursor):
            comps.path = "/api/v1/sessions"
            query = [URLQueryItem(name: "include_archived", value: includeArchived ? "true" : "false"),
                     URLQueryItem(name: "limit", value: "50")]
            if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }   // omit when nil
        case let .events(sessionId, fromSequence):
            comps.path = "/api/v1/sessions/\(sessionId.value)/events"
            query = [URLQueryItem(name: "limit", value: "50")]
            if let seq = fromSequence {
                guard seq >= 0 else { throw AuthError.invalidResponse }
                query.append(URLQueryItem(name: "from_sequence", value: String(seq)))     // omit when nil; no `after`
            }
        case let .eventsBefore(sessionId, beforeSequence):
            guard beforeSequence >= 0 else { throw AuthError.invalidResponse }
            comps.path = "/api/v1/sessions/\(sessionId.value)/events/before"
            query = [URLQueryItem(name: "before_sequence", value: String(beforeSequence)),
                     URLQueryItem(name: "limit", value: "50")]
        case let .actions(sessionId):
            comps.path = "/api/v1/sessions/\(sessionId.value)/actions"
            query = [URLQueryItem(name: "limit", value: "200")]                            // no filters
        case let .checkpoints(sessionId):
            comps.path = "/api/v1/sessions/\(sessionId.value)/checkpoints"
            query = [URLQueryItem(name: "limit", value: "100")]                            // no checkpointId
        }
        comps.queryItems = query
        guard let url = comps.url, url.host == "api.sentinelayer.com", url.user == nil else {
            throw AuthError.invalidResponse
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        return req
    }
}
