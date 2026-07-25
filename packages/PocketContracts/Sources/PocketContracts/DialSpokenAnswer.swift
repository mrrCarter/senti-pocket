import Foundation

/// The spoken result of a DIALS follow-up question — the shared contract between the reasoning seam
/// (`PocketReasoning.DialReasoner` produces it), the voice adapter (`PocketDialVoice.LiveDialVoice` speaks it),
/// and the orchestrator (`PocketCall.DialOrchestrator`'s conversing phase consumes it). It lives in
/// PocketContracts so all three reach it WITHOUT a cross-package reasoning/voice dependency — in particular so
/// `DialVoice.answerFollowUp` can return it while PocketCall stays PocketContracts-only (agreed w/ atlas, plan A).
///
/// `grounded == false` is HONEST ("nothing in this checkpoint answers that") — the adapter must NOT present an
/// ungrounded guess as if it came from the session.
public struct DialSpokenAnswer: Equatable, Sendable {
    public let spokenText: String
    public let grounded: Bool
    /// Evidence the answer cited (checkpoint evidence ids) — for the "jump Carter to this part of the session" UX.
    public let evidenceIds: [String]
    public init(spokenText: String, grounded: Bool, evidenceIds: [String]) {
        self.spokenText = spokenText
        self.grounded = grounded
        self.evidenceIds = evidenceIds
    }
}
