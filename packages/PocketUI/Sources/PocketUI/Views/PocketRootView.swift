#if canImport(SwiftUI)
import SwiftUI
import PocketContracts

public struct PocketRootView: View {
    private let state: PocketUIState
    private let send: (PocketUIIntent) -> Void

    public init(state: PocketUIState, send: @escaping (PocketUIIntent) -> Void) {
        self.state = state
        self.send = send
    }

    public var body: some View {
        NavigationStack {
            destination
        }
        .sheet(
            item: Binding<EvidenceRef?>(
                get: { state.resolvedPresentedEvidence },
                set: { _ in }
            ),
            onDismiss: { send(.dismissEvidence) }
        ) { evidence in
            EvidenceDetailView(evidence: evidence)
        }
        .alert(
            "Senti Pocket",
            isPresented: Binding(
                get: { state.alertMessage != nil },
                set: { isPresented in
                    if !isPresented { send(.dismissAlert) }
                }
            )
        ) {
            Button("OK") {}
        } message: {
            Text(state.alertMessage ?? "")
        }
        .tint(PocketPalette.accent)
    }

    @ViewBuilder
    private var destination: some View {
        switch state.destination {
        case .inbox(let inboxState):
            CheckpointInboxView(
                state: inboxState,
                connectivity: state.connectivity,
                send: send
            )

        case .incoming(let incomingState):
            IncomingBriefingView(
                state: incomingState,
                connectivity: state.connectivity,
                send: send
            )

        case .conversation(let conversationState):
            ConversationView(
                state: conversationState,
                connectivity: state.connectivity,
                send: send
            )

        case .proposal(let proposalState):
            ActionProposalReviewView(
                state: proposalState,
                connectivity: state.connectivity,
                send: send
            )

        case .receipt(let receiptState):
            ActionReceiptView(state: receiptState) {
                send(.dismissReceipt)
            }
        }
    }
}
#endif
