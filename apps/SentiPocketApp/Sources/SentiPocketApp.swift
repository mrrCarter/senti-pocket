import SwiftUI
import PocketContracts
import PocketCall   // VerifiedBundle — the ONLY trusted way to hold a bundle
import PocketUI
import PocketReasoning   // ReasoningProvider + CachedReasoningProvider (the real coordinator's provider)

/// App shell (Atlas). The end-to-end state machine + lane feature views plug in here as they land.
/// For Sunday watchability, every screen ships a #Preview wired to the canonical fixture so the Xcode
/// canvas renders live on `git pull` + open — no simulator run required to see progress.
@main
struct SentiPocketApp: App {
    #if DEBUG
    @StateObject private var model = PocketAppModel()
    #endif
    #if canImport(CallKit) && canImport(PushKit)
    /// App-lifetime DIALS wiring (onAnswered hookup part-b + the app-seam teardown): owns the SentiCallManager (its
    /// PKPushRegistry delegate must live the whole app) + the DialCoordinator, and installs the push-receive/answer/end
    /// adapters + the governed DI seams (hydrate via the authed DialHydrationClient / makeRun via the stoppable
    /// LiveDialRun = LiveDialVoice+PhoneWriteAdapter+DialOrchestrator).
    @StateObject private var dialHost = DialHost()
    #endif
    #if !DEBUG
    /// The login GATE (Atlas, 322268 — closes the gate≠live gap): makes SentiNativeAuth LIVE. Signed-out →
    /// PocketSignInView; signed-in → the authed PhoneRootView. Every authed client (hydrate/reason/write) is
    /// unreachable until a REAL token is stored (warden gate #1). DEBUG stays on the fixture flow (no real auth).
    @StateObject private var signIn = SignInCoordinator(login: SentiPocketApp.makeLogin())
    #endif

    var body: some Scene {
        WindowGroup {
            rootView
            #if canImport(CallKit) && canImport(PushKit)
                .environmentObject(dialHost)   // hold + provide the host; ensures it inits + registers for VoIP at launch
                .onAppear { wireRegistrarToLogin() }
                .modifier(DemoDialTriggerModifier())   // config-gated (default OFF) read-only demo trigger; no button when disabled
            #endif
        }
    }

    #if canImport(CallKit) && canImport(PushKit)
    /// Wire login → the device VoIP-register: on a fresh login (SignInCoordinator.onAuthenticated) register the cached
    /// token so a ring can be ADDRESSED to this device. With DialHost's onVoipToken adapter this covers both orderings
    /// (token-before-login and token-after-login). Release only — DEBUG runs the fixture flow with no real auth/register.
    @MainActor
    private func wireRegistrarToLogin() {
        #if !DEBUG
        signIn.onAuthenticated = { [weak dialHost] in dialHost?.onLoginCompleted() }
        #endif
    }
    #endif

    @ViewBuilder private var rootView: some View {
        #if DEBUG
        RootAppView(model: model)
        #else
        // WARDEN gate #1 (322268): the authed surfaces are unreachable until a REAL token is stored.
        if signIn.isAuthenticated {
            PhoneRootView()   // B2: the REAL coordinator + phone-write flow (kills the old static RootView List)
        } else {
            PocketSignInView(phase: signIn.phase, send: signIn.send)
        }
        #endif
    }

    #if !DEBUG
    /// Build the REAL device-flow login closure (gate #2: never fake a token). The auth-API base is SENTI_API_URL if
    /// set, else the gateway (which proxies /api/v1/auth/cli/… in the demo) — @claude-pocket-relay confirms which on PR.
    private static func makeLogin() -> () async throws -> Void {
        let base = authBaseURL()
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.1"
        return { try await SentiNativeAuth(apiBaseURL: base, appVersion: version).login() }
    }

    /// The auth device-flow base: SENTI_API_URL if configured, else SENTI_GATEWAY_URL, else the current tunnel. Kept
    /// separate from the gateway resolver so auth can move to its own host without a code change.
    private static func authBaseURL() -> URL {
        let fallback = "https://experienced-disposal-urge-approved.trycloudflare.com"
        let configured = (Bundle.main.object(forInfoDictionaryKey: "SENTI_API_URL") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "SENTI_GATEWAY_URL") as? String)
        let raw = (configured?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        return URL(string: raw) ?? URL(string: fallback)!
    }
    #endif
}

#if canImport(CallKit) && canImport(PushKit)
/// The REAL, config-gated production entry point for the foreground demo dial (Pulse issue 2a). Shows a VISIBLE
/// trigger ONLY when POCKET_DEMO_DIAL_ENABLED is on (default OFF → NO button). The label is HONEST: verified fixture,
/// READ-ONLY (the demo episode is composed with a non-writing writer — a confirm posts nothing), no sign-in / no user
/// token — it reaches the pickup VOICE only. Tapping it seeds-then-rings (received before ring) via DialHost.
private struct DemoDialTriggerModifier: ViewModifier {
    @EnvironmentObject private var dialHost: DialHost
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom) {
            if DialHost.demoDialEnabled {
                Button { dialHost.triggerDemoDialIfEnabled() } label: {
                    VStack(spacing: 2) {
                        Text("Ring the demo pickup").font(.headline)
                        Text("Verified fixture · read-only · no sign-in · reaches the voice, never writes")
                            .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding()
                .accessibilityIdentifier("demo-dial-trigger")
            }
        }
    }
}
#endif

/// B2 composition root (warden #261831): the real reasoning coordinator + the phone-write flow, wired to the
/// live-demo gateway. Reasoning uses the Cached provider today (labeled sample); relay's GatewayReasoningProvider
/// drops into `selectProvider`'s online branch when PocketSyncClient lands. The WRITE flow is fully live.
struct PhoneRootView: View {
    @StateObject private var reasoning: RealReasoningCoordinator
    @StateObject private var write: PhoneWriteViewModel

    init() {
        let bundle = FixtureLoader.canonicalBundle()
        let sessionId = bundle?.sessionId ?? "6cf7e861-546a-4b9f-b937-39182a5bd395"
        let checkpointId = bundle?.checkpointId
        let cached = CachedReasoningProvider(cachedBriefing: PocketFixtures.briefingPlan,
                                             cachedEvidence: bundle?.evidence ?? [])
        // ONLINE → real gateway reasoning (GatewayReasoningHTTPClient → relay's gated /brief+/answer, bearer session
        // token). It reasons the moment relay's backend + a key/Gemma are live; until then /brief 501/503 → the driver
        // surfaces .failed honestly (never a fabricated brief). OFFLINE/reconnecting → the honest Cached floor.
        let online = GatewayReasoningProvider(client: GatewayReasoningHTTPClient(apiBaseURL: Self.gatewayURL()))
        _reasoning = StateObject(wrappedValue: RealReasoningCoordinator(
            sessionId: sessionId, checkpointId: checkpointId,
            selectProvider: { isOnline in isOnline ? (online as ReasoningProvider) : (cached as ReasoningProvider) }))
        _write = StateObject(wrappedValue: PhoneWriteViewModel(
            sessionId: sessionId,
            client: PocketWriteClient(apiBaseURL: Self.gatewayURL())))
    }

    var body: some View { PocketPhoneView(reasoning: reasoning, write: write) }

    /// Item 5: the gateway URL is a CONFIG value (ephemeral cloudflared tunnel, forge re-publishes on churn), read
    /// from Info.plist `SENTI_GATEWAY_URL` so forge re-points WITHOUT a code change. Falls back to the current tunnel.
    private static func gatewayURL() -> URL {
        let fallback = "https://experienced-disposal-urge-approved.trycloudflare.com"
        let configured = (Bundle.main.object(forInfoDictionaryKey: "SENTI_GATEWAY_URL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = (configured.map { $0.isEmpty ? fallback : $0 }) ?? fallback
        return URL(string: chosen) ?? URL(string: fallback)!
    }
}

#if DEBUG
/// DEBUG uses the canonical verified fixture and the in-module demo seam. Release never names that seam.
private struct RootAppView: View {
    @ObservedObject var model: PocketAppModel

    var body: some View {
        if model.verifiedBundle != nil {
            PocketRootView(state: model.state, send: model.send)
        } else {
            RootView()
        }
    }
}
#endif

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
                StatusView(title: "No bundle", systemImage: "bolt.slash",
                    message: "canonical_checkpoint.json failed to load — check Resources bundling.")
            } else {
                StatusView(title: "Bundle not verified", systemImage: "lock.trianglebadge.exclamationmark",
                    message: "The cached checkpoint is unsigned or signed by an untrusted key. Senti Pocket refuses to display, narrate, or answer from an unverified bundle — fail-closed. Sign the fixture under a trusted key (pocket-demo-app-fixture) to enable the demo.")
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

/// iOS 16-compatible empty/error state (ContentUnavailableView is iOS 17+, but the app target is pinned to iOS 16
/// per the baseline — forge #238084 caught the mismatch on the real Mac). Pure VStack/Image/Text = iOS 16-safe.
private struct StatusView: View {
    let title: String
    let systemImage: String
    let message: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview("Root — verify-gated canonical fixture") {
    RootView()
}
