import SwiftUI

// MARK: - App shell (Atlas, V4 §85) — the BARE TabView structure + a screen-INJECTION seam. This layer defines NO
// presentation: no copy, no view-models, no fallbacks, no badges. Pulse owns every visible screen + the row/content
// view-models + the factory off Relay's repository snapshot, and INJECTS her designed screens into the Sessions and
// Activity tabs via `@ViewBuilder` (not blank slots). The Pocket tab hosts the working fail-closed verified-briefing
// scaffold (RootView) until Pulse's redesigned briefing lands. Tab set + IA (3 tabs; account/settings as a sheet,
// NOT a 4th tab) per north-star #239314(B).

enum PocketTab: Hashable { case sessions, pocket, activity }

struct AppShell<Sessions: View, Activity: View>: View {
    @State private var tab: PocketTab = .pocket
    private let sessions: Sessions
    private let activity: Activity

    /// Pulse injects her designed screens here; the shell only composes them into the tab structure.
    init(@ViewBuilder sessions: () -> Sessions, @ViewBuilder activity: () -> Activity) {
        self.sessions = sessions()
        self.activity = activity()
    }

    var body: some View {
        TabView(selection: $tab) {
            sessions
                .tabItem { Label("Sessions", systemImage: "rectangle.stack") }
                .tag(PocketTab.sessions)

            RootView()   // fail-closed verified-briefing scaffold; Pulse's redesigned briefing replaces this
                .tabItem { Label("Pocket", systemImage: "phone.fill") }
                .tag(PocketTab.pocket)

            activity
                .tabItem { Label("Activity", systemImage: "waveform.path.ecg") }
                .tag(PocketTab.activity)
        }
    }
}

// Default composition: empty Sessions/Activity until Pulse injects her screens. No Atlas presentation/copy.
extension AppShell where Sessions == EmptyView, Activity == EmptyView {
    init() { self.init(sessions: { EmptyView() }, activity: { EmptyView() }) }
}

#Preview("App shell (structure)") {
    AppShell()
}
