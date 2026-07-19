#if DEBUG
import AVFoundation
import Combine
import Foundation
import PocketCall
import PocketContracts
import PocketUI

/// Fixture-only app coordinator. It owns presentation transitions and audio completion, but never performs a write.
/// The only receipt it can request is the DEBUG seam's unsigned `pendingConnectivity` state.
@MainActor
final class PocketAppModel: NSObject, ObservableObject {
    @Published private(set) var state: PocketUIState
    let verifiedBundle: VerifiedBundle?

    private enum SpeechPurpose {
        case briefing
        case proposal(ProposalReadBackAttempt)
    }

    private struct ActiveSpeech {
        let utteranceID: ObjectIdentifier
        let purpose: SpeechPurpose
    }

    private let ledger = ProposalConfirmationLedger()
    private let synthesizer = AVSpeechSynthesizer()
    private var activeSpeech: ActiveSpeech?
    private var pushToTalkIsActive = false
    private var completedPushToTalkCycles = 0

    override init() {
        let verified = FixtureLoader.canonicalBundle().flatMap(VerifiedBundle.verify)
        verifiedBundle = verified
        state = Self.initialState(verified)
        super.init()
        synthesizer.delegate = self
    }

    func send(_ intent: PocketUIIntent) {
        guard let verifiedBundle else { return }

        switch intent {
        case .selectCheckpoint(let context):
            guard matches(context, verifiedBundle: verifiedBundle) else {
                failClosed("Checkpoint identity changed before it could be opened.")
                return
            }
            resetConversation()
            showIncoming(verifiedBundle)

        case .answer(let context), .callSenti(let context):
            guard matches(context, verifiedBundle: verifiedBundle) else {
                failClosed("Checkpoint identity changed before the briefing began.")
                return
            }
            resetConversation()
            guard showConversation(verifiedBundle, includesCachedAnswer: false, voiceState: .speaking(segmentId: nil)) else {
                return
            }
            speakBriefing()

        case .listenLater(let context):
            guard matches(context, verifiedBundle: verifiedBundle) else {
                failClosed("Checkpoint identity changed before Listen Later was saved.")
                return
            }
            stopActiveSpeech(message: "Read-back stopped before completion.")
            resetConversation()
            showInbox(verifiedBundle, attention: .listenLater)

        case .snooze(let context, let option):
            guard matches(context, verifiedBundle: verifiedBundle) else {
                failClosed("Checkpoint identity changed before Snooze was saved.")
                return
            }
            stopActiveSpeech(message: "Read-back stopped before completion.")
            resetConversation()
            showInbox(verifiedBundle, attention: .snoozed(until: Date().addingTimeInterval(option.duration)))

        case .interrupt(let context):
            guard matchesCurrentConversation(context, verifiedBundle: verifiedBundle) else {
                failClosed("The active briefing no longer matches this checkpoint.")
                return
            }
            stopActiveSpeech(message: "Read-back interrupted before completion.")
            _ = showConversation(
                verifiedBundle,
                includesCachedAnswer: completedPushToTalkCycles > 0,
                voiceState: .interrupted
            )

        case .pushToTalkBegan(let context):
            guard matchesCurrentConversation(context, verifiedBundle: verifiedBundle),
                  !pushToTalkIsActive else { return }
            stopActiveSpeech(message: "Read-back interrupted before completion.")
            pushToTalkIsActive = true
            _ = showConversation(
                verifiedBundle,
                includesCachedAnswer: completedPushToTalkCycles > 0,
                voiceState: .listening,
                isPushToTalkActive: true
            )

        case .pushToTalkEnded(let context):
            guard matchesCurrentConversation(context, verifiedBundle: verifiedBundle),
                  pushToTalkIsActive else { return }
            pushToTalkIsActive = false
            completedPushToTalkCycles += 1
            if completedPushToTalkCycles == 1 {
                _ = showConversation(verifiedBundle, includesCachedAnswer: true, voiceState: .idle)
            } else {
                showProposal(verifiedBundle)
            }

        case .stopNarration(let context):
            guard matchesCurrentConversation(context, verifiedBundle: verifiedBundle) else { return }
            stopActiveSpeech(message: "Read-back stopped before completion.")
            _ = showConversation(
                verifiedBundle,
                includesCachedAnswer: completedPushToTalkCycles > 0,
                voiceState: .idle
            )

        case .replayBriefing(let context):
            guard matchesCurrentConversation(context, verifiedBundle: verifiedBundle) else {
                failClosed("The cached briefing no longer matches this checkpoint.")
                return
            }
            stopActiveSpeech(message: "Read-back stopped before completion.")
            guard showConversation(
                verifiedBundle,
                includesCachedAnswer: completedPushToTalkCycles > 0,
                voiceState: .speaking(segmentId: nil)
            ) else { return }
            speakBriefing()

        case .endConversation(let context):
            guard matches(context, verifiedBundle: verifiedBundle) else { return }
            stopActiveSpeech(message: "Read-back stopped before completion.")
            resetConversation()
            showIncoming(verifiedBundle)

        case .openEvidence(let selection):
            state = PocketUIState(
                destination: state.destination,
                connectivity: state.connectivity,
                presentedEvidence: selection,
                alertMessage: state.alertMessage
            )

        case .dismissEvidence:
            state = PocketUIState(
                destination: state.destination,
                connectivity: state.connectivity,
                alertMessage: state.alertMessage
            )

        case .requestProposalReadBack(let payload):
            beginProposalReadBack(payload)

        case .confirmProposal(let confirmation):
            guard case .proposal(let proposalState) = state.destination,
                  confirmation.proposal == proposalState.confirmationGate.proposal,
                  confirmation.proposalId == proposalState.confirmationGate.proposal.id,
                  confirmation.proposalHash == proposalState.confirmationGate.proposal.proposalHash,
                  let receiptState = PocketUIDemoFixtures.pendingReceiptState(
                    for: confirmation,
                    confirmedAt: Date()
                  ) else {
                failClosed("Confirmation no longer matches the displayed action.")
                return
            }
            activeSpeech = nil
            state = PocketUIState(destination: .receipt(receiptState), connectivity: offlineConnectivity)

        case .cancelProposal(let proposalID):
            guard case .proposal(let proposalState) = state.destination,
                  proposalState.confirmationGate.proposal.id == proposalID else { return }
            var gate = proposalState.confirmationGate
            if case .proposal(let attempt)? = activeSpeech?.purpose {
                gate.failReadBack(attempt, message: "Read-back cancelled before completion.")
            }
            gate.invalidate(reason: "Proposal cancelled. A new decision requires a new authorization.")
            activeSpeech = nil
            synthesizer.stopSpeaking(at: .immediate)
            resetConversation()
            showIncoming(verifiedBundle)

        case .dismissReceipt:
            stopActiveSpeech(message: "Read-back stopped before completion.")
            resetConversation()
            showIncoming(verifiedBundle)

        case .dismissAlert:
            state = PocketUIState(
                destination: state.destination,
                connectivity: state.connectivity,
                presentedEvidence: state.presentedEvidence
            )
        }
    }

    private static func initialState(_ verifiedBundle: VerifiedBundle?) -> PocketUIState {
        guard let verifiedBundle else {
            return PocketUIState(
                destination: .inbox(CheckpointInboxState(items: [])),
                connectivity: .offline(cachedAt: nil),
                alertMessage: "The cached checkpoint could not be verified."
            )
        }
        return PocketUIState(
            destination: .incoming(PocketUIDemoFixtures.incomingState(verifiedBundle: verifiedBundle)),
            connectivity: .offline(cachedAt: verifiedBundle.bundle.createdAt)
        )
    }

    private var offlineConnectivity: PocketConnectivity {
        .offline(cachedAt: verifiedBundle?.bundle.createdAt)
    }

    private func matches(_ context: CheckpointContext, verifiedBundle: VerifiedBundle) -> Bool {
        context == CheckpointContext(bundle: verifiedBundle.bundle)
    }

    private func matchesCurrentConversation(
        _ context: CheckpointContext,
        verifiedBundle: VerifiedBundle
    ) -> Bool {
        guard matches(context, verifiedBundle: verifiedBundle),
              case .conversation(let conversation) = state.destination else { return false }
        return conversation.bundle == verifiedBundle.bundle && conversation.integrity.kind == .verified
    }

    private func showInbox(_ verifiedBundle: VerifiedBundle, attention: CheckpointAttention) {
        let item = CheckpointInboxItem(
            verifiedBundle: verifiedBundle,
            attention: attention,
            cachedForOffline: true
        )
        state = PocketUIState(
            destination: .inbox(CheckpointInboxState(items: [item])),
            connectivity: offlineConnectivity
        )
    }

    private func showIncoming(_ verifiedBundle: VerifiedBundle) {
        state = PocketUIState(
            destination: .incoming(PocketUIDemoFixtures.incomingState(verifiedBundle: verifiedBundle)),
            connectivity: offlineConnectivity
        )
    }

    @discardableResult
    private func showConversation(
        _ verifiedBundle: VerifiedBundle,
        includesCachedAnswer: Bool,
        voiceState: VoiceConversationState,
        isPushToTalkActive: Bool = false
    ) -> Bool {
        guard let conversation = PocketUIDemoFixtures.conversationState(
            verifiedBundle: verifiedBundle,
            includesCachedAnswer: includesCachedAnswer,
            voiceState: voiceState,
            isPushToTalkActive: isPushToTalkActive
        ) else {
            failClosed("The verified checkpoint does not support the canonical offline demo flow.")
            return false
        }
        state = PocketUIState(destination: .conversation(conversation), connectivity: offlineConnectivity)
        return true
    }

    private func showProposal(_ verifiedBundle: VerifiedBundle) {
        stopActiveSpeech(message: "Read-back stopped before completion.")
        guard let proposal = PocketUIDemoFixtures.proposalReviewState(
            verifiedBundle: verifiedBundle,
            ledger: ledger,
            currentDate: Date()
        ) else {
            failClosed("The cached decision could not be authorized for exact confirmation.")
            return
        }
        state = PocketUIState(destination: .proposal(proposal), connectivity: offlineConnectivity)
    }

    private func beginProposalReadBack(_ payload: ProposalReadBackPayload) {
        guard case .proposal(let proposalState) = state.destination,
              payload == ProposalReadBackPayload(proposal: proposalState.confirmationGate.proposal),
              activeSpeech == nil else {
            failClosed("Read-back request no longer matches the displayed action.")
            return
        }

        var gate = proposalState.confirmationGate
        guard let attempt = gate.beginReadBack(for: gate.proposal, at: Date()),
              attempt.payload == payload else {
            failClosed("The proposal changed or expired before read-back could begin.")
            return
        }

        state = PocketUIState(
            destination: .proposal(ActionProposalReviewState(confirmationGate: gate)),
            connectivity: offlineConnectivity
        )
        let utterance = AVSpeechUtterance(string: attempt.payload.spokenText)
        activeSpeech = ActiveSpeech(
            utteranceID: ObjectIdentifier(utterance),
            purpose: .proposal(attempt)
        )
        synthesizer.speak(utterance)
    }

    private func speakBriefing() {
        let exactBriefing = PocketFixtures.briefingPlan.segments.map(\.text).joined(separator: " ")
        let utterance = AVSpeechUtterance(string: exactBriefing)
        activeSpeech = ActiveSpeech(
            utteranceID: ObjectIdentifier(utterance),
            purpose: .briefing
        )
        synthesizer.speak(utterance)
    }

    private func stopActiveSpeech(message: String) {
        guard let activeSpeech else { return }
        if case .proposal(let attempt) = activeSpeech.purpose,
           case .proposal(let proposalState) = state.destination {
            var gate = proposalState.confirmationGate
            gate.failReadBack(attempt, message: message)
            state = PocketUIState(
                destination: .proposal(ActionProposalReviewState(confirmationGate: gate)),
                connectivity: offlineConnectivity
            )
        }
        self.activeSpeech = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func resetConversation() {
        pushToTalkIsActive = false
        completedPushToTalkCycles = 0
    }

    private func failClosed(_ message: String) {
        stopActiveSpeech(message: message)
        guard let verifiedBundle else {
            state = Self.initialState(nil)
            return
        }
        state = PocketUIState(
            destination: .incoming(PocketUIDemoFixtures.incomingState(verifiedBundle: verifiedBundle)),
            connectivity: offlineConnectivity,
            alertMessage: message
        )
    }

    private func completeSpeech(utteranceID: ObjectIdentifier) {
        guard let activeSpeech, activeSpeech.utteranceID == utteranceID else { return }
        self.activeSpeech = nil

        switch activeSpeech.purpose {
        case .briefing:
            guard let verifiedBundle,
                  case .conversation = state.destination else { return }
            _ = showConversation(
                verifiedBundle,
                includesCachedAnswer: completedPushToTalkCycles > 0,
                voiceState: .idle
            )

        case .proposal(let attempt):
            guard case .proposal(let proposalState) = state.destination else { return }
            var gate = proposalState.confirmationGate
            guard gate.completeReadBack(attempt, for: gate.proposal, at: Date()) else {
                failClosed("Proposal changed or authorization expired during read-back.")
                return
            }
            state = PocketUIState(
                destination: .proposal(ActionProposalReviewState(confirmationGate: gate)),
                connectivity: offlineConnectivity
            )
        }
    }

    private func cancelSpeech(utteranceID: ObjectIdentifier) {
        guard let activeSpeech, activeSpeech.utteranceID == utteranceID else { return }
        self.activeSpeech = nil
        switch activeSpeech.purpose {
        case .briefing:
            guard let verifiedBundle,
                  case .conversation = state.destination else { return }
            _ = showConversation(
                verifiedBundle,
                includesCachedAnswer: completedPushToTalkCycles > 0,
                voiceState: .interrupted
            )
        case .proposal(let attempt):
            guard case .proposal(let proposalState) = state.destination else { return }
            var gate = proposalState.confirmationGate
            gate.failReadBack(attempt, message: "Audio read-back was cancelled. Try again.")
            state = PocketUIState(
                destination: .proposal(ActionProposalReviewState(confirmationGate: gate)),
                connectivity: offlineConnectivity
            )
        }
    }
}

extension PocketAppModel: @preconcurrency AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.completeSpeech(utteranceID: utteranceID) }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.cancelSpeech(utteranceID: utteranceID) }
    }
}
#endif
