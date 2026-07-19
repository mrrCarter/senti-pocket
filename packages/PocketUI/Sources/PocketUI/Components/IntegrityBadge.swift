#if canImport(SwiftUI)
import SwiftUI

struct IntegrityBadge: View {
    let integrity: BundleIntegrityState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(label)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(PocketPalette.textPrimary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.13), in: Capsule())
        .accessibilityLabel(accessibilityLabel)
    }

    private var icon: String {
        switch integrity.kind {
        case .verified: return "checkmark.shield.fill"
        case .unverified: return "questionmark.diamond.fill"
        case .invalid: return "exclamationmark.shield.fill"
        }
    }

    private var label: String {
        switch integrity.kind {
        case .verified: return "Verified bundle"
        case .unverified: return "Unverified bundle"
        case .invalid: return "Integrity error"
        }
    }

    private var color: Color {
        switch integrity.kind {
        case .verified: return PocketPalette.verified
        case .unverified: return PocketPalette.warning
        case .invalid: return PocketPalette.danger
        }
    }

    private var accessibilityLabel: String {
        switch integrity.kind {
        case .verified:
            return "Verified bundle, signing key \(integrity.signingKeyId ?? "unknown")"
        case .unverified:
            return "Unverified bundle, \(integrity.failureReason ?? "verification unavailable")"
        case .invalid:
            return "Bundle integrity error, \(integrity.failureReason ?? "verification failed")"
        }
    }
}
#endif
