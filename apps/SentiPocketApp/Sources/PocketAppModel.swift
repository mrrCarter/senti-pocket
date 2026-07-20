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
        case answer
        case proposal(ProposalReadBackAttempt)
    }

    private struct ActiveSpeech {
        let utteranceID: ObjectIdentifier
        let purpose: SpeechPurpose
    }

    private let ledger = ProposalConfirmationLedger()
    private let synthesizer = AVSpeechSynthesizer()
    private let speechRecognizer = OnDeviceSpeechRecognizer()
    private var activeSpeech: ActiveSpeech?
    private var speechStartTask: Task<Void, Error>?
    private var speechFinishTask: Task<Void, Never>?
    private var activeRecognitionID: UUID?
    private var recognizedQuestionAnswer: QuestionAnswer?
    private var pushToTalkIsActive = false
    private var completedPushToTalkCycles = 0
    /// Persisted across every showConversation re-render (Pulse Listen-only contract #2). listenOnly disables mic input.
    private var conversationInteractionMode: ConversationInteractionMode = .interactive

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
            guard matchesInboxCheckpoint(context, verifiedBundle: verifiedBundle) else {
                failClosed("Checkpoint identity changed before it could be opened.")
                return
            }
            stopActiveSpeech(message: "Read-back stopped before navigation.")
            resetConversation()
            showIncoming(verifiedBundle)

        case .answer(let context), .callSenti(let context):
            guard matchesIncomingCheckpoint(context, verifiedBundle: verifiedBundle) else {
                failClosed("Checkpoint identity changed before the briefing began.")
                return
            }
            stopActiveSpeech(message: "Read-back stopped before the briefing began.")
            resetConversation()
            conversationInteractionMode = .interactive
            guard showConversation(verifiedBundle, includesCachedAnswer: false, voiceState: .speaking(segmentId: nil)) else {
                return
            }
            speakBriefing()

        case .listenToBriefing(let context):
            // Pulse Listen-only contract #1: validate incoming checkpoint, enter a listenOnly speaking conversation,
            // then AVSpeech the briefing. No mic, no proposal/write — the view hides Interrupt/PTT/proposal.
            guard matchesIncomingCheckpoint(context, verifiedBundle: verifiedBundle) else {
                failClosed("Checkpoint identity changed before the briefing began.")
                return
            }
            stopActiveSpeech(message: "Read-back stopped before the briefing began.")
            resetConversation()
            conversationInteractionMode = .listenOnly
            guard showConversation(verifiedBundle, includesCachedAnswer: false, voiceState: .speaking(segmentId: nil)) else {
                return
            }
            speakBriefing()

        case .listenLater(let context):
            guard matchesIncomingCheckpoint(context, verifiedBundle: verifiedBundle) else {
                failClosed("Checkpoint identity changed before Listen Later was saved.")
                return
            }
            stopActiveSpeech(message: "Read-back stopped before completion.")
            resetConversation()
            showInbox(verifiedBundle, attention: .listenLater)

        case .snooze(let context, let option):
            guard matchesIncomingCheckpoint(context, verifiedBundle: verifiedBundle) else {
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
            guard conversationInteractionMode.allowsVoiceInput else { return }   // listen-only: no barge-in (Stop handles stopping)
            stopActiveSpeech(message: "Read-back interrupted before completion.")
            _ = showConversation(
                verifiedBundle,
                includesCachedAnswer: completedPushToTalkCycles > 0,
                voiceState: .interrupted
            )

        case .pushToTalkBegan(let context):
            guard matchesCurrentConversation(context, verifiedBundle: verifiedBundle),
                  conversationInteractionMode.allowsVoiceInput,
                  !pushToTalkIsActive else { return }
            stopActiveSpeech(message: "Read-back interrupted before completion.")
            pushToTalkIsActive = true
            let recognitionID = UUID()
            activeRecognitionID = recognitionID
            _ = showConversation(
                verifiedBundle,
                includesCachedAnswer: completedPushToTalkCycles > 0,
                voiceState: .listening,
                isPushToTalkActive: true
            )
            let startTask = Task { @MainActor [speechRecognizer] in
                try await speechRecognizer.start()
            }
            speechStartTask = startTask
            Task { @MainActor [weak self] in
                do {
                    try await startTask.value
                } catch {
                    self?.handleRecognitionFailure(error, recognitionID: recognitionID)
                }
            }

        case .pushToTalkEnded(let context):
            guard matchesCurrentConversation(context, verifiedBundle: verifiedBundle),
                  conversationInteractionMode.allowsVoiceInput,
                  pushToTalkIsActive,
                  let recognitionID = activeRecognitionID else { return }
            pushToTalkIsActive = false
            _ = showConversation(
                verifiedBundle,
                includesCachedAnswer: completedPushToTalkCycles > 0,
                voiceState: .thinking
            )
            let startTask = speechStartTask
            speechFinishTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await startTask?.value
                    guard self.activeRecognitionID == recognitionID else { return }
                    let transcript = try await self.speechRecognizer.stop()
                    self.completeRecognition(transcript, recognitionID: recognitionID)
                } catch {
                    self.handleRecognitionFailure(error, recognitionID: recognitionID)
                }
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
            guard matchesCurrentConversation(context, verifiedBundle: verifiedBundle) else { return }
            stopActiveSpeech(message: "Read-back stopped before completion.")
            resetConversation()
            showIncoming(verifiedBundle)

        case .openEvidence(let selection):
            guard matchesCurrentEvidenceSelection(selection, verifiedBundle: verifiedBundle) else {
                failClosed("Evidence no longer belongs to the active verified checkpoint.")
                return
            }
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

    private func matchesInboxCheckpoint(
        _ context: CheckpointContext,
        verifiedBundle: VerifiedBundle
    ) -> Bool {
        guard matches(context, verifiedBundle: verifiedBundle),
              case .inbox(let inbox) = state.destination else { return false }
        let expectedIntegrity = BundleIntegrityState(verifiedBundle: verifiedBundle)
        return inbox.items.contains {
            $0.bundle == verifiedBundle.bundle && $0.integrity == expectedIntegrity
        }
    }

    private func matchesIncomingCheckpoint(
        _ context: CheckpointContext,
        verifiedBundle: VerifiedBundle
    ) -> Bool {
        guard matches(context, verifiedBundle: verifiedBundle),
              case .incoming(let incoming) = state.destination else { return false }
        return incoming.bundle == verifiedBundle.bundle
            && incoming.integrity == BundleIntegrityState(verifiedBundle: verifiedBundle)
    }

    private func matchesCurrentConversation(
        _ context: CheckpointContext,
        verifiedBundle: VerifiedBundle
    ) -> Bool {
        guard matches(context, verifiedBundle: verifiedBundle),
              case .conversation(let conversation) = state.destination else { return false }
        return conversation.bundle == verifiedBundle.bundle && conversation.integrity.kind == .verified
    }

    private func matchesCurrentEvidenceSelection(
        _ selection: PresentedEvidenceSelection,
        verifiedBundle: VerifiedBundle
    ) -> Bool {
        guard case .conversation(let conversation) = state.destination,
              conversation.bundle == verifiedBundle.bundle,
              conversation.integrity == BundleIntegrityState(verifiedBundle: verifiedBundle) else {
            return false
        }

        let citedEvidenceIDs = Set(
            conversation.briefingPlan.segments.flatMap(\.evidenceIds)
                + conversation.transcript.flatMap { entry in
                    if case .questionAnswer(let answer) = entry { return answer.citations }
                    return []
                }
        )
        guard citedEvidenceIDs.contains(selection.evidenceId) else { return false }
        return verifiedBundle.bundle.evidence.contains { evidence in
            PresentedEvidenceSelection(evidence: evidence, verifiedBundle: verifiedBundle) == selection
        }
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
        guard let canonicalConversation = PocketUIDemoFixtures.conversationState(
            verifiedBundle: verifiedBundle,
            includesCachedAnswer: false
        ) else {
            failClosed("The verified checkpoint does not support the canonical offline demo flow.")
            return false
        }
        var transcript = canonicalConversation.briefingPlan.segments.map(ConversationEntry.briefing)
        if conversationInteractionMode.allowsVoiceInput {
            // Mic-transcription notice is honest only when the mic is live; listen-only shows mic-off copy in the view.
            transcript.append(.notice(ConversationNotice(
                id: "on-device-speech-cached-answer",
                text: "Microphone transcription runs on this device. Answers are matched against cached evidence; no live Gemma or network model is running."
            )))
        }
        if includesCachedAnswer, let recognizedQuestionAnswer {
            transcript.append(.questionAnswer(recognizedQuestionAnswer))
        }
        let conversation = ConversationState(
            verifiedBundle: verifiedBundle,
            briefingPlan: canonicalConversation.briefingPlan,
            transcript: transcript,
            voiceState: voiceState,
            isPushToTalkActive: isPushToTalkActive,
            interactionMode: conversationInteractionMode
        )
        let preservesConversationPresentation: Bool
        if case .conversation = state.destination {
            preservesConversationPresentation = true
        } else {
            preservesConversationPresentation = false
        }
        state = PocketUIState(
            destination: .conversation(conversation),
            connectivity: offlineConnectivity,
            presentedEvidence: preservesConversationPresentation ? state.presentedEvidence : nil,
            alertMessage: preservesConversationPresentation ? state.alertMessage : nil
        )
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

    private func speakAnswer(_ answer: String) {
        let utterance = AVSpeechUtterance(string: answer)
        activeSpeech = ActiveSpeech(
            utteranceID: ObjectIdentifier(utterance),
            purpose: .answer
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
        cancelRecognition()
        pushToTalkIsActive = false
        completedPushToTalkCycles = 0
        recognizedQuestionAnswer = nil
        conversationInteractionMode = .interactive
    }

    private func failClosed(_ message: String) {
        cancelRecognition()
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

        case .answer:
            guard let verifiedBundle,
                  case .conversation = state.destination else { return }
            _ = showConversation(
                verifiedBundle,
                includesCachedAnswer: true,
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
        case .answer:
            guard let verifiedBundle,
                  case .conversation = state.destination else { return }
            _ = showConversation(
                verifiedBundle,
                includesCachedAnswer: true,
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

    private func completeRecognition(_ transcript: String, recognitionID: UUID) {
        guard activeRecognitionID == recognitionID,
              let verifiedBundle,
              case .conversation = state.destination else { return }
        activeRecognitionID = nil
        speechStartTask = nil
        speechFinishTask = nil

        if completedPushToTalkCycles == 0 {
            let answer = cachedAnswer(for: transcript, verifiedBundle: verifiedBundle)
            recognizedQuestionAnswer = answer
            completedPushToTalkCycles = 1
            guard showConversation(
                verifiedBundle,
                includesCachedAnswer: true,
                voiceState: .speaking(segmentId: nil)
            ) else { return }
            speakAnswer(answer.answer)
            return
        }

        guard matchesCanonicalDecision(transcript) else {
            _ = showConversation(
                verifiedBundle,
                includesCachedAnswer: true,
                voiceState: .error(
                    message: "Decision heard, but it did not match ‘rotate the token and do not deploy.’ No proposal was created."
                )
            )
            return
        }

        completedPushToTalkCycles = 2
        showProposal(verifiedBundle)
    }

    private func handleRecognitionFailure(_ error: Error, recognitionID: UUID) {
        guard activeRecognitionID == recognitionID else { return }
        activeRecognitionID = nil
        pushToTalkIsActive = false
        speechStartTask?.cancel()
        speechStartTask = nil
        speechFinishTask?.cancel()
        speechFinishTask = nil
        speechRecognizer.cancel()

        guard let verifiedBundle,
              case .conversation = state.destination else { return }
        _ = showConversation(
            verifiedBundle,
            includesCachedAnswer: completedPushToTalkCycles > 0,
            voiceState: .error(message: error.localizedDescription)
        )
    }

    private func cancelRecognition() {
        activeRecognitionID = nil
        speechStartTask?.cancel()
        speechStartTask = nil
        speechFinishTask?.cancel()
        speechFinishTask = nil
        speechRecognizer.cancel()
    }

    private func cachedAnswer(
        for question: String,
        verifiedBundle: VerifiedBundle
    ) -> QuestionAnswer {
        let normalized = question.lowercased()
        let isCanonicalQuestion = normalized.contains("token")
            && (normalized.contains("parser") || normalized.contains("fixed"))
        return QuestionAnswer(
            id: "speech-question-1",
            checkpointId: verifiedBundle.bundle.checkpointId,
            question: question,
            answer: isCanonicalQuestion
                ? PocketFixtures.questionAnswer.answer
                : "I do not have cached evidence that answers that question.",
            citations: isCanonicalQuestion ? PocketFixtures.questionAnswer.citations : [],
            answeredOffline: true,
            createdAt: Date()
        )
    }

    private func matchesCanonicalDecision(_ transcript: String) -> Bool {
        let normalized = transcript
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
        let requestsRotation = normalized.contains("rotate") && normalized.contains("token")
        let blocksDeployment = normalized.contains("do not deploy")
            || normalized.contains("don't deploy")
            || normalized.contains("no deploy")
        return requestsRotation && blocksDeployment
    }
}

extension PocketAppModel: AVSpeechSynthesizerDelegate {
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
