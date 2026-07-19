import Foundation

// Lossless Senti Sessions WIRE DTOs — source-bound to sentinelayer-api
// (deployed 3ca7640 == origin/main 91a2c3fa; serializers session_relay_service.py + routes/sessions.py,
// verified against tests/test_sessions.py). Relay owns these; ATLAS projects typed domain values atop them.
//
// Conventions matched EXACTLY to the wire:
//  - ITEM objects use camelCase keys (default Codable, property name == wire key).
//  - PAGE ENVELOPES mix snake_case keys (next_cursor / has_more / include_archived / next_before_sequence)
//    -> mapped via CodingKeys.
//  - Timestamps are kept as the RAW ISO-8601 String (lossless; the projection parses with tolerant ISO8601,
//    so a fractional-second variance never fails wire decode).
//  - Open/unknown blobs (payload, metadata, projection, tokenRange, summarySections) stay JSONValue.
//  - Event.event / action.actionType stay raw String at the wire (the projection maps to open enums).
//  - A generic membership-authorized checkpoint is ordinary content and is NOT verify-gated here; only a
//    separately-signed Pocket briefing artifact crosses VerifiedBundle (in PocketCall), never this ref.

// MARK: - Sessions list

public struct SessionSummary: Codable, Equatable, Sendable, Identifiable {
    public var id: String { sessionId }
    public let sessionId: String
    public let status: String?
    public let archiveStatus: String?
    public let visibility: String?
    public let membershipRole: String?
    public let title: String?
    public let summaryText: String?
    public let summaryGeneratedAt: String?
    public let summaryModel: String?
    public let agentCount: Int?
    public let eventCount: Int?
    public let totalCostUsd: Decimal?
    public let createdAt: String?
    public let lastActivityAt: String?
    public let expiresAt: String?
    public let killedAt: String?
    public let templateName: String?
    public let codebasePath: String?
    public let s3ArchivePath: String?
}

/// GET /api/v1/sessions -> route wrapper adds count + include_archived around the service page.
public struct SessionListPage: Codable, Equatable, Sendable {
    public let sessions: [SessionSummary]
    public let count: Int?
    public let includeArchived: Bool?
    public let nextCursor: String?
    public let hasMore: Bool?

    enum CodingKeys: String, CodingKey {
        case sessions, count
        case includeArchived = "include_archived"
        case nextCursor = "next_cursor"
        case hasMore = "has_more"
    }
}

// MARK: - Events

public struct SessionEventAgent: Codable, Equatable, Sendable {
    public let id: String?
    public let model: String?
    public let role: String?
}

/// _event_from_db_row emits BOTH a nested `agent{}` AND flat agentId/agentModel — both preserved (lossless).
public struct SessionEventDTO: Codable, Equatable, Sendable {
    public let event: String
    public let agent: SessionEventAgent?
    public let agentId: String?
    public let agentModel: String?
    public let payload: JSONValue
    public let ts: String?
    public let timestamp: String?
    public let cursor: String?
    public let sequenceId: Int64
    public let sessionId: String
    public let source: String?
    public let eventId: String?
    public let idempotencyToken: String?
}

/// GET /{session_id}/events (after/from_sequence) -> forward/tail page: { events } ONLY.
public struct SessionEventForwardPage: Codable, Equatable, Sendable {
    public let events: [SessionEventDTO]
}

/// GET /{session_id}/events/before (beforeSequence) -> historical page. `next_before_sequence` is a
/// SEQUENCE ANCHOR (Int64), NOT an opaque cursor.
public struct SessionEventBeforePage: Codable, Equatable, Sendable {
    public let events: [SessionEventDTO]
    public let count: Int?
    public let nextBeforeSequence: Int64?
    public let hasMore: Bool?
    public let partial: Bool?

    enum CodingKeys: String, CodingKey {
        case events, count, partial
        case nextBeforeSequence = "next_before_sequence"
        case hasMore = "has_more"
    }
}

// MARK: - Actions (SEPARATE feed from events; not SSE)

public struct SessionActionDTO: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let sessionId: String
    public let targetSequenceId: Int64?
    public let targetCursor: String?
    public let targetActionId: String?
    public let actionType: String
    public let actorKind: String?
    public let actorId: String?
    public let actorUserId: String?
    public let actorRole: String?
    public let note: String?
    public let metadata: JSONValue?
    public let idempotencyKey: String?
    public let createdAt: String?
}

/// GET /{session_id}/actions -> envelope, NOT bare rows. `projection` preserved losslessly.
public struct SessionActionPage: Codable, Equatable, Sendable {
    public let sessionId: String
    public let actions: [SessionActionDTO]
    public let count: Int?
    public let projection: JSONValue?
}

// MARK: - Checkpoints (generic session_checkpoint resource; membership-authorized, NOT verify-gated)

public struct SessionCheckpointRef: Codable, Equatable, Sendable, Identifiable {
    public var id: String { checkpointId }
    public let checkpointId: String
    public let sessionId: String
    public let kind: String?
    public let startSequence: Int64?
    public let endSequence: Int64?
    public let title: String?
    public let summary: String?
    public let createdBy: String?
    public let createdByAgentId: String?
    public let tokenRange: JSONValue?
    public let eventSequence: Int64?
    public let cursor: String?
    public let createdAt: String?
    public let summarySections: JSONValue?
    public let grade: String?
}

/// GET /{session_id}/checkpoints -> { checkpoints, count } (list lacks a cursor).
public struct SessionCheckpointListPage: Codable, Equatable, Sendable {
    public let checkpoints: [SessionCheckpointRef]
    public let count: Int?
}
