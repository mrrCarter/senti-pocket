// PocketContracts v0.1.1 — FROZEN by Atlas (claude-pocket-atlas).
// v0.1.1 (contract fix per Echo blocker @a9f5252): every public struct now has an explicit `public init`
// so external packages (PocketUI / PocketInference / PocketVoice / PocketSyncClient / PocketActionsClient)
// can CONSTRUCT these types — Swift's synthesized memberwise + Decodable inits are `internal`. Data shape
// is UNCHANGED (canonical_checkpoint.json still valid); this is a source-compatible cross-module fix.
// Any field change after freeze = bump version + threaded HANDOFF.
//
// Safety invariant (non-negotiable): the local model may PRODUCE an ActionProposal, but deterministic
// code owns target resolution, authorization, confirmation, execution, and receipts.
import Foundation

public enum PocketContracts {
    public static let version = "0.1.1"
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
    public let summary: String
    public let evidence: [EvidenceRef]
    public init(agentId: String, summary: String, evidence: [EvidenceRef]) {
        self.agentId = agentId; self.summary = summary; self.evidence = evidence
    }
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
    public init(id: String, kind: ActionKind, targetSessionId: String, targetSequence: Int, renderedPreview: String, requiresConfirmation: Bool, createdAt: Date, sourceQuestionId: String?) {
        self.id = id; self.kind = kind; self.targetSessionId = targetSessionId; self.targetSequence = targetSequence
        self.renderedPreview = renderedPreview; self.requiresConfirmation = requiresConfirmation
        self.createdAt = createdAt; self.sourceQuestionId = sourceQuestionId
    }
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
    public let executedAt: Date?
    public let failureReason: String?
    public init(id: String, proposalId: String, status: ReceiptStatus, resultingSequence: Int?, targetSessionId: String, confirmedByHumanAt: Date, executedAt: Date?, failureReason: String?) {
        self.id = id; self.proposalId = proposalId; self.status = status; self.resultingSequence = resultingSequence
        self.targetSessionId = targetSessionId; self.confirmedByHumanAt = confirmedByHumanAt
        self.executedAt = executedAt; self.failureReason = failureReason
    }
}

public enum ReceiptStatus: String, Codable, Equatable {
    case pendingConnectivity   // offline: NEVER represent as sent
    case posted                // success: resultingSequence is set
    case failed                // failureReason is set
}
