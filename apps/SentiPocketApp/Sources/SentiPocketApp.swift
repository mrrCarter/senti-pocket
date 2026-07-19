import SwiftUI
import PocketContracts
import PocketCall   // VerifiedBundle — the ONLY trusted way to hold a bundle
import PocketUI     // Pulse's polished PocketRootView + states/intents

/// App shell (Atlas base). pocket-forge hackathon demo wiring: mounts Pulse's redesigned PocketRootView and
/// drives an interactive FIXTURE tour of the full loop (incoming → conversation → confirm → receipt) so the
/// judge can tap through every redesigned screen. Fail-closed is preserved: nothing renders unless the
/// canonical bundle verifies under the pinned trusted key.
@main
struct SentiPocketApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

struct RootView: View {
    private let decoded: PocketBundle?
    private let verified: VerifiedBundle?

    init() {
        let d = FixtureLoader.canonicalBundle()
        decoded = d
        verified = d.flatMap { VerifiedBundle.verify($0) }
    }

    var body: some View {
        if let vb = verified {
            DemoFlowView(verifiedBundle: vb)
        } else if decoded == nil {
            NavigationStack {
                StatusView(title: "No bundle", systemImage: "bolt.slash",
                    message: "canonical_checkpoint.json failed to load — check Resources bundling.")
            }
        } else {
            NavigationStack {
                StatusView(title: "Bundle not verified", systemImage: "lock.trianglebadge.exclamationmark",
                    message: "The cached checkpoint is unsigned or signed by an untrusted key. Senti Pocket refuses to display, narrate, or answer from an unverified bundle — fail-closed.")
                    .navigationTitle("Fail-closed")
            }
        }
    }
}

/// Owns the redesigned flow's state + a minimal DEMO reducer over Pulse's real intents/states.
/// This is fixture-first (no live broker); the reducer just advances the destination so every polished
/// screen is reachable by tapping. The real end-to-end state machine (Atlas lane) replaces this later.
struct DemoFlowView: View {
    @StateObject private var store: PocketDemoStore
    init(verifiedBundle: VerifiedBundle) {
        _store = StateObject(wrappedValue: PocketDemoStore(verifiedBundle: verifiedBundle))
    }
    var body: some View {
        PocketRootView(state: store.state, send: { store.send($0) })
    }
}

@MainActor
final class PocketDemoStore: ObservableObject {
    @Published private(set) var state: PocketUIState
    private let vb: VerifiedBundle

    init(verifiedBundle: VerifiedBundle) {
        vb = verifiedBundle
        // DEMO START: .incoming — the "Senti is calling" ring. Tap Answer to walk the fixture loop
        // (incoming -> conversation -> End -> receipt). incoming/conversation/receipt all verified rendering.
        state = PocketUIState(destination: .incoming(Self.incoming(vb)), connectivity: .online)
    }

    func send(_ intent: PocketUIIntent) {
        switch intent {
        case .answer, .callSenti:
            state = PocketUIState(destination: .conversation(Self.conversation(vb)), connectivity: .online)
        case .endConversation, .confirmProposal:
            // Proposal/confirm screen needs the real in-module confirmation gate (ProposalAuthorizationContext
            // init is intentionally internal — external code can't forge an authorization). For the fixture
            // demo we advance conversation -> receipt directly, showing the honest "pending, not sent" receipt.
            state = PocketUIState(destination: .receipt(Self.receipt()), connectivity: .online)
        case .dismissReceipt, .listenLater, .snooze:
            state = PocketUIState(destination: .incoming(Self.incoming(vb)), connectivity: .online)
        default:
            break   // conversation-internal controls / evidence / alerts: no-op in the fixture demo
        }
    }

    private static func incoming(_ vb: VerifiedBundle) -> IncomingBriefingState {
        IncomingBriefingState(verifiedBundle: vb, sessionDisplayName: "Senti Pocket build room")
    }

    private static func conversation(_ vb: VerifiedBundle) -> ConversationState {
        ConversationState(
            verifiedBundle: vb,
            briefingPlan: PocketFixtures.briefingPlan,
            transcript: PocketFixtures.briefingPlan.segments.map(ConversationEntry.briefing)
                + [.questionAnswer(PocketFixtures.questionAnswer)],
            voiceState: .speaking(segmentId: "b2"),
            isPushToTalkActive: false
        )
    }

    private static func receipt() -> ReceiptScreenState {
        ReceiptScreenState(proposal: PocketFixtures.actionProposal, receipt: PocketFixtures.pendingReceipt)
    }
}

private struct StatusView: View {
    let title: String
    let systemImage: String
    let message: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
