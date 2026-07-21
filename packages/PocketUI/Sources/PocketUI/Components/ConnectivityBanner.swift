#if canImport(SwiftUI)
import SwiftUI

public struct ConnectivityBanner: View {
    private let connectivity: PocketConnectivity

    public init(connectivity: PocketConnectivity) {
        self.connectivity = connectivity
    }

    public var body: some View {
        switch connectivity {
        case .online:
            EmptyView()

        case .offline(let cachedAt):
            statusBanner(
                icon: "wifi.slash",
                title: "Offline · Cached evidence",
                detail: offlineDetail(cachedAt: cachedAt),
                color: PocketPalette.warning
            )
            .accessibilityIdentifier(PocketAccessibilityID.offlineBanner)

        case .reconnecting:
            statusBanner(
                icon: "arrow.triangle.2.circlepath",
                title: "Reconnecting",
                detail: "Briefings stay available. Pending actions are not sent yet.",
                color: PocketPalette.listening
            )
            .accessibilityIdentifier(PocketAccessibilityID.reconnectingBanner)
        }
    }

    private func offlineDetail(cachedAt: Date?) -> String {
        guard let cachedAt else {
            return "Briefing and Q&A stay available. Confirmed actions queue as pending — not sent."
        }
        return "Cached \(cachedAt.formatted(date: .abbreviated, time: .shortened)). "
            + "Confirmed actions queue as pending — not sent."
    }

    private func statusBanner(
        icon: String,
        title: String,
        detail: String,
        color: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(PocketPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(color.opacity(0.32), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
    }
}
#endif
