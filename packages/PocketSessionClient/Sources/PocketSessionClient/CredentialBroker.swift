import Foundation
import PocketContracts

// STEP 2 (behavior) for the ratified contract (docs/auth-fetch-contract.md @ 15c83561, V11).
// The INTERNAL broker: sole owner of the credential + generation + execution + status classification.
// Neither the credential/generation nor any HTTPURLResponse ever leaves the actor (R1/R2). `perform` returns
// only Data. Not public; only the module's transport/repository call it.
/// Broker-only capability. Its initializer is fileprivate to THIS file (which contains only CredentialBroker),
/// so ONLY the broker can mint one — and `SealedResponse.open(_:)` requires it, so ONLY the broker can open a
/// sealed response. A non-broker / future PocketSessionClient file cannot construct an ExecutionGrant (won't
/// compile) = STRUCTURAL §4c broker-only observation (P1-B DiD), not reliance on the current call graph.
struct ExecutionGrant: Sendable { fileprivate init() {} }

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

    /// A provisional sign-in capability, issued by the actor at the START of a sign-in flow. `commit` accepts it
    /// only if broker state is UNCHANGED since it was issued — so a sign-in whose token-exchange straddled a
    /// sign-out or a newer sign-in cannot clobber that later state (P1-C).
    struct SignInAttempt: Sendable { fileprivate let base: UInt64 }
    func beginSignIn() throws -> SignInAttempt {
        guard !tombstone else { throw AuthError.stateMismatch }   // no sign-in while a sign-out wipe is in flight
        return SignInAttempt(base: currentGeneration)
    }

    /// Atomic, GUARDED commit of {credential + subject namespace} at a NEW generation (§4a). Succeeds ONLY if no
    /// sign-out (tombstone) and no newer generation intervened since `attempt` was issued; otherwise the stale
    /// attempt is rejected (`.stateMismatch`) and the current state — e.g. a completed sign-out — stands.
    func commit(credential: String, subjectId: String, expiresAt: Date, attempt: SignInAttempt) throws {
        guard !tombstone, attempt.base == currentGeneration else { throw AuthError.stateMismatch }
        // Input validation BEFORE any authority write (snapshot `now` once): reject a whitespace-only or
        // header-injecting (CR/LF) credential/subject, and a credential already within the 60s skew of expiry.
        let now = Date()
        guard !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !subjectId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !credential.contains(where: { $0 == "\r" || $0 == "\n" }),
              expiresAt.timeIntervalSince(now) > skew else { throw AuthError.invalidResponse }
        currentGeneration &+= 1
        authority = Authority(credential: credential, subjectId: subjectId,
                              generation: currentGeneration, expiresAt: expiresAt)
    }

    /// §4b/R6' sign-out: write the tombstone AND advance the generation FIRST — both before awaiting either
    /// deletion — so any in-flight request under the old generation compares unequal at classification and
    /// returns no Data during the wipe window. (Keychain/filesystem deletion + `.wipePending` are the
    /// repository/keystore's concern; the broker's job is to make the credential immediately unusable.)
    /// A sign-out capability owning the post-increment generation. `completeSignOut` accepts it only if that same
    /// generation is still current — so a stale sign-out's completion can't clear a NEWER sign-out's tombstone.
    struct SignOutAttempt: Sendable { fileprivate let base: UInt64 }

    func beginSignOutTombstone() -> SignOutAttempt {
        tombstone = true
        currentGeneration &+= 1
        authority = nil
        return SignOutAttempt(base: currentGeneration)
    }

    /// Called after BOTH Keychain + filesystem deletions succeed. Clears the tombstone to a clean signed-out state
    /// ONLY if still-current (no newer sign-out advanced the generation); otherwise throws `.stateMismatch` and
    /// LEAVES the tombstone (a newer sign-out still governs). Until cleared, the tombstone rejects any commit and
    /// any beginSignIn.
    func completeSignOut(attempt: SignOutAttempt) throws {
        guard tombstone, attempt.base == currentGeneration else { throw AuthError.stateMismatch }
        tombstone = false
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
        // 3. Execute; the SEALED response returns to the broker only — status/body unobservable until open().
        let sealed = try await executor.execute(request)
        // 4. §4c: compare captured generation against the PRIVATE authority BEFORE opening the envelope. On
        //    mismatch the sealed response is DISCARDED UNOPENED — structural zero status/body observation (a stale
        //    401 is never classified and can never invalidate/suppress the current generation).
        if tombstone || authority?.generation != captured {
            if let live = authority, !tombstone, live.isUsable(now: Date(), skew: skew) {
                throw CancellationError()               // superseded by a valid newer committed pair — retryable
            } else {
                throw AuthError.reauthenticationRequired  // superseded by sign-out (tombstone / no committed pair)
            }
        }
        // 5. Generation EQUAL ⇒ only NOW open the envelope and classify (§4b).
        let (status, data, requestId) = sealed.open(ExecutionGrant())
        switch status {
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
            throw TransportError.server(status: status, code: nil, requestId: requestId)
        }
    }

    // MARK: - §5 request construction (fixed origin/method/path/query; the ONLY place a URL is built)

    private static let origin = URL(string: "https://api.sentinelayer.com")!   // scheme+host+443, no userinfo

    private static func buildRequest(_ spec: SessionRequestSpec, credential: String) throws -> URLRequest {
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
