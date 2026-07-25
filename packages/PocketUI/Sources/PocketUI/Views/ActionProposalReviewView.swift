#if canImport(SwiftUI)
import SwiftUI
import PocketContracts

public struct ActionProposalReviewView: View {
    private enum FocusTarget: Hashable {
        case readBackStatus
        case confirmationStatus
    }

    private let state: ActionProposalReviewState
    private let connectivity: PocketConnectivity
    private let send: (PocketUIIntent) -> Void

    // Visual double-activation guard. The shared ledger is authoritative; this key keeps the button visibly
    // disabled while the coordinator publishes its submitting state.
    @State private var locallyConsumedProposalKey: String?
    @AccessibilityFocusState private var focusedStatus: FocusTarget?

    public init(
        state: ActionProposalReviewState,
        connectivity: PocketConnectivity,
        send: @escaping (PocketUIIntent) -> Void
    ) {
        self.state = state
        self.connectivity = connectivity
        self.send = send
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            content(currentDate: timeline.date)
        }
    }

    private func content(currentDate: Date) -> some View {
        let gate = state.confirmationGate
        let proposal = gate.proposal
        let authorizationIsCurrent = gate.validation.matches(proposal, at: currentDate)

        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ConnectivityBanner(connectivity: connectivity)
                safetyHeader
                validationBanner(gate: gate, currentDate: currentDate)
                    .accessibilityFocused($focusedStatus, equals: .confirmationStatus)
                exactTargetCard(proposal: proposal)
                exactMessageCard(proposal: proposal)
                readBackCard(gate: gate, currentDate: currentDate)
                    .accessibilityFocused($focusedStatus, equals: .readBackStatus)
                confirmationActions(gate: gate, currentDate: currentDate)
            }
            .padding(18)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Confirm action")
        .navigationBarBackButtonHidden(true)
        .accessibilityIdentifier(PocketAccessibilityID.proposalScreen)
        .pocketCanvas()
        .onChange(of: proposalKey(proposal)) { _ in
            locallyConsumedProposalKey = nil
            focusedStatus = nil
        }
        .onChange(of: gate.readBack) { readBack in
            switch readBack {
            case .completed, .failed:
                focusedStatus = .readBackStatus
            case .notStarted, .speaking:
                break
            }
        }
        .onChange(of: gate.phase) { phase in
            switch phase {
            case .submitting, .consumed, .invalidated:
                focusedStatus = .confirmationStatus
            case .awaitingReadBack, .readingBack, .ready:
                break
            }
        }
        .onChange(of: authorizationIsCurrent) { isCurrent in
            if !isCurrent {
                focusedStatus = .confirmationStatus
            }
        }
    }

    private var safetyHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Review the exact action", systemImage: "lock.shield.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(PocketPalette.accent)
            Text("Nothing is sent until the full target and message are read back and you explicitly confirm.")
                .font(.body)
                .foregroundStyle(PocketPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func validationBanner(gate: ProposalConfirmationGate, currentDate: Date) -> some View {
        switch gate.phase {
        case .invalidated(let reason):
            statusMessage(
                icon: "exclamationmark.shield.fill",
                title: "Confirmation unavailable",
                detail: reason,
                color: PocketPalette.danger
            )
            .accessibilityIdentifier(PocketAccessibilityID.proposalValidationError)

        case .consumed, .submitting:
            statusMessage(
                icon: "lock.fill",
                title: "Confirmation already used",
                detail: "This single-use confirmation cannot be activated again.",
                color: PocketPalette.warning
            )

        default:
            if !gate.validation.matches(gate.proposal, at: currentDate) {
                statusMessage(
                    icon: "clock.badge.exclamationmark.fill",
                    title: "Confirmation expired",
                    detail: "Request a fresh proposal authorization and complete the exact read-back again.",
                    color: PocketPalette.danger
                )
                .accessibilityIdentifier(PocketAccessibilityID.proposalValidationError)
            } else {
                EmptyView()
            }
        }
    }

    private func exactTargetCard(proposal: ActionProposal) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Exact target")
                .font(.headline)

            exactField(
                label: "Action kind",
                value: proposal.kind.rawValue,
                accessibilityId: PocketAccessibilityID.proposalKind,
                monospaced: false
            )
            exactField(
                label: "Target session",
                value: proposal.targetSessionId,
                accessibilityId: PocketAccessibilityID.proposalTargetSession
            )
            exactField(
                label: "Target message sequence",
                value: String(proposal.targetSequence),
                accessibilityId: PocketAccessibilityID.proposalTargetSequence
            )
        }
        .pocketCard()
    }

    private func exactMessageCard(proposal: ActionProposal) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Full message text")
                .font(.headline)
            Text(verbatim: proposal.renderedPreview)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(PocketPalette.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(PocketPalette.separator.opacity(0.72), lineWidth: 0.5)
                }
                .accessibilityIdentifier(PocketAccessibilityID.proposalMessage)
                .accessibilityLabel("Full message text")
                .accessibilityValue(proposal.renderedPreview)

            Text("Displayed verbatim. Mentions, symbols, whitespace, and line breaks are not interpreted as instructions.")
                .font(.caption)
                .foregroundStyle(PocketPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .pocketCard()
    }

    private func readBackCard(gate: ProposalConfirmationGate, currentDate: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(systemName: readBackIcon(gate.readBack))
                    .foregroundStyle(readBackColor(gate.readBack))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(readBackTitle(gate.readBack))
                        .font(.headline)
                    Text(readBackDetail(gate.readBack))
                        .font(.caption)
                        .foregroundStyle(PocketPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button {
                send(.requestProposalReadBack(ProposalReadBackPayload(proposal: gate.proposal)))
            } label: {
                Label("Read exact action aloud", systemImage: "speaker.wave.2.fill")
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(PocketPalette.listening)
            .disabled(!canRequestReadBack(gate: gate, currentDate: currentDate))
            .accessibilityIdentifier(PocketAccessibilityID.proposalReadBack)
            .accessibilityHint("Reads the action kind, full session, sequence, and full message")
        }
        .pocketCard()
    }

    private func confirmationActions(gate: ProposalConfirmationGate, currentDate: Date) -> some View {
        VStack(spacing: 12) {
            Button {
                let key = proposalKey(gate.proposal)
                guard locallyConsumedProposalKey != key,
                      let intent = gate.consume(currentProposal: gate.proposal, at: Date()) else { return }
                locallyConsumedProposalKey = key
                send(.confirmProposal(intent))
            } label: {
                Label(
                    confirmButtonTitle,
                    systemImage: connectivity.requiresQueuedWrite
                        ? "tray.and.arrow.down.fill"
                        : "paperplane.fill"
                )
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.borderedProminent)
            .tint(PocketPalette.accent)
            .disabled(
                !gate.canConfirm(currentProposal: gate.proposal, at: currentDate)
                    || locallyConsumedProposalKey == proposalKey(gate.proposal)
            )
            .accessibilityIdentifier(PocketAccessibilityID.proposalConfirm)
            .accessibilityHint(confirmAccessibilityHint)

            Button(role: .cancel) {
                send(.cancelProposal(proposalId: gate.proposal.id))
            } label: {
                Text("Cancel — do not send")
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier(PocketAccessibilityID.proposalCancel)

            if connectivity.requiresQueuedWrite {
                Label(
                    "Confirming queues PENDING_CONNECTIVITY. It is not sent until a fresh governed write succeeds.",
                    systemImage: "wifi.slash"
                )
                .font(.caption)
                .foregroundStyle(PocketPalette.warning)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func exactField(
        label: String,
        value: String,
        accessibilityId: String,
        monospaced: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(PocketPalette.textSecondary)
            Text(verbatim: value)
                .font(monospaced ? .body.monospaced() : .body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(value)
        .accessibilityIdentifier(accessibilityId)
    }

    private func statusMessage(
        icon: String,
        title: String,
        detail: String,
        color: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(PocketPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    private func canRequestReadBack(gate: ProposalConfirmationGate, currentDate: Date) -> Bool {
        guard gate.validation.matches(gate.proposal, at: currentDate), gate.proposal.requiresConfirmation else {
            return false
        }
        switch gate.phase {
        case .awaitingReadBack, .ready:
            return true
        case .readingBack, .submitting, .consumed, .invalidated:
            return false
        }
    }

    private var confirmButtonTitle: String {
        connectivity.requiresQueuedWrite ? "Confirm and queue" : "Confirm exact action"
    }

    private var confirmAccessibilityHint: String {
        connectivity.requiresQueuedWrite
            ? "Consumes this confirmation once and queues it as pending connectivity, not sent"
            : "Consumes this confirmation once and requests governed posting"
    }

    private func proposalKey(_ proposal: ActionProposal) -> String {
        "\(proposal.id):\(proposal.proposalHash)"
    }

    private func readBackIcon(_ readBack: ProposalReadBackState) -> String {
        switch readBack {
        case .notStarted: return "speaker.wave.2"
        case .speaking: return "waveform.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func readBackColor(_ readBack: ProposalReadBackState) -> Color {
        switch readBack {
        case .notStarted, .speaking: return PocketPalette.listening
        case .completed: return PocketPalette.accent
        case .failed: return PocketPalette.danger
        }
    }

    private func readBackTitle(_ readBack: ProposalReadBackState) -> String {
        switch readBack {
        case .notStarted: return "Read-back required"
        case .speaking: return "Reading the exact action"
        case .completed: return "Exact read-back completed"
        case .failed: return "Read-back failed"
        }
    }

    private func readBackDetail(_ readBack: ProposalReadBackState) -> String {
        switch readBack {
        case .notStarted:
            return "Confirm remains unavailable until this exact target and full message finish playing."
        case .speaking:
            return "Listen for the action kind, target session, target sequence, and full message."
        case .completed:
            return "The completed read-back is bound to this proposal hash. Any change invalidates it."
        case .failed(let message):
            return message
        }
    }
}
#endif
