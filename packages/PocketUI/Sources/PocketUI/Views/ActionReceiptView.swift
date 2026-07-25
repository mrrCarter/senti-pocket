#if canImport(SwiftUI)
import SwiftUI
import PocketContracts

public struct ActionReceiptView: View {
    private let state: ReceiptScreenState
    private let onDone: () -> Void
    @AccessibilityFocusState private var receiptStatusFocused: Bool

    public init(state: ReceiptScreenState, onDone: @escaping () -> Void) {
        self.state = state
        self.onDone = onDone
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ReceiptStatusCard(presentation: state.presentation)
                    .accessibilityFocused($receiptStatusFocused)

                VStack(alignment: .leading, spacing: 14) {
                    Text("Receipt binding")
                        .font(.headline)
                    receiptField("Proposal", value: state.receipt.proposalId)
                    receiptField("Target session", value: state.receipt.targetSessionId)
                    receiptField("Confirmed proposal hash", value: state.receipt.confirmedProposalHash)
                    if let signingKeyId = state.presentation.verifiedSigningKeyId {
                        receiptField("Signing key", value: signingKeyId)
                    }
                    if let result = state.presentation.verifiedResult {
                        verifiedResultFields(result)
                    }
                }
                .pocketCard()

                Button(action: onDone) {
                    Text("Done")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .tint(PocketPalette.accent)
                .accessibilityIdentifier(PocketAccessibilityID.receiptDone)
            }
            .padding(20)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Action receipt")
        .navigationBarBackButtonHidden(true)
        .accessibilityIdentifier(PocketAccessibilityID.receiptScreen)
        .pocketCanvas()
        .onAppear {
            receiptStatusFocused = true
        }
    }

    @ViewBuilder
    private func verifiedResultFields(_ result: ActionResultRef) -> some View {
        switch result {
        case .action(let actionId, let targetSequenceId, let targetCursor):
            receiptField(
                "Result type",
                value: "Thread action",
                accessibilityId: PocketAccessibilityID.receiptResultKind,
                monospaced: false
            )
            receiptField(
                "Action ID",
                value: actionId,
                accessibilityId: PocketAccessibilityID.receiptActionId
            )
            receiptField(
                "Thread target sequence",
                value: String(targetSequenceId),
                accessibilityId: PocketAccessibilityID.receiptTargetSequence
            )
            if let targetCursor {
                receiptField(
                    "Thread target cursor",
                    value: targetCursor,
                    accessibilityId: PocketAccessibilityID.receiptTargetCursor
                )
            }

        case .sequence(let sequenceId):
            receiptField(
                "Result type",
                value: "Sequence",
                accessibilityId: PocketAccessibilityID.receiptResultKind,
                monospaced: false
            )
            receiptField(
                "Resulting sequence",
                value: String(sequenceId),
                accessibilityId: PocketAccessibilityID.receiptResultingSequence
            )
        }
    }

    private func receiptField(
        _ label: String,
        value: String,
        accessibilityId: String? = nil,
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
        .accessibilityIdentifier(accessibilityId ?? "pocket.receipt.field.\(label)")
    }
}

struct ReceiptStatusCard: View {
    let presentation: ReceiptPresentation

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title.weight(.semibold))
                .foregroundStyle(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(color)
                Text(detail)
                    .font(.body)
                    .foregroundStyle(PocketPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .pocketCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(detail)
        .accessibilityIdentifier(PocketAccessibilityID.receiptStatus)
    }

    private var title: String {
        presentation.title
    }

    private var detail: String {
        presentation.detail
    }

    private var icon: String {
        switch presentation.status {
        case .pendingConnectivity: return "clock.badge.exclamationmark.fill"
        case .posted: return "checkmark.shield.fill"
        case .failed: return "xmark.octagon.fill"
        case .invalid: return "exclamationmark.shield.fill"
        }
    }

    private var color: Color {
        switch presentation.status {
        case .pendingConnectivity: return PocketPalette.warning
        case .posted: return PocketPalette.verified
        case .failed, .invalid: return PocketPalette.danger
        }
    }
}
#endif
