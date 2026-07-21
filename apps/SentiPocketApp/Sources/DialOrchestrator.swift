// DialOrchestrator — the app-side state machine for "Senti Pocket dials Carter" (Carter #266304). Composes the
// pieces we already have: forge's CallKit ring (via the RingPresenter seam), my ReasoningProvider (digs the session
// to answer Carter's follow-ups = free inference into his sessions), and my write flow (Carter's dictated "GO"/reply
// posted as human-mrrcarter). DRAFT for crew co-design — the RingPresenter + reasoning + write are injected seams so
// forge's ring and relay's endpoint drop in without this type depending on their concrete implementations.
//
// HONESTY carried through: the reply Carter dictates goes through the SAME governed write (confirm gate + signature
// render-gate + durable outbox) — dialing him does not create a lower-trust write path.

import Foundation
import PocketReasoning

/// Presents / ends an incoming "Senti is calling". Forge's SentiCallManager conforms (decoupled so branch topology
/// and the CallKit dependency stay out of this orchestrator). Long-lived (a singleton) — held weakly.
protocol RingPresenter: AnyObject {
    func ring(callerName: String)
    func endCall()
}

/// The PHASE of the call. The active DecisionRing is held separately (activeRing) so every phase — including
/// `.answering` — can reach the ring's context (fixes the "stuck after a follow-up" bug).
enum DialPhase: Equatable {
    case idle
    case ringing            // CallKit ringing; Carter hasn't answered
    case speakingUpdate     // answered — speaking the message/decision, then openFloor()
    case listening          // Q&A: Carter asks, Pocket digs the session
    case answering(ReasonedAnswer) // speaking a dug-up answer, then back to listening
    case posting            // posting Carter's dictated reply as him
    case posted             // reply posted; agents will see it
    case declined           // Carter declined / hung up — nothing posted
}

@MainActor
final class DialOrchestrator: ObservableObject {
    @Published private(set) var phase: DialPhase = .idle
    @Published private(set) var activeRing: DecisionRing?

    private weak var ring: RingPresenter?
    /// Builds a reasoning driver for a ring's session (the "dig the session for the answer" path). Injected so the
    /// provider (Gateway online / Gemma or Cached offline) is chosen by the composition root per the ring's context.
    private let reasoningFor: @Sendable (RingContext) -> ReasoningDriver
    /// Posts Carter's dictated reply through the FULL governed write (confirm gate + render-gate + outbox).
    private let write: PhoneWriteViewModel
    private var answerTask: Task<Void, Never>?

    init(ring: RingPresenter,
         write: PhoneWriteViewModel,
         reasoningFor: @escaping @Sendable (RingContext) -> ReasoningDriver) {
        self.ring = ring
        self.write = write
        self.reasoningFor = reasoningFor
    }

    /// A DecisionRing arrived (VoIP push → here) → present the CallKit ring.
    func receiveRing(_ decisionRing: DecisionRing) {
        activeRing = decisionRing
        ring?.ring(callerName: Self.callerName(decisionRing))
        phase = .ringing
    }

    /// Carter picked up → speak the message/decision (the voice layer reads activeRing.message), then openFloor().
    func answered() {
        guard phase == .ringing else { return }
        phase = .speakingUpdate
    }

    /// Done speaking the update / an answer → open the floor for Carter's questions.
    func openFloor() {
        switch phase {
        case .speakingUpdate, .answering: phase = .listening
        default: break
        }
    }

    /// Carter asked a follow-up → dig the session (grounding-first) and surface the answer. A bare update ring (no
    /// context) can't be dug — we don't invent an answer; the voice layer says "that ring carried no session to check."
    func ask(_ question: String) {
        guard phase == .listening, let context = activeRing?.context else { return }
        answerTask?.cancel()
        let driver = reasoningFor(context)
        answerTask = Task { [weak self] in
            let result = await driver.answer(question, sessionId: context.sessionId, checkpointId: context.checkpointId)
            guard let self, !Task.isCancelled else { return }
            if case .answered(let answer, _) = result { self.phase = .answering(answer) }
            // answer() only yields .answered here; on anything else stay listening (never fabricate).
        }
    }

    /// Carter dictated a reply ("GO" / a message) → route it through the governed write (confirm gate + render-gate).
    func dictateReply(_ message: String) {
        guard activeRing != nil else { return }
        phase = .posting
        write.draft(message)   // → .confirming; the confirm tap posts it as human-mrrcarter, then replyPosted()
    }

    /// The write posted (observed when write.state becomes .sent) — reply is in the room; end the call.
    func replyPosted() {
        ring?.endCall()
        activeRing = nil
        phase = .posted
    }

    /// Carter declined / hung up — a governed write NEVER happens without his explicit dictated reply + confirm.
    func decline() {
        answerTask?.cancel()
        ring?.endCall()
        activeRing = nil
        phase = .declined
    }

    private static func callerName(_ r: DecisionRing) -> String {
        switch r.priority {
        case .update:   return "Senti · update from \(r.requestedBy)"
        case .decision: return "Senti · \(r.requestedBy) needs a decision"
        case .urgent:   return "Senti · URGENT — \(r.requestedBy) is blocked"
        }
    }
}
