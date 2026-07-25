#if DEBUG
import Foundation
import PocketCall
import PocketContracts

/// Debug-only, fixture-backed presentation states for the app-hosted demo driver.
///
/// This surface deliberately accepts an already verified bundle and never exposes the internal proposal
/// authorization adapter. It is absent from Release builds, performs no network/model/audio work, and can
/// produce only an unsigned `pendingConnectivity` receipt after a real single-use confirmation intent.
public enum PocketUIDemoFixtures {
    public static func initialState(verifiedBundle: VerifiedBundle) -> PocketUIState {
        PocketUIState(
            destination: .inbox(CheckpointInboxState(items: [
                CheckpointInboxItem(
                    verifiedBundle: verifiedBundle,
                    attention: .unheard,
                    cachedForOffline: true
                )
            ])),
            connectivity: .offline(cachedAt: verifiedBundle.bundle.createdAt)
        )
    }

    public static func incomingState(
        verifiedBundle: VerifiedBundle,
        sessionDisplayName: String = "Senti Pocket build room"
    ) -> IncomingBriefingState {
        IncomingBriefingState(
            verifiedBundle: verifiedBundle,
            sessionDisplayName: sessionDisplayName
        )
    }

    public static func conversationState(
        verifiedBundle: VerifiedBundle,
        includesCachedAnswer: Bool,
        voiceState: VoiceConversationState = .idle,
        isPushToTalkActive: Bool = false
    ) -> ConversationState? {
        guard supportsCanonicalFlow(verifiedBundle) else { return nil }

        var transcript = PocketFixtures.briefingPlan.segments.map(ConversationEntry.briefing)
        transcript.append(.notice(ConversationNotice(
            id: "fixture-replay",
            text: "Fixture replay: briefing and answers are cached. No live model or network is running."
        )))
        if includesCachedAnswer {
            transcript.append(.questionAnswer(PocketFixtures.questionAnswer))
        }

        return ConversationState(
            verifiedBundle: verifiedBundle,
            briefingPlan: PocketFixtures.briefingPlan,
            transcript: transcript,
            voiceState: voiceState,
            isPushToTalkActive: isPushToTalkActive
        )
    }

    /// Bridges the current v0.1.8 internal authorization adapter without making that adapter public.
    /// The caller receives a normal gate and must still complete the exact read-back and consume it once.
    public static func proposalReviewState(
        verifiedBundle: VerifiedBundle,
        ledger: ProposalConfirmationLedger,
        currentDate: Date
    ) -> ActionProposalReviewState? {
        let proposal = PocketFixtures.actionProposal
        guard supportsCanonicalFlow(verifiedBundle),
              proposal.isValidForConfirmation() else {
            return nil
        }

        let context = ProposalAuthorizationContext(
            id: "debug-fixture-\(verifiedBundle.bundle.checkpointId)",
            confirmationChallenge: "debug-fixture-exact-readback",
            expectedTargetSessionId: proposal.targetSessionId,
            expectedTargetSequence: proposal.targetSequence,
            oldestAllowedProposalDate: proposal.createdAt,
            evaluatedAt: currentDate,
            validUntil: currentDate.addingTimeInterval(240)
        )
        let validation = ProposalValidationState.authorize(proposal, context: context)
        guard validation.matches(proposal, at: currentDate) else { return nil }

        return ActionProposalReviewState(confirmationGate: ProposalConfirmationGate(
            proposal: proposal,
            validation: validation,
            ledger: ledger,
            currentDate: currentDate
        ))
    }

    /// An honest offline terminal for the demo. Requiring `ActionConfirmationIntent` preserves the exact
    /// read-back + single-use gate; the result is explicitly unsigned, unexecuted, and never presented as sent.
    public static func pendingReceiptState(
        for confirmation: ActionConfirmationIntent,
        confirmedAt: Date
    ) -> ReceiptScreenState? {
        let proposal = confirmation.proposal
        let receipt = ActionReceipt(
            id: "debug-pending-\(proposal.id)",
            proposalId: proposal.id,
            status: .pendingConnectivity,
            result: nil,
            targetSessionId: proposal.targetSessionId,
            confirmedByHumanAt: confirmedAt,
            confirmedProposalHash: confirmation.proposalHash,
            executedAt: nil,
            failureReason: nil,
            signature: nil,
            signingKeyId: nil
        )
        guard receipt.isStructurallyValid() else { return nil }
        return ReceiptScreenState(proposal: proposal, receipt: receipt)
    }

    private static func supportsCanonicalFlow(_ verifiedBundle: VerifiedBundle) -> Bool {
        let bundle = verifiedBundle.bundle
        return bundle.contractsVersion == PocketContracts.version
            && bundle.checkpointId == PocketFixtures.briefingPlan.checkpointId
            && bundle.sessionId == PocketFixtures.sessionId
            && bundle.sequenceEnd == PocketFixtures.actionProposal.targetSequence
            && bundle.evidence == PocketFixtures.evidence
            && Set(PocketFixtures.questionAnswer.citations).isSubset(of: Set(bundle.evidence.map(\.id)))
    }
}
#endif
