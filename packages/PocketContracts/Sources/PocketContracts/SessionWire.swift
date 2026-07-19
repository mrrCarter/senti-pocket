import Foundation

// Lossless Senti Sessions WIRE DTOs — source-bound to sentinelayer-api
// (deployed 3ca7640 == origin/main 91a2c3fa; serializers session_relay_service.py + routes/sessions.py
// + session_checkpoint_grading.py, verified against tests/test_sessions.py). Relay owns the wire layer;
// ATLAS projects typed domain values atop these reviewed DTOs.
//
// Rules matched EXACTLY to the wire:
//  - ITEM objects use camelCase keys (default Codable). PAGE ENVELOPES mix snake_case -> CodingKeys.
//  - REQUIRED (non-optional) == the route/serializer GUARANTEES the key: malformed/partial wire must FAIL
//    decode, never silently mint ambiguous domain state. Only truly-nullable fields are Optional.
//  - Timestamps kept as RAW ISO String (lossless; projection parses tolerant ISO8601).
//  - Open/unknown blobs (payload, metadata, projection, tokenRange, summarySections, agent) stay JSONValue
//    so future keys are preserved losslessly. event/actionType stay raw String (projection maps open enums).
//  - A generic session checkpoint is ordinary membership-authorized content, NOT verify-gated here; only a
//    separately-signed Pocket briefing artifact crosses VerifiedBundle (in PocketCall), never this DTO.

// MARK: - Sessions list

public struct SessionSummary: Codable, Equatable, Sendable, Identifiable {
    public var id: String { sessionId }
    public let sessionId: String
    public let status: String
    public let archiveStatus: String
    public let visibility: String
    public let membershipRole: String
    public let title: String?
    public let summaryText: String?
    public let summaryGeneratedAt: String?
    public let summaryModel: String?
    public let agentCount: Int
    public let eventCount: Int
    public let totalCostUsd: Decimal
    public let createdAt: String?
    public let lastActivityAt: String?
    public let expiresAt: String?
    public let killedAt: String?
    public let templateName: String?
    public let codebasePath: String?
    public let s3ArchivePath: String?
}

/// GET /api/v1/sessions -> route wrapper (sessions.py:2512-2517).
public struct SessionListPage: Codable, Equatable, Sendable {
    public let sessions: [SessionSummary]
    public let count: Int
    public let includeArchived: Bool
    public let nextCursor: String?
    public let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case sessions, count
        case includeArchived = "include_archived"
        case nextCursor = "next_cursor"
        case hasMore = "has_more"
    }
}

// MARK: - Events

/// _event_from_db_row (:3806-3821) always emits id/event/payload/agentId/agentModel/ts/timestamp/cursor/
/// sequenceId/sessionId, plus a nested `agent` presentation object (role/displayName/provider/clientKind).
/// `agent` is JSONValue for losslessness; eventId/idempotencyToken are conditional; `source` key is
/// always emitted but its value is DB-nullable (models/session.py:141).
public struct SessionEventDTO: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let event: String
    public let agent: JSONValue          // always emitted (presentation object); JSONValue = lossless
    public let agentId: String
    public let agentModel: String
    public let payload: JSONValue
    public let ts: String
    public let timestamp: String
    public let cursor: String
    public let sequenceId: Int64
    public let sessionId: String
    public let source: String?           // key always emitted, but SessionEvent.source is DB-nullable (models/session.py:141)
    public let eventId: String?
    public let idempotencyToken: String?
}

/// GET /{session_id}/events (after/from_sequence) -> forward/tail page: { events } ONLY.
public struct SessionEventForwardPage: Codable, Equatable, Sendable {
    public let events: [SessionEventDTO]
}

/// GET /{session_id}/events/before (beforeSequence) -> historical page. `next_before_sequence` is a
/// SEQUENCE ANCHOR (Int64), nullable when the page reaches the start; NOT an opaque cursor.
public struct SessionEventBeforePage: Codable, Equatable, Sendable {
    public let events: [SessionEventDTO]
    public let count: Int
    public let nextBeforeSequence: Int64?
    public let hasMore: Bool
    public let partial: Bool

    enum CodingKeys: String, CodingKey {
        case events, count, partial
        case nextBeforeSequence = "next_before_sequence"
        case hasMore = "has_more"
    }
}

// MARK: - Actions (SEPARATE feed from events; not SSE)

/// _message_action_row (:5977) — targetSequenceId/actorKind/actorId/metadata/idempotencyKey/createdAt are
/// DB+serializer non-null; targetCursor/targetActionId/actorUserId/actorRole/note are nullable.
public struct SessionActionDTO: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let sessionId: String
    public let targetSequenceId: Int64
    public let targetCursor: String?
    public let targetActionId: String?
    public let actionType: String
    public let actorKind: String
    public let actorId: String
    public let actorUserId: String?
    public let actorRole: String?
    public let note: String?
    public let metadata: JSONValue
    public let idempotencyKey: String
    public let createdAt: String
}

/// GET /{session_id}/actions -> envelope, NOT bare rows. `projection` preserved losslessly.
public struct SessionActionPage: Codable, Equatable, Sendable {
    public let sessionId: String
    public let actions: [SessionActionDTO]
    public let count: Int
    public let projection: JSONValue
}

// MARK: - Checkpoints (generic session_checkpoint resource; membership-authorized, NOT verify-gated)

/// Full-content checkpoint DTO (renamed from Ref — it carries title/summary/grade family, not just a ref).
/// kind/title/summary are present before the service returns a row; the grade family is
/// serializer-guaranteed non-null (both normalize_checkpoint_grade return paths emit all four —
/// build_checkpoint_grade uses _grade_letter, which always yields a letter).
public struct SessionCheckpointDTO: Codable, Equatable, Sendable, Identifiable {
    public var id: String { checkpointId }
    public let checkpointId: String
    public let sessionId: String
    public let kind: String
    public let title: String
    public let summary: String
    public let startSequence: Int64?
    public let endSequence: Int64?
    public let tokenRange: JSONValue?
    // serializer-guaranteed non-null (createdBy/createdByAgentId normalized to strings; eventSequence/cursor/
    // createdAt derived from the always-present event; summarySections synthesized; grade family from
    // normalize_checkpoint_grade whose both return paths emit non-null values):
    public let createdBy: String
    public let createdByAgentId: String
    public let eventSequence: Int64
    public let cursor: String
    public let createdAt: String
    public let summarySections: JSONValue
    public let grade: String
    public let gradeScore: Int
    public let gradeVersion: String
    public let gradeReasons: JSONValue
}

/// GET /{session_id}/checkpoints -> { checkpoints, count } (list lacks a cursor).
public struct SessionCheckpointListPage: Codable, Equatable, Sendable {
    public let checkpoints: [SessionCheckpointDTO]
    public let count: Int
}
