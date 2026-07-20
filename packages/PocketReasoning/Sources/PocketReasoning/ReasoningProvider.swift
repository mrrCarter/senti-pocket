// ReasoningProvider — the app-shell ↔ reasoning-provider CONTRACT (Atlas). Approved by relay (#252445) + grounding-
// reconciled (#252458). This is the domain the app coordinator routes through, replacing the 3 fixture-hardcoded lines
// in PocketAppModel (L446 static briefing, L646 hard-refuse, pinned-.offline).
//
// Warden honesty bar (#252350) satisfied BY CONSTRUCTION:
//   #1 honest labeling → `provenance` on every provider; a cached sample can never be mistaken for a live reasoned brief.
//   #2 grounding-first → routing (answered/clarify/unavailable) is decided SERVER-SIDE by relay's routeAnswer
//      (@29033f3, verified at source); the app never re-routes on LLM confidence.
//   #3 provenance → `.answered` carries the grounded evidenceIds (into bundle.evidence[].id).

import Foundation
import PocketContracts

/// A source of briefings + answers over a signature-verified checkpoint. Connectivity-AGNOSTIC: the coordinator
/// observes connectivity and picks the provider (online Gateway vs offline Cached/E4B); the protocol never imports
/// PocketUI (where PocketConnectivity lives), so the reasoning layer does not depend on the UI layer.
public protocol ReasoningProvider: Sendable {
    /// Whether this provider emits LIVE reasoned output (gateway / on-device E4B) or a LABELED cached sample.
    /// The UI reads this so "cached sample" and "your live reasoned brief" are always distinguishable (bar #1).
    var provenance: ReasoningProvenance { get }

    /// Briefing for a checkpoint. `sessionId` is REQUIRED (the gateway membership-gates on it — handlers.mjs L169-173);
    /// `checkpointId` is optional (nil ⇒ the gateway's latest durable checkpoint for the session).
    func briefing(sessionId: String, checkpointId: String?) async throws -> BriefingPlan

    /// Question grounded in the checkpoint. NEVER hard-refuses — returns `.clarify` or `.unavailable(nearestTopics)`
    /// instead of the old L646 "no cache evidence" dead-end.
    func answer(_ question: String, sessionId: String, checkpointId: String?) async throws -> ReasonedAnswer
}

public enum ReasoningProvenance: String, Sendable, Equatable {
    case liveReasoned    // gateway cloud-LLM (or, later, on-device E4B) reasoned over the verified checkpoint
    case cachedSample    // offline fixture/last-sync fallback — a labeled sample, NEVER rendered as live/reasoned/verified
}

/// The result of a grounded question. Mirrors relay's /answer status union (handlers.mjs L145-154 → routeAnswer).
public enum ReasonedAnswer: Sendable, Equatable {
    /// Grounded answer: non-empty evidenceIds retrieved from the verified bundle. Relay's grounding-first routeAnswer
    /// decides this server-side; empty evidenceIds is invalid by contract → the Gateway provider downgrades to `.unavailable`.
    case answered(ReasonedQuestionAnswer)
    /// Thin/ambiguous grounding: ask, don't guess (relay `status == "clarify"`).
    case clarify(prompt: String, options: [String])
    /// No grounding close enough — surface the nearest topics, never a flat refuse (relay `status == "unavailable"`).
    case unavailable(nearestTopics: [NearestTopic])
}

/// Relay's `answer` payload {text, taggedText, evidenceIds (non-empty), llmConfidence?}. Distinct from the frozen
/// PocketContracts.QuestionAnswer: it adds taggedText (audio-tags #252160) + llmConfidence, and keeps them OFF the
/// governed-write QuestionAnswer. Routing is grounding-first — llmConfidence is a secondary tiebreaker only, NEVER
/// the routing gate (LLMs are confidently wrong). Every evidenceId here is genuinely grounded (hallucinated cites
/// are dropped server-side in routeAnswer).
public struct ReasonedQuestionAnswer: Sendable, Equatable, Identifiable {
    public let id: String
    public let checkpointId: String
    public let question: String
    public let text: String                 // PLAIN — display + AVSpeech / OpenAI-TTS
    public let taggedText: String?           // audio-tagged (ElevenLabs); nil when the gateway had no distinct tagged form
    public let evidenceIds: [String]         // grounded citations into bundle.evidence[].id — MUST be non-empty
    public let llmConfidence: Double?        // SECONDARY tiebreaker only — never the routing gate; nil when omitted
    public let provenance: ReasoningProvenance
    public let createdAt: Date
    public init(id: String, checkpointId: String, question: String, text: String, taggedText: String?,
                evidenceIds: [String], llmConfidence: Double?, provenance: ReasoningProvenance, createdAt: Date) {
        self.id = id; self.checkpointId = checkpointId; self.question = question; self.text = text
        self.taggedText = taggedText; self.evidenceIds = evidenceIds; self.llmConfidence = llmConfidence
        self.provenance = provenance; self.createdAt = createdAt
    }
}

/// Relay's `unavailable.nearestTopics[]` = {label, evidenceId}. "Nothing exact, but here's the closest real thing."
public struct NearestTopic: Sendable, Equatable, Identifiable {
    public var id: String { evidenceId }
    public let label: String
    public let evidenceId: String
    public init(label: String, evidenceId: String) { self.label = label; self.evidenceId = evidenceId }
}
