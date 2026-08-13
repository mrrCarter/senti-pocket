import Foundation
import PocketCall

// DialCoordinator — the app-lifetime owner that turns an ANSWERED DIALS ring into a governed-write flow (Forge,
// onAnswered hookup increment 2/2 + the app-seam teardown, spec B). It stores the LEAN/RICH `DialReceiveState`
// decoded at PUSH-RECEIVE (keyed by dialId), and on ANSWER HYDRATES it via atlas's DialHydrationClient
// (`.renderable`→no-fetch / `.needsHydration`→authed GET+merge / `.rejected`→refuse) then runs a generation-scoped
// EPISODE (brief→converse→dictate→confirm→post).
//
// EPISODE OWNERSHIP (spec B): the coordinator owns exactly ONE generation-scoped episode per CallKit UUID — a holder
// for the per-call run (the `DialRun`, which owns the run Task + the stoppable voice + the writer). A hangup / provider
// reset / report-failure arrives as a CallEndEvent → `endEpisode`, the SINGLE teardown owner: it cancels the run,
// stops synth + mic, tears down ONLY a pre-submit (unauthorized) writer draft, and discards UNANSWERED pending. A
// STALE run's late completion can never clear a REPLACEMENT episode (generation check), and a noncooperative hydrate
// can never start an already-ended episode (post-hydrate re-check).
//
// This file is the testable CORE: received→store / answered→hydrate→run→end + the teardown, over INJECTED seams
// (`hydrate` / `makeRun` / `endCall`) so the whole flow is unit-testable without CallKit, PushKit, network, whisper,
// or the reasoning gateway. The production wiring (real DialHydrationClient + the LiveDialRun composition + the
// SentiCallKit receive/answer/end hooks) is the thin glue DialHost supplies.
//
// SECURITY: `hydrate` is the substitution gate (DialHydration.merge refuses a fetched signal whose id/session/
// checkpoint ≠ the push core). A hydrate failure → `.declined`, NOTHING posted. No stored state for the answered
// dialId → `.declined`, NOTHING posted. The write only ever happens inside the episode's run → the SAME governed confirm.

/// One runnable, stoppable governed-dial run. Production impl (LiveDialRun) composes LiveDialVoice + PhoneWriteAdapter +
/// DialOrchestrator; a mock drives the coordinator's tests. The coordinator holds it as the per-call episode so a
/// teardown can stop it.
@MainActor
protocol DialRun: AnyObject {
    /// Drive the governed flow to a terminal outcome (honors cancellation as a decline that posts/queues nothing).
    func run() async -> DialOutcome
    /// Prompt, SYNCHRONOUS cooperative cancel of the run Task (a hangup → the run declines). Does NOT cancel an
    /// already-authorized governed write — that attempt is retained/reconciled by the writer.
    func cancel()
    /// Async teardown: stop synth + mic immediately, and cancel ONLY a PRE-SUBMIT (unauthorized) draft. An authorized
    /// in-flight write is RETAINED (an accepted server write cannot be retracted).
    func teardown() async
}

@MainActor
final class DialCoordinator: ObservableObject {
    /// Hydrate a received state into a renderable ring (atlas's DialHydrationClient.hydrate). Throws on refuse/absent.
    private let hydrate: (DialReceiveState) async throws -> RenderableRing
    /// Build the governed run for a hydrated ring (constructs LiveDialVoice+PhoneWriteAdapter+DialOrchestrator, wrapped
    /// as a stoppable DialRun). Injected so the coordinator's orchestration + teardown is testable in isolation.
    private let makeRun: (RenderableRing) -> DialRun
    /// End the CallKit call (SentiCallManager.end) once the flow reaches a terminal outcome.
    private let endCall: (UUID) -> Void

    /// DialReceiveState captured at push-receive, keyed by relay's dialId, consumed once on answer.
    private var pending: [String: DialReceiveState] = [:]

    /// One generation-scoped episode per CallKit UUID. A class (reference) so `answered` and `endEpisode` share the
    /// SAME instance — a teardown flips `ended`/stops `run` and the in-flight answer observes it.
    private final class Episode {
        let generation: Int
        let dialId: String
        var run: DialRun?
        var ended = false
        init(generation: Int, dialId: String) { self.generation = generation; self.dialId = dialId }
    }
    private var episodes: [UUID: Episode] = [:]
    /// Monotonic — every `answered` claims a fresh generation, so a superseded/stale run can be told apart from the
    /// current one when clearing shared state (a stale run must never clear a replacement).
    private var generationCounter = 0

    /// Test hook: how many episodes are currently retained (0 after every run + teardown has drained — no leak).
    var episodeCount: Int { episodes.count }

    init(hydrate: @escaping (DialReceiveState) async throws -> RenderableRing,
         makeRun: @escaping (RenderableRing) -> DialRun,
         endCall: @escaping (UUID) -> Void) {
        self.hydrate = hydrate
        self.makeRun = makeRun
        self.endCall = endCall
    }

    /// PUSH-RECEIVE: store the decoded state so the ANSWER can branch/hydrate it. (Wired from SentiCallKit's
    /// receive-hook; the LEAN push carries only id+core, the governed content is fetched at answer.)
    func received(_ state: DialReceiveState, dialId: String) {
        pending[dialId] = state
    }

    /// Discard UNANSWERED pending for a dialId (spec B): a decline / provider-reset BEFORE the ring is answered leaves
    /// nothing seeded to hydrate. Touches ONLY pending state — never a running episode.
    func discard(dialId: String) {
        pending[dialId] = nil
    }

    /// ANSWER (SentiCallManager.onAnswered → this, via `dialId` + the CallKit UUID): claim a generation, hydrate the
    /// stored state (security gate), then run the governed episode. Always ends the call on a terminal outcome. NEVER
    /// posts on a missing state or a hydration refusal — those decline with nothing posted or queued.
    @discardableResult
    func answered(dialId: String, callUUID: UUID) async -> DialOutcome {
        // MAX ONE live run per CallKit UUID (spec B, one episode): refuse a duplicate answer for a UUID that already has
        // a LIVE (not externally-ended) episode — do NOT start a second run and do NOT end the call (the live episode
        // owns its own terminal end; a duplicate must never orphan it). A stale/ended episode still draining is NOT
        // live and MAY be superseded below.
        if let existing = episodes[callUUID], !existing.ended {
            return .declined("call \(callUUID) already has a live episode")
        }

        generationCounter += 1
        let gen = generationCounter
        let episode = Episode(generation: gen, dialId: dialId)
        episodes[callUUID] = episode

        // Finalize (Pulse round-6 #2): the CURRENT generation ALWAYS clears its slot — regardless of `ended` — so an
        // external hangup/reset/failure never RETAINS the Episode → run → voice/writer indefinitely. It programmatically
        // endCalls ONLY when NOT externally ended (a hangup/reset already ended the call; re-ending could end a
        // replacement). A stale/superseded generation (the map moved on) clears nothing → a stale A cannot end/clear B.
        func finish(_ outcome: DialOutcome) -> DialOutcome {
            if let ep = episodes[callUUID], ep.generation == gen {
                let externallyEnded = ep.ended
                episodes[callUUID] = nil
                if !externallyEnded { endCall(callUUID) }
            }
            return outcome
        }

        guard let state = pending.removeValue(forKey: dialId) else {
            return finish(.declined("no ring state for dial \(dialId)"))
        }

        let ring: RenderableRing
        do {
            ring = try await hydrate(state)
        } catch {
            // Substitution refused / absent / unauthorized / unavailable — honest decline, nothing posted.
            return finish(.declined("hydration failed: \(error.localizedDescription)"))
        }

        // Re-check AFTER hydrate, BEFORE starting the run (spec B): a hangup during a (possibly noncooperative) hydrate
        // must NOT start an already-ended or superseded episode. No run was created yet → nothing to stop; just decline.
        guard let ep = episodes[callUUID], ep.generation == gen, !ep.ended else {
            return finish(.declined("episode ended before run"))
        }

        let run = makeRun(ring)
        ep.run = run
        // A teardown that landed between the guard and here set `ended` — honor it (stop the just-built run, no run()).
        if ep.ended { run.cancel(); await run.teardown(); return finish(.declined("episode ended before run")) }

        let outcome = await run.run()
        // finish() re-checks generation + ended POST-run: a run whose episode was ended/superseded WHILE running must
        // not clear a replacement or end a call it no longer owns.
        return finish(outcome)
    }

    /// TEARDOWN (spec B): a CallEndEvent (hangup / provider reset / report-failure) for a CallKit UUID. The SINGLE
    /// teardown owner — idempotent. Discards UNANSWERED pending for the ring, then (if an episode is live) marks it
    /// ended, cancels the run, and stops synth + mic + tears down an unauthorized writer draft. Does NOT clear the
    /// episode slot: the run's own `finish` clears it under a generation check, so a stale run can't clear a replacement.
    func endEpisode(callUUID: UUID, dialId: String?) {
        if let dialId { discard(dialId: dialId) }        // unanswered pending for this ring → gone
        guard let ep = episodes[callUUID], !ep.ended else { return }   // idempotent (no episode, or already torn down)
        ep.ended = true
        ep.run?.cancel()                                 // prompt cooperative cancel (pre-submit → decline, no post)
        if let run = ep.run {
            Task { await run.teardown() }                // stop synth + mic; cancel ONLY an unauthorized draft
        }
    }
}
