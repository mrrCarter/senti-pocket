#if canImport(SwiftUI)
import SwiftUI
import PocketContracts

public struct EvidenceDetailView: View {
    private let evidence: EvidenceRef
    @Environment(\.dismiss) private var dismiss

    public init(evidence: EvidenceRef) {
        self.evidence = evidence
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label("Cached evidence", systemImage: "iphone.and.arrow.forward")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PocketPalette.accent)

                    Text(verbatim: evidence.snippet)
                        .font(.title3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .pocketCard()

                    metadataRow("Agent", value: evidence.agentId)
                    metadataRow("Session", value: evidence.sessionId)
                    metadataRow("Sequence", value: String(evidence.sequence))
                    metadataRow(
                        "Captured",
                        value: evidence.ts.formatted(date: .complete, time: .standard)
                    )

                    Label(
                        "This is the bounded cached reference. Opening it never performs a live fetch.",
                        systemImage: "lock.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(PocketPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Evidence")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier(PocketAccessibilityID.evidenceDone)
                }
            }
            .pocketCanvas()
            .accessibilityIdentifier(PocketAccessibilityID.evidenceScreen)
        }
    }

    private func metadataRow(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(PocketPalette.textSecondary)
            Text(verbatim: value)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
#endif
