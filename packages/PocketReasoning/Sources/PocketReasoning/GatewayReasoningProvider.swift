// UnboundGatewayReasoningProvider — validates and maps relay's gated gateway wire responses
// (POST /brief @4b1feaa, POST /answer @bf79a6fa) and maps their wire responses → bounded unbound candidates
// (BriefingPlan / UnboundReasonedAnswer). The wire DTOs below are SOURCE-BOUND to relay's handlers.mjs (read at the gated SHA, not
// inferred). Relay owns the CONCRETE client (PocketSyncClient: URLSession + auth + decode) conforming to
// `GatewayReasoningClient`; this adapter is client-agnostic so it unit-tests against a mock today. It deliberately
// does NOT conform to `ReasoningProvider` and exposes no provenance: only a higher trust boundary that independently
// verifies the cited checkpoint may publish its output as `.liveReasoned`.
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

/// A decoded HTTP 200 is not sufficient authority to present or persist a briefing. These errors identify the
/// fail-closed envelope checks performed before a wire response becomes a `BriefingPlan`.
public enum GatewayReasoningProviderError: Error, Equatable, LocalizedError {
    case ungroundedBriefing
    case incompatibleContractsVersion(actual: String?)
    case checkpointMismatch
    case malformedBriefing
    case malformedAnswer

    public var errorDescription: String? {
        switch self {
        case .ungroundedBriefing:
            return "No grounded briefing was available for this checkpoint."
        case .incompatibleContractsVersion:
            return "The reasoning response uses an incompatible contracts version."
        case .checkpointMismatch:
            return "The reasoning response belongs to a different checkpoint."
        case .malformedBriefing:
            return "The reasoning gateway returned an invalid grounded briefing."
        case .malformedAnswer:
            return "The reasoning gateway returned an invalid answer."
        }
    }
}

/// A structurally valid gateway answer that has not yet been admitted against a signature-verified checkpoint.
///
/// This is deliberately a distinct type from `ReasonedAnswer`: decoding and shape validation alone cannot mint a
/// domain answer that callers may present as grounded. A verified boundary must bind its citations to the exact
/// `VerifiedBundle` and explicitly promote it.
public enum UnboundReasonedAnswer: Sendable, Equatable {
    case answered(UnboundReasonedQuestionAnswer)
    case clarify(prompt: String, options: [String])
    case unavailable(nearestTopics: [NearestTopic])
}

/// The answered member of `UnboundReasonedAnswer`. It intentionally carries no `ReasoningProvenance` because the
/// gateway response has not yet been independently bound to signed checkpoint evidence.
public struct UnboundReasonedQuestionAnswer: Sendable, Equatable {
    public let id: String
    public let checkpointId: String
    public let question: String
    public let text: String
    public let taggedText: String?
    public let evidenceIds: [String]
    public let llmConfidence: Double?
    public let createdAt: Date

    public init(
        id: String,
        checkpointId: String,
        question: String,
        text: String,
        taggedText: String?,
        evidenceIds: [String],
        llmConfidence: Double?,
        createdAt: Date
    ) {
        self.id = id
        self.checkpointId = checkpointId
        self.question = question
        self.text = text
        self.taggedText = taggedText
        self.evidenceIds = evidenceIds
        self.llmConfidence = llmConfidence
        self.createdAt = createdAt
    }
}

// MARK: - Unbound wire adapter

public struct UnboundGatewayReasoningProvider: Sendable {
    private let client: GatewayReasoningClient
    private let clock: @Sendable () -> Date

    public init(client: GatewayReasoningClient, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.clock = clock
    }

    public func briefing(sessionId: String, checkpointId: String?) async throws -> BriefingPlan {
        let wire = try await client.postBrief(sessionId: sessionId, checkpointId: checkpointId)
        try Self.validateBriefing(wire, requestedCheckpointId: checkpointId)
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

    public func answer(
        _ question: String,
        sessionId: String,
        checkpointId: String?
    ) async throws -> UnboundReasonedAnswer {
        let wire = try await client.postAnswer(question: question, sessionId: sessionId, checkpointId: checkpointId)
        try Self.validateResponseProvenance(
            checkpointId: wire.checkpointId,
            contractsVersion: wire.contractsVersion,
            requestedCheckpointId: checkpointId,
            malformedError: .malformedAnswer
        )
        try Self.validateAnswerShape(wire)
        switch wire.status {
        case "answered":
            // DEFENSE-IN-DEPTH: relay's routeAnswer already guarantees non-empty grounded evidenceIds on "answered".
            // We re-check on the client so even a gateway regression can never surface an ungrounded answer as grounded.
            guard let body = wire.answer, !body.evidenceIds.isEmpty else {
                return .unavailable(nearestTopics: Self.mapTopics(wire.unavailable))
            }
            return .answered(UnboundReasonedQuestionAnswer(
                id: "answer-\(wire.checkpointId)",
                checkpointId: wire.checkpointId,
                question: question,
                text: body.text,
                taggedText: Self.normalizedTagged(body.taggedText, plain: body.text),
                evidenceIds: body.evidenceIds,
                llmConfidence: body.llmConfidence,
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

    /// Mirrors the gateway's grounding gate and applies the phone's frozen bundle budgets before the result can be
    /// displayed or cached. Exact evidence membership is checked later against `VerifiedBundle` by PocketCall;
    /// this unbound layer rejects an internally inconsistent/tampered wire envelope even before that binding is
    /// available. Its public type cannot be injected into `ReasoningDriver`, and its answer method returns the
    /// distinct `UnboundReasonedAnswer` candidate type. Release callers must wrap it in a verified checkpoint
    /// boundary before a `ReasonedAnswer` or `.liveReasoned` provenance can exist.
    private static func validateBriefing(_ wire: BriefWire, requestedCheckpointId: String?) throws {
        guard wire.grounded else { throw GatewayReasoningProviderError.ungroundedBriefing }
        try validateResponseProvenance(
            checkpointId: wire.checkpointId,
            contractsVersion: wire.contractsVersion,
            requestedCheckpointId: requestedCheckpointId,
            malformedError: .malformedBriefing
        )
        guard !wire.segments.isEmpty, wire.segments.count <= PocketBundle.capEvidence else {
            throw GatewayReasoningProviderError.malformedBriefing
        }

        var totalElements = wire.segments.count
        var totalBytes = wire.checkpointId.utf8.count + (wire.contractsVersion?.utf8.count ?? 0)
        for segment in wire.segments {
            guard hasVisibleText(segment.text, maxBytes: PocketBundle.capSummary),
                  segment.taggedText.map({ hasVisibleText($0, maxBytes: PocketBundle.capSummary) }) ?? true,
                  taggedTextMatchesPlain(segment.taggedText, plain: segment.text),
                  !segment.evidenceIds.isEmpty,
                  segment.evidenceIds.count <= PocketBundle.capEvidence else {
                throw GatewayReasoningProviderError.malformedBriefing
            }

            var citedIds = Set<[UInt8]>()
            for evidenceId in segment.evidenceIds {
                guard isWellFormedIdentity(evidenceId, maxBytes: PocketBundle.capEvId),
                      citedIds.insert(identityKey(evidenceId)).inserted else {
                    throw GatewayReasoningProviderError.malformedBriefing
                }
            }

            guard consume(segment.evidenceIds.count, into: &totalElements, limit: PocketBundle.maxTotalElements),
                  consume(segment.text.utf8.count, into: &totalBytes, limit: PocketBundle.maxTotalBytes),
                  consume(segment.taggedText?.utf8.count ?? 0, into: &totalBytes, limit: PocketBundle.maxTotalBytes) else {
                throw GatewayReasoningProviderError.malformedBriefing
            }
            for evidenceId in segment.evidenceIds {
                guard consume(evidenceId.utf8.count, into: &totalBytes, limit: PocketBundle.maxTotalBytes) else {
                    throw GatewayReasoningProviderError.malformedBriefing
                }
            }
        }
    }

    private static func validateResponseProvenance(
        checkpointId: String,
        contractsVersion: String?,
        requestedCheckpointId: String?,
        malformedError: GatewayReasoningProviderError
    ) throws {
        guard contractsVersion == PocketContracts.version else {
            throw GatewayReasoningProviderError.incompatibleContractsVersion(actual: contractsVersion)
        }
        guard isWellFormedIdentity(checkpointId, maxBytes: PocketBundle.capId) else {
            throw malformedError
        }
        if let requestedCheckpointId, !byteExact(checkpointId, requestedCheckpointId) {
            throw GatewayReasoningProviderError.checkpointMismatch
        }
    }

    private static func validateAnswerShape(_ wire: AnswerWire) throws {
        switch wire.status {
        case "answered":
            guard let body = wire.answer else { throw GatewayReasoningProviderError.malformedAnswer }
            // Preserve the existing honest downgrade for an answered discriminator that carries no citations. None
            // of the ungrounded body is surfaced; only a separately validated unavailable context can cross.
            guard !body.evidenceIds.isEmpty else {
                try validateTopics(wire.unavailable)
                return
            }
            guard hasVisibleText(body.text, maxBytes: PocketBundle.capSummary),
                  body.taggedText.map({ hasVisibleText($0, maxBytes: PocketBundle.capSummary) }) ?? true,
                  taggedTextMatchesPlain(body.taggedText, plain: body.text),
                  body.evidenceIds.count <= PocketBundle.capEvidence else {
                throw GatewayReasoningProviderError.malformedAnswer
            }
            var seen = Set<[UInt8]>()
            var totalBytes = wire.checkpointId.utf8.count + (wire.contractsVersion?.utf8.count ?? 0)
            guard consume(body.text.utf8.count, into: &totalBytes, limit: PocketBundle.maxTotalBytes),
                  consume(body.taggedText?.utf8.count ?? 0, into: &totalBytes, limit: PocketBundle.maxTotalBytes) else {
                throw GatewayReasoningProviderError.malformedAnswer
            }
            for evidenceId in body.evidenceIds {
                guard isWellFormedIdentity(evidenceId, maxBytes: PocketBundle.capEvId),
                      seen.insert(identityKey(evidenceId)).inserted,
                      consume(evidenceId.utf8.count, into: &totalBytes, limit: PocketBundle.maxTotalBytes) else {
                    throw GatewayReasoningProviderError.malformedAnswer
                }
            }
        case "clarify":
            guard let clarify = wire.clarify,
                  hasVisibleText(clarify.prompt, maxBytes: PocketBundle.capSummary),
                  clarify.options.count <= 4,
                  clarify.options.allSatisfy({ hasVisibleText($0, maxBytes: PocketBundle.capStr) }) else {
                throw GatewayReasoningProviderError.malformedAnswer
            }

        case "unavailable":
            try validateTopics(wire.unavailable)

        default:
            // The caller maps an unknown discriminator to honest unavailable, but even that context must be bounded.
            try validateTopics(wire.unavailable)
        }
    }

    private static func validateTopics(_ unavailable: UnavailableWire?) throws {
        let topics = unavailable?.nearestTopics ?? []
        guard topics.count <= PocketBundle.capEvidence else {
            throw GatewayReasoningProviderError.malformedAnswer
        }
        var seen = Set<[UInt8]>()
        var totalBytes = 0
        for topic in topics {
            guard hasVisibleText(topic.label, maxBytes: PocketBundle.capStr),
                  isWellFormedIdentity(topic.evidenceId, maxBytes: PocketBundle.capEvId),
                  seen.insert(identityKey(topic.evidenceId)).inserted,
                  consume(topic.label.utf8.count, into: &totalBytes, limit: PocketBundle.maxTotalBytes),
                  consume(topic.evidenceId.utf8.count, into: &totalBytes, limit: PocketBundle.maxTotalBytes) else {
                throw GatewayReasoningProviderError.malformedAnswer
            }
        }
    }

    private static func isWellFormedIdentity(_ value: String, maxBytes: Int) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maxBytes else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && byteExact(trimmed, value)
    }

    private static func hasVisibleText(_ value: String, maxBytes: Int) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maxBytes else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func taggedTextMatchesPlain(_ taggedText: String?, plain: String) -> Bool {
        guard let taggedText else { return true }
        let stripped = taggedText.replacingOccurrences(
            of: #"\[[a-z][a-z0-9 _-]{0,24}\]"#,
            with: " ",
            options: .regularExpression
        )
        return normalizedWhitespace(stripped) == normalizedWhitespace(plain)
    }

    private static func normalizedWhitespace(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func identityKey(_ value: String) -> [UInt8] {
        Array(value.utf8)
    }

    private static func byteExact(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    private static func consume(_ amount: Int, into total: inout Int, limit: Int) -> Bool {
        guard amount >= 0, total <= limit, amount <= limit - total else { return false }
        total += amount
        return true
    }

    private static func mapTopics(_ wire: UnavailableWire?) -> [NearestTopic] {
        (wire?.nearestTopics ?? []).map { NearestTopic(label: $0.label, evidenceId: $0.evidenceId) }
    }
}
