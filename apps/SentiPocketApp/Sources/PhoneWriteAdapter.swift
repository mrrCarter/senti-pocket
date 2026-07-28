import Combine
import Foundation
import PocketCall

/// Bridges the shipped PhoneWriteViewModel (the governed write that posts AS Carter) to the DialOrchestrator's
/// `DialWriter` seam. This is the load-bearing seam: the orchestrator only calls `confirmAndPost()` AFTER a
/// deterministic SpokenConfirm, and `confirmAndPost()` triggers the SAME `confirm()` the human tap uses — so voice-GO
/// is byte-for-byte the tap's governed write (relay's confirmedProposalHash triple-bind applies unchanged). The
/// adapter NEVER posts on its own; it maps the ViewModel's terminal state to a DialWriteResult (no optimistic "sent").
@MainActor
final class PhoneWriteAdapter: DialEpisodeWriter {
    private let viewModel: PhoneWriteViewModel

    init(_ viewModel: PhoneWriteViewModel) {
        self.viewModel = viewModel
    }

    func draft(_ message: String) async {
        viewModel.draft(message)
    }

    func cancel() async {
        viewModel.cancel()
    }

    /// HANGUP teardown (spec C): cancel ONLY a pre-submit draft; retain an authorized in-flight/reconciling write.
    func cancelIfUnsubmitted() async {
        viewModel.cancelIfUnsubmitted()
    }

    /// Fire the SAME explicit-confirm authorizer as the tap, then await the write's TERMINAL state. `.sending` /
    /// `.confirming` are transient (skipped); the render-gate inside the ViewModel guarantees `.sent` only on a
    /// signature-verified `.posted` receipt, so `.posted` here is never optimistic.
    func confirmAndPost() async -> DialWriteResult {
        guard case .confirming = viewModel.state else {
            return .refused("no confirmable draft is armed")   // fail-safe: nothing to confirm → never posts
        }
        // Pulse round-7 #2: the FIRST synchronous action guards cancellation. If the enclosing Task was ALREADY
        // canceled before adapter entry (a hangup at/before confirm), do NOT persist or start the independent POST —
        // cancel the unsubmitted draft and refuse. A pre-submit end yields ZERO POST/queue.
        if Task.isCancelled {
            viewModel.cancelIfUnsubmitted()
            return .refused("canceled before confirm")
        }
        viewModel.confirm()   // identical GovernedWriteConfirmation to the human tap (voice-GO === tap-GO)
        for await state in viewModel.$state.values {
            switch state {
            case .sent:                    return .posted
            case .pending(let message):    return .pending(message)
            case .reconciling(let message): return .pending(message)   // authorized + retained/reconcilable — NOT "not posted"
            case .refused(let message):    return .refused(message)
            case .composing:               return .refused("write returned to composing without posting")
            case .sending, .confirming:    continue   // transient — keep awaiting the terminal state
            }
        }
        // The state stream ENDED without a terminal state — e.g. a hangup cancelled the orchestrator observer while the
        // POST Task + durable outbox keep running INDEPENDENTLY (Pulse round-6 #3). Re-inspect the VM: an AUTHORIZED
        // write (sending/pending/reconciling) reports a RETAINED result, NEVER .refused — ownership transferred at
        // confirm() and is not retracted by a cancelled observer (that would FALSELY classify an authorized write).
        switch viewModel.state {
        case .sent:                     return .posted
        case .pending(let message):     return .pending(message)
        case .reconciling(let message): return .pending(message)
        case .sending:                  return .pending("Sending — your confirmed message is retained.")
        case .refused(let message):     return .refused(message)
        case .composing, .confirming:   return .refused("write state stream ended before a terminal result")
        }
    }
}
