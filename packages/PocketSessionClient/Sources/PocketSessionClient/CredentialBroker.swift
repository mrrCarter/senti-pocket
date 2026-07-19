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

/// Injected time source for the broker. `wallNow` interprets the server's ABSOLUTE `expiresAt`; `monotonicNow` is
/// a CONTINUOUS monotonic instant that advances through device sleep (ContinuousClock) — deliberately NOT
/// SuspendingClock/uptime, which pause during sleep and would extend bearer validity past its true lifetime. The
/// broker pairs ONE wall + ONE monotonic sample at commit and at every usability check so a backward wall-clock
/// jump can never resurrect an expired credential (§4b; Echo/Pulse ruling). Injectable so a KAV drives both clocks
/// deterministically (a fake anchors a base ContinuousClock instant and advances it under test control).
protocol BrokerClock: Sendable {
    func wallNow() -> Date
    func monotonicNow() -> ContinuousClock.Instant
}

struct SystemClock: BrokerClock {
    func wallNow() -> Date { Date() }
    func monotonicNow() -> ContinuousClock.Instant { ContinuousClock().now }
}

actor CredentialBroker {

    // MARK: - Private atomic authority (§4c distinguishing signal)

    /// The committed pair — credential AND subject namespace bound to ONE generation. A usable, unexpired pair
    /// with no tombstone is the ONLY thing that authorizes a fetch or the CancellationError/retry path. The raw
    /// credential string never leaves the actor.
    private struct Authority {
        let credential: String            // opaque bearer; never logged / never returned
        let subjectId: String             // resolved via /auth/mcp-subject; keys the cache namespace (digest elsewhere)
        let generation: UInt64
        let wallDeadline: Date                          // expiresAt - skew: absolute wall bound (§4b conservative)
        let monotonicDeadline: ContinuousClock.Instant  // M0 + (expiresAt - W0 - skew): elapsed bound immune to wall jumps
        /// Usable ONLY if BOTH bounds hold: the wall clock is before the absolute deadline AND the CONTINUOUS
        /// monotonic clock is before the elapsed deadline anchored at commit. Requiring both means a BACKWARD
        /// wall-clock jump can't resurrect an expired credential (monotonic keeps advancing); a forward-then-back
        /// jump can't either, because the caller terminally invalidates on the first failure (§4b).
        func isUsable(wallNow: Date, monotonicNow: ContinuousClock.Instant) -> Bool {
            wallNow < wallDeadline && monotonicNow < monotonicDeadline
        }
    }

    private var authority: Authority?     // nil ⇒ signed out
    private var currentGeneration: UInt64 = 0
    private var tombstone = false         // set FIRST during sign-out (with a generation advance) before wipe awaits
    private let skew: TimeInterval = 60   // §4b: never use a credential within 60s of expiry for network
    private let executor: SessionExecuting
    private let clock: BrokerClock

    init(executor: SessionExecuting, clock: BrokerClock = SystemClock()) {
        self.executor = executor
        self.clock = clock
    }

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
        // Pair ONE wall + ONE monotonic sample at commit (§4b), then validate BEFORE any authority write: reject a
        // whitespace-only or header-injecting (CR/LF) credential/subject, and a credential already within the 60s
        // skew of expiry. The wall sample interprets the server's absolute expiry; the monotonic (ContinuousClock)
        // sample anchors an elapsed deadline immune to later wall jumps.
        let w0 = clock.wallNow()
        let m0 = clock.monotonicNow()
        let lifetime = expiresAt.timeIntervalSince(w0)     // seconds of validity remaining per our wall clock at commit
        guard !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !subjectId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              credential.rangeOfCharacter(from: .controlCharacters) == nil,   // no CR/LF header-injection…
              subjectId.rangeOfCharacter(from: .controlCharacters) == nil,    // …symmetric on subjectId (Forge flag)
              lifetime > skew else { throw AuthError.invalidResponse }
        // usableDuration = lifetime - skew (> 0 by the guard), floored to whole ms = conservative (expire early,
        // never late); monotonicDeadline is that far past the commit monotonic instant M0.
        let usableMillis = Int((lifetime - skew) * 1000)
        currentGeneration &+= 1
        authority = Authority(credential: credential, subjectId: subjectId, generation: currentGeneration,
                              wallDeadline: expiresAt.addingTimeInterval(-skew),
                              monotonicDeadline: m0.advanced(by: .milliseconds(usableMillis)))
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
        // Pair one wall + one monotonic sample for the request-start usability check.
        let wnow = clock.wallNow()
        let mnow = clock.monotonicNow()
        // 1. Snapshot the private authority at request start. No pair or a tombstone ⇒ fail closed. If a pair
        //    exists but EITHER bound has passed, terminally invalidate (advance generation + clear authority)
        //    before failing closed, so no later wall jump can resurrect it (§4b terminal invalidation).
        guard let start = authority, !tombstone else {
            throw AuthError.reauthenticationRequired
        }
        guard start.isUsable(wallNow: wnow, monotonicNow: mnow) else {
            currentGeneration &+= 1
            authority = nil
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
            // Re-sample both clocks and classify the CURRENT (newer) authority under the SAME both-bounds rule.
            let wr = clock.wallNow()
            let mr = clock.monotonicNow()
            if let live = authority, !tombstone, live.isUsable(wallNow: wr, monotonicNow: mr) {
                throw CancellationError()               // superseded by a valid newer committed pair — retryable
            } else {
                // Superseded by sign-out (authority already nil) OR by a newer authority that is itself expired —
                // terminally invalidate that dead newer authority before failing closed (§4b terminal invalidation).
                if authority != nil {
                    currentGeneration &+= 1
                    authority = nil
                }
                throw AuthError.reauthenticationRequired
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
