import SwiftUI
import PocketContracts

/// App shell (Atlas). The end-to-end state machine + lane feature views plug in here as they land.
/// For Sunday watchability, every screen ships a #Preview wired to the canonical fixture so the Xcode
/// canvas renders live on `git pull` + open — no simulator run required to see progress.
@main
struct SentiPocketApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Placeholder root until Pulse's PocketUI lands. Loads the canonical PocketBundle and shows the headline
/// + grounded claims + evidence count — proving the contract + fixture decode end-to-end on-device.
struct RootView: View {
    private let bundle: PocketBundle? = FixtureLoader.canonicalBundle()

    var body: some View {
        NavigationStack {
            if let b = bundle {
                List {
                    Section("Senti is calling") {
                        Text(b.summary.headline).font(.headline)
                        Text("checkpoint \(b.checkpointId) · seq \(b.sequenceStart)–\(b.sequenceEnd)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(b.summary.perAgent, id: \.agentId) { agent in
                        Section(agent.agentId) {
                            ForEach(agent.claims) { claim in
                                HStack(alignment: .top) {
                                    Text(badge(claim.kind)).font(.caption2)
                                    Text(claim.text).font(.subheadline)
                                }
                            }
                        }
                    }
                    Section("Contracts") {
                        Text("PocketContracts v\(PocketContracts.version) · \(b.evidence.count) evidence refs")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("Senti Pocket")
            } else {
                ContentUnavailableView("No bundle", systemImage: "bolt.slash",
                    description: Text("canonical_checkpoint.json failed to load — check Resources bundling."))
            }
        }
    }

    private func badge(_ kind: ClaimKind) -> String {
        switch kind {
        case .fact: return "[FACT]"
        case .inference: return "[INFER]"
        case .recommendation: return "[REC]"
        }
    }
}

#Preview("Root — canonical fixture") {
    RootView()
}
