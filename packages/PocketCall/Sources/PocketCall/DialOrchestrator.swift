import Foundation
import PocketContracts

// DialOrchestrator — the app-side state flow for DIALS ("Senti Pocket dials Carter"). Composes the SHIPPED pieces
// (SentiCallKit ring, SpokenConfirm bar-2b verdict, the governed write) into warden's VERIFIED consent-flow:
//   answer → hear the decision → CONVERSE (grounded Q&A) → DICTATE a reply → read-back → DETERMINISTIC confirm →
//   the governed write posts as Carter.
// Load-bearing invariant (warden's bar): a governed write NEVER happens without his explicit DICTATED reply AND an
// explicit confirm. Decline / hangup (cancellation) / unclear-confirm-exhausted → NOTHING is posted or queued.
// Dependencies are injected protocols, so this consent state machine is unit-testable WITHOUT CallKit / ASR / network,
// and the confirm authorizer is the SAME governed write() the tap uses (voice-confirm just triggers it, per bar 2b/2c).

/// A decision ring reduced to what the flow needs (SentiCallManager.IncomingDecisionCall maps to this; kept
/// CallKit-free so the state machine compiles + tests without the CallKit/PushKit guard).
public struct DialRequest: Equatable, Sendable {
    public let dialId: String
    public let message: String
    public let callerName: String
    public let priority: String
    public init(dialId: String, message: String, callerName: String, priority: String) {
        self.dialId = dialId
        self.message = message
        self.callerName = callerName
        self.priority = priority
    }
}

/// Voice I/O the orchestrator drives. Real impl = PocketVoice TTS + on-device ASR; a mock drives the tests.
public protocol DialVoice: Sendable {
    func speak(_ text: String) async
    func listen() async -> String   // the recognized transcript ("" if nothing was recognized)
    /// Answer a spoken follow-up QUESTION aloud, grounded-or-honestly-unavailable (never invents). Used ONLY in the
    /// conversing phase; it speaks a NEW answer and returns it — it does NOT, and MUST NOT, post anything. The
    /// orchestrator routes an utterance here only when DialReplyMarker classifies it as a question, so answering a
    /// follow-up can never be confused with authorizing a write.
    func answerFollowUp(_ question: String) async -> DialSpokenAnswer
}

public enum DialWriteResult: Equatable, Sendable {
    case posted                 // a verified .posted receipt (signature verified under the pinned key)
    case pending(String)        // offline / transient — queued, retryable; the confirmed intent is retained
    case refused(String)        // the gateway refused / non-posted / signature not verified — never "sent"
}

/// The governed write the orchestrator drives. Real impl wraps PhoneWriteViewModel (draft → confirm() → resulting
/// state). `confirmAndPost` is the SAME explicit-confirm authorizer the human tap uses — the orchestrator only ever
/// calls it AFTER a deterministic confirm, so voice-GO === tap-GO.
public protocol DialWriter: Sendable {
    func draft(_ message: String) async
    func confirmAndPost() async -> DialWriteResult
    func cancel() async
}

public enum DialOutcome: Equatable, Sendable {
    case posted                 // Carter dictated + confirmed → the governed write posted as him
    case pending(String)        // confirmed but offline → queued (never shown as sent)
    case declined(String)       // decline / hangup / no reply / unclear-exhausted → NOTHING posted or queued
}

@MainActor
public final class DialOrchestrator {
    private let voice: DialVoice
    private let writer: DialWriter
    private let maxConfirmRetries: Int
    private let maxConversingTurns: Int

    public init(voice: DialVoice, writer: DialWriter, maxConfirmRetries: Int = 2, maxConversingTurns: Int = 6) {
        self.voice = voice
        self.writer = writer
        self.maxConfirmRetries = max(0, maxConfirmRetries)
        self.maxConversingTurns = max(1, maxConversingTurns)
    }

    /// Drive one answered decision call to a terminal outcome. Honors Task cancellation (a hangup cancels the run
    /// Task) as a decline that leaves nothing posted/queued. NEVER posts without an explicit dictated reply + confirm.
    public func run(_ request: DialRequest) async -> DialOutcome {
        // 1. BRIEF: open by telling him WHO's asking (beat 4), then the decision. `callerName` is the AUTHED,
        //    hydrated caller identity (NeedCarterSignal.callerName → "Senti · <requestedBy> needs your decision" /
        //    "… needs you to choose" / "… needs a GO"), so it already names the requesting agent + the ask — no bare
        //    "Decision needed." and no unauthenticated push field in the spoken line. (A future literal "This is
        //    <agent>." would thread the authed `requestedBy` onto DialRequest; this uses what the ring already carries.)
        if Task.isCancelled { return .declined("hung up before briefing") }
        await voice.speak("\(request.callerName). \(request.message)")

        // 2. CONVERSE: grounded Q&A until an EXPLICIT reply-marker. A marker-less utterance is ALWAYS answered,
        //    NEVER posted — the marker is the ONLY path from speech to a governed write. No reply → nothing posted.
        guard let reply = await converse() else {
            return .declined("no dictated reply")
        }

        // 3. DRAFT the governed write (arms the read-back; posts nothing yet).
        if Task.isCancelled { return .declined("hung up before draft") }
        await writer.draft(reply)

        // 4. CONFIRM: read back the EXACT reply and require a DETERMINISTIC spoken confirm (bar 2b), bounded retries.
        for attempt in 0...maxConfirmRetries {
            if Task.isCancelled { await writer.cancel(); return .declined("hung up during confirm") }
            await voice.speak("I'll post as you: \(reply). Say confirm to send, or cancel.")
            let heard = await voice.listen()
            switch SpokenConfirm.verdict(for: heard) {
            case .confirmed:
                switch await writer.confirmAndPost() {
                case .posted:            return .posted
                case .pending(let why):  return .pending(why)
                case .refused(let why):  await voice.speak("Not sent — \(why)"); return .declined("write refused: \(why)")
                }
            case .declined:
                await writer.cancel()
                await voice.speak("Cancelled. Nothing was posted.")
                return .declined("explicit decline")
            case .unclear(let why):
                if attempt < maxConfirmRetries {
                    await voice.speak("I didn't get a clear confirm.")
                    continue
                }
                await writer.cancel()
                await voice.speak("No clear confirm, so nothing was posted.")
                return .declined("confirm unclear: \(why)")
            }
        }
        // Unreachable (the loop returns), but fail-safe: never fall through to a post.
        await writer.cancel()
        return .declined("confirm not obtained")
    }

    /// The CONVERSING phase: let Carter ask grounded follow-ups, then dictate his reply. Returns the dictated reply
    /// — the ONLY path from speech to a governed write — or nil (silence / hangup / exhausted without a marker →
    /// decline, nothing posted).
    ///
    /// Consent seam (co-designed + gated w/ atlas): every utterance is classified by `DialReplyMarker`. A question
    /// (no marker) is ALWAYS answered via `voice.answerFollowUp` and NEVER posted; ambiguity resolves toward
    /// "answer," never "post." Only an explicit prefix reply-marker exits to a write. A bare marker takes the NEXT
    /// utterance verbatim. Even so, the returned reply still flows through DRAFT → the SAME governed confirmAndPost
    /// the tap uses — a false marker can never auto-post.
    private func converse() async -> String? {
        await voice.speak("Ask me anything about this, or say 'my reply is' when you're ready to post.")
        for _ in 0..<maxConversingTurns {
            if Task.isCancelled { return nil }
            let heard = (await voice.listen()).trimmingCharacters(in: .whitespacesAndNewlines)
            switch DialReplyMarker.classify(heard) {
            case .question:
                guard !heard.isEmpty else {
                    // silence / hangup without a marker → nothing posted (never a default/ambient reply)
                    await voice.speak("I didn't hear anything, so nothing was posted.")
                    return nil
                }
                // Grounded-or-honest answer, spoken aloud by the voice. This NEVER posts.
                _ = await voice.answerFollowUp(heard)
            case .reply(let text):
                return text
            case .awaitingReply:
                await voice.speak("Go ahead with your reply.")
                let next = (await voice.listen()).trimmingCharacters(in: .whitespacesAndNewlines)
                return next.isEmpty ? nil : next
            }
        }
        // Exhausted the conversing budget without an explicit reply-marker → nothing posted.
        await voice.speak("We can pick this up later — nothing was posted.")
        return nil
    }
}
