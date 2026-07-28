import XCTest
import PocketCall
@testable import SentiPocketApp

final class DialCoordinatorTests: XCTestCase {

    /// A stoppable mock run: records run/cancel/teardown, and can BLOCK inside run() until cancelled/opened so a test
    /// can hang up mid-run. cancel() unblocks the run (like the orchestrator's cooperative cancellation → decline).
    @MainActor
    final class MockRun: DialRun {
        let ring: RenderableRing
        let outcome: DialOutcome
        let blocks: Bool
        private(set) var runCalls = 0
        private(set) var cancelled = false
        private(set) var tornDown = false
        private var gate: CheckedContinuation<Void, Never>?
        private var opened = false
        init(ring: RenderableRing, outcome: DialOutcome, blocks: Bool) {
            self.ring = ring; self.outcome = outcome; self.blocks = blocks
        }
        func run() async -> DialOutcome {
            runCalls += 1
            if blocks && !opened { await withCheckedContinuation { gate = $0 } }
            return cancelled ? .declined("cancelled") : outcome
        }
        func open() { opened = true; gate?.resume(); gate = nil }
        func cancel() { cancelled = true; open() }
        func teardown() async { tornDown = true }
    }

    final class Recorder: @unchecked Sendable {
        var ranRings: [RenderableRing] = []
        var endedCalls: [UUID] = []
        var runs: [MockRun] = []
    }

    private func core(_ id: String = "need_1", session: String = "6cf7e861", cp: String? = "cp_9") -> RingCore {
        RingCore(id: id, kind: "decisionYours", priority: "high", callerName: "Senti", sessionId: session, checkpointId: cp)
    }
    private func ring(_ id: String = "need_1", message: String = "Ship it?") -> RenderableRing {
        RenderableRing(core: core(id), message: message, options: [], evidenceSeqs: [], confidence: 0.9)
    }
    private func state(_ id: String = "need_1") -> DialReceiveState {
        .needsHydration(id: id, core: core(id))
    }

    @MainActor
    private func make(_ rec: Recorder,
                      outcome: DialOutcome = .posted,
                      blocks: Bool = false,
                      hydrate: @escaping (DialReceiveState) async throws -> RenderableRing) -> DialCoordinator {
        DialCoordinator(
            hydrate: hydrate,
            makeRun: { r in
                rec.ranRings.append(r)
                let run = MockRun(ring: r, outcome: outcome, blocks: blocks)
                rec.runs.append(run)
                return run
            },
            endCall: { rec.endedCalls.append($0) }
        )
    }

    // MARK: - Answer flow (unchanged invariants over the new makeRun seam)

    // CRITICAL: no stored state (a stray/duplicate answer) → declined, the governed run is NEVER built, call ends.
    @MainActor
    func test_answered_without_stored_state_declines_and_never_runs() async {
        let rec = Recorder(); let uuid = UUID()
        let c = make(rec, hydrate: { _ in XCTFail("must not hydrate without stored state"); return self.ring() })
        let out = await c.answered(dialId: "need_x", callUUID: uuid)
        if case .declined = out {} else { return XCTFail("expected declined") }
        XCTAssertTrue(rec.ranRings.isEmpty)     // never built a run
        XCTAssertEqual(rec.endedCalls, [uuid])  // call ended
    }

    // CRITICAL: a hydration failure (substitution refusal / 410 unavailable / notLoggedIn) → declined, NEVER runs.
    @MainActor
    func test_answered_hydration_failure_declines_and_never_runs() async {
        struct Boom: Error {}
        let rec = Recorder(); let uuid = UUID()
        let c = make(rec, hydrate: { _ in throw Boom() })
        c.received(state("need_1"), dialId: "need_1")
        let out = await c.answered(dialId: "need_1", callUUID: uuid)
        if case .declined = out {} else { return XCTFail("hydration failure must decline") }
        XCTAssertTrue(rec.ranRings.isEmpty)     // NEVER built a run on a refused/failed hydrate
        XCTAssertEqual(rec.endedCalls, [uuid])
    }

    // Happy path: hydrate → run the HYDRATED ring → return its outcome → end the call, EXACTLY ONE run.
    @MainActor
    func test_answered_happy_hydrates_runs_once_and_ends() async {
        let rec = Recorder(); let uuid = UUID()
        let r = ring("need_1", message: "Rotate the token?")
        let c = make(rec, outcome: .posted, hydrate: { _ in r })
        c.received(state("need_1"), dialId: "need_1")
        let out = await c.answered(dialId: "need_1", callUUID: uuid)
        XCTAssertEqual(out, .posted)
        XCTAssertEqual(rec.runs.count, 1)                                // exactly ONE owned run (no PushKit)
        XCTAssertEqual(rec.runs.first?.runCalls, 1)
        XCTAssertEqual(rec.ranRings.first?.message, "Rotate the token?")  // the HYDRATED ring reached the run
        XCTAssertEqual(rec.endedCalls, [uuid])
    }

    @MainActor
    func test_answered_passes_through_the_run_outcome() async {
        let rec = Recorder()
        let c = make(rec, outcome: .pending("offline"), hydrate: { _ in self.ring() })
        c.received(state("need_1"), dialId: "need_1")
        let out = await c.answered(dialId: "need_1", callUUID: UUID())
        XCTAssertEqual(out, .pending("offline"))
    }

    // The stored state is consumed once — a second answer for the same dialId finds nothing (no double-post).
    @MainActor
    func test_answered_consumes_stored_state_once() async {
        let rec = Recorder()
        let c = make(rec, hydrate: { _ in self.ring() })
        c.received(state("need_1"), dialId: "need_1")
        _ = await c.answered(dialId: "need_1", callUUID: UUID())
        let out2 = await c.answered(dialId: "need_1", callUUID: UUID())
        if case .declined = out2 {} else { return XCTFail("2nd answer must find no state") }
        XCTAssertEqual(rec.runs.count, 1)  // ran exactly once — no double-post
    }

    // Reachability contract (spec A): presentForegroundDial does received() BEFORE the ring, so the ANSWER finds
    // seeded pending state and runs the pickup — instead of the orphan decline (dialId="demo" that seeded nothing).
    // This mirrors that ordering: seed (.renderable, as the demo factory produces) THEN answer → the run is reached.
    @MainActor
    func test_seed_before_answer_reaches_the_run_not_an_orphan_decline() async {
        let rec = Recorder(); let uuid = UUID()
        let c = make(rec, outcome: .posted, hydrate: { s in
            guard case .renderable(let r) = s else { XCTFail("a demo seed is .renderable"); return self.ring() }
            return r   // .renderable hydrates trivially (no fetch) — the DialHydrationClient passthrough
        })
        let demoRing = self.ring("demo-1", message: "Ship the release?")
        c.received(.renderable(demoRing), dialId: "demo-1")            // presentForegroundDial: received FIRST …
        let out = await c.answered(dialId: "demo-1", callUUID: uuid)   // … THEN the ring is answered
        XCTAssertEqual(out, .posted)
        XCTAssertEqual(rec.runs.count, 1, "the seeded ring reached the pickup run (no orphan decline)")
        XCTAssertEqual(rec.ranRings.first?.core.id, "demo-1")
    }

    // MARK: - discard / endEpisode (spec A/B teardown)

    // discard(dialId:) cleans UNANSWERED pending only — a subsequent answer then declines (nothing to run).
    @MainActor
    func test_discard_removes_unanswered_pending() async {
        let rec = Recorder(); let uuid = UUID()
        let c = make(rec, hydrate: { _ in XCTFail("discarded pending must not hydrate"); return self.ring() })
        c.received(state("need_1"), dialId: "need_1")
        c.discard(dialId: "need_1")
        let out = await c.answered(dialId: "need_1", callUUID: uuid)
        if case .declined = out {} else { return XCTFail("discarded → declined") }
        XCTAssertTrue(rec.ranRings.isEmpty)
    }

    // A decline/reset BEFORE answer (CallEndEvent with a dialId, no live episode) discards the pending ring.
    @MainActor
    func test_endEpisode_before_answer_discards_pending() async {
        let rec = Recorder(); let uuid = UUID()
        let c = make(rec, hydrate: { _ in XCTFail("must not hydrate a discarded ring"); return self.ring() })
        c.received(state("need_1"), dialId: "need_1")
        c.endEpisode(callUUID: uuid, dialId: "need_1")   // hangup/reset before the answer
        let out = await c.answered(dialId: "need_1", callUUID: uuid)
        if case .declined = out {} else { return XCTFail("declined after pending discarded") }
        XCTAssertTrue(rec.ranRings.isEmpty)
    }

    // END DURING A BLOCKED RUN: the single owned run is cancelled + torn down (stop synth+mic), drained exactly once.
    @MainActor
    func test_end_during_blocked_run_cancels_tears_down_and_drains_once() async {
        let rec = Recorder(); let uuid = UUID()
        let c = make(rec, outcome: .posted, blocks: true, hydrate: { _ in self.ring() })
        c.received(state("need_1"), dialId: "need_1")
        let answerTask = Task { await c.answered(dialId: "need_1", callUUID: uuid) }
        while rec.runs.isEmpty { await Task.yield() }    // let answered → hydrate → makeRun → run() reach the gate
        XCTAssertEqual(rec.runs.first?.runCalls, 1)

        c.endEpisode(callUUID: uuid, dialId: "need_1")   // HANG UP mid-run
        let out = await answerTask.value

        for _ in 0..<8 { await Task.yield() }            // let the teardown Task run
        XCTAssertEqual(rec.runs.count, 1)                // exactly one owned run
        XCTAssertTrue(rec.runs.first!.cancelled, "hangup must cancel the run")
        XCTAssertTrue(rec.runs.first!.tornDown, "hangup must tear down (stop synth+mic + writer)")
        if case .declined = out {} else { XCTFail("a cancelled run declines — nothing posted") }
        XCTAssertEqual(rec.endedCalls, [uuid])
    }

    // endEpisode is IDEMPOTENT — a second end for the same UUID does not re-tear-down or double-end.
    @MainActor
    func test_endEpisode_is_idempotent() async {
        let rec = Recorder(); let uuid = UUID()
        let c = make(rec, outcome: .posted, blocks: true, hydrate: { _ in self.ring() })
        c.received(state("need_1"), dialId: "need_1")
        let answerTask = Task { await c.answered(dialId: "need_1", callUUID: uuid) }
        while rec.runs.isEmpty { await Task.yield() }
        c.endEpisode(callUUID: uuid, dialId: "need_1")
        c.endEpisode(callUUID: uuid, dialId: "need_1")   // second end — must be a harmless no-op
        _ = await answerTask.value
        for _ in 0..<8 { await Task.yield() }
        XCTAssertEqual(rec.runs.count, 1)
        XCTAssertEqual(rec.endedCalls, [uuid])           // endCall fired exactly once
    }

    // REPLACEMENT GENERATION: a stale episode's LATE completion must not clear a replacement episode — the replacement
    // survives + is still tearable-down. (Same CallKit UUID is contrived, but directly exercises the generation guard.)
    @MainActor
    func test_replacement_generation_survives_stale_late_completion() async {
        let rec = Recorder(); let uuid = UUID()
        let c = make(rec, outcome: .posted, blocks: true, hydrate: { s in
            // hydrate to a ring whose id echoes the requested dialId
            if case .needsHydration(let id, let core) = s {
                return RenderableRing(core: core, message: "m-\(id)", options: [], evidenceSeqs: [], confidence: nil)
            }
            return self.ring()
        })
        c.received(state("d1"), dialId: "d1")
        c.received(state("d2"), dialId: "d2")

        let t1 = Task { await c.answered(dialId: "d1", callUUID: uuid) }   // gen1
        while rec.runs.count < 1 { await Task.yield() }
        let t2 = Task { await c.answered(dialId: "d2", callUUID: uuid) }   // gen2 REPLACES episodes[uuid]
        while rec.runs.count < 2 { await Task.yield() }

        // gen1 completes LATE (after gen2 installed). Its finish() must NOT clear episodes[uuid] (that slot is gen2 now).
        rec.runs[0].open()
        _ = await t1.value

        // Prove gen2 survived: it is still the live episode, so a hangup now tears DOWN run2 (would no-op if cleared).
        c.endEpisode(callUUID: uuid, dialId: "d2")
        _ = await t2.value
        for _ in 0..<8 { await Task.yield() }
        XCTAssertTrue(rec.runs[1].tornDown, "replacement (gen2) run must still be torn down — it was not cleared by the stale gen1")
        XCTAssertTrue(rec.runs[1].cancelled)
    }
}
