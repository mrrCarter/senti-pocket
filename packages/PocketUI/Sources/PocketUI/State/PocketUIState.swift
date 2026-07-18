import Foundation
import PocketContracts
import PocketCall

/// A bundle-bound evidence selection. It can only be minted from a `VerifiedBundle`; the raw `EvidenceRef` is
/// resolved again from the current verified conversation before presentation, so navigation or integrity changes
/// dismiss stale evidence rather than retaining caller-supplied content.
public struct PresentedEvidenceSelection: Equatable, Identifiable, Sendable {
    public var id: String { "\(checkpointId).\(evidenceId)" }

    public let checkpointId: String
    public let sessionId: String
    public let evidenceId: String
    private let sourceBundle: VerifiedBundle
    private let evidence: EvidenceRef

    public init?(evidence: EvidenceRef, verifiedBundle: VerifiedBundle) {
        let bundle = verifiedBundle.bundle
        guard bundle.evidence.contains(evidence),
              bundle.evidence.filter({ $0.id == evidence.id }).count == 1 else { return nil }
        self.checkpointId = bundle.checkpointId
        self.sessionId = bundle.sessionId
        self.evidenceId = evidence.id
        self.sourceBundle = verifiedBundle
        self.evidence = evidence
    }

    fileprivate func resolve(in verifiedBundle: VerifiedBundle) -> EvidenceRef? {
        let bundle = verifiedBundle.bundle
        guard verifiedBundle == sourceBundle,
              bundle.evidence.filter({ $0.id == evidenceId }).count == 1,
              bundle.evidence.contains(evidence) else { return nil }
        return evidence
    }
}

public struct PocketUIState: Equatable, Sendable {
    public let destination: PocketDestination
    public let connectivity: PocketConnectivity
    public let presentedEvidence: PresentedEvidenceSelection?
    public let alertMessage: String?

    public init(
        destination: PocketDestination,
        connectivity: PocketConnectivity,
        presentedEvidence: PresentedEvidenceSelection? = nil,
        alertMessage: String? = nil
    ) {
        self.destination = destination
        self.connectivity = connectivity
        self.presentedEvidence = presentedEvidence
        self.alertMessage = alertMessage
    }

    /// Resolves only against the currently displayed verified conversation. A transition to another bundle,
    /// destination, or integrity state returns nil and causes SwiftUI to dismiss the sheet.
    var resolvedPresentedEvidence: EvidenceRef? {
        guard let presentedEvidence,
              let verifiedBundle = destination.verifiedConversationBundle else { return nil }
        return presentedEvidence.resolve(in: verifiedBundle)
    }
}

public enum PocketDestination: Equatable, Sendable {
    case inbox(CheckpointInboxState)
    case incoming(IncomingBriefingState)
    case conversation(ConversationState)
    case proposal(ActionProposalReviewState)
    case receipt(ReceiptScreenState)

    fileprivate var verifiedConversationBundle: VerifiedBundle? {
        guard case .conversation(let state) = self else { return nil }
        return state.integrity.verifiedBundle(boundTo: state.bundle)
    }
}

public enum PocketConnectivity: Equatable, Sendable {
    case online
    case offline(cachedAt: Date?)
    case reconnecting

    /// Only a known-online state may be described as immediately post-capable. Reconnecting is queued.
    public var requiresQueuedWrite: Bool {
        if case .online = self { return false }
        return true
    }
}

public struct CheckpointContext: Equatable, Sendable {
    public let checkpointId: String
    public let sessionId: String
    public let sequenceStart: Int
    public let sequenceEnd: Int

    public init(
        checkpointId: String,
        sessionId: String,
        sequenceStart: Int,
        sequenceEnd: Int
    ) {
        self.checkpointId = checkpointId
        self.sessionId = sessionId
        self.sequenceStart = sequenceStart
        self.sequenceEnd = sequenceEnd
    }

    public init(bundle: PocketBundle) {
        self.init(
            checkpointId: bundle.checkpointId,
            sessionId: bundle.sessionId,
            sequenceStart: bundle.sequenceStart,
            sequenceEnd: bundle.sequenceEnd
        )
    }
}

public enum CheckpointAttention: Equatable, Sendable {
    case unheard
    case heard
    case snoozed(until: Date)
    case listenLater
}

public struct BundleIntegrityState: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case verified
        case unverified
        case invalid
    }

    private enum Status: Equatable, Sendable {
        case verified(VerifiedBundle)
        case unverified(reason: String)
        case invalid(reason: String)
    }

    private let status: Status

    /// The only production path to trusted content. `VerifiedBundle` itself is privately minted by PocketCall
    /// after gateway-signature verification; there is no caller-asserted `.verified(keyId)` label.
    public init(verifiedBundle: VerifiedBundle) {
        self.status = .verified(verifiedBundle)
    }

    public static func unverified(reason: String) -> Self {
        Self(status: .unverified(reason: reason))
    }

    public static func invalid(reason: String) -> Self {
        Self(status: .invalid(reason: reason))
    }

    private init(status: Status) {
        self.status = status
    }

    public var kind: Kind {
        switch status {
        case .verified: return .verified
        case .unverified: return .unverified
        case .invalid: return .invalid
        }
    }

    public var signingKeyId: String? {
        guard case .verified(let verifiedBundle) = status else { return nil }
        return verifiedBundle.bundle.signingKeyId
    }

    public var allowsBriefing: Bool {
        if case .verified = status { return true }
        return false
    }

    public var failureReason: String? {
        switch status {
        case .verified:
            return nil
        case .unverified(let reason), .invalid(let reason):
            return reason
        }
    }

    fileprivate func bound(to bundle: PocketBundle) -> Self {
        guard case .verified(let verifiedBundle) = status else { return self }
        guard verifiedBundle.bundle == bundle else {
            return .invalid(reason: "Verified bundle identity does not match the presented checkpoint.")
        }
        return self
    }

    fileprivate func verifiedBundle(boundTo bundle: PocketBundle) -> VerifiedBundle? {
        guard case .verified(let verifiedBundle) = status,
              verifiedBundle.bundle == bundle else { return nil }
        return verifiedBundle
    }
}

public struct CheckpointInboxItem: Equatable, Identifiable, Sendable {
    public var id: String { bundle.checkpointId }

    public let bundle: PocketBundle
    public let attention: CheckpointAttention
    public let cachedForOffline: Bool
    public let integrity: BundleIntegrityState

    public init(
        bundle: PocketBundle,
        attention: CheckpointAttention,
        cachedForOffline: Bool,
        integrity: BundleIntegrityState
    ) {
        self.bundle = bundle
        self.attention = attention
        self.cachedForOffline = cachedForOffline
        self.integrity = integrity.bound(to: bundle)
    }

    public init(
        verifiedBundle: VerifiedBundle,
        attention: CheckpointAttention,
        cachedForOffline: Bool
    ) {
        self.init(
            bundle: verifiedBundle.bundle,
            attention: attention,
            cachedForOffline: cachedForOffline,
            integrity: BundleIntegrityState(verifiedBundle: verifiedBundle)
        )
    }
}

public struct CheckpointInboxState: Equatable, Sendable {
    public let items: [CheckpointInboxItem]
    public let isLoading: Bool
    public let errorMessage: String?

    public init(
        items: [CheckpointInboxItem],
        isLoading: Bool = false,
        errorMessage: String? = nil
    ) {
        self.items = items
        self.isLoading = isLoading
        self.errorMessage = errorMessage
    }
}

public struct IncomingBriefingState: Equatable, Sendable {
    public let bundle: PocketBundle
    public let sessionDisplayName: String?
    public let integrity: BundleIntegrityState

    public init(
        bundle: PocketBundle,
        sessionDisplayName: String? = nil,
        integrity: BundleIntegrityState
    ) {
        self.bundle = bundle
        self.sessionDisplayName = sessionDisplayName
        self.integrity = integrity.bound(to: bundle)
    }

    public init(
        verifiedBundle: VerifiedBundle,
        sessionDisplayName: String? = nil
    ) {
        self.init(
            bundle: verifiedBundle.bundle,
            sessionDisplayName: sessionDisplayName,
            integrity: BundleIntegrityState(verifiedBundle: verifiedBundle)
        )
    }
}

public enum VoiceConversationState: Equatable, Sendable {
    case idle
    case speaking(segmentId: String?)
    case interrupted
    case listening
    case thinking
    case error(message: String)
}

public struct ConversationNotice: Equatable, Identifiable, Sendable {
    public let id: String
    public let text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

public enum ConversationEntry: Equatable, Identifiable, Sendable {
    case briefing(BriefingSegment)
    case questionAnswer(QuestionAnswer)
    case notice(ConversationNotice)

    public var id: String {
        switch self {
        case .briefing(let segment): return "briefing.\(segment.id)"
        case .questionAnswer(let answer): return "qa.\(answer.id)"
        case .notice(let notice): return "notice.\(notice.id)"
        }
    }
}

public struct ConversationState: Equatable, Sendable {
    public let bundle: PocketBundle
    public let integrity: BundleIntegrityState
    public let briefingPlan: BriefingPlan
    public let transcript: [ConversationEntry]
    public let voiceState: VoiceConversationState
    public let isPushToTalkActive: Bool

    public init(
        bundle: PocketBundle,
        integrity: BundleIntegrityState,
        briefingPlan: BriefingPlan,
        transcript: [ConversationEntry],
        voiceState: VoiceConversationState,
        isPushToTalkActive: Bool
    ) {
        self.bundle = bundle
        self.integrity = integrity.bound(to: bundle)
        self.briefingPlan = briefingPlan
        self.transcript = transcript
        self.voiceState = voiceState
        self.isPushToTalkActive = isPushToTalkActive
    }

    public init(
        verifiedBundle: VerifiedBundle,
        briefingPlan: BriefingPlan,
        transcript: [ConversationEntry],
        voiceState: VoiceConversationState,
        isPushToTalkActive: Bool
    ) {
        self.init(
            bundle: verifiedBundle.bundle,
            integrity: BundleIntegrityState(verifiedBundle: verifiedBundle),
            briefingPlan: briefingPlan,
            transcript: transcript,
            voiceState: voiceState,
            isPushToTalkActive: isPushToTalkActive
        )
    }

    func evidenceSelection(for evidence: EvidenceRef) -> PresentedEvidenceSelection? {
        guard let verifiedBundle = integrity.verifiedBundle(boundTo: bundle) else { return nil }
        return PresentedEvidenceSelection(evidence: evidence, verifiedBundle: verifiedBundle)
    }
}

public struct ActionProposalReviewState: Equatable, Sendable {
    public let confirmationGate: ProposalConfirmationGate

    public init(confirmationGate: ProposalConfirmationGate) {
        self.confirmationGate = confirmationGate
    }
}

public struct ReceiptScreenState: Equatable, Sendable {
    public let proposal: ActionProposal
    public let receipt: ActionReceipt
    public let presentation: ReceiptPresentation

    public init(
        proposal: ActionProposal,
        receipt: ActionReceipt,
        trustStore: ReceiptTrustStore = ReceiptTrustStore()
    ) {
        self.proposal = proposal
        self.receipt = receipt
        self.presentation = ReceiptPresentation.evaluate(
            receipt: receipt,
            proposal: proposal,
            trustStore: trustStore
        )
    }
}
