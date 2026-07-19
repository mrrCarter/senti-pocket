#if DEBUG && canImport(SwiftUI)
import Foundation
import SwiftUI
import PocketContracts
import PocketCall

private enum CanonicalPreviewFixture {
    static let verifiedBundle: VerifiedBundle? = {
        let bundles = [Bundle.main] + Bundle.allBundles
        guard let url = bundles.compactMap({
            $0.url(forResource: "canonical_checkpoint", withExtension: "json")
        }).first,
        let data = try? Data(contentsOf: url) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(PocketBundle.self, from: data),
              decoded.contractsVersion == PocketContracts.version,
              decoded.contractsVersion == "0.1.8",
              decoded.checkpointId == "cp_954233b7_000012" else {
            return nil
        }
        return VerifiedBundle.verify(decoded)
    }()

    static let unverified = BundleIntegrityState.unverified(
        reason: "No trusted signature was supplied."
    )

    static func readyGate() -> ProposalConfirmationGate {
        let proposal = PocketFixtures.actionProposal
        let now = Date()
        let context = ProposalAuthorizationContext(
            id: "preview-authorization",
            confirmationChallenge: "preview-episode-challenge",
            expectedTargetSessionId: proposal.targetSessionId,
            expectedTargetSequence: proposal.targetSequence,
            oldestAllowedProposalDate: proposal.createdAt,
            evaluatedAt: now,
            validUntil: now.addingTimeInterval(240)
        )
        var gate = ProposalConfirmationGate(
            proposal: proposal,
            validation: .authorize(proposal, context: context),
            ledger: ProposalConfirmationLedger(),
            currentDate: now
        )
        if let attempt = gate.beginReadBack(for: proposal, at: now) {
            _ = gate.completeReadBack(attempt, for: proposal, at: now)
        }
        return gate
    }
}

private struct CanonicalVerifiedBundlePreview<Content: View>: View {
    private let content: (VerifiedBundle) -> Content

    init(@ViewBuilder content: @escaping (VerifiedBundle) -> Content) {
        self.content = content
    }

    var body: some View {
        if let verifiedBundle = CanonicalPreviewFixture.verifiedBundle {
            content(verifiedBundle)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "doc.badge.ellipsis")
                    .font(.largeTitle)
                Text("Canonical v0.1.8 preview fixture unavailable or unverified")
                    .font(.headline)
                Text("The host must bundle the v0.1.8 cp_954233b7_000012 canonical_checkpoint.json fixture.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }
}

@available(iOS 17.0, macOS 14.0, *)
#Preview("Inbox — canonical checkpoint") {
    CanonicalVerifiedBundlePreview { verifiedBundle in
        NavigationStack {
            CheckpointInboxView(
                state: CheckpointInboxState(items: [
                    CheckpointInboxItem(
                        verifiedBundle: verifiedBundle,
                        attention: .unheard,
                        cachedForOffline: true
                    )
                ]),
                connectivity: .online,
                send: { _ in }
            )
        }
    }
}

@available(iOS 17.0, macOS 14.0, *)
#Preview("Root — canonical inbox") {
    CanonicalVerifiedBundlePreview { verifiedBundle in
        PocketRootView(
            state: PocketUIState(
                destination: .inbox(CheckpointInboxState(items: [
                    CheckpointInboxItem(
                        verifiedBundle: verifiedBundle,
                        attention: .unheard,
                        cachedForOffline: true
                    )
                ])),
                connectivity: .online
            ),
            send: { _ in }
        )
    }
}

@available(iOS 17.0, macOS 14.0, *)
#Preview("Incoming call — canonical checkpoint") {
    CanonicalVerifiedBundlePreview { verifiedBundle in
        NavigationStack {
            IncomingBriefingView(
                state: IncomingBriefingState(
                    verifiedBundle: verifiedBundle,
                    sessionDisplayName: "Senti Pocket build room"
                ),
                connectivity: .online,
                send: { _ in }
            )
        }
    }
}

@available(iOS 17.0, macOS 14.0, *)
#Preview("Incoming call — integrity blocked") {
    CanonicalVerifiedBundlePreview { verifiedBundle in
        let bundle = verifiedBundle.bundle
        NavigationStack {
            IncomingBriefingView(
                state: IncomingBriefingState(
                    bundle: bundle,
                    sessionDisplayName: "Hidden until verified",
                    integrity: .invalid(reason: "Signature mismatch")
                ),
                connectivity: .online,
                send: { _ in }
            )
        }
    }
}

@available(iOS 17.0, macOS 14.0, *)
#Preview("Conversation — verified cached fixture") {
    CanonicalVerifiedBundlePreview { verifiedBundle in
        NavigationStack {
            ConversationView(
                state: ConversationState(
                    verifiedBundle: verifiedBundle,
                    briefingPlan: PocketFixtures.briefingPlan,
                    transcript: PocketFixtures.briefingPlan.segments.map(ConversationEntry.briefing)
                        + [.questionAnswer(PocketFixtures.questionAnswer)],
                    voiceState: .speaking(segmentId: "b2"),
                    isPushToTalkActive: false
                ),
                connectivity: .offline(cachedAt: verifiedBundle.bundle.createdAt),
                send: { _ in }
            )
        }
    }
}

@available(iOS 17.0, macOS 14.0, *)
#Preview("Conversation — integrity blocked") {
    CanonicalVerifiedBundlePreview { verifiedBundle in
        let bundle = verifiedBundle.bundle
        NavigationStack {
            ConversationView(
                state: ConversationState(
                    bundle: bundle,
                    integrity: .invalid(reason: "Signature mismatch"),
                    briefingPlan: PocketFixtures.briefingPlan,
                    transcript: PocketFixtures.briefingPlan.segments.map(ConversationEntry.briefing),
                    voiceState: .speaking(segmentId: "b2"),
                    isPushToTalkActive: false
                ),
                connectivity: .online,
                send: { _ in }
            )
        }
    }
}

@available(iOS 17.0, macOS 14.0, *)
#Preview("Evidence — bounded cached reference") {
    CanonicalVerifiedBundlePreview { verifiedBundle in
        let bundle = verifiedBundle.bundle
        if let evidence = bundle.evidence.first {
            EvidenceDetailView(evidence: evidence)
        }
    }
}

@available(iOS 17.0, macOS 14.0, *)
#Preview("Confirmation — exact read-back complete") {
    NavigationStack {
        ActionProposalReviewView(
            state: ActionProposalReviewState(
                confirmationGate: CanonicalPreviewFixture.readyGate()
            ),
            connectivity: .online,
            send: { _ in }
        )
    }
}

@available(iOS 17.0, macOS 14.0, *)
#Preview("Confirmation — reconnecting queues") {
    NavigationStack {
        ActionProposalReviewView(
            state: ActionProposalReviewState(
                confirmationGate: CanonicalPreviewFixture.readyGate()
            ),
            connectivity: .reconnecting,
            send: { _ in }
        )
    }
}

@available(iOS 17.0, macOS 14.0, *)
#Preview("Receipt — pending connectivity, not sent") {
    NavigationStack {
        ActionReceiptView(
            state: ReceiptScreenState(
                proposal: PocketFixtures.actionProposal,
                receipt: PocketFixtures.pendingReceipt
            ),
            onDone: {}
        )
    }
}

@available(iOS 17.0, macOS 14.0, *)
#Preview("Receipt — placeholder signature rejected") {
    NavigationStack {
        ActionReceiptView(
            state: ReceiptScreenState(
                proposal: PocketFixtures.actionProposal,
                receipt: PocketFixtures.postedReceipt
            ),
            onDone: {}
        )
    }
}

@available(iOS 17.0, macOS 14.0, *)
#Preview("Component — offline banner") {
    ConnectivityBanner(connectivity: .offline(cachedAt: PocketFixtures.ts))
        .padding()
        .background(PocketPalette.canvas)
}

@available(iOS 17.0, macOS 14.0, *)
#Preview("Component — evidence card") {
    CanonicalVerifiedBundlePreview { verifiedBundle in
        let bundle = verifiedBundle.bundle
        if let evidence = bundle.evidence.first {
            EvidenceCard(evidence: evidence, onOpen: { _ in })
                .padding()
                .background(PocketPalette.canvas)
        }
    }
}

@available(iOS 17.0, macOS 14.0, *)
#Preview("Component — push to talk") {
    PushToTalkControl(isActive: false, onBegin: {}, onEnd: {})
        .padding()
        .background(PocketPalette.canvas)
}

@available(iOS 17.0, macOS 14.0, *)
#Preview("Component — integrity states") {
    CanonicalVerifiedBundlePreview { verifiedBundle in
        VStack(spacing: 12) {
            IntegrityBadge(integrity: BundleIntegrityState(verifiedBundle: verifiedBundle))
            IntegrityBadge(integrity: CanonicalPreviewFixture.unverified)
            IntegrityBadge(integrity: .invalid(reason: "Signature mismatch"))
            ClaimBadge(kind: .fact)
            ClaimBadge(kind: .inference)
            ClaimBadge(kind: .recommendation)
        }
        .padding()
        .background(PocketPalette.canvas)
    }
}
#endif
