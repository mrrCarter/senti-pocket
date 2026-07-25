// NeedCarterSignal — the shared "Carter is needed" contract for ring-the-owner (Carter #314703). ONE typed signal
// both trigger paths emit and all three sides (relay gateway / atlas app / forge device) bind:
//   • EXPLICIT path — an agent/Claude/ChatGPT calls `sl ring-owner "<q>"` / the MCP tool → relay dispatches it.
//   • MAGICAL path — the NeedCarterDetector reads the chat tail (cheap pattern gate → LLM confirm) and emits this
//     ONLY when Carter is genuinely needed (no false rings). requestedBy = "detector".
//
// It is a SUPERSET of PocketCall.DialRequest (forge's answer-side type): richer for detection/dispatch/audit
// (kind, context, confidence, evidenceSeqs), and it maps DOWN to a DialRequest for the orchestrator via
// `dialFields()` — so it EXTENDS the shipped dial flow instead of forking a second ring type.
//
// Codable/Sendable so it rides relay's /dial payload wire + the VoIP push verbatim.

import Foundation

/// What kind of attention Carter is being asked for — drives both the ring priority and how Pocket presents it.
public enum NeedCarterKind: Codable, Equatable, Sendable {
    case go                       // "just say GO" — a proceed/greenlight
    case decisionYours            // an open decision only Carter can make
    case pickOption([String])     // choose among concrete labeled options (A/B/C…)
    case info                     // an FYI / status update (no decision needed)
    case checkpointReady          // a milestone checkpoint is ready to review (Carter's checkpoint-ring)

    /// Maps to relay's /dial priority string (the wire the ring substrate already speaks).
    public var dialPriority: String {
        switch self {
        case .info, .checkpointReady: return "medium"
        case .go, .pickOption:        return "medium"
        case .decisionYours:          return "high"
        }
    }

    /// A stable discriminator for logging / the pattern gate.
    public var slug: String {
        switch self {
        case .go: return "go"
        case .decisionYours: return "decision-yours"
        case .pickOption: return "pick-option"
        case .info: return "info"
        case .checkpointReady: return "checkpoint-ready"
        }
    }
}

/// Where the crew is, so Pocket can answer Carter's follow-ups by digging the exact session/checkpoint.
public struct NeedCarterContext: Codable, Equatable, Sendable {
    public let sessionId: String
    public let checkpointId: String?
    /// One line on what's needed — spoken as the lead-in AND used to scope the session dig.
    public let whatWeNeed: String
    public init(sessionId: String, checkpointId: String?, whatWeNeed: String) {
        self.sessionId = sessionId; self.checkpointId = checkpointId; self.whatWeNeed = whatWeNeed
    }
}

public struct NeedCarterSignal: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: NeedCarterKind
    public let question: String          // the decision/update spoken on pickup
    public let context: NeedCarterContext
    /// The detector's confidence Carter is GENUINELY needed (0…1). Explicit-path signals set 1.0 (a human/agent
    /// asked directly); the magical path sets the LLM-confirm confidence, and a ring only fires above a gated floor.
    public let confidence: Double
    /// The chat sequence ids this signal was derived from — makes every ring auditable + lets Pocket jump Carter
    /// straight to the relevant chat. Empty for a pure explicit `ring-owner` with no cited context.
    public let evidenceSeqs: [Int]
    /// The agent id that requested it, or "detector" for the magical path.
    public let requestedBy: String
    public let createdAt: Date

    public init(id: String, kind: NeedCarterKind, question: String, context: NeedCarterContext,
                confidence: Double, evidenceSeqs: [Int], requestedBy: String, createdAt: Date) {
        self.id = id; self.kind = kind; self.question = question; self.context = context
        self.confidence = confidence; self.evidenceSeqs = evidenceSeqs
        self.requestedBy = requestedBy; self.createdAt = createdAt
    }

    /// The fields the answer-side orchestrator needs — maps this superset DOWN to forge's DialRequest shape
    /// (dialId, message, callerName, priority) WITHOUT importing PocketCall (contracts stays dependency-free).
    /// The app's SentiCallManager builds a DialRequest from these.
    public func dialFields() -> (dialId: String, message: String, callerName: String, priority: String) {
        (dialId: id, message: question, callerName: Self.callerName(kind: kind, requestedBy: requestedBy), priority: kind.dialPriority)
    }

    /// A ring fires only when the detected need clears this confidence floor (explicit path = 1.0, always clears).
    /// The magical path gates here so a low-confidence "maybe needed" never rings Carter.
    public static let ringConfidenceFloor: Double = 0.6
    public var clearsRingFloor: Bool { confidence >= Self.ringConfidenceFloor }

    private static func callerName(kind: NeedCarterKind, requestedBy: String) -> String {
        switch kind {
        case .info:            return "Senti · update from \(requestedBy)"
        case .checkpointReady: return "Senti · checkpoint ready"
        case .decisionYours:   return "Senti · \(requestedBy) needs your decision"
        case .pickOption:      return "Senti · \(requestedBy) needs you to choose"
        case .go:              return "Senti · \(requestedBy) needs a GO"
        }
    }
}
