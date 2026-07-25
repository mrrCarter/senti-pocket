import Foundation
import PocketContracts

public enum SnoozeOption: Hashable, CaseIterable, Sendable {
    case fiveMinutes
    case fifteenMinutes
    case oneHour

    public var duration: TimeInterval {
        switch self {
        case .fiveMinutes: return 5 * 60
        case .fifteenMinutes: return 15 * 60
        case .oneHour: return 60 * 60
        }
    }

    public var title: String {
        switch self {
        case .fiveMinutes: return "5 minutes"
        case .fifteenMinutes: return "15 minutes"
        case .oneHour: return "1 hour"
        }
    }
}

public enum PocketUIIntent: Equatable, Sendable {
    case selectCheckpoint(CheckpointContext)
    case answer(CheckpointContext)
    case listenToBriefing(CheckpointContext)
    case listenLater(CheckpointContext)
    case snooze(CheckpointContext, SnoozeOption)
    case callSenti(CheckpointContext)

    case interrupt(CheckpointContext)
    case pushToTalkBegan(CheckpointContext)
    case pushToTalkEnded(CheckpointContext)
    case stopNarration(CheckpointContext)
    case replayBriefing(CheckpointContext)
    case endConversation(CheckpointContext)

    /// Minted only from the current verified conversation; arbitrary evidence cannot become presentation state.
    case openEvidence(PresentedEvidenceSelection)
    case dismissEvidence

    /// Read-back is a request only; Atlas mints an attempt from `beginReadBack` before starting audio.
    case requestProposalReadBack(ProposalReadBackPayload)
    /// The UI can emit this only after the shared ledger atomically mints a single-use capability.
    case confirmProposal(ActionConfirmationIntent)
    case cancelProposal(proposalId: String)
    case dismissReceipt
    case dismissAlert
}
