#if canImport(SwiftUI)
import SwiftUI

enum PocketPalette {
    static let canvas = Color(red: 0.035, green: 0.055, blue: 0.095)
    static let raised = Color(red: 0.075, green: 0.105, blue: 0.165)
    static let accent = Color(red: 0.21, green: 0.82, blue: 0.72)
    static let listening = Color(red: 0.38, green: 0.64, blue: 1.0)
    static let warning = Color(red: 1.0, green: 0.73, blue: 0.23)
    static let danger = Color(red: 1.0, green: 0.35, blue: 0.38)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.72)
}

struct PocketCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(PocketPalette.raised, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            }
    }
}

extension View {
    func pocketCard() -> some View {
        modifier(PocketCardModifier())
    }

    func pocketCanvas() -> some View {
        background(PocketPalette.canvas.ignoresSafeArea())
            .preferredColorScheme(.dark)
    }
}
#endif
