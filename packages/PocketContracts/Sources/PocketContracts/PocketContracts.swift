// PocketContracts v0.1 — FROZEN by Atlas (claude-pocket-atlas) at Phase 0.
// Owner: claude-pocket-atlas. Any change after freeze = bump `contractsVersion` + a threaded HANDOFF.
// Safety invariant (non-negotiable): the local model may PRODUCE an ActionProposal, but deterministic
// code owns target resolution, authorization, confirmation, execution, and receipts. No type here lets
// a model field drive a write directly — see ActionProposal/ActionReceipt notes.
import Foundation

public enum PocketContracts {
    public static let version = "0.1.0"
}

// MARK: - Source (Relay produces RawCheckpoint + CheckpointSummary; gateway summarizes)

/// The actual events from one Senti room segment. Relay extracts this from `sl session export`
/// (events sliced to [startSequence, endSequence]) — field names track Relay's PROVEN live shape
/// (room 954233b7, 41 real auto-checkpoints) so no lane invents shapes.
public struct RawCheckpoint: Codable, Equatable {
    public let checkpointId: String            // durable checkpoint id (sl session checkpoint list)
    public let sessionId: String               // source Senti session
    public let sessionTitle: String
    public let startSequence: Int              // inclusive source range (matches durable checkpoint)
    public let endSequence: Int
    public let capturedAt: Date
    public let agents: [String]                // participating agent ids (export.agents/participants)
    public let events: [RawEvent]              // export.events sliced to [startSequence,endSequence]
}

/// One event from `sl session export` events[]. Real fields: {event, agent, payload, sequenceId, idempotencyToken, ts}.
public struct RawEvent: Codable, Equatable {
    public let sequenceId: Int                 // canonical range anchor (export sequenceId)
    public let event: String                   // session_message | session_reply | session_action | ...
    public let agentId: String                 // agent.id
    public let payload: String                 // message body — Relay pre-scrubs secrets before this crosses to the phone
    public let idempotencyToken: String?       // per-event; Relay uses for EXTRACTION dedup (writeback idempotency is separate)
    public let ts: Date
}

/// Per-agent grounded summary. BASELINE = senti auto_summary `summarySections`
/// (schema=checkpoint_summary_sections_v1) + grade/gradeScore; Relay's gateway summarizer ENRICHES
/// that baseline into evidence-cited perAgent claims. `summaryBaselineSchema` records the source schema.
public struct CheckpointSummary: Codable, Equatable {
    public let checkpointId: String
    public let headline: String                // one-line "what happened" (from senti title/summary)
    public let summaryBaselineSchema: String   // e.g. "checkpoint_summary_sections_v1" (provenance)
    public let grade: String?                  // senti grade/gradeScore passthrough (optional)
    public let perAgent: [AgentSummary]
    public let risks: [String]
    public let blockers: [String]
}

public struct AgentSummary: Codable, Equatable {
    public let agentId: String
    public let summary: String
    public let evidence: [EvidenceRef]         // bounded citations for every claim
}

// MARK: - Bundle (what the phone caches + briefs from)

/// Bounded, signed bundle the phone stores and works from OFFLINE. Signature is verified before use.
public struct PocketBundle: Codable, Equatable {
    public let contractsVersion: String        // == PocketContracts.version at build time
    public let checkpointId: String
    public let sessionId: String
    public let sequenceStart: Int
    public let sequenceEnd: Int
    public let summary: CheckpointSummary
    public let evidence: [EvidenceRef]          // deduped, bounded set the UI can cite
    public let createdAt: Date
    public let signature: String                // gateway signature over the canonical bundle bytes
    public let signingKeyId: String
}

/// A bounded, self-contained pointer to a piece of evidence. Never a live fetch at brief-time (offline honesty).
public struct EvidenceRef: Codable, Equatable, Identifiable {
    public let id: String                       // stable ref id (used by QuestionAnswer citations)
    public let sessionId: String
    public let sequence: Int                    // exact source sequence
    public let agentId: String
    public let snippet: String                  // bounded, pre-scrubbed excerpt shown on the evidence card
    public let ts: Date
}

// MARK: - Briefing + Q&A (Echo/Pulse consume; local, offline-capable)

/// The plan the phone narrates. Pure data; TTS/barge-in owned by Echo, rendering by Pulse.
public struct BriefingPlan: Codable, Equatable {
    public let checkpointId: String
    public let segments: [BriefingSegment]      // ordered spoken segments
}

public struct BriefingSegment: Codable, Equatable, Identifiable {
    public let id: String
    public let text: String                     // spoken text
    public let evidenceIds: [String]            // EvidenceRef.id backing this segment (for the card)
}

/// A local Q&A turn answered from cached evidence only. `answeredOffline` must be honest.
public struct QuestionAnswer: Codable, Equatable, Identifiable {
    public let id: String
    public let checkpointId: String
    public let question: String
    public let answer: String
    public let citations: [String]              // EvidenceRef.id list — every answer must cite or say "no evidence"
    public let answeredOffline: Bool
    public let createdAt: Date
}

// MARK: - Governed write (SAFETY-CRITICAL)

/// A typed proposal the model MAY produce from dictated speech. It is inert until deterministic code
/// resolves + authorizes the target and the human explicitly confirms. NOTHING here is executed on
/// construction. `renderedPreview` is exactly what is read back + shown; targetSessionId/targetSequence
/// are RESOLVED by deterministic code (not free-form model text) before a proposal is confirmable.
public struct ActionProposal: Codable, Equatable, Identifiable {
    public let id: String                       // proposal id (idempotency anchor)
    public let kind: ActionKind                 // constrained enum — no free-form tool name
    public let targetSessionId: String          // deterministically resolved (validated against known sessions)
    public let targetSequence: Int              // the exact sequence being replied under
    public let renderedPreview: String          // EXACT bytes read back + shown; what will be posted
    public let requiresConfirmation: Bool       // always true in v0.1
    public let createdAt: Date
    public let sourceQuestionId: String?        // provenance: which Q&A turn this came from
}

public enum ActionKind: String, Codable, Equatable {
    case threadedReply        // post a threaded reply under targetSequence (the only write in Sunday scope)
    case opinionRequest       // ask an agent for an opinion (threaded)
    // NO destructive/deploy/tool kinds in Sunday scope.
}

/// Result of an executed governed write, or an honest pending/failure state. Produced by deterministic
/// code AFTER explicit confirmation + a successful (or failed) Senti post. Offline => status=.pendingConnectivity.
public struct ActionReceipt: Codable, Equatable, Identifiable {
    public let id: String                       // == ActionProposal.id (idempotency)
    public let proposalId: String
    public let status: ReceiptStatus
    public let resultingSequence: Int?          // the Senti sequence created on success
    public let targetSessionId: String
    public let confirmedByHumanAt: Date         // proof the human confirmed
    public let executedAt: Date?                // nil until actually posted
    public let failureReason: String?           // set on .failed
}

public enum ReceiptStatus: String, Codable, Equatable {
    case pendingConnectivity   // offline: NEVER represent as sent
    case posted                // success: resultingSequence is set
    case failed                // failureReason is set; not posted
}
