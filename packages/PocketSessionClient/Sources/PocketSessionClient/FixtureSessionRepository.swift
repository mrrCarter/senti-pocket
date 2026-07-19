import Foundation
import PocketContracts

// STEP 2 (behavior) for the ratified contract (docs/auth-fetch-contract.md @ 15c83561, V11) — §5a seam (B).
//
// The SHIPPING/demo repository the app consumes when there is no live authorization. It ALWAYS vends the exact
// frozen non-live triple `(.fixture, .offline, .unknown)` with nil watermark/sync, and can NEVER emit
// `.network`/`.live`/`.complete` — it holds no credential, no broker, no executor, and does no network. This is
// seam (B), strictly separate from seam (A) (the private KAV executor that drives the REAL broker path). A
// step-3 negative KAV proves this type can never mint a live/network/complete provenance.
//
// Canned pages are DECODED from minimal fixture JSON via the public wire Codable (the wire DTOs' memberwise
// inits are internal to PocketContracts, so a snapshot's page can only come through decode — never fabricated).
public struct FixtureSessionRepository: SessionRepository {
    public init() {}

    // Frozen non-live provenance — the ONLY snapshot shape this type ever returns.
    private func snapshot<Page: Sendable & Equatable>(_ page: Page) -> RepositorySnapshot<Page> {
        RepositorySnapshot(page: page, source: .fixture, authStatus: .offline,
                           completeness: .unknown, serverWatermark: nil, lastSuccessfulSync: nil)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        // Malformed fixture JSON (e.g. after a future wire Codable change) maps to a caught TransportError.decoding
        // — NEVER a process kill from a public repository path. A step-3 KAV exercises every constant.
        do { return try JSONDecoder().decode(type, from: Data(json.utf8)) }
        catch { throw TransportError.decoding }
    }

    public func sessions(includeArchived: Bool, cursor: String?) async throws -> RepositorySnapshot<SessionListPage> {
        // Echo the requested include_archived (was hardcoded false) — query-truthful even in the fixture.
        snapshot(try Self.decode(SessionListPage.self,
            #"{"sessions":[],"count":0,"include_archived":\#(includeArchived),"next_cursor":null,"has_more":false}"#))
    }
    public func events(sessionId: SessionID, fromSequence: Int64?) async throws -> RepositorySnapshot<SessionEventForwardPage> {
        if let seq = fromSequence, seq < 0 { throw AuthError.invalidResponse }   // §5: reject negative BEFORE returning
        return snapshot(try Self.decode(SessionEventForwardPage.self, #"{"events":[]}"#))
    }
    public func eventsBefore(sessionId: SessionID, beforeSequence: Int64) async throws -> RepositorySnapshot<SessionEventBeforePage> {
        guard beforeSequence >= 0 else { throw AuthError.invalidResponse }       // §5: reject negative BEFORE returning
        return snapshot(try Self.decode(SessionEventBeforePage.self,
            #"{"events":[],"count":0,"next_before_sequence":null,"has_more":false,"partial":false}"#))
    }
    public func actions(sessionId: SessionID) async throws -> RepositorySnapshot<SessionActionPage> {
        snapshot(try Self.decode(SessionActionPage.self,
            #"{"sessionId":"\#(sessionId.value)","actions":[],"count":0,"projection":{}}"#))
    }
    public func checkpoints(sessionId: SessionID) async throws -> RepositorySnapshot<SessionCheckpointListPage> {
        snapshot(try Self.decode(SessionCheckpointListPage.self, #"{"checkpoints":[],"count":0}"#))
    }
}
