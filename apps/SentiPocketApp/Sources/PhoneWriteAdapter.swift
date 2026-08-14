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
    private let isWriteAuthorized: @MainActor () -> Bool
    /// True only for the unconfirmed draft this adapter successfully armed. A restored `.pending` intent belongs to
    /// an earlier explicit confirmation and must never be erased when a later call hangs up before it can draft.
    private var ownsUnconfirmedDraft = false

    init(
        _ viewModel: PhoneWriteViewModel,
        isWriteAuthorized: @escaping @MainActor () -> Bool = { true }
    ) {
        self.viewModel = viewModel
        self.isWriteAuthorized = isWriteAuthorized
    }

    func draft(_ message: String) async {
        guard isWriteAuthorized(), case .composing = viewModel.state else { return }
        viewModel.draft(message)
        if case .confirming = viewModel.state {
            ownsUnconfirmedDraft = true
        }
    }

    func cancel() async {
        guard ownsUnconfirmedDraft else { return }
        ownsUnconfirmedDraft = false
        viewModel.cancel()
    }

    /// Fire the SAME explicit-confirm authorizer as the tap, then await the write's TERMINAL state. `.sending` /
    /// `.confirming` are transient (skipped); the render-gate inside the ViewModel guarantees `.sent` only for a
    /// `VerifiedActionReceipt` bound to the exact proposal, confirmation, result, key id, and signature.
    func confirmAndPost() async -> DialWriteResult {
        guard ownsUnconfirmedDraft, case .confirming = viewModel.state else {
            return .refused("no confirmable draft is armed")   // fail-safe: nothing to confirm → never posts
        }
        guard !Task.isCancelled else {
            await cancel()
            return .refused("the call ended before confirmation")
        }
        guard isWriteAuthorized() else {
            await cancel()
            return .refused("the selected session or authentication changed before confirmation")
        }
        viewModel.confirm()   // identical GovernedWriteConfirmation to the human tap (voice-GO === tap-GO)
        ownsUnconfirmedDraft = false
        // Explicit confirmation is the commit point: post() has synchronously claimed the durable outbox before its
        // HTTP task can run. A hangup after this line revokes speech and any *new* write authority, but cannot honestly
        // retract an operation that may already be at the gateway. Surface it as pending if this wait is cancelled;
        // the idempotent outbox/reconcile path will finish it exactly once or retain it for retry.
        if Task.isCancelled {
            return resultAfterCancelledConfirmedWait()
        }
        for await state in viewModel.$state.values {
            switch state {
            case .sent:                 return .posted
            case .pending(let message): return .pending(message)
            case .blockedByPendingSession(let sessionId):
                return .refused("a confirmed write is already queued for session \(sessionId)")
            case .refused(let message): return .refused(message)
            case .composing:            return .refused("write returned to composing without posting")
            case .sending, .confirming: continue   // transient — keep awaiting the terminal state
            }
        }
        if Task.isCancelled {
            return resultAfterCancelledConfirmedWait()
        }
        return .refused("write state stream ended before a terminal result")
    }

    private func resultAfterCancelledConfirmedWait() -> DialWriteResult {
        switch viewModel.state {
        case .sent:
            return .posted
        case .pending(let message):
            return .pending(message)
        case .blockedByPendingSession(let sessionId):
            return .refused("a confirmed write is already queued for session \(sessionId)")
        case .refused(let message):
            return .refused(message)
        case .sending, .confirming:
            return .pending("The confirmed write is secured in the device outbox and will finish or reconcile.")
        case .composing:
            return .refused("write returned to composing without posting")
        }
    }
}
