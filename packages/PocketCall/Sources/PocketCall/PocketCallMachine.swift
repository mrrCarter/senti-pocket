import Foundation
import PocketContracts

/// The deterministic end-to-end call flow (Atlas-owned). Pure `reduce(state, event) -> state` — the UI (Pulse)
/// renders `state`, the lanes emit `event`s. The SAFETY INVARIANT is encoded HERE, not just in the UI:
///   `.executing` is reachable ONLY from `.awaitingConfirmation` via `.confirmed`, and ONLY when the exact
///   proposal `isValidForConfirmation()` (requiresConfirmation + hash matches + bounded). There is NO other
///   edge into `.executing`. So "it cannot post what you didn't confirm" holds even if a screen misbehaves.
public enum PocketCallState: Equatable, Sendable {
    case idle
    case incoming(PocketBundle)                              // "Senti is calling"
    case briefing(PocketBundle, BriefingPlan)               // narrating (Echo speaks; barge-in interrupts)
    case conversing(PocketBundle, answers: [QuestionAnswer]) // barge-in Q&A over cached evidence
    case awaitingConfirmation(PocketBundle, ActionProposal)  // proposal preview + read-back; awaiting EXPLICIT confirm
    case executing(PocketBundle, ActionProposal)             // governed writeback in flight
    case completed(ActionReceipt)                            // receipt (posted / pendingConnectivity / failed)
    case dismissed
}

public enum PocketCallEvent: Sendable {
    case bundleArrived(PocketBundle)
    case answered(BriefingPlan)          // user answered the call -> start the briefing
    case interrupted                     // barge-in during briefing -> go to Q&A
    case briefingCompleted               // briefing finished naturally -> Q&A
    case questionAnswered(QuestionAnswer)// a local Q&A turn (stays in conversing)
    case proposalDrafted(ActionProposal) // dictated instruction -> typed proposal preview
    case confirmed                       // the human EXPLICITLY confirmed the exact proposal
    case cancelled                       // the human rejected the proposal -> back to Q&A
    case executed(ActionReceipt)         // writeback returned a receipt (posted/pending/failed)
    case dismiss                         // end the call from anywhere
}

public enum PocketCall {
    /// Pure, total transition. Unrecognized (state,event) pairs are no-ops (return the same state) — the flow
    /// never lands in an undefined place, and no event can shortcut into `.executing`.
    public static func reduce(_ state: PocketCallState, _ event: PocketCallEvent) -> PocketCallState {
        // `.dismiss` always ends the call (except once completed, where the receipt is the terminal UI).
        if case .dismiss = event {
            if case .completed = state { return state }
            return .dismissed
        }

        switch (state, event) {
        case let (.idle, .bundleArrived(bundle)):
            return .incoming(bundle)

        case let (.incoming(bundle), .answered(plan)):
            return .briefing(bundle, plan)

        case let (.briefing(bundle, _), .interrupted),
             let (.briefing(bundle, _), .briefingCompleted):
            return .conversing(bundle, answers: [])

        case let (.conversing(bundle, answers), .questionAnswered(qa)):
            return .conversing(bundle, answers: answers + [qa])

        case let (.conversing(bundle, _), .proposalDrafted(proposal)):
            return .awaitingConfirmation(bundle, proposal)

        // SAFETY-CRITICAL edge: confirm -> execute ONLY if the exact proposal is valid-for-confirmation.
        case let (.awaitingConfirmation(bundle, proposal), .confirmed):
            return proposal.isValidForConfirmation()
                ? .executing(bundle, proposal)
                : .awaitingConfirmation(bundle, proposal)   // invalid proposal: refuse to advance (fail-safe)

        case let (.awaitingConfirmation(bundle, _), .cancelled):
            return .conversing(bundle, answers: [])

        case let (.executing(_, _), .executed(receipt)):
            return .completed(receipt)

        default:
            return state   // no-op: undefined transition (incl. any attempt to skip confirmation)
        }
    }

    /// Convenience: fold a sequence of events from an initial state. Deterministic.
    public static func run(_ initial: PocketCallState = .idle, _ events: [PocketCallEvent]) -> PocketCallState {
        events.reduce(initial, reduce)
    }
}
