import SwiftUI

// MARK: - App shell (Atlas) — STRUCTURE ONLY. Pulse owns the look, the design tokens, the final tab set, and every
// screen (PR #11/#13 north-star). This file is the bare TabView container + the fail-closed boundary; it carries NO
// palette and NO presentational placeholders (Pulse HOLD #238728). Pulse's redesigned screens replace each tab's
// content; the Pocket tab currently hosts the working fail-closed verified-briefing scaffold (RootView) until the
// redesigned briefing lands. Nothing here is presented as the final v1 look.

/// The tab set is Pulse's call (incl. whether "You" exists). This is a minimal placeholder set pending Pulse's north-star.
enum PocketTab: Hashable { case sessions, pocket, activity }

struct AppShell: View {
    @State private var tab: PocketTab = .pocket

    var body: some View {
        TabView(selection: $tab) {
            ScaffoldTab(label: "Sessions")
                .tabItem { Label("Sessions", systemImage: "rectangle.stack") }
                .tag(PocketTab.sessions)

            RootView()   // fail-closed verified-briefing scaffold; Pulse's redesigned briefing replaces this
                .tabItem { Label("Pocket", systemImage: "phone.fill") }
                .tag(PocketTab.pocket)

            ScaffoldTab(label: "Activity")
                .tabItem { Label("Activity", systemImage: "waveform.path.ecg") }
                .tag(PocketTab.activity)
        }
    }
}

/// Deliberately unstyled structural placeholder — Pulse's designed screen replaces it. No palette, no marketing copy.
private struct ScaffoldTab: View {
    let label: String
    var body: some View {
        NavigationStack {
            Text("\(label) — Pulse screen slots here")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(label)
        }
    }
}

#Preview("App shell (structure)") {
    AppShell()
}
