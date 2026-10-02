import SwiftUI
import PocketContracts
import PocketCall   // VerifiedBundle — the ONLY trusted way to hold a bundle
import PocketUI
import PocketReasoning
import PocketSyncClient

/// App shell (Atlas). The end-to-end state machine + lane feature views plug in here as they land.
/// For Sunday watchability, every screen ships a #Preview wired to the canonical fixture so the Xcode
/// canvas renders live on `git pull` + open — no simulator run required to see progress.
@main
struct SentiPocketApp: App {
    #if DEBUG
    @StateObject private var model = PocketAppModel()
    #endif
    #if canImport(CallKit) && canImport(PushKit)
    /// App-lifetime DIALS wiring (onAnswered hookup part-b): owns the SentiCallManager (its PKPushRegistry delegate
    /// must live the whole app) + the DialCoordinator, and installs the push-receive/answer adapters + the governed
    /// DI seams (hydrate via the authed DialHydrationClient / runDial via LiveDialVoice+PhoneWriteAdapter+orchestrator).
    @StateObject private var dialHost = DialHost()
    #endif
    #if !DEBUG
    /// The login GATE (Atlas, 322268 — closes the gate≠live gap): makes SentiNativeAuth LIVE. Signed-out →
    /// PocketSignInView; signed-in → the authenticated three-tab app. Every authed client (sync/hydrate/reason/write) is
    /// unreachable until a REAL token is stored (warden gate #1). DEBUG stays on the fixture flow (no real auth).
    @StateObject private var signIn = SignInCoordinator(login: SentiPocketApp.makeLogin())
    #endif

    var body: some Scene {
        WindowGroup {
            rootView
            #if canImport(CallKit) && canImport(PushKit)
                // The host is app-lifetime, but it constructs PushKit/CallKit only with a valid trusted gateway config.
                .environmentObject(dialHost)
                .onAppear { wireRegistrarToLogin() }
                .onChange(of: releaseAuthenticationIsActive) { isActive in
                    if !isActive { dialHost.onAuthenticationInvalidated() }
                }
            #endif
        }
    }

    #if canImport(CallKit) && canImport(PushKit)
    private var releaseAuthenticationIsActive: Bool {
        #if DEBUG
        false
        #else
        signIn.isAuthenticated
        #endif
    }

    /// Wire login → the device VoIP-register: on a fresh login (SignInCoordinator.onAuthenticated) register the cached
    /// token so a ring can be ADDRESSED to this device. With DialHost's onVoipToken adapter this covers both orderings
    /// (token-before-login and token-after-login). Release only — DEBUG runs the fixture flow with no real auth/register.
    @MainActor
    private func wireRegistrarToLogin() {
        #if !DEBUG
        signIn.onAuthenticated = { [weak dialHost] in dialHost?.onLoginCompleted() }
        signIn.onAuthenticationRevoked = { [weak dialHost] in dialHost?.onAuthenticationInvalidated() }
        dialHost.installAuthenticationExpiryHandler { [weak signIn] in
            signIn?.invalidateAuthentication()
        }
        if signIn.isAuthenticated {
            dialHost.onLoginCompleted()
        }
        #endif
    }
    #endif

    @ViewBuilder private var rootView: some View {
        #if DEBUG
        RootAppView(model: model)
        #else
        // WARDEN gate #1 (322268): the authed surfaces are unreachable until a REAL token is stored.
        if signIn.isAuthenticated {
            #if canImport(CallKit) && canImport(PushKit)
            AuthenticatedRootView(
                authenticationEpoch: signIn.authenticationEpoch,
                onReauthenticationRequired: { expectedEpoch in
                    guard signIn.isCurrentAuthentication(expectedEpoch) else { return }
                    signIn.invalidateAuthentication(expectedEpoch: expectedEpoch)
                },
                onSessionSelectionChanged: { expectedEpoch, sessionId in
                    guard signIn.isCurrentAuthentication(expectedEpoch) else { return }
                    dialHost.selectSession(sessionId)
                }
            )
            .id(signIn.authenticationEpoch)
            #else
            AuthenticatedRootView(
                authenticationEpoch: signIn.authenticationEpoch,
                onReauthenticationRequired: { expectedEpoch in
                    signIn.invalidateAuthentication(expectedEpoch: expectedEpoch)
                }
            )
            .id(signIn.authenticationEpoch)
            #endif
        } else {
            PocketSignInView(phase: signIn.phase, send: signIn.send)
        }
        #endif
    }

    #if !DEBUG
    /// Build the REAL device-flow login closure (gate #2: never fake a token). SENTI_API_URL may explicitly override
    /// the gateway, but there is no baked public-tunnel fallback: missing/invalid configuration fails before auth.
    private static func makeLogin() -> () async throws -> Void {
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.1"
        return {
            guard let base = GatewayEndpoint.resolve(
                infoPlistKeys: ["SENTI_API_URL", "SENTI_GATEWAY_URL"]
            ) else {
                throw GatewayEndpointError.notConfigured
            }
            try await SentiNativeAuth(apiBaseURL: base, appVersion: version).login()
        }
    }
    #endif
}

/// Release composition of the authenticated repository-backed Sessions surface and the selected-session Pocket flow.
private struct AuthenticatedRootView: View {
    @StateObject private var sessions: SessionListCoordinator
    @StateObject private var details: SelectedSessionDetailCoordinator
    @StateObject private var revocationRelay: AuthenticatedSessionRevocationRelay
    @State private var selectedTab: PocketTab = .sessions
    private let authenticationRevision: UInt64

    init(
        authenticationEpoch: UInt64,
        onReauthenticationRequired: @escaping @MainActor @Sendable (UInt64) -> Void,
        onSessionSelectionChanged: @escaping @MainActor (UInt64, String?) -> Void = { _, _ in }
    ) {
        let guardedReauthentication: @MainActor @Sendable () -> Void = {
            onReauthenticationRequired(authenticationEpoch)
        }
        let apiURL = GatewayEndpoint.resolve(infoPlistKeys: ["SENTI_API_URL", "SENTI_GATEWAY_URL"])
        let transport = HTTPSessionTransport(
            apiBaseURL: apiURL,
            tokenProvider: { SessionTokenStore.load() }
        )
        let revocationRelay = AuthenticatedSessionRevocationRelay(
            onReauthenticationRequired: guardedReauthentication
        )
        let details = SelectedSessionDetailCoordinator(
            transport: transport,
            onReauthenticationRequired: {
                revocationRelay.invalidateAuthentication()
            },
            onSelectionRevoked: { sessionId in
                revocationRelay.revokeSelection(expectedSessionId: sessionId)
            }
        )
        let sessions = SessionListCoordinator(
            repository: SessionRepository(transport: transport),
            onReauthenticationRequired: {
                revocationRelay.invalidateAuthentication()
            },
            onSelectionChanged: { sessionId in
                details.setSelectedSession(
                    sessionId,
                    authenticationRevision: authenticationEpoch
                )
                onSessionSelectionChanged(authenticationEpoch, sessionId)
            }
        )
        revocationRelay.sessions = sessions
        revocationRelay.details = details

        _sessions = StateObject(wrappedValue: sessions)
        _details = StateObject(wrappedValue: details)
        _revocationRelay = StateObject(wrappedValue: revocationRelay)
        self.authenticationRevision = authenticationEpoch
    }

    var body: some View {
        AppShell(
            selection: $selectedTab,
            sessions: {
                NavigationStack {
                    SessionListView(state: sessions.state) { intent in
                        sessions.send(intent)
                        if case .selectSession(let sessionId) = intent,
                           sessions.selectedSessionId == sessionId {
                            selectedTab = .pocket
                        }
                    }
                }
            },
            pocket: {
                SelectedSessionPocketView(
                    sessions: sessions,
                    onReauthenticationRequired: invalidateProtectedAuthentication
                )
            },
            activity: {
                SelectedSessionActivityBoundary(
                    sessions: sessions,
                    details: details
                )
            }
        )
        .onAppear {
            details.setSelectedSession(
                sessions.selectedSessionId,
                authenticationRevision: authenticationRevision
            )
            sessions.start()
        }
        .onDisappear {
            sessions.clearSelection()
            details.clearSelection()
        }
    }

    @MainActor
    private func invalidateProtectedAuthentication() {
        revocationRelay.invalidateAuthentication()
    }
}

/// Breaks the construction cycle between the session allowlist and its selected-session detail coordinator while
/// keeping revocation synchronous on the main actor. References are weak; the authenticated root owns both objects.
@MainActor
private final class AuthenticatedSessionRevocationRelay: ObservableObject {
    weak var sessions: SessionListCoordinator?
    weak var details: SelectedSessionDetailCoordinator?

    private let onReauthenticationRequired: @MainActor @Sendable () -> Void

    init(onReauthenticationRequired: @escaping @MainActor @Sendable () -> Void) {
        self.onReauthenticationRequired = onReauthenticationRequired
    }

    func invalidateAuthentication() {
        sessions?.invalidateAuthentication()
        details?.invalidateAuthentication()
        onReauthenticationRequired()
    }

    func revokeSelection(expectedSessionId: String) {
        guard sessions?.selectedSessionId == expectedSessionId else { return }
        sessions?.clearSelection()
    }
}

private struct SelectedSessionPocketView: View {
    @ObservedObject var sessions: SessionListCoordinator
    let onReauthenticationRequired: @MainActor @Sendable () -> Void

    @ViewBuilder var body: some View {
        if let sessionId = sessions.selectedSessionId {
            PhoneRootView(
                sessionId: sessionId,
                onReauthenticationRequired: onReauthenticationRequired,
                isWriteAuthorized: {
                    sessions.selectedSessionId == sessionId
                }
            )
                .id(sessionId)
        } else {
            NavigationStack {
                StatusView(
                    title: "Choose a session",
                    systemImage: "rectangle.stack",
                    message: "Select an authorized session before asking Senti or posting as yourself."
                )
                .navigationTitle("Pocket")
            }
        }
    }
}

private struct SelectedSessionActivityBoundary: View {
    @ObservedObject var sessions: SessionListCoordinator
    @ObservedObject var details: SelectedSessionDetailCoordinator

    @ViewBuilder
    var body: some View {
        NavigationStack {
            Group {
                if sessions.selectedSessionId == nil {
                    StatusView(
                        title: "Choose a session",
                        systemImage: "waveform.path.ecg",
                        message: "Select an authorized session before loading its activity or room checkpoints."
                    )
                    .navigationTitle("Activity")
                } else {
                    activityContent
                        .toolbar {
                            ToolbarItem(placement: .navigationBarTrailing) {
                                NavigationLink {
                                    checkpointContent
                                } label: {
                                    Label("Room checkpoints", systemImage: "tray.full")
                                        .labelStyle(.iconOnly)
                                }
                                .accessibilityLabel("Room checkpoints")
                            }
                        }
                }
            }
            .navigationDestination(isPresented: destinationIsPresented) {
                if let destination = details.destination {
                    destinationView(destination)
                }
            }
        }
        .id(sessions.selectedSessionId)
    }

    /// Item-based navigation destinations require iOS 17; Pocket's floor remains iOS 16.
    private var destinationIsPresented: Binding<Bool> {
        Binding(
            get: { details.destination != nil },
            set: { isPresented in
                if !isPresented {
                    details.clearDestination()
                }
            }
        )
    }

    @ViewBuilder
    private func destinationView(_ destination: SessionDetailDestination) -> some View {
        switch destination {
        case .event(let sequenceId, let eventId):
            if let event = details.event(sequenceId: sequenceId, eventId: eventId) {
                SessionEventDetailView(
                    event: event,
                    provenance: details.activityState?.provenance ?? .unavailable
                )
            }
        case .action(let actionId):
            if let action = details.action(actionId: actionId) {
                SessionActionDetailView(
                    action: action,
                    provenance: details.activityState?.provenance ?? .unavailable
                )
            }
        }
    }

    @ViewBuilder
    private var activityContent: some View {
        if let state = details.activityState {
            SessionActivityView(state: state) { intent in
                details.send(intent)
            }
        } else {
            loadStatus(
                details.activityLoadState,
                emptyTitle: "No activity loaded",
                systemImage: "waveform.path.ecg",
                retry: { details.refreshActivity() }
            )
            .navigationTitle("Activity")
        }
    }

    @ViewBuilder
    private var checkpointContent: some View {
        if let state = details.checkpointState {
            SessionCheckpointListView(state: state) { intent in
                details.send(intent)
            }
        } else {
            loadStatus(
                details.checkpointLoadState,
                emptyTitle: "No room checkpoints loaded",
                systemImage: "tray.full",
                retry: { details.refreshCheckpoints() }
            )
            .navigationTitle("Room checkpoints")
        }
    }

    private func loadStatus(
        _ loadState: SelectedSessionDetailLoadState,
        emptyTitle: String,
        systemImage: String,
        retry: @escaping () -> Void
    ) -> some View {
        let title: String
        let message: String
        let actionTitle: String?
        let action: (() -> Void)?

        switch loadState {
        case .loading:
            title = "Loading"
            message = "Fetching the selected session through your current Senti authorization."
            actionTitle = nil
            action = nil
        case .failed(let failure):
            title = failure.title
            message = failure.detail
            actionTitle = "Try again"
            action = retry
        case .idle, .loaded:
            title = emptyTitle
            message = "Refresh to load the currently selected authorized session."
            actionTitle = "Refresh"
            action = retry
        }

        return StatusView(
            title: title,
            systemImage: loadState.isLoading ? "arrow.triangle.2.circlepath" : systemImage,
            message: message,
            actionTitle: actionTitle,
            action: action
        )
    }
}

/// B2 selected-session composition: the real reasoning coordinator + phone-write flow. No Release fixture identity or
/// cached sample is used; the only session id comes from SessionListCoordinator's currently authorized row allowlist.
struct PhoneRootView: View {
    @StateObject private var reasoning: RealReasoningCoordinator
    @StateObject private var write: PhoneWriteViewModel

    init(
        sessionId: String,
        onReauthenticationRequired: @escaping @MainActor @Sendable () -> Void = {},
        isWriteAuthorized: @escaping @MainActor () -> Bool = { true }
    ) {
        let unavailable = UnavailableSessionReasoningProvider()
        let gatewayURL = GatewayEndpoint.resolve(infoPlistKeys: ["SENTI_GATEWAY_URL"])
        let authenticationExpiry = AuthenticationExpiryRelay()
        authenticationExpiry.install(onReauthenticationRequired)
        // ONLINE → real gateway reasoning (GatewayReasoningHTTPClient → relay's gated /brief+/answer, bearer session
        // token). It reasons the moment relay's backend + a key/Gemma are live; until then /brief 501/503 → the driver
        // surfaces .failed honestly (never a fabricated brief). A build with no trusted gateway has no selected-session
        // cache yet and returns an explicit unavailable error; it never borrows the DEBUG fixture's session content.
        let online = gatewayURL.map {
            GatewayReasoningProvider(client: GatewayReasoningHTTPClient(
                apiBaseURL: $0,
                onReauthenticationRequired: { authenticationExpiry.signal(expectedToken: $0) }
            ))
        }
        _reasoning = StateObject(wrappedValue: RealReasoningCoordinator(
            sessionId: sessionId, checkpointId: nil,
            selectProvider: { isOnline in
                if isOnline, let online { return online as ReasoningProvider }
                return unavailable as ReasoningProvider
            }))
        _write = StateObject(wrappedValue: PhoneWriteViewModel(
            sessionId: sessionId,
            client: PocketWriteClient(apiBaseURL: gatewayURL),
            onReauthenticationRequired: { expectedToken in
                if expectedToken == nil || SessionTokenStore.load() == expectedToken {
                    onReauthenticationRequired()
                }
            },
            isWriteAuthorized: isWriteAuthorized))
    }

    var body: some View { PocketPhoneView(reasoning: reasoning, write: write) }
}

private struct UnavailableSessionReasoningProvider: ReasoningProvider {
    let provenance: ReasoningProvenance = .cachedSample

    func briefing(sessionId: String, checkpointId: String?) async throws -> BriefingPlan {
        throw UnavailableSessionReasoningError.noVerifiedCache
    }

    func answer(
        _ question: String,
        sessionId: String,
        checkpointId: String?
    ) async throws -> ReasonedAnswer {
        throw UnavailableSessionReasoningError.noVerifiedCache
    }
}

private enum UnavailableSessionReasoningError: LocalizedError {
    case noVerifiedCache

    var errorDescription: String? {
        "No verified briefing is cached for this session. Connect to Senti to reason over its latest checkpoint."
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

#if DEBUG
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
#endif

/// iOS 16-compatible empty/error state (ContentUnavailableView is iOS 17+, but the app target is pinned to iOS 16
/// per the baseline — forge #238084 caught the mismatch on the real Mac). Pure VStack/Image/Text = iOS 16-safe.
private struct StatusView: View {
    let title: String
    let systemImage: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?

    init(
        title: String,
        systemImage: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if DEBUG
#Preview("Root — verify-gated canonical fixture") {
    RootView()
}
#endif
