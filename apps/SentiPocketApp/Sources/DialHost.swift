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
//   • makeRun seam  = the governed LiveDialRun (LiveDialVoice + PhoneWriteAdapter + DialOrchestrator), a STOPPABLE run
//   • endCall seam  = SentiCallManager.end
//
// FOOTGUN-SAFE (warden's load-bearing gate): the write-driving content is ONLY ever the HYDRATED RenderableRing — the
// coordinator never receives IncomingDecisionCall, and makeRun builds DialRequest from the hydrated ring's core, so the
// unauthenticated push fields can't reach the write by construction. `modelURL` comes from WhisperModelLocator.resolve()
// (option A, on-device Whisper); when the model isn't provisioned it nil-degrades (brief-only, no capture) — a missing
// model never blocks a dial.
//
// SPEC A/B/D wiring: presentForegroundDial SEEDS pending BEFORE ringing (reachability without PushKit); endEpisode is
// the SINGLE teardown owner for a hangup/reset/report-failure; the pocket-TTS bearer (spec D) is read at runtime and
// handed to the WAV synth so the pickup speaks in the pocket voice (nil → Siri).
@MainActor
final class DialHost: ObservableObject {
    let callManager = SentiCallManager()
    private let coordinator: DialCoordinator
    private let registrar: DeviceRingRegistrar

    init(gatewayURL: URL = DialHost.gatewayURL()) {
        let cm = callManager
        let dialClient = DialHydrationClient(apiBaseURL: gatewayURL)   // default tokenProvider = real Keychain SessionTokenStore
        let bearer = DialHost.gatewayBearerProvider()                  // spec D: pocket-TTS bearer (runtime Info.plist, nil → Siri)
        let coord = DialCoordinator(
            hydrate: { try await dialClient.hydrate($0) },
            makeRun: { ring in DialHost.makeRun(ring, gatewayURL: gatewayURL, bearerProvider: bearer) },
            endCall: { [weak cm] uuid in cm?.end(uuid) }
        )
        self.coordinator = coord
        // Device VoIP-register (PR 2, onto the live login #103): a ring can only be ADDRESSED to this device once the
        // gateway knows its APNs VoIP token. Register when the token arrives/rotates (adapter below) AND on login
        // (onLoginCompleted, wired from SignInCoordinator.onAuthenticated by SentiPocketApp) — covers both orderings.
        // sessionId = the app-PRIMARY session (same derivation as PhoneRootView) — a member session the gateway accepts.
        let sessionId = FixtureLoader.canonicalBundle()?.sessionId ?? "6cf7e861-546a-4b9f-b937-39182a5bd395"
        let reg = DeviceRingRegistrar(client: DeviceRingRegistrationClient(apiBaseURL: gatewayURL), sessionId: sessionId)
        self.registrar = reg
        // Adapter 1 — store the state decoded at push-receive (governed content fetched on answer).
        callManager.onDialReceived = { coord.received($0, dialId: $1) }
        // Adapter 2 — hydrate + run off the dialId + CallKit UUID ONLY; never off IncomingDecisionCall.message.
        callManager.onAnswered = { call in
            Task { @MainActor in await coord.answered(dialId: call.dialId, callUUID: call.id) }
        }
        // Adapter 3 (spec B) — every resolved end (hangup / provider reset / report-failure, all via the single
        // CallEndRouter) tears down the matching generation-scoped episode: cancel the run, stop synth + mic, cancel an
        // unauthorized draft (retain an authorized write), discard unanswered pending.
        callManager.onEndEvent = { event in coord.endEpisode(callUUID: event.callUUID, dialId: event.dialId) }
        // Adapter 4 — register this device's VoIP token when PKPushRegistry delivers or ROTATES it (authed POST).
        callManager.onVoipToken = { [reg] token in _ = reg.tokenUpdated(token) }
    }

    /// Register (or re-register) the device's cached VoIP token now login has persisted a Bearer. Wired from
    /// SignInCoordinator.onAuthenticated by SentiPocketApp — the other half of the register trigger.
    func onLoginCompleted() { registrar.loginCompleted() }

    // MARK: - Foreground reachability (spec A, P0-3)

    /// SEED the coordinator's pending state BEFORE ringing, so when the human answers, `answered` finds the seeded ring,
    /// hydrates it, and reaches the pickup voice — instead of declining. Received-before-ring is the load-bearing order.
    func presentForegroundDial(state: DialReceiveState, call: IncomingDecisionCall) {
        coordinator.received(state, dialId: call.dialId)   // seed FIRST (so the answer finds pending state)
        callManager.ring(call)                             // THEN ring
    }

    /// Fire a foreground demo dial IFF the demo-dial capability is enabled (default OFF → NO ring). When enabled, mints
    /// a VERIFY-GATED seed (VerifiedBundle.verify) and seeds-then-rings. Ring/audio/READ-ONLY: WITHOUT a real
    /// SessionTokenStore token this is NOT authenticated LEAN /dial hydration and NOT governed writeback. Returns whether
    /// a ring was presented (false = disabled OR the fixture didn't verify → fail-closed, no ring).
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

    /// Build the governed RUN for a HYDRATED ring: compose the stoppable LiveDialVoice (pocket-TTS bearer wired — spec
    /// D) + the governed PhoneWriteViewModel + the DialOrchestrator into a LiveDialRun the coordinator can stop on
    /// hangup. DialRequest is built from the ring's AUTHED core (with a pickOption ring's choices folded into the spoken
    /// text so the pickup READS the options), NEVER the push.
    static func makeRun(_ ring: RenderableRing, gatewayURL: URL,
                        bearerProvider: @escaping @Sendable () async -> String?) -> DialRun {
        let reasoner = ProviderDialReasoner(
            provider: GatewayReasoningProvider(client: GatewayReasoningHTTPClient(apiBaseURL: gatewayURL)))
        let voice = LiveDialVoice(reasoner: reasoner,
                                  sessionId: ring.core.sessionId,
                                  checkpointId: ring.core.checkpointId,
                                  modelURL: WhisperModelLocator.resolve(),
                                  synthesizer: GatewayWAVSpeechSynthesizer(endpoint: gatewayURL, bearerProvider: bearerProvider))
        let writeModel = PhoneWriteViewModel(sessionId: ring.core.sessionId,
                                             client: PocketWriteClient(apiBaseURL: gatewayURL))
        let request = DialRequest(dialId: ring.core.id,
                                  message: dialSpokenMessage(message: ring.message, options: ring.options),
                                  callerName: ring.core.callerName,
                                  priority: ring.core.priority)
        return LiveDialRun(voice: voice, writeModel: writeModel, request: request)
    }

    /// The pocket-TTS demo bearer (spec D), read at RUNTIME from Info.plist `SENTI_GATEWAY_BEARER` — a PUBLIC-DEMO
    /// capability injected at build time, NEVER a source/project.yml literal. Absent/empty → nil → GatewayWAVSpeech-
    /// Synthesizer keeps its default (Siri) TTS. `@Sendable`, reads only Bundle.main (no captured state).
    nonisolated static func gatewayBearerProvider() -> @Sendable () async -> String? {
        return {
            guard let raw = Bundle.main.object(forInfoDictionaryKey: "SENTI_GATEWAY_BEARER") as? String else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
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
