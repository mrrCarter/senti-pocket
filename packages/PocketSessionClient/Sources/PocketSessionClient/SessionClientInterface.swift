import Foundation
import PocketContracts

// Frozen interface for the ratified Pocket Auth + Session-Fetch security contract
// (docs/auth-fetch-contract.md @ a0a9114c). STEP 1 of the fixture-first build: the exact §4 type surface as
// compileable declarations. Implementations (fixture CredentialBroker/Transport/Repository) + KAVs land in
// steps 2–3; warden source-gates the whole (compile + green + compile-NEGATIVE + N-vs-N+1). FIXTURE-ONLY:
// no live sign-in/fetch until server-P1 (63446896) + Pocket client registration deploy under Carter's GO.
//
// PUBLIC surface = the protocols + these value types. The request-CONSTRUCTING types (SessionRequestSpec and,
// in step 2, CredentialBroker) stay INTERNAL to this module — that module boundary is what makes the
// compile-negative KAV real: an external, non-@testable target literally cannot name the internal constructor,
// so no consumer can obtain a credential-bearing request (R2 no-confused-deputy).

// MARK: - Validated session identifier (§2 grammar; NOT assumed UUID)

/// Opaque, single-path-segment session id. The initializer THROWS `AuthError.invalidResponse` on any grammar
/// violation, before any transport/broker execution — so `/`, `..`, control, space, `%`, empty never reach a URL.
public struct SessionID: Sendable, Equatable, Hashable {
    public let value: String
    public init(_ raw: String) throws {
        guard Self.isValid(raw) else { throw AuthError.invalidResponse }
        self.value = raw
    }
    // ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ — covers observed UUID (6cf7e861-…) and short-hex (954233b7) forms.
    private static let head = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
    private static let body = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
    private static func isValid(_ s: String) -> Bool {
        guard (1...128).contains(s.count), let first = s.first, head.contains(first) else { return false }
        return s.allSatisfy { body.contains($0) }
    }
}

// MARK: - Auth state + errors

public enum AuthState: Sendable, Equatable {
    case signedOut
    case authenticating
    case signedIn(expiresAt: Date)
    case reauthenticationRequired
    case wipePending                       // sign-out wipe incomplete; credential unusable, reads disabled
    case error(AuthError)
}

public enum AuthError: Error, Sendable, Equatable {
    case userCancelled, stateMismatch, exchangeFailed, subjectResolutionFailed
    case reauthenticationRequired          // 401 (possible revocation) or no unexpired credential
    case network
    case keychain                          // non-wipe Keychain op failure
    case invalidResponse                   // incl. SessionID grammar violation
    case wipeFailed(keychain: Bool, cache: Bool)   // sign-out: exact per-half flags (both true ⇒ both deletions failed)
}

public enum TransportError: Error, Sendable, Equatable {
    case accessDenied                      // 403 — authz denied (target cache suppressed, renders nothing)
    case decoding
    case network
    case offlineNoCache                    // distinct from network — truthful "offline + nothing cached"
    case server(status: Int, code: String?, requestId: String?)   // a NORMALIZED status Int only; raw response/headers/token never escape
    // NOTE: no `.unauthorized` — a 401 flows as AuthError.reauthenticationRequired, never a transport error.
}

// MARK: - Snapshot provenance (a fixture/cached result never masquerades as live network)

public enum Source: Sendable, Equatable { case network(at: Date), cached(at: Date), fixture }
public enum AuthStatus: Sendable, Equatable { case live, authExpired, offline }
public enum Completeness: Sendable, Equatable { case complete, partial(reason: String), unknown }  // any cached fallback ⇒ never .complete
public enum Watermark: Sendable, Equatable { case cursor(String), sequence(Int64) }                // opaque cursor vs Int64 sequence never conflated

public struct RepositorySnapshot<Page: Sendable & Equatable>: Sendable, Equatable {
    public let page: Page
    public let source: Source
    public let authStatus: AuthStatus
    public let completeness: Completeness
    public let serverWatermark: Watermark?
    public let lastSuccessfulSync: Date?
    public init(page: Page, source: Source, authStatus: AuthStatus, completeness: Completeness,
                serverWatermark: Watermark?, lastSuccessfulSync: Date?) {
        self.page = page; self.source = source; self.authStatus = authStatus
        self.completeness = completeness; self.serverWatermark = serverWatermark; self.lastSuccessfulSync = lastSuccessfulSync
    }
}

// MARK: - Public protocols (the ONLY public surface; no arbitrary-request API)

public protocol AuthProviding: Sendable {
    func currentState() async -> AuthState
    func stateUpdates() async -> AsyncStream<AuthState>
    @MainActor func signIn() async throws          // ONLY interactive entry; single UI flight
    func signOut() async throws                    // tombstone-gated; signedOut only after both wipes succeed
}

/// Network-only; each method names a typed operation (never a URL/method/header). Returns a merged wire page.
public protocol SessionTransport: Sendable {
    func listSessions(includeArchived: Bool, cursor: String?) async throws -> SessionListPage
    func events(sessionId: SessionID, fromSequence: Int64?) async throws -> SessionEventForwardPage
    func eventsBefore(sessionId: SessionID, beforeSequence: Int64) async throws -> SessionEventBeforePage
    func actions(sessionId: SessionID) async throws -> SessionActionPage
    func checkpoints(sessionId: SessionID) async throws -> SessionCheckpointListPage
}

/// ONE contract: async throws -> Snapshot with exact thrown cases (§4b). Subject-partitioned; owns the cache;
/// owns 401→invalidate+suppress-subject-cache+throw-reauthenticationRequired and 403→suppress-target-cache+throw-accessDenied.
public protocol SessionRepository: Sendable {
    func sessions(includeArchived: Bool, cursor: String?) async throws -> RepositorySnapshot<SessionListPage>
    func events(sessionId: SessionID, fromSequence: Int64?) async throws -> RepositorySnapshot<SessionEventForwardPage>
    func eventsBefore(sessionId: SessionID, beforeSequence: Int64) async throws -> RepositorySnapshot<SessionEventBeforePage>
    func actions(sessionId: SessionID) async throws -> RepositorySnapshot<SessionActionPage>
    func checkpoints(sessionId: SessionID) async throws -> RepositorySnapshot<SessionCheckpointListPage>
}

// MARK: - INTERNAL request constructor (the compile-negative boundary)

/// The closed set of the five read operations. INTERNAL by design: only this module can name/construct it, so
/// only the internal CredentialBroker (step 2) can turn one into a credential-bearing request. `beforeSequence`
/// / `fromSequence` are validated `>= 0` by the broker before execution (contract §5).
enum SessionRequestSpec: Sendable, Equatable {
    case listSessions(includeArchived: Bool, cursor: String?)
    case events(sessionId: SessionID, fromSequence: Int64?)
    case eventsBefore(sessionId: SessionID, beforeSequence: Int64)
    case actions(sessionId: SessionID)
    case checkpoints(sessionId: SessionID)
}
