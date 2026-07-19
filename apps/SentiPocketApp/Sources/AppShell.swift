import SwiftUI

// MARK: - App shell (Atlas, V4 §85) — the BARE TabView structure ONLY. This layer defines NO presentation: no copy,
// no view-models, no fallbacks, no badges, no placeholders. Pulse owns every visible screen + the row/content
// view-models + the factory off Relay's repository snapshot; her designed screens mount into these tab slots.
// The Pocket tab currently hosts the working fail-closed verified-briefing scaffold (RootView) until Pulse's
// redesigned briefing lands. Tab set + IA (3 tabs; account/settings as a sheet, NOT a 4th tab) per north-star #239314(B).

enum PocketTab: Hashable { case sessions, pocket, activity }

struct AppShell: View {
    @State private var tab: PocketTab = .pocket

    var body: some View {
        TabView(selection: $tab) {
            // Pulse's Sessions screen mounts here (rooms / membership / cached-or-live timeline / checkpoints,
            // built by Pulse's factory off Relay's SessionRepository snapshot). No Atlas presentation.
            TabSlot()
                .tabItem { Label("Sessions", systemImage: "rectangle.stack") }
                .tag(PocketTab.sessions)

            RootView()   // fail-closed verified-briefing scaffold; Pulse's redesigned briefing replaces this
                .tabItem { Label("Pocket", systemImage: "phone.fill") }
                .tag(PocketTab.pocket)

            // Pulse's Activity screen mounts here.
            TabSlot()
                .tabItem { Label("Activity", systemImage: "waveform.path.ecg") }
                .tag(PocketTab.activity)
        }
    }
}

/// A bare structural mount point for a Pulse-owned screen. Deliberately carries NO copy or presentation (§85) — the
/// designed screen replaces it.
private struct TabSlot: View {
    var body: some View { Color.clear }
}

#Preview("App shell (structure)") {
    AppShell()
}
