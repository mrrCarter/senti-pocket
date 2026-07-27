#if canImport(CallKit) && canImport(PushKit)
import Foundation
import PocketCall
import PocketContracts
import PocketReasoning
import PocketDialVoice

// DialHost — the app-lifetime composition wiring for DIALS (Forge, onAnswered hookup part-b). Owns the
// SentiCallManager (its PKPushRegistry delegate must live the whole app) + the DialCoordinator, and installs the
// two adapters + the three governed DI seams warden's part-b gate specifies:
//   • push-receive  → coordinator.received(state, dialId)         (adapter 1)
//   • answer        → coordinator.answered(dialId, callUUID)      (adapter 2)  — dialId+UUID only, never .message
//   • hydrate seam  = the AUTHED DialHydrationClient (governed content from the GET, never the push)
//   • runDial seam  = the governed LiveDialVoice + PhoneWriteAdapter + DialOrchestrator
//   • endCall seam  = SentiCallManager.end
//
// FOOTGUN-SAFE (warden's load-bearing gate): the write-driving content is ONLY ever the HYDRATED RenderableRing —
// the coordinator never receives IncomingDecisionCall, and `run` builds DialRequest from the hydrated ring's core,
// so the unauthenticated push fields can't reach the write by construction. `modelURL` comes from
// WhisperModelLocator.resolve() (option A, on-device Whisper); when the model isn't provisioned it resolves to nil
// → listen() degrades to "" → the orchestrator briefs but can't capture — nothing posts (the same fail-safe as before).
@MainActor
final class DialHost: ObservableObject {
    let callManager = SentiCallManager()
    private let coordinator: DialCoordinator
    private let registrar: DeviceRingRegistrar

    init(gatewayURL: URL = DialHost.gatewayURL()) {
        let cm = callManager
        let dialClient = DialHydrationClient(apiBaseURL: gatewayURL)   // default tokenProvider = real Keychain SessionTokenStore
        let coord = DialCoordinator(
            hydrate: { try await dialClient.hydrate($0) },
            runDial: { await DialHost.run($0, gatewayURL: gatewayURL) },
            endCall: { [weak cm] uuid in cm?.end(uuid) }
        )
        self.coordinator = coord
        // Device VoIP-register (PR 2, onto the live login #103): a ring can only be ADDRESSED to this device once the
        // gateway knows its APNs VoIP token. Register when the token arrives/rotates (adapter 3 below) AND on login
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
        // Adapter 3 — register this device's VoIP token when PKPushRegistry delivers or ROTATES it (authed POST).
        callManager.onVoipToken = { [reg] token in _ = reg.tokenUpdated(token) }
    }

    /// Register (or re-register) the device's cached VoIP token now login has persisted a Bearer. Wired from
    /// SignInCoordinator.onAuthenticated by SentiPocketApp — the other half of the register trigger.
    func onLoginCompleted() { registrar.loginCompleted() }

    /// Build + run the governed flow for a HYDRATED ring. DialRequest is built from the ring's core (authed), NEVER
    /// the push. modelURL is resolved by WhisperModelLocator (App Support side-load / bundle); it nil-degrades
    /// (brief-only, no capture) when the model isn't provisioned — so a missing model never blocks a dial.
    static func run(_ ring: RenderableRing, gatewayURL: URL) async -> DialOutcome {
        let reasoner = ProviderDialReasoner(
            provider: GatewayReasoningProvider(client: GatewayReasoningHTTPClient(apiBaseURL: gatewayURL)))
        let voice = LiveDialVoice(reasoner: reasoner,
                                  sessionId: ring.core.sessionId,
                                  checkpointId: ring.core.checkpointId,
                                  modelURL: WhisperModelLocator.resolve())
        let writer = PhoneWriteAdapter(PhoneWriteViewModel(sessionId: ring.core.sessionId,
                                                           client: PocketWriteClient(apiBaseURL: gatewayURL)))
        let request = DialRequest(dialId: ring.core.id,
                                  // the AUTHED, hydrated governed content — with a pickOption ring's choices folded
                                  // into the spoken text so the pickup READS the options, not just the question (#17).
                                  message: dialSpokenMessage(message: ring.message, options: ring.options),
                                  callerName: ring.core.callerName,
                                  priority: ring.core.priority)
        return await DialOrchestrator(voice: voice, writer: writer).run(request)
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
