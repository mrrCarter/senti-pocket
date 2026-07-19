import SwiftUI
import PocketContracts
import PocketCall   // VerifiedBundle — the ONLY trusted way to hold a bundle

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

/// Placeholder root until Pulse's PocketUI lands. FAIL-CLOSED: it decodes the cached checkpoint and then
/// requires `VerifiedBundle.verify` (trusted signingKeyId + semantic validity + ed25519 under the pinned key)
/// BEFORE showing anything. An unsigned or untrusted-key bundle renders the refusal state — Senti Pocket never
/// displays, narrates, or answers from an unverified bundle. (On forge-day, once the fixture is signed under a
/// trusted key, this same screen renders the briefing.)
struct RootView: View {
    private let decoded: PocketBundle? = FixtureLoader.canonicalBundle()
    private let verified: VerifiedBundle?

    init() { verified = FixtureLoader.canonicalBundle().flatMap { VerifiedBundle.verify($0) } }

    var body: some View {
        NavigationStack {
            if let vb = verified {
                briefing(vb.bundle)
            } else if decoded == nil {
                ContentUnavailableView("No bundle", systemImage: "bolt.slash",
                    description: Text("canonical_checkpoint.json failed to load — check Resources bundling."))
            } else {
                ContentUnavailableView("Bundle not verified", systemImage: "lock.trianglebadge.exclamationmark",
                    description: Text("The cached checkpoint is unsigned or signed by an untrusted key. Senti Pocket refuses to display, narrate, or answer from an unverified bundle — fail-closed. Sign the fixture under a trusted key (pocket-demo-app-fixture) to enable the demo."))
                    .navigationTitle("Fail-closed")
            }
        }
    }

    @ViewBuilder private func briefing(_ b: PocketBundle) -> some View {
        List {
            Section("Senti is calling") {
                Text(b.summary.headline).font(.headline)
                Text("checkpoint \(b.checkpointId) · seq \(b.sequenceStart)–\(b.sequenceEnd)")
                    .font(.caption).foregroundStyle(.secondary)
                Label("verified · \(b.signingKeyId)", systemImage: "checkmark.seal.fill")
                    .font(.caption2).foregroundStyle(.green)
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
    }

    private func badge(_ kind: ClaimKind) -> String {
        switch kind {
        case .fact: return "[FACT]"
        case .inference: return "[INFER]"
        case .recommendation: return "[REC]"
        }
    }
}

#Preview("Root — verify-gated canonical fixture") {
    RootView()
}
