// PocketContracts v0.1.2 — FROZEN by Atlas (claude-pocket-atlas).
// v0.1.2 (warden gate #230840): [1 REQUIRED] ActionProposal.proposalHash + ActionReceipt.confirmedProposalHash
//   = content-integrity binding for the governed write — confirm==execute at the Pulse<->Relay seam,
//   invalidate-on-change, single-use (TOCTOU-proof). [2] AgentSummary.claims (fact/inference/recommendation)
//   for grounded epistemic status. Both ADDITIVE (new fields); PocketBundle TOP-LEVEL shape unchanged, but
//   AgentSummary gains `claims` so the canonical fixture adds claims arrays (see Fixtures/canonical_checkpoint.json).
// v0.1.1 (Echo blocker @a9f5252): explicit public inits so external packages construct cross-module.
//
// Safety invariant (non-negotiable): the model may PRODUCE an ActionProposal, but deterministic code owns
// target resolution, authorization, confirmation, execution, and receipts — and proposalHash makes the core
// claim ("it cannot post what you didn't confirm") verifiable + testable across separate lanes.
// Any field change after freeze = bump version + threaded HANDOFF.
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public enum PocketContracts {
    public static let version = "0.1.2"
}

// MARK: - Source (Relay produces RawCheckpoint + CheckpointSummary; gateway summarizes)

public struct RawCheckpoint: Codable, Equatable {
    public let checkpointId: String
    public let sessionId: String
    public let sessionTitle: String
    public let startSequence: Int
    public let endSequence: Int
    public let capturedAt: Date
    public let agents: [String]
    public let events: [RawEvent]
    public init(checkpointId: String, sessionId: String, sessionTitle: String, startSequence: Int, endSequence: Int, capturedAt: Date, agents: [String], events: [RawEvent]) {
        self.checkpointId = checkpointId; self.sessionId = sessionId; self.sessionTitle = sessionTitle
        self.startSequence = startSequence; self.endSequence = endSequence; self.capturedAt = capturedAt
        self.agents = agents; self.events = events
    }
}

public struct RawEvent: Codable, Equatable {
    public let sequenceId: Int
    public let event: String
    public let agentId: String
    public let payload: String
    public let idempotencyToken: String?
    public let ts: Date
    public init(sequenceId: Int, event: String, agentId: String, payload: String, idempotencyToken: String?, ts: Date) {
        self.sequenceId = sequenceId; self.event = event; self.agentId = agentId
        self.payload = payload; self.idempotencyToken = idempotencyToken; self.ts = ts
    }
}

public struct CheckpointSummary: Codable, Equatable {
    public let checkpointId: String
    public let headline: String
    public let summaryBaselineSchema: String
    public let grade: String?
    public let perAgent: [AgentSummary]
    public let risks: [String]
    public let blockers: [String]
    public init(checkpointId: String, headline: String, summaryBaselineSchema: String, grade: String?, perAgent: [AgentSummary], risks: [String], blockers: [String]) {
        self.checkpointId = checkpointId; self.headline = headline; self.summaryBaselineSchema = summaryBaselineSchema
        self.grade = grade; self.perAgent = perAgent; self.risks = risks; self.blockers = blockers
    }
}

public struct AgentSummary: Codable, Equatable {
    public let agentId: String
    public let summary: String                  // free-text overview (per-agent; disagreement preserved, no false consensus)
    public let claims: [Claim]                  // v0.1.2: epistemic-status-tagged, evidence-cited claims (grounding wedge)
    public let evidence: [EvidenceRef]
    public init(agentId: String, summary: String, claims: [Claim], evidence: [EvidenceRef]) {
        self.agentId = agentId; self.summary = summary; self.claims = claims; self.evidence = evidence
    }
}

/// A single grounded claim with explicit epistemic status (baseline §2: distinguish fact/inference/recommendation),
/// so the grounding eval can grade honesty and the briefing can LABEL it aloud. Fact/inference MUST cite
/// EvidenceRef.ids; a recommendation may be uncited.
public struct Claim: Codable, Equatable, Identifiable {
    public let id: String
    public let text: String
    public let kind: ClaimKind
    public let evidenceIds: [String]
    public init(id: String, text: String, kind: ClaimKind, evidenceIds: [String]) {
        self.id = id; self.text = text; self.kind = kind; self.evidenceIds = evidenceIds
    }
}

public enum ClaimKind: String, Codable, Equatable {
    case fact            // directly supported by cited evidence
    case inference       // reasoned from evidence (must still cite the basis)
    case recommendation  // suggested action/opinion (may be uncited)
}

// MARK: - Bundle (what the phone caches + briefs from)

public struct PocketBundle: Codable, Equatable {
    public let contractsVersion: String
    public let checkpointId: String
    public let sessionId: String
    public let sequenceStart: Int
    public let sequenceEnd: Int
    public let summary: CheckpointSummary
    public let evidence: [EvidenceRef]
    public let createdAt: Date
    public let signature: String
    public let signingKeyId: String
    public init(contractsVersion: String, checkpointId: String, sessionId: String, sequenceStart: Int, sequenceEnd: Int, summary: CheckpointSummary, evidence: [EvidenceRef], createdAt: Date, signature: String, signingKeyId: String) {
        self.contractsVersion = contractsVersion; self.checkpointId = checkpointId; self.sessionId = sessionId
        self.sequenceStart = sequenceStart; self.sequenceEnd = sequenceEnd; self.summary = summary
        self.evidence = evidence; self.createdAt = createdAt; self.signature = signature; self.signingKeyId = signingKeyId
    }
}

public struct EvidenceRef: Codable, Equatable, Identifiable {
    public let id: String
    public let sessionId: String
    public let sequence: Int
    public let agentId: String
    public let snippet: String
    public let ts: Date
    public init(id: String, sessionId: String, sequence: Int, agentId: String, snippet: String, ts: Date) {
        self.id = id; self.sessionId = sessionId; self.sequence = sequence
        self.agentId = agentId; self.snippet = snippet; self.ts = ts
    }
}

// MARK: - Briefing + Q&A (Echo/Pulse consume; local, offline-capable)

public struct BriefingPlan: Codable, Equatable {
    public let checkpointId: String
    public let segments: [BriefingSegment]
    public init(checkpointId: String, segments: [BriefingSegment]) {
        self.checkpointId = checkpointId; self.segments = segments
    }
}

public struct BriefingSegment: Codable, Equatable, Identifiable {
    public let id: String
    public let text: String
    public let evidenceIds: [String]
    public init(id: String, text: String, evidenceIds: [String]) {
        self.id = id; self.text = text; self.evidenceIds = evidenceIds
    }
}

public struct QuestionAnswer: Codable, Equatable, Identifiable {
    public let id: String
    public let checkpointId: String
    public let question: String
    public let answer: String
    public let citations: [String]
    public let answeredOffline: Bool
    public let createdAt: Date
    public init(id: String, checkpointId: String, question: String, answer: String, citations: [String], answeredOffline: Bool, createdAt: Date) {
        self.id = id; self.checkpointId = checkpointId; self.question = question; self.answer = answer
        self.citations = citations; self.answeredOffline = answeredOffline; self.createdAt = createdAt
    }
}

// MARK: - Governed write (SAFETY-CRITICAL)

public struct ActionProposal: Codable, Equatable, Identifiable {
    public let id: String
    public let kind: ActionKind
    public let targetSessionId: String
    public let targetSequence: Int
    public let renderedPreview: String
    public let requiresConfirmation: Bool
    public let createdAt: Date
    public let sourceQuestionId: String?
    /// v0.1.2: deterministic digest binding the CONFIRMABLE content = base64url(SHA-256(UTF-8(canonicalPayload))).
    /// Pulse verifies it at read-back/confirm; Relay verifies it again at writeback; ActionReceipt.confirmedProposalHash
    /// echoes exactly this. ANY change to kind/targetSessionId/targetSequence/renderedPreview changes the hash and
    /// INVALIDATES a prior confirmation (single-use, TOCTOU-proof at the Pulse<->Relay seam).
    public let proposalHash: String
    /// Explicit-hash init (cross-platform; used by decode + non-Apple hosts). Producers on Apple use the convenience init.
    public init(id: String, kind: ActionKind, targetSessionId: String, targetSequence: Int, renderedPreview: String, requiresConfirmation: Bool, createdAt: Date, sourceQuestionId: String?, proposalHash: String) {
        self.id = id; self.kind = kind; self.targetSessionId = targetSessionId; self.targetSequence = targetSequence
        self.renderedPreview = renderedPreview; self.requiresConfirmation = requiresConfirmation
        self.createdAt = createdAt; self.sourceQuestionId = sourceQuestionId; self.proposalHash = proposalHash
    }

    /// The EXACT canonical bytes the hash covers — order-fixed, newline-delimited, versioned prefix. Every lane
    /// MUST derive the hash from THIS (never re-serialize differently) or the confirm<->execute binding breaks.
    public static func canonicalPayload(kind: ActionKind, targetSessionId: String, targetSequence: Int, renderedPreview: String) -> String {
        return "pocket.actionproposal.v1\n\(kind.rawValue)\n\(targetSessionId)\n\(targetSequence)\n\(renderedPreview)"
    }
    #if canImport(CryptoKit)
    /// proposalHash = base64url(SHA-256(UTF-8(canonicalPayload))). Producers compute; confirm + writeback verify.
    public static func computeHash(kind: ActionKind, targetSessionId: String, targetSequence: Int, renderedPreview: String) -> String {
        let bytes = Data(canonicalPayload(kind: kind, targetSessionId: targetSessionId, targetSequence: targetSequence, renderedPreview: renderedPreview).utf8)
        let d = SHA256.hash(data: bytes)
        return Data(d).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    /// Producer convenience (Apple): builds a proposal with a freshly-computed hash + requiresConfirmation = true.
    public init(id: String, kind: ActionKind, targetSessionId: String, targetSequence: Int, renderedPreview: String, createdAt: Date, sourceQuestionId: String?) {
        let h = ActionProposal.computeHash(kind: kind, targetSessionId: targetSessionId, targetSequence: targetSequence, renderedPreview: renderedPreview)
        self.init(id: id, kind: kind, targetSessionId: targetSessionId, targetSequence: targetSequence, renderedPreview: renderedPreview, requiresConfirmation: true, createdAt: createdAt, sourceQuestionId: sourceQuestionId, proposalHash: h)
    }
    /// Verify the stored hash still matches the content. Call at CONFIRM and again at WRITEBACK; refuse on mismatch.
    public func hashMatchesContent() -> Bool {
        return proposalHash == ActionProposal.computeHash(kind: kind, targetSessionId: targetSessionId, targetSequence: targetSequence, renderedPreview: renderedPreview)
    }
    #endif
}

public enum ActionKind: String, Codable, Equatable {
    case threadedReply
    case opinionRequest
    // NO destructive/deploy/tool kinds in Sunday scope.
}

public struct ActionReceipt: Codable, Equatable, Identifiable {
    public let id: String
    public let proposalId: String
    public let status: ReceiptStatus
    public let resultingSequence: Int?
    public let targetSessionId: String
    public let confirmedByHumanAt: Date
    public let confirmedProposalHash: String   // v0.1.2: the EXACT ActionProposal.proposalHash the human confirmed.
                                               // Writeback MUST refuse if the live proposal's hash != this. Proves
                                               // "what was posted == what was confirmed" (airtight core claim).
    public let executedAt: Date?
    public let failureReason: String?
    public init(id: String, proposalId: String, status: ReceiptStatus, resultingSequence: Int?, targetSessionId: String, confirmedByHumanAt: Date, confirmedProposalHash: String, executedAt: Date?, failureReason: String?) {
        self.id = id; self.proposalId = proposalId; self.status = status; self.resultingSequence = resultingSequence
        self.targetSessionId = targetSessionId; self.confirmedByHumanAt = confirmedByHumanAt
        self.confirmedProposalHash = confirmedProposalHash
        self.executedAt = executedAt; self.failureReason = failureReason
    }
}

public enum ReceiptStatus: String, Codable, Equatable {
    case pendingConnectivity   // offline: NEVER represent as sent
    case posted                // success: resultingSequence is set
    case failed                // failureReason is set
}
