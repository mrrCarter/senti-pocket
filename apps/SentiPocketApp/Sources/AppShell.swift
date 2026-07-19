import SwiftUI
import PocketContracts   // Atlas's SessionRow projection over Relay's SessionWire DTOs

// MARK: - App shell (Atlas) — STRUCTURE ONLY. Pulse owns the look, the design tokens, the final tab set, and every
// screen (PR #11/#13 north-star). This file is the bare TabView container + the fail-closed boundary; it carries NO
// palette and NO presentational placeholders (Pulse HOLD #238728). Pulse's redesigned screens replace each tab's
// content; the Pocket tab currently hosts the working fail-closed verified-briefing scaffold (RootView) until the
// redesigned briefing lands. Nothing here is presented as the final v1 look.
//
// The [Sessions] tab now renders Atlas's typed projection (SessionRow) over the merged SessionWire DTOs (warden
// step 1, #239244) — STRUCTURE ONLY, to prove the wire-through and give Pulse a slot. It is EMPTY in the running app
// until Relay's step-2 gated, membership-authorized fetch supplies rows: there is NO live fetch on this surface yet.

/// The tab set is Pulse's call (incl. whether "You" exists). This is a minimal placeholder set pending Pulse's north-star.
enum PocketTab: Hashable { case sessions, pocket, activity }

struct AppShell: View {
    @State private var tab: PocketTab = .pocket
    /// Live rows arrive via Relay's step-2 gated fetch; empty until then (decode-only surface, no live fetch).
    let sessionRows: [SessionRow]

    init(sessionRows: [SessionRow] = []) { self.sessionRows = sessionRows }

    var body: some View {
        TabView(selection: $tab) {
            SessionsList(rows: sessionRows)
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

/// STRUCTURE ONLY — renders Atlas's `SessionRow` projection so the wire-through is proven; Pulse's designed
/// SessionsScreen replaces the visual. No palette, no design tokens. Empty until Relay's gated fetch supplies rows.
private struct SessionsList: View {
    let rows: [SessionRow]
    var body: some View {
        NavigationStack {
            Group {
                if rows.isEmpty {
                    Text("Sessions appear here once you're signed in")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(rows) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.displayTitle)
                            if let sub = row.subtitle {
                                Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Sessions")
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

#if DEBUG
extension AppShell {
    /// Preview-only rows, decoded exactly like real wire data (NOT shown in the running app — the live Sessions tab
    /// stays empty until Relay's gated fetch). Demonstrates the SessionRow projection + title fallback rendering.
    static var previewRows: [SessionRow] {
        let json = """
        [{"sessionId":"954233b7-1822-42bc-9cfe-1eb95eb0357a","status":"active","archiveStatus":"active",
          "visibility":"private","membershipRole":"owner","title":"AUTH canary","summaryText":"canary cleared · 41 events",
          "summaryGeneratedAt":null,"summaryModel":null,"agentCount":2,"eventCount":41,"totalCostUsd":1.2,
          "createdAt":null,"lastActivityAt":"2026-07-18T10:36:34Z","expiresAt":null,"killedAt":null,
          "templateName":null,"codebasePath":null,"s3ArchivePath":null},
         {"sessionId":"6cf7e861-546a-4b9f-b937-39182a5bd395","status":"active","archiveStatus":"active",
          "visibility":"private","membershipRole":"contributor","title":null,"summaryText":"senti pocket mobile app build",
          "summaryGeneratedAt":null,"summaryModel":null,"agentCount":5,"eventCount":239,"totalCostUsd":8.4,
          "createdAt":null,"lastActivityAt":"2026-07-19T09:31:00.123456+00:00","expiresAt":null,"killedAt":null,
          "templateName":null,"codebasePath":null,"s3ArchivePath":null}]
        """
        return ((try? JSONDecoder().decode([SessionSummary].self, from: Data(json.utf8))) ?? []).map(SessionRow.init)
    }
}

#Preview("Sessions — populated (preview only)") {
    AppShell(sessionRows: AppShell.previewRows)
}
#endif
