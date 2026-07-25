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
// so the unauthenticated push fields can't reach the write by construction. `modelURL` is nil until the whisper
// provisioner ships → listen() degrades to "" → the orchestrator declines (briefs but can't capture) — nothing posts.
@MainActor
final class DialHost: ObservableObject {
    let callManager = SentiCallManager()
    private let coordinator: DialCoordinator

    init(gatewayURL: URL = DialHost.gatewayURL()) {
        let cm = callManager
        let dialClient = DialHydrationClient(apiBaseURL: gatewayURL)   // default tokenProvider = real Keychain SessionTokenStore
        let coord = DialCoordinator(
            hydrate: { try await dialClient.hydrate($0) },
            runDial: { await DialHost.run($0, gatewayURL: gatewayURL) },
            endCall: { [weak cm] uuid in cm?.end(uuid) }
        )
        self.coordinator = coord
        // Adapter 1 — store the state decoded at push-receive (governed content fetched on answer).
        callManager.onDialReceived = { coord.received($0, dialId: $1) }
        // Adapter 2 — hydrate + run off the dialId + CallKit UUID ONLY; never off IncomingDecisionCall.message.
        callManager.onAnswered = { call in
            Task { @MainActor in await coord.answered(dialId: call.dialId, callUUID: call.id) }
        }
    }

    /// Build + run the governed flow for a HYDRATED ring. DialRequest is built from the ring's core (authed), NEVER
    /// the push. modelURL nil until the whisper provisioner ships.
    static func run(_ ring: RenderableRing, gatewayURL: URL) async -> DialOutcome {
        let reasoner = ProviderDialReasoner(
            provider: GatewayReasoningProvider(client: GatewayReasoningHTTPClient(apiBaseURL: gatewayURL)))
        let voice = LiveDialVoice(reasoner: reasoner,
                                  sessionId: ring.core.sessionId,
                                  checkpointId: ring.core.checkpointId,
                                  modelURL: nil)
        let writer = PhoneWriteAdapter(PhoneWriteViewModel(sessionId: ring.core.sessionId,
                                                           client: PocketWriteClient(apiBaseURL: gatewayURL)))
        let request = DialRequest(dialId: ring.core.id,
                                  message: ring.message,          // the AUTHED, hydrated governed content
                                  callerName: ring.core.callerName,
                                  priority: ring.core.priority)
        return await DialOrchestrator(voice: voice, writer: writer).run(request)
    }

    /// Gateway URL config (Info.plist SENTI_GATEWAY_URL; ephemeral cloudflared tunnel, forge re-points on churn).
    static func gatewayURL() -> URL {
        let fallback = "https://experienced-disposal-urge-approved.trycloudflare.com"
        let configured = (Bundle.main.object(forInfoDictionaryKey: "SENTI_GATEWAY_URL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = (configured.map { $0.isEmpty ? fallback : $0 }) ?? fallback
        return URL(string: chosen) ?? URL(string: fallback)!
    }
}
#endif
