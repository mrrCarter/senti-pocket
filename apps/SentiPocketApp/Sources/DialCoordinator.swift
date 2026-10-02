import Foundation
import PocketCall

// DialCoordinator — the app-lifetime owner that turns an ANSWERED DIALS ring into a governed-write flow (Forge,
// onAnswered hookup increment 2/2). It stores the LEAN/RICH `DialReceiveState` decoded at PUSH-RECEIVE (keyed by
// dialId), and on ANSWER HYDRATES it via atlas's DialHydrationClient (`.renderable`→no-fetch / `.needsHydration`→
// authed GET+merge / `.rejected`→refuse) then runs the DialOrchestrator (brief→converse→dictate→confirm→post).
//
// This file is the testable CORE: the received→store / answered→retrieve→hydrate→run→end orchestration + the
// consent-load-bearing error handling, over INJECTED seams (`hydrate` / `runDial` / `endCall`) so the whole answer
// flow is unit-testable without CallKit, PushKit, network, whisper, or the reasoning gateway. The production wiring
// (real DialHydrationClient + LiveDialVoice/PhoneWriteAdapter construction + @main @StateObject + the SentiCallKit
// receive-hook) is the thin glue that supplies these seams — a follow-up increment.
//
// SECURITY: `hydrate` is the substitution gate (DialHydration.merge refuses a fetched signal whose id/session/
// checkpoint ≠ the push core). A hydrate failure → `.declined`, NOTHING posted. No stored state for the answered
// dialId → `.declined`, NOTHING posted. The write only ever happens inside `runDial` → the SAME governed confirm.

@MainActor
final class DialCoordinator: ObservableObject {
    /// Hydrate a received state into a renderable ring (atlas's DialHydrationClient.hydrate). Throws on refuse/absent.
    private let hydrate: (DialReceiveState) async throws -> RenderableRing
    /// Drive the governed dial flow for a hydrated ring → outcome (constructs LiveDialVoice+PhoneWriteAdapter+
    /// DialOrchestrator and runs it). Injected so the coordinator's orchestration is testable in isolation.
    private let runDial: (RenderableRing, UUID) async -> DialOutcome
    /// End the CallKit call (SentiCallManager.end) once the flow reaches a terminal outcome.
    private let endCall: (UUID) -> Void

    private struct PendingDial {
        let dialId: String
        let state: DialReceiveState
    }

    /// One received episode per CallKit UUID. `dialId` remains correlation data, never the ownership key: two pushes
    /// that repeat a dial id cannot consume or substitute each other's state across CallKit episodes.
    private var pending: [UUID: PendingDial] = [:]

    init(hydrate: @escaping (DialReceiveState) async throws -> RenderableRing,
         runDial: @escaping (RenderableRing, UUID) async -> DialOutcome,
         endCall: @escaping (UUID) -> Void) {
        self.hydrate = hydrate
        self.runDial = runDial
        self.endCall = endCall
    }

    /// PUSH-RECEIVE: store the decoded state so the ANSWER can branch/hydrate it. (Wired from SentiCallKit's
    /// receive-hook; the LEAN push carries only id+core, the governed content is fetched at answer.)
    func received(_ state: DialReceiveState, dialId: String, callUUID: UUID) {
        pending[callUUID] = PendingDial(dialId: dialId, state: state)
    }

    func discard(callUUID: UUID) {
        pending.removeValue(forKey: callUUID)
    }

    func discardAll() {
        pending.removeAll()
    }

    /// ANSWER (SentiCallManager.onAnswered → this, via `dialId` + the CallKit UUID): hydrate the stored state
    /// (security gate) and run the governed flow. Always ends the call on a terminal outcome. Returns the outcome
    /// (for logging/tests). NEVER posts on a missing state or a hydration refusal — those decline with nothing
    /// posted or queued. Takes plain `dialId`/`callUUID` (not the CallKit-guarded IncomingDecisionCall) so the core
    /// compiles + tests without CallKit; the SentiCallKit glue passes `call.dialId` + `call.id`.
    @discardableResult
    func answered(dialId: String, callUUID: UUID) async -> DialOutcome {
        defer { endCall(callUUID) }
        guard !Task.isCancelled else {
            discard(callUUID: callUUID)
            return .declined("call ended before hydration")
        }
        guard let episode = pending.removeValue(forKey: callUUID),
              episode.dialId == dialId else {
            return .declined("no ring state for dial \(dialId)")
        }
        let ring: RenderableRing
        do {
            ring = try await hydrate(episode.state)
        } catch {
            // Substitution refused / absent / unauthorized / unavailable — honest decline, nothing posted.
            return .declined("hydration failed: \(error.localizedDescription)")
        }
        guard !Task.isCancelled else {
            return .declined("call ended during hydration")
        }
        return await runDial(ring, callUUID)
    }
}
