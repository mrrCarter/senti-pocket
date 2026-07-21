import Foundation

// DialOrchestrator — the app-side state flow for DIALS ("Senti Pocket dials Carter"). Composes the SHIPPED pieces
// (SentiCallKit ring, SpokenConfirm bar-2b verdict, the governed write) into warden's VERIFIED consent-flow:
//   answer → hear the decision → DICTATE a reply → read-back → DETERMINISTIC confirm → the governed write posts as Carter.
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

    public init(voice: DialVoice, writer: DialWriter, maxConfirmRetries: Int = 2) {
        self.voice = voice
        self.writer = writer
        self.maxConfirmRetries = max(0, maxConfirmRetries)
    }

    /// Drive one answered decision call to a terminal outcome. Honors Task cancellation (a hangup cancels the run
    /// Task) as a decline that leaves nothing posted/queued. NEVER posts without an explicit dictated reply + confirm.
    public func run(_ request: DialRequest) async -> DialOutcome {
        // 1. BRIEF: speak the decision needing his call.
        if Task.isCancelled { return .declined("hung up before briefing") }
        await voice.speak("Decision needed. \(request.message)")

        // 2. DICTATE: capture his spoken reply. No reply → no write (never a default/ambient reply).
        if Task.isCancelled { return .declined("hung up before dictation") }
        await voice.speak("What should I post as you? Speak your reply after the tone.")
        let reply = (await voice.listen()).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else {
            await voice.speak("I didn't catch a reply, so nothing was posted.")
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
}
