import SwiftUI

// MARK: - App shell (Atlas, V4 §85) — the BARE TabView structure + a screen-INJECTION seam. This layer defines NO
// presentation: no copy, no view-models, no fallbacks, no badges. Pulse owns every visible screen + the row/content
// view-models + the factory off Relay's repository snapshot, and INJECTS the designed Sessions, Pocket, and Activity
// screens via `@ViewBuilder` (not blank slots). Tab set + IA (3 tabs; account/settings as a sheet, NOT a 4th tab)
// per north-star #239314(B).

enum PocketTab: Hashable { case sessions, pocket, activity }

struct AppShell<Sessions: View, Pocket: View, Activity: View>: View {
    @Binding private var tab: PocketTab
    private let sessions: Sessions
    private let pocket: Pocket
    private let activity: Activity

    /// Feature owners inject designed screens here; the shell only composes them into the tab structure.
    init(
        selection: Binding<PocketTab>,
        @ViewBuilder sessions: () -> Sessions,
        @ViewBuilder pocket: () -> Pocket,
        @ViewBuilder activity: () -> Activity
    ) {
        _tab = selection
        self.sessions = sessions()
        self.pocket = pocket()
        self.activity = activity()
    }

    var body: some View {
        TabView(selection: $tab) {
            sessions
                .tabItem { Label("Sessions", systemImage: "rectangle.stack") }
                .tag(PocketTab.sessions)

            pocket
                .tabItem { Label("Pocket", systemImage: "phone.fill") }
                .tag(PocketTab.pocket)

            activity
                .tabItem { Label("Activity", systemImage: "waveform.path.ecg") }
                .tag(PocketTab.activity)
        }
    }
}

// AppShell is INJECTION-ONLY: there is deliberately no zero-argument initializer.

#if DEBUG
private struct AppShellPreview: View {
    @State private var selection: PocketTab = .pocket

    var body: some View {
        AppShell(
            selection: $selection,
            sessions: { List { Text("Session · room A"); Text("Session · room B") } },
            pocket: { RootView() },
            activity: { List { Text("Activity · event 1"); Text("Activity · event 2") } }
        )
    }
}

#Preview("App shell (injection)") {
    AppShellPreview()
}
#endif
