#if canImport(SwiftUI)
import SwiftUI
import PocketContracts

public struct EvidenceCard: View {
    private let evidence: EvidenceRef
    private let onOpen: (EvidenceRef) -> Void

    public init(evidence: EvidenceRef, onOpen: @escaping (EvidenceRef) -> Void) {
        self.evidence = evidence
        self.onOpen = onOpen
    }

    public var body: some View {
        Button {
            onOpen(evidence)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "link.circle.fill")
                    .font(.title2)
                    .foregroundStyle(PocketPalette.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: evidence.snippet)
                        .font(.subheadline)
                        .foregroundStyle(PocketPalette.textPrimary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(evidence.agentId) · sequence \(evidence.sequence)")
                        .font(.caption)
                        .foregroundStyle(PocketPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PocketPalette.textSecondary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(12)
            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(PocketAccessibilityID.evidenceCard(evidence.id))
        .accessibilityLabel("Evidence from \(evidence.agentId), sequence \(evidence.sequence)")
        .accessibilityValue(evidence.snippet)
        .accessibilityHint("Opens the full cached evidence reference")
    }
}

struct EvidenceLinksView: View {
    let ids: [String]
    let evidence: [EvidenceRef]
    let emptyLabel: String
    let onOpen: (EvidenceRef) -> Void

    var body: some View {
        let resolution = EvidenceResolution.resolve(ids: ids, in: evidence)
        VStack(alignment: .leading, spacing: 8) {
            if ids.isEmpty {
                Label(emptyLabel, systemImage: "exclamationmark.magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(PocketPalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(resolution.resolved) { reference in
                EvidenceCard(evidence: reference, onOpen: onOpen)
            }
            ForEach(resolution.missingIds, id: \.self) { missingId in
                Label("Evidence unavailable: \(missingId)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(PocketPalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Evidence unavailable, reference \(missingId)")
            }
        }
    }
}
#endif
