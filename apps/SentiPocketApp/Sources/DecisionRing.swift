// DecisionRing — the trigger contract for "Senti Pocket dials Carter" (Carter #266304). An agent hits a Senti
// "ring Carter" command with a message + context; the gateway VoIP-pushes this to Pocket; Pocket rings, speaks the
// message, digs the session for follow-up answers, and posts back whatever Carter dictates ("GO" / a message).
//
// DRAFT contract for crew co-design (Carter: "decide TOGETHER"). Lives in the app for now; promote to a shared
// package (PocketContracts) once relay's command endpoint + this shape are agreed, so agent↔gateway↔Pocket all bind it.

import Foundation

/// Ring urgency — maps to how CallKit presents + how insistently it rings (Carter: "medium priority").
enum RingPriority: String, Codable, Sendable, Equatable {
    case update       // FYI — a status update, no decision needed
    case decision     // Carter's call is wanted (the default "medium" — a decision awaits)
    case urgent       // blocking — the crew is stuck without him
}

/// Where the agents are, so Pocket can answer follow-ups ("if i ask more info") by digging the session.
struct RingContext: Codable, Sendable, Equatable {
    let sessionId: String
    let checkpointId: String?
    /// One line on what the crew needs / is deciding — spoken as the lead-in + used to scope the session dig.
    let whatWeNeed: String
}

/// The dial trigger an agent sends.
struct DecisionRing: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let message: String            // the update / decision text spoken to Carter on pickup
    let priority: RingPriority
    let context: RingContext?      // nil for a bare update; present when Pocket may need to dig for more
    let requestedBy: String        // the agent id that rang (so Carter knows who needs him)
    let createdAt: Date

    init(id: String = UUID().uuidString,
         message: String,
         priority: RingPriority = .decision,
         context: RingContext? = nil,
         requestedBy: String,
         createdAt: Date = Date()) {
        self.id = id
        self.message = message
        self.priority = priority
        self.context = context
        self.requestedBy = requestedBy
        self.createdAt = createdAt
    }
}
