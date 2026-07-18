#if canImport(SwiftUI)
import SwiftUI
import PocketContracts

struct ClaimBadge: View {
    let kind: ClaimKind

    var body: some View {
        Text(label)
            .font(.caption2.weight(.heavy))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
            .accessibilityLabel(accessibilityLabel)
    }

    private var label: String {
        switch kind {
        case .fact: return "FACT"
        case .inference: return "INFERENCE"
        case .recommendation: return "RECOMMENDATION"
        }
    }

    private var accessibilityLabel: String {
        switch kind {
        case .fact: return "Claim type, fact"
        case .inference: return "Claim type, inference"
        case .recommendation: return "Claim type, recommendation"
        }
    }

    private var color: Color {
        switch kind {
        case .fact: return PocketPalette.accent
        case .inference: return PocketPalette.listening
        case .recommendation: return PocketPalette.warning
        }
    }
}
#endif
