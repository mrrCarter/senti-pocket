#if canImport(CallKit) && canImport(PushKit)
import Foundation
import PocketCall
import PocketContracts
import PocketReasoning
import PocketDialVoice

// DialHost — the app-lifetime composition wiring for DIALS (Forge, onAnswered hookup part-b). With a trusted gateway
// configured, it owns SentiCallManager (its PKPushRegistry delegate must live the whole app) + DialCoordinator and
// installs the two adapters + three governed DI seams warden's part-b gate specifies:
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
    let callManager: SentiCallManager?
    private let coordinator: DialCoordinator?
    private let registrar: DeviceRingRegistrar?

    init(gatewayURL: URL? = DialHost.gatewayURL()) {
        guard let gatewayURL else {
            // The default/unconfigured build does not start PushKit token acquisition or construct any gateway client.
            // A later configured launch builds the complete, app-lifetime call stack below.
            callManager = nil
            coordinator = nil
            registrar = nil
            return
        }

        let cm = SentiCallManager()
        let dialClient = DialHydrationClient(apiBaseURL: gatewayURL)
        let coord = DialCoordinator(
            hydrate: { try await dialClient.hydrate($0) },
            runDial: { await DialHost.run($0, gatewayURL: gatewayURL) },
            endCall: { [weak cm] uuid in cm?.end(uuid) }
        )

        // Device VoIP-register (PR 2, onto the live login #103): a ring can only be ADDRESSED to this device once the
        // gateway knows its APNs VoIP token. sessionId is the app-primary session, matching PhoneRootView.
        let sessionId = FixtureLoader.canonicalBundle()?.sessionId ?? "6cf7e861-546a-4b9f-b937-39182a5bd395"
        let reg = DeviceRingRegistrar(
            client: DeviceRingRegistrationClient(apiBaseURL: gatewayURL),
            sessionId: sessionId
        )

        self.callManager = cm
        self.coordinator = coord
        self.registrar = reg
        // Adapter 1 — store the state decoded at push-receive (governed content fetched on answer).
        cm.onDialReceived = { coord.received($0, dialId: $1) }
        // Adapter 2 — hydrate + run off the dialId + CallKit UUID ONLY; never off IncomingDecisionCall.message.
        cm.onAnswered = { call in
            Task { @MainActor in await coord.answered(dialId: call.dialId, callUUID: call.id) }
        }
        // Adapter 3 — register this device's VoIP token when PKPushRegistry delivers or ROTATES it (authed POST).
        cm.onVoipToken = { [weak self] token in
            guard let registrar = self?.registrar else { return }
            _ = registrar.tokenUpdated(token)
        }
    }

    /// Register (or re-register) the device's cached VoIP token now login has persisted a Bearer. Wired from
    /// SignInCoordinator.onAuthenticated by SentiPocketApp — the other half of the register trigger.
    func onLoginCompleted() { registrar?.loginCompleted() }

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

    /// `nonisolated` keeps the default argument usable off the main actor. Missing or invalid configuration is nil,
    /// so the initializer never creates the PushKit/CallKit stack or any gateway client.
    nonisolated static func gatewayURL() -> URL? {
        GatewayEndpoint.resolve(infoPlistKeys: ["SENTI_GATEWAY_URL"])
    }
}
#endif
