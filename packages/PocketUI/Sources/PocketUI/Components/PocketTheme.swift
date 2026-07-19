#if canImport(SwiftUI)
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum PocketPalette {
    static var canvas: Color {
        #if os(iOS)
        Color(uiColor: .systemGroupedBackground)
        #elseif os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color.clear
        #endif
    }

    static var raised: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemGroupedBackground)
        #elseif os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color.primary.opacity(0.06)
        #endif
    }

    static var inset: Color {
        #if os(iOS)
        Color(uiColor: .tertiarySystemGroupedBackground)
        #elseif os(macOS)
        Color(nsColor: .underPageBackgroundColor)
        #else
        Color.primary.opacity(0.04)
        #endif
    }

    static var separator: Color {
        #if os(iOS)
        Color(uiColor: .separator)
        #elseif os(macOS)
        Color(nsColor: .separatorColor)
        #else
        Color.secondary.opacity(0.28)
        #endif
    }

    // Action and conversational state colors. Green is deliberately absent:
    // it is reserved for verified cryptographic state and signed receipts.
    static let accent = Color.indigo
    static let listening = Color.blue
    static let verified = Color.green
    static let warning = Color.orange
    static let danger = Color.red

    // Epistemic categories are not trust verdicts.
    static let fact = Color.secondary
    static let inference = Color.indigo
    static let recommendation = Color.purple

    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
}

struct PocketCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(PocketPalette.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(PocketPalette.separator.opacity(0.72), lineWidth: 0.5)
            }
    }
}

extension View {
    func pocketCard() -> some View {
        modifier(PocketCardModifier())
    }

    func pocketCanvas() -> some View {
        background(PocketPalette.canvas.ignoresSafeArea())
    }
}
#endif
