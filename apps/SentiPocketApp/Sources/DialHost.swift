#if canImport(CallKit) && canImport(PushKit)
import Foundation
import PocketCall
import PocketContracts
import PocketReasoning
import PocketDialVoice
import PocketVoice

// DialHost — the app-lifetime composition wiring for DIALS (Forge). Owns the SentiCallManager (its PKPushRegistry
// delegate must live the whole app) + the DialCoordinator, and installs the governed DI seams:
//   • push-receive  → coordinator.received(state, dialId)         (adapter 1)
//   • answer        → coordinator.answered(dialId, callUUID)      (adapter 2)  — dialId+UUID only, never .message
//   • end           → coordinator.endEpisode(callUUID, dialId)    (adapter 3, spec B)  — from the single CallEndRouter
//   • hydrate seam  = the AUTHED DialHydrationClient (governed content from the GET, never the push)
//   • makeRun seam  = the stoppable LiveDialRun. A REAL /dial ring gets the governed PhoneWriteAdapter; a FOREGROUND
//                     demo dial (tracked in DemoDialRegistry) gets a NON-WRITING ReadOnlyDialWriter — read-only by
//                     construction, so a demo confirm can never author a governed write regardless of any token.
//   • endCall seam  = SentiCallManager.end
//
// FOOTGUN-SAFE (warden's load-bearing gate): the write-driving content is ONLY ever the HYDRATED RenderableRing — the
// coordinator never receives IncomingDecisionCall, and makeRun builds DialRequest from the hydrated ring's core, so the
// unauthenticated push fields can't reach the write by construction. `modelURL` comes from WhisperModelLocator.resolve()
// (option A, on-device Whisper); when the model isn't provisioned it nil-degrades (brief-only, no capture).
//
// SPEC A/B/D wiring: presentForegroundDial marks the dialId read-only + SEEDS pending BEFORE ringing (reachability
// without PushKit); endEpisode is the SINGLE teardown owner for a hangup/reset/report-failure; the pocket-TTS bearer
// (spec D) is read at runtime UNCHANGED and handed to the WAV synth (which is the sole authority that validates/rejects
// it) so the pickup speaks in the pocket voice (nil/malformed → Siri).

/// Tracks the dialIds minted for FOREGROUND demo dials, so the makeRun seam composes a READ-ONLY (non-writing) episode
/// for them (read-only-by-construction) while real /dial rings get the governed write path.
@MainActor
final class DemoDialRegistry {
    private(set) var ids: Set<String> = []
    func markDemo(_ dialId: String) { ids.insert(dialId) }
    func forget(_ dialId: String) { ids.remove(dialId) }
    func isDemo(_ dialId: String) -> Bool { ids.contains(dialId) }
}

@MainActor
final class DialHost: ObservableObject {
    let callManager = SentiCallManager()
    private let coordinator: DialCoordinator
    private let registrar: DeviceRingRegistrar
    let demoRegistry: DemoDialRegistry

    init(gatewayURL: URL = DialHost.gatewayURL()) {
        let cm = callManager
        let dialClient = DialHydrationClient(apiBaseURL: gatewayURL)   // default tokenProvider = real Keychain SessionTokenStore
        let bearer = DialHost.gatewayBearerProvider()                  // spec D: pocket-TTS bearer (runtime Info.plist, UNCHANGED)
        let demoRegistry = DemoDialRegistry()
        let coord = DialCoordinator(
            hydrate: { try await dialClient.hydrate($0) },
            // READ-ONLY-BY-CONSTRUCTION: a foreground demo dialId gets the NON-WRITING run; a real /dial ring gets the
            // governed write run. The choice is bound HERE at composition, so a demo episode can never write.
            makeRun: { ring in
                demoRegistry.isDemo(ring.core.id)
                    ? DialHost.makeDemoRun(ring, gatewayURL: gatewayURL, bearerProvider: bearer)
                    : DialHost.makeRun(ring, gatewayURL: gatewayURL, bearerProvider: bearer)
            },
            endCall: { [weak cm] uuid in cm?.end(uuid) }
        )
        self.coordinator = coord
        self.demoRegistry = demoRegistry
        // Device VoIP-register (PR 2, onto the live login #103): a ring can only be ADDRESSED to this device once the
        // gateway knows its APNs VoIP token. Register when the token arrives/rotates (adapter below) AND on login
        // (onLoginCompleted, wired from SignInCoordinator.onAuthenticated by SentiPocketApp) — covers both orderings.
        let sessionId = FixtureLoader.canonicalBundle()?.sessionId ?? "6cf7e861-546a-4b9f-b937-39182a5bd395"
        let reg = DeviceRingRegistrar(client: DeviceRingRegistrationClient(apiBaseURL: gatewayURL), sessionId: sessionId)
        self.registrar = reg
        // Adapter 1 — store the state decoded at push-receive (governed content fetched on answer). A REAL push ring is
        // NEVER marked demo → it takes the governed write path.
        callManager.onDialReceived = { coord.received($0, dialId: $1) }
        // Adapter 2 — hydrate + run off the dialId + CallKit UUID ONLY; never off IncomingDecisionCall.message.
        callManager.onAnswered = { call in
            Task { @MainActor in await coord.answered(dialId: call.dialId, callUUID: call.id) }
        }
        // Adapter 3 (spec B) — every resolved end (hangup / provider reset / report-failure, all via the single
        // CallEndRouter) tears down the matching generation-scoped episode, then forgets any demo-dial registration.
        callManager.onEndEvent = { event in
            coord.endEpisode(callUUID: event.callUUID, dialId: event.dialId)
            if let d = event.dialId { demoRegistry.forget(d) }
        }
        // Adapter 4 — register this device's VoIP token when PKPushRegistry delivers or ROTATES it (authed POST).
        callManager.onVoipToken = { [reg] token in _ = reg.tokenUpdated(token) }
    }

    /// Register (or re-register) the device's cached VoIP token now login has persisted a Bearer. Wired from
    /// SignInCoordinator.onAuthenticated by SentiPocketApp — the other half of the register trigger.
    func onLoginCompleted() { registrar.loginCompleted() }

    // MARK: - Foreground reachability (spec A, P0-3)

    /// SEED the coordinator's pending state BEFORE ringing, so when the human answers, `answered` finds the seeded ring,
    /// hydrates it, and reaches the pickup voice — instead of declining. Received-before-ring is the load-bearing order.
    /// The dialId is marked READ-ONLY first: a foreground dial can never author a governed write (no push, no /dial auth).
    func presentForegroundDial(state: DialReceiveState, call: IncomingDecisionCall) {
        demoRegistry.markDemo(call.dialId)                 // read-only-by-construction (before the run can be built)
        coordinator.received(state, dialId: call.dialId)   // seed FIRST (so the answer finds pending state)
        callManager.ring(call)                             // THEN ring
    }

    /// The REAL, config-gated production entry point (the demo trigger button calls this). Fires a foreground demo dial
    /// IFF POCKET_DEMO_DIAL_ENABLED (default OFF → NO ring). When enabled, mints a VERIFY-GATED seed
    /// (VerifiedBundle.verify) and marks-read-only + seeds + rings. HONEST LABEL: verified fixture, READ-ONLY (composed
    /// with a non-writing writer — a demo confirm posts nothing), NO user token / NO governed writeback; it reaches the
    /// pickup VOICE only. Returns whether a ring was presented (false = disabled OR the fixture didn't verify).
    @discardableResult
    func triggerDemoDialIfEnabled() -> Bool {
        guard DialHost.demoDialEnabled else { return false }
        guard let seed = DemoDialFactory.makeFromCanonical() else { return false }
        let call = IncomingDecisionCall(id: seed.callUUID, dialId: seed.dialId, callerDisplayName: seed.callerName,
                                        message: seed.message, context: nil, priority: seed.priority)
        presentForegroundDial(state: seed.state, call: call)
        return true
    }

    /// The demo-dial gate (spec A) — Info.plist `POCKET_DEMO_DIAL_ENABLED`, DEFAULT OFF (absent/false → disabled). A
    /// dedicated demo build flips it on. Accepts a Bool, NSNumber, or "true"/"yes"/"1" string (xcconfig/plist injection).
    static var demoDialEnabled: Bool {
        let v = Bundle.main.object(forInfoDictionaryKey: "POCKET_DEMO_DIAL_ENABLED")
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        if let s = v as? String { return ["true", "yes", "1"].contains(s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
        return false
    }

    // MARK: - Governed run construction (spec B/D)

    /// Build the REAL governed RUN for a HYDRATED /dial ring: stoppable LiveDialVoice (pocket-TTS bearer wired — spec D)
    /// + the governed PhoneWriteAdapter + the DialOrchestrator, as a LiveDialRun the coordinator can stop on hangup.
    static func makeRun(_ ring: RenderableRing, gatewayURL: URL,
                        bearerProvider: @escaping @Sendable () async -> String?) -> DialRun {
        let voice = makeVoice(ring, gatewayURL: gatewayURL, bearerProvider: bearerProvider)
        let writeModel = PhoneWriteViewModel(sessionId: ring.core.sessionId,
                                             client: PocketWriteClient(apiBaseURL: gatewayURL))
        return LiveDialRun(voice: voice, writer: PhoneWriteAdapter(writeModel), request: makeRequest(ring))
    }

    /// Build the READ-ONLY DEMO run: the SAME stoppable voice, but a NON-WRITING ReadOnlyDialWriter — so a demo
    /// "confirm" produces ZERO write requests and ZERO outbox, regardless of any SessionTokenStore token. It reaches
    /// the pickup VOICE only.
    static func makeDemoRun(_ ring: RenderableRing, gatewayURL: URL,
                            bearerProvider: @escaping @Sendable () async -> String?) -> DialRun {
        let voice = makeVoice(ring, gatewayURL: gatewayURL, bearerProvider: bearerProvider)
        return LiveDialRun(voice: voice, writer: ReadOnlyDialWriter(), request: makeRequest(ring))
    }

    private static func makeVoice(_ ring: RenderableRing, gatewayURL: URL,
                                  bearerProvider: @escaping @Sendable () async -> String?) -> LiveDialVoice {
        let reasoner = ProviderDialReasoner(
            provider: GatewayReasoningProvider(client: GatewayReasoningHTTPClient(apiBaseURL: gatewayURL)))
        return LiveDialVoice(reasoner: reasoner,
                             sessionId: ring.core.sessionId,
                             checkpointId: ring.core.checkpointId,
                             modelURL: WhisperModelLocator.resolve(),
                             synthesizer: GatewayWAVSpeechSynthesizer(endpoint: gatewayURL, bearerProvider: bearerProvider))
    }

    /// DialRequest from the ring's AUTHED core (a pickOption ring's choices folded into the spoken text so the pickup
    /// READS the options), NEVER the push.
    private static func makeRequest(_ ring: RenderableRing) -> DialRequest {
        DialRequest(dialId: ring.core.id,
                    message: dialSpokenMessage(message: ring.message, options: ring.options),
                    callerName: ring.core.callerName,
                    priority: ring.core.priority)
    }

    /// The pocket-TTS bearer resolution (spec D / Pulse): return the Info.plist `SENTI_GATEWAY_BEARER` value UNCHANGED —
    /// NEVER trim/normalize. The synth's `validatedBearer` is the SOLE authority and REJECTS a malformed bearer
    /// (whitespace / CRLF / Unicode-space / control) UNCHANGED → zero network → Siri; trimming here would smuggle a
    /// padded token past that reject-unchanged contract. Absent key → nil → Siri.
    nonisolated static func resolveBearer(_ configured: String?) -> String? { configured }

    /// The runtime bearer provider handed to the WAV synth. Reads only Bundle.main (no captured state); `@Sendable`.
    nonisolated static func gatewayBearerProvider() -> @Sendable () async -> String? {
        return { resolveBearer(Bundle.main.object(forInfoDictionaryKey: "SENTI_GATEWAY_BEARER") as? String) }
    }

    /// Gateway URL config (Info.plist SENTI_GATEWAY_URL; ephemeral cloudflared tunnel, forge re-points on churn).
    /// `nonisolated` so it's usable as the init's default arg (evaluated off the main actor) — it touches no state.
    nonisolated static func gatewayURL() -> URL {
        let fallback = "https://experienced-disposal-urge-approved.trycloudflare.com"
        let configured = (Bundle.main.object(forInfoDictionaryKey: "SENTI_GATEWAY_URL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = (configured.map { $0.isEmpty ? fallback : $0 }) ?? fallback
        return URL(string: chosen) ?? URL(string: fallback)!
    }
}
#endif
