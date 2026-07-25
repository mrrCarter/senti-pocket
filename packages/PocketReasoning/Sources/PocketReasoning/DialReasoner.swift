// DialReasoner — the REASONING half of the DIALS voice loop (Atlas lane), the seam forge's DialVoice adapter injects.
// When Carter is on a decision-ring and asks a follow-up ("wait, which checkpoint?"), Pocket must DIG THE SESSION for
// a grounded answer — Carter's "free inference into my sessions" — NOT a canned reply. That dig is my ReasoningProvider.
//
// Lane split (agreed w/ forge #318849): forge owns the DialVoice adapter's AUDIO I/O (speak via pocket-tts, listen via
// whisper) + the SentiCallManager.onAnswered→DialOrchestrator.run hookup; the follow-up-ANSWER comes from an injected
// DialReasoner. This is that injectable — so forge's adapter calls `answer(...)` and gets a grounded, honest result
// with NO PocketReasoning-internals leaking into the audio/orchestration layer.

import Foundation

/// The minimal reasoning seam the DialVoice adapter depends on. Forge's adapter holds one of these and calls it when
/// the recognized transcript is a QUESTION (vs a dictated reply). Kept tiny + Sendable so the audio layer stays clean.
public protocol DialReasoner: Sendable {
    /// Answer Carter's spoken follow-up by grounding it in the ring's session/checkpoint. Returns spoken-ready text
    /// (what pocket-tts says back) plus whether it was actually grounded — so the adapter can honestly say
    /// "let me check…" then read a grounded answer, or "I don't have that in this checkpoint" instead of inventing one.
    func answerFollowUp(_ question: String, sessionId: String, checkpointId: String?) async -> DialSpokenAnswer
}

/// The spoken result of a dial follow-up. `grounded == false` is honest ("nothing in this checkpoint answers that")
/// — the adapter must NOT present an ungrounded guess as if it were from the session.
public struct DialSpokenAnswer: Equatable, Sendable {
    public let spokenText: String
    public let grounded: Bool
    /// Evidence the answer cited (checkpoint evidence ids) — for the "jump Carter to this part of the session" UX.
    public let evidenceIds: [String]
    public init(spokenText: String, grounded: Bool, evidenceIds: [String]) {
        self.spokenText = spokenText; self.grounded = grounded; self.evidenceIds = evidenceIds
    }
}

/// The concrete reasoner backing DialVoice: bridges the ring's follow-up to a ReasoningProvider (online Gateway /
/// offline Cached-or-Gemma), mapping the grounding-first ReasonedAnswer to a spoken result. Provider is injected so
/// the dial reasoner uses whichever provider the coordinator picked for connectivity — one reasoning brain, reused.
public struct ProviderDialReasoner: DialReasoner {
    private let provider: ReasoningProvider
    public init(provider: ReasoningProvider) { self.provider = provider }

    public func answerFollowUp(_ question: String, sessionId: String, checkpointId: String?) async -> DialSpokenAnswer {
        do {
            switch try await provider.answer(question, sessionId: sessionId, checkpointId: checkpointId) {
            case .answered(let qa):
                // Grounded answer from the session — speak it, carry the evidence for the jump-to UX.
                return DialSpokenAnswer(spokenText: qa.text, grounded: true, evidenceIds: qa.evidenceIds)
            case .clarify(let prompt, let options):
                // Ambiguous — ask Carter to disambiguate rather than guess. Honest, not fabricated.
                let opts = options.isEmpty ? "" : " " + options.joined(separator: ", or ") + "?"
                return DialSpokenAnswer(spokenText: prompt + opts, grounded: false, evidenceIds: [])
            case .unavailable(let topics):
                // Nothing grounded — say so, offer the nearest real context (never invent an answer).
                let near = topics.prefix(2).map(\.label).joined(separator: "; ")
                let text = near.isEmpty
                    ? "I don't have anything in this checkpoint that answers that."
                    : "I don't have a direct answer in this checkpoint. The closest context is: \(near)."
                return DialSpokenAnswer(spokenText: text, grounded: false, evidenceIds: [])
            }
        } catch {
            // A reasoning failure is spoken honestly, never a fabricated answer.
            return DialSpokenAnswer(spokenText: "I couldn't reach the session to answer that right now.",
                                    grounded: false, evidenceIds: [])
        }
    }
}
