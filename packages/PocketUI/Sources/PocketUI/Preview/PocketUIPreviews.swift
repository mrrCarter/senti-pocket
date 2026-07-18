#if DEBUG && canImport(SwiftUI)
import Foundation
import SwiftUI
import PocketContracts

private enum CanonicalPreviewFixture {
    static let bundle: PocketBundle? = {
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
        return decoded
    }()

    static let unverified = BundleIntegrityState.unverified(
        reason: "Canonical fixture is explicitly unsigned."
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

private struct CanonicalBundlePreview<Content: View>: View {
    private let content: (PocketBundle) -> Content

    init(@ViewBuilder content: @escaping (PocketBundle) -> Content) {
        self.content = content
    }

    var body: some View {
        if let bundle = CanonicalPreviewFixture.bundle {
            content(bundle)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "doc.badge.ellipsis")
                    .font(.largeTitle)
                Text("Canonical v0.1.8 preview fixture unavailable")
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
    CanonicalBundlePreview { bundle in
        NavigationStack {
            CheckpointInboxView(
                state: CheckpointInboxState(items: [
                    CheckpointInboxItem(
                        bundle: bundle,
                        attention: .unheard,
                        cachedForOffline: true,
                        integrity: CanonicalPreviewFixture.unverified
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
    CanonicalBundlePreview { bundle in
        PocketRootView(
            state: PocketUIState(
                destination: .inbox(CheckpointInboxState(items: [
                    CheckpointInboxItem(
                        bundle: bundle,
                        attention: .unheard,
                        cachedForOffline: true,
                        integrity: CanonicalPreviewFixture.unverified
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
    CanonicalBundlePreview { bundle in
        NavigationStack {
            IncomingBriefingView(
                state: IncomingBriefingState(
                    bundle: bundle,
                    sessionDisplayName: "Senti Pocket build room",
                    integrity: CanonicalPreviewFixture.unverified
                ),
                connectivity: .online,
                send: { _ in }
            )
        }
    }
}

@available(iOS 17.0, macOS 14.0, *)
#Preview("Incoming call — integrity blocked") {
    CanonicalBundlePreview { bundle in
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
#Preview("Conversation — unsigned fixture blocked") {
    CanonicalBundlePreview { bundle in
        NavigationStack {
            ConversationView(
                state: ConversationState(
                    bundle: bundle,
                    integrity: CanonicalPreviewFixture.unverified,
                    briefingPlan: PocketFixtures.briefingPlan,
                    transcript: PocketFixtures.briefingPlan.segments.map(ConversationEntry.briefing)
                        + [.questionAnswer(PocketFixtures.questionAnswer)],
                    voiceState: .speaking(segmentId: "b2"),
                    isPushToTalkActive: false
                ),
                connectivity: .offline(cachedAt: bundle.createdAt),
                send: { _ in }
            )
        }
    }
}

@available(iOS 17.0, macOS 14.0, *)
#Preview("Conversation — integrity blocked") {
    CanonicalBundlePreview { bundle in
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
    CanonicalBundlePreview { bundle in
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
    CanonicalBundlePreview { bundle in
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
    VStack(spacing: 12) {
        IntegrityBadge(integrity: CanonicalPreviewFixture.unverified)
        IntegrityBadge(integrity: .invalid(reason: "Signature mismatch"))
        ClaimBadge(kind: .fact)
        ClaimBadge(kind: .inference)
        ClaimBadge(kind: .recommendation)
    }
    .padding()
    .background(PocketPalette.canvas)
}
#endif
