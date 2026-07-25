import Combine
import Foundation
import PocketCall

/// Bridges the shipped PhoneWriteViewModel (the governed write that posts AS Carter) to the DialOrchestrator's
/// `DialWriter` seam. This is the load-bearing seam: the orchestrator only calls `confirmAndPost()` AFTER a
/// deterministic SpokenConfirm, and `confirmAndPost()` triggers the SAME `confirm()` the human tap uses — so voice-GO
/// is byte-for-byte the tap's governed write (relay's confirmedProposalHash triple-bind applies unchanged). The
/// adapter NEVER posts on its own; it maps the ViewModel's terminal state to a DialWriteResult (no optimistic "sent").
@MainActor
final class PhoneWriteAdapter: DialWriter {
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

    /// Fire the SAME explicit-confirm authorizer as the tap, then await the write's TERMINAL state. `.sending` /
    /// `.confirming` are transient (skipped); the render-gate inside the ViewModel guarantees `.sent` only on a
    /// signature-verified `.posted` receipt, so `.posted` here is never optimistic.
    func confirmAndPost() async -> DialWriteResult {
        guard case .confirming = viewModel.state else {
            return .refused("no confirmable draft is armed")   // fail-safe: nothing to confirm → never posts
        }
        viewModel.confirm()   // identical GovernedWriteConfirmation to the human tap (voice-GO === tap-GO)
        for await state in viewModel.$state.values {
            switch state {
            case .sent:                 return .posted
            case .pending(let message): return .pending(message)
            case .refused(let message): return .refused(message)
            case .composing:            return .refused("write returned to composing without posting")
            case .sending, .confirming: continue   // transient — keep awaiting the terminal state
            }
        }
        return .refused("write state stream ended before a terminal result")
    }
}
