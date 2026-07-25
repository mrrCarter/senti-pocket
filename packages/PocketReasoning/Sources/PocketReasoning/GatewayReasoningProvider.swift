// GatewayReasoningProvider — the ONLINE provider (.liveReasoned). Consumes relay's gated gateway endpoints
// (POST /brief @4b1feaa, POST /answer @bf79a6fa) and maps their wire responses → the domain (BriefingPlan /
// ReasonedAnswer). The wire DTOs below are SOURCE-BOUND to relay's handlers.mjs (read at the gated SHA, not
// inferred). Relay owns the CONCRETE client (PocketSyncClient: URLSession + auth + decode) conforming to
// `GatewayReasoningClient`; this provider is client-agnostic so it unit-tests against a mock today.
//
// AUDIT NOTE (Atlas independent audit, 2026-07-20 — surfaced to the room): the gateway's "grounding" is currently
// `bundle.evidence.map(e => e.id)` — the ENTIRE verified bundle's evidence set (handlers.mjs L139/L184), NOT a
// retrieval-relevance-filtered subset. So routeAnswer's guarantee is ANTI-HALLUCINATION ("cited id ∈ bundle"),
// which is correct + honest for a single small checkpoint. But it is NOT the RRF retrieval the memory-spec (ENGRAM
// §7) describes; at MEMORY-NEEDLE scale (recall across many sessions), "grounded == cited any evidence in a huge
// corpus" degrades to meaningless. This is the seam where real retrieval (FTS5+dense+RRF+rerank) MUST replace the
// full-bundle set before memory-scale needling — else the honesty guarantee silently weakens as the corpus grows.

import Foundation
import PocketContracts

// MARK: - Client seam (relay's PocketSyncClient conforms to this; provider stays testable against a mock)

public protocol GatewayReasoningClient: Sendable {
    func postBrief(sessionId: String, checkpointId: String?) async throws -> BriefWire
    func postAnswer(question: String, sessionId: String, checkpointId: String?) async throws -> AnswerWire
}

// MARK: - Wire DTOs (source-bound to handlers.mjs at the gated SHAs; relay confirms/owns on the concrete client)

/// POST /brief 200 body (handlers.mjs L202): `{ segments:[{text,taggedText,evidenceIds}], grounded, checkpointId, contractsVersion }`.
public struct BriefWire: Codable, Sendable, Equatable {
    public let segments: [BriefSegmentWire]
    public let grounded: Bool
    public let checkpointId: String
    public let contractsVersion: String?
    public init(segments: [BriefSegmentWire], grounded: Bool, checkpointId: String, contractsVersion: String?) {
        self.segments = segments; self.grounded = grounded; self.checkpointId = checkpointId; self.contractsVersion = contractsVersion
    }
}
/// Note (audit): the gateway sends NO per-segment `id` (handlers.mjs L197) — the provider synthesizes a stable index id.
public struct BriefSegmentWire: Codable, Sendable, Equatable {
    public let text: String
    public let taggedText: String?
    public let evidenceIds: [String]
    public init(text: String, taggedText: String?, evidenceIds: [String]) {
        self.text = text; self.taggedText = taggedText; self.evidenceIds = evidenceIds
    }
}

/// POST /answer 200 body (handlers.mjs L154 spread of routeAnswer + provenance).
public struct AnswerWire: Codable, Sendable, Equatable {
    public let status: String                 // "answered" | "clarify" | "unavailable"
    public let answer: AnswerBodyWire?
    public let clarify: ClarifyWire?
    public let unavailable: UnavailableWire?
    public let checkpointId: String
    public let contractsVersion: String?
    public init(status: String, answer: AnswerBodyWire?, clarify: ClarifyWire?, unavailable: UnavailableWire?,
                checkpointId: String, contractsVersion: String?) {
        self.status = status; self.answer = answer; self.clarify = clarify; self.unavailable = unavailable
        self.checkpointId = checkpointId; self.contractsVersion = contractsVersion
    }
}
public struct AnswerBodyWire: Codable, Sendable, Equatable {
    public let text: String
    public let taggedText: String?
    public let evidenceIds: [String]
    public let llmConfidence: Double?
    public init(text: String, taggedText: String?, evidenceIds: [String], llmConfidence: Double?) {
        self.text = text; self.taggedText = taggedText; self.evidenceIds = evidenceIds; self.llmConfidence = llmConfidence
    }
}
public struct ClarifyWire: Codable, Sendable, Equatable {
    public let prompt: String
    public let options: [String]
    public init(prompt: String, options: [String]) { self.prompt = prompt; self.options = options }
}
public struct UnavailableWire: Codable, Sendable, Equatable {
    public let nearestTopics: [NearestTopicWire]
    public init(nearestTopics: [NearestTopicWire]) { self.nearestTopics = nearestTopics }
}
public struct NearestTopicWire: Codable, Sendable, Equatable {
    public let label: String
    public let evidenceId: String
    public init(label: String, evidenceId: String) { self.label = label; self.evidenceId = evidenceId }
}

// MARK: - Provider

public struct GatewayReasoningProvider: ReasoningProvider {
    public let provenance: ReasoningProvenance = .liveReasoned
    private let client: GatewayReasoningClient
    private let clock: @Sendable () -> Date

    public init(client: GatewayReasoningClient, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.clock = clock
    }

    public func briefing(sessionId: String, checkpointId: String?) async throws -> BriefingPlan {
        let wire = try await client.postBrief(sessionId: sessionId, checkpointId: checkpointId)
        // Gateway sends no segment id → synthesize a stable, order-based id. taggedText==plain means "no distinct
        // tagged form" (splitTagged returns plain when untagged) → normalize to nil so the UI/TTS layer doesn't
        // treat plain text as if it carried ElevenLabs tags.
        let segments = wire.segments.enumerated().map { index, seg in
            BriefingSegment(
                id: "seg-\(index)",
                text: seg.text,
                evidenceIds: seg.evidenceIds,
                tone: nil,
                taggedText: Self.normalizedTagged(seg.taggedText, plain: seg.text)
            )
        }
        return BriefingPlan(checkpointId: wire.checkpointId, segments: segments)
    }

    public func answer(_ question: String, sessionId: String, checkpointId: String?) async throws -> ReasonedAnswer {
        let wire = try await client.postAnswer(question: question, sessionId: sessionId, checkpointId: checkpointId)
        switch wire.status {
        case "answered":
            // DEFENSE-IN-DEPTH: relay's routeAnswer already guarantees non-empty grounded evidenceIds on "answered".
            // We re-check on the client so even a gateway regression can never surface an ungrounded answer as grounded.
            guard let body = wire.answer, !body.evidenceIds.isEmpty else {
                return .unavailable(nearestTopics: Self.mapTopics(wire.unavailable))
            }
            return .answered(ReasonedQuestionAnswer(
                id: "answer-\(wire.checkpointId)",
                checkpointId: wire.checkpointId,
                question: question,
                text: body.text,
                taggedText: Self.normalizedTagged(body.taggedText, plain: body.text),
                evidenceIds: body.evidenceIds,
                llmConfidence: body.llmConfidence,
                provenance: .liveReasoned,
                createdAt: clock()
            ))
        case "clarify":
            return .clarify(
                prompt: wire.clarify?.prompt ?? "Which did you mean?",
                options: wire.clarify?.options ?? []
            )
        case "unavailable":
            return .unavailable(nearestTopics: Self.mapTopics(wire.unavailable))
        default:
            // Unknown status → honest unavailable; never fabricate an answer from an unrecognized shape.
            return .unavailable(nearestTopics: Self.mapTopics(wire.unavailable))
        }
    }

    private static func normalizedTagged(_ tagged: String?, plain: String) -> String? {
        guard let tagged, tagged != plain else { return nil }
        return tagged
    }

    private static func mapTopics(_ wire: UnavailableWire?) -> [NearestTopic] {
        (wire?.nearestTopics ?? []).map { NearestTopic(label: $0.label, evidenceId: $0.evidenceId) }
    }
}
