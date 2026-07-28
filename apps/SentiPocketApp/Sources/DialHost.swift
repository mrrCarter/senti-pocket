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
//   • end           → coordinator.endEpisode(callUUID, dialId)    (adapter 3)  — from the single CallEndRouter
//   • hydrate seam  = the AUTHED DialHydrationClient (governed content from the GET, never the push)
//   • makeRun seam  = the stoppable LiveDialRun. A REAL /dial ring gets the governed PhoneWriteAdapter; a FOREGROUND
//                     demo dial (tracked in DemoDialRegistry) gets a NON-WRITING ReadOnlyDialWriter — read-only by
//                     construction, so a demo confirm can never author a governed write regardless of any token.
//   • endCall seam  = SentiCallManager.end
//
// FAIL-CLOSED GATEWAY CONFIG (Pulse round-6 #1): `gatewayURL()` returns a URL ONLY for a non-blank, parseable, HTTPS
// config with a host — there is NO hardcoded host default. A missing/blank/unparseable/non-https config yields nil, and
// makeVoice then pairs the pocket-TTS bearer with NOTHING → on-device Siri (zero network, the bearer is NEVER sent to
// an unintended host); the reasoner is UnavailableDialReasoner and a real write is refused. The bearer + endpoint are
// ONE coupled config unit — a credential is never paired with a wrong/dead host.
//
// FOOTGUN-SAFE (warden's gate): the write-driving content is ONLY ever the HYDRATED RenderableRing.

/// A DialReasoner used when NO gateway is configured (fail-closed): it never touches the network and answers
/// honestly-unavailable — so a bad config degrades to Siri-brief + "I can't reach that", never a wrong-host request.
struct UnavailableDialReasoner: DialReasoner {
    func answerFollowUp(_ question: String, sessionId: String, checkpointId: String?) async -> DialSpokenAnswer {
        DialSpokenAnswer(spokenText: "I can't reach that right now — no gateway is configured.", grounded: false, evidenceIds: [])
    }
}

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
    private let registrar: DeviceRingRegistrar?   // nil when no valid gateway config (fail-closed: no register)
    let demoRegistry: DemoDialRegistry

    init(gatewayURL: URL? = DialHost.gatewayURL()) {
        let cm = callManager
        let dialClient = gatewayURL.map { DialHydrationClient(apiBaseURL: $0) }   // nil → not configured (fail-closed)
        let bearer = DialHost.gatewayBearerProvider()                            // pocket-TTS bearer (runtime Info.plist, UNCHANGED)
        let demoRegistry = DemoDialRegistry()
        let coord = DialCoordinator(
            // No gateway configured → hydrate is unavailable (an answered ring declines; nothing posted).
            hydrate: { state in
                guard let dialClient else { throw DialHydrationClientError.notConfigured }
                return try await dialClient.hydrate(state)
            },
            // READ-ONLY-BY-CONSTRUCTION: a foreground demo dialId (OR a no-gateway config) gets the NON-WRITING run; a
            // real /dial ring with a valid gateway gets the governed write run. Bound HERE at composition.
            makeRun: { ring in
                DialHost.makeRun(ring, gatewayURL: gatewayURL, bearerProvider: bearer,
                                 readOnly: demoRegistry.isDemo(ring.core.id))
            },
            endCall: { [weak cm] uuid in cm?.end(uuid) }
        )
        self.coordinator = coord
        self.demoRegistry = demoRegistry
        // Device VoIP-register (only when a valid gateway is configured — otherwise there is nothing to register with).
        let sessionId = FixtureLoader.canonicalBundle()?.sessionId ?? "6cf7e861-546a-4b9f-b937-39182a5bd395"
        let reg = gatewayURL.map { DeviceRingRegistrar(client: DeviceRingRegistrationClient(apiBaseURL: $0), sessionId: sessionId) }
        self.registrar = reg
        // Adapter 1 — store the state decoded at push-receive (governed content fetched on answer). A REAL push ring is
        // NEVER marked demo → it takes the governed write path.
        callManager.onDialReceived = { coord.received($0, dialId: $1) }
        // Adapter 2 — hydrate + run off the dialId + CallKit UUID ONLY; never off IncomingDecisionCall.message.
        callManager.onAnswered = { call in
            Task { @MainActor in await coord.answered(dialId: call.dialId, callUUID: call.id) }
        }
        // Adapter 3 — every resolved end (hangup / provider reset / report-failure, all via the single CallEndRouter)
        // tears down the matching generation-scoped episode, then forgets any demo-dial registration.
        callManager.onEndEvent = { event in
            coord.endEpisode(callUUID: event.callUUID, dialId: event.dialId)
            if let d = event.dialId { demoRegistry.forget(d) }
        }
        // Adapter 4 — register this device's VoIP token when PKPushRegistry delivers or ROTATES it (authed POST).
        callManager.onVoipToken = { [reg] token in _ = reg?.tokenUpdated(token) }
    }

    /// Register (or re-register) the device's cached VoIP token now login has persisted a Bearer. No-op when no gateway
    /// is configured. Wired from SignInCoordinator.onAuthenticated by SentiPocketApp.
    func onLoginCompleted() { _ = registrar?.loginCompleted() }

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

    // MARK: - Governed run construction (fail-closed on gateway config)

    /// Build the stoppable RUN for a HYDRATED ring. `readOnly` (a demo dial) OR a nil gateway → a NON-WRITING
    /// ReadOnlyDialWriter (a confirm posts nothing); a real ring with a valid gateway → the governed PhoneWriteAdapter.
    static func makeRun(_ ring: RenderableRing, gatewayURL: URL?,
                        bearerProvider: @escaping @Sendable () async -> String?, readOnly: Bool) -> DialRun {
        let voice = makeVoice(ring, gatewayURL: gatewayURL, bearerProvider: bearerProvider)
        let writer: DialEpisodeWriter
        if !readOnly, let url = gatewayURL {
            writer = PhoneWriteAdapter(PhoneWriteViewModel(sessionId: ring.core.sessionId,
                                                           client: PocketWriteClient(apiBaseURL: url)))
        } else {
            writer = ReadOnlyDialWriter()   // demo OR no gateway configured → non-writing (fail-closed)
        }
        return LiveDialRun(voice: voice, writer: writer, request: makeRequest(ring))
    }

    static func makeVoice(_ ring: RenderableRing, gatewayURL: URL?,
                          bearerProvider: @escaping @Sendable () async -> String?) -> LiveDialVoice {
        let reasoner: any DialReasoner
        if let url = gatewayURL {
            reasoner = ProviderDialReasoner(provider: GatewayReasoningProvider(client: GatewayReasoningHTTPClient(apiBaseURL: url)))
        } else {
            reasoner = UnavailableDialReasoner()   // no gateway → never a wrong-host reasoner request
        }
        return LiveDialVoice(reasoner: reasoner,
                             sessionId: ring.core.sessionId,
                             checkpointId: ring.core.checkpointId,
                             modelURL: WhisperModelLocator.resolve(),
                             synthesizer: makeTTSSynth(gatewayURL: gatewayURL, bearerProvider: bearerProvider))
    }

    /// THE COUPLING (Pulse round-6 #1): the pocket-TTS bearer is paired with a gateway endpoint ONLY when the URL is a
    /// valid, HTTPS, configured host. A nil URL → on-device Siri (AVSpeechSynthesizerAdapter) → ZERO network and the
    /// bearer is NEVER sent. There is no hardcoded host anywhere in this path. `session` is injectable for tests.
    static func makeTTSSynth(gatewayURL: URL?,
                             bearerProvider: @escaping @Sendable () async -> String?,
                             session: URLSession? = nil) -> any SpeechSynthesizer {
        guard let url = gatewayURL else { return AVSpeechSynthesizerAdapter() }
        return GatewayWAVSpeechSynthesizer(endpoint: url, bearerProvider: bearerProvider, session: session)
    }

    /// DialRequest from the ring's AUTHED core (a pickOption ring's choices folded into the spoken text so the pickup
    /// READS the options), NEVER the push.
    private static func makeRequest(_ ring: RenderableRing) -> DialRequest {
        DialRequest(dialId: ring.core.id,
                    message: dialSpokenMessage(message: ring.message, options: ring.options),
                    callerName: ring.core.callerName,
                    priority: ring.core.priority)
    }

    /// The pocket-TTS bearer resolution (Pulse): return the Info.plist `SENTI_GATEWAY_BEARER` value UNCHANGED — NEVER
    /// trim/normalize. The synth's `validatedBearer` is the SOLE authority and REJECTS a malformed bearer unchanged →
    /// zero network → Siri. Absent key → nil → Siri.
    nonisolated static func resolveBearer(_ configured: String?) -> String? { configured }

    /// The runtime bearer provider handed to the WAV synth. Reads only Bundle.main (no captured state); `@Sendable`.
    nonisolated static func gatewayBearerProvider() -> @Sendable () async -> String? {
        return { resolveBearer(Bundle.main.object(forInfoDictionaryKey: "SENTI_GATEWAY_BEARER") as? String) }
    }

    /// FAIL-CLOSED gateway URL (Pulse round-6 #1): valid ONLY if non-blank, parseable, HTTPS, with a host. There is NO
    /// hardcoded host default — a missing/blank/unparseable/non-https config yields nil, so makeVoice sends no bearer
    /// (Siri, zero wire) and the reasoner/write are unavailable. A credential is never paired with an unintended host.
    nonisolated static func gatewayURL(from configured: String?) -> URL? {
        guard let raw = configured?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let url = URL(string: raw), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// `nonisolated` so it's usable as the init's default arg (evaluated off the main actor) — it touches no state.
    nonisolated static func gatewayURL() -> URL? {
        gatewayURL(from: Bundle.main.object(forInfoDictionaryKey: "SENTI_GATEWAY_URL") as? String)
    }
}
#endif
