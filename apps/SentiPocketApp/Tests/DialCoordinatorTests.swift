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

    /// A bounded spin (P2: never an unbounded yield-loop). Fails the test rather than hanging if the condition never
    /// holds within a generous cooperative-yield budget.
    @MainActor
    private func spin(until cond: @escaping () -> Bool, _ message: String = "condition never held",
                      file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<10_000 { if cond() { return }; await Task.yield() }
        XCTFail("spin timed out: \(message)", file: file, line: line)
    }

    /// A MainActor gate a test can block/release (for a noncooperative hydrate).
    @MainActor
    final class Gate {
        private var cont: CheckedContinuation<Void, Never>?
        private var opened = false
        private(set) var entered = false
        func wait() async { entered = true; if opened { return }; await withCheckedContinuation { cont = $0 } }
        func open() { opened = true; cont?.resume(); cont = nil }
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

    // END DURING A BLOCKED RUN: the single owned run is cancelled + torn down (stop synth+mic), drained once. The
    // EXTERNAL teardown must NOT programmatically endCall (the system's hangup already ended the call).
    @MainActor
    func test_end_during_blocked_run_cancels_tears_down_and_drains_once() async {
        let rec = Recorder(); let uuid = UUID()
        let c = make(rec, outcome: .posted, blocks: true, hydrate: { _ in self.ring() })
        c.received(state("need_1"), dialId: "need_1")
        let answerTask = Task { await c.answered(dialId: "need_1", callUUID: uuid) }
        await spin(until: { !rec.runs.isEmpty }, "run never started")
        XCTAssertEqual(rec.runs.first?.runCalls, 1)

        c.endEpisode(callUUID: uuid, dialId: "need_1")   // HANG UP mid-run
        let out = await answerTask.value

        await spin(until: { rec.runs.first?.tornDown == true }, "teardown never ran")
        XCTAssertEqual(rec.runs.count, 1)                // exactly one owned run
        XCTAssertTrue(rec.runs.first!.cancelled, "hangup must cancel the run")
        XCTAssertTrue(rec.runs.first!.tornDown, "hangup must tear down (stop synth+mic + writer)")
        if case .declined = out {} else { XCTFail("a cancelled run declines — nothing posted") }
        XCTAssertTrue(rec.endedCalls.isEmpty, "an EXTERNAL teardown must NOT programmatically endCall (the system already did)")
        XCTAssertEqual(c.episodeCount, 0, "no Episode/run leak after an external end")
    }

    // endEpisode is IDEMPOTENT — a second end for the same UUID does not re-tear-down or double-anything.
    @MainActor
    func test_endEpisode_is_idempotent() async {
        let rec = Recorder(); let uuid = UUID()
        let c = make(rec, outcome: .posted, blocks: true, hydrate: { _ in self.ring() })
        c.received(state("need_1"), dialId: "need_1")
        let answerTask = Task { await c.answered(dialId: "need_1", callUUID: uuid) }
        await spin(until: { !rec.runs.isEmpty }, "run never started")
        c.endEpisode(callUUID: uuid, dialId: "need_1")
        c.endEpisode(callUUID: uuid, dialId: "need_1")   // second end — a harmless no-op
        _ = await answerTask.value
        await spin(until: { rec.runs.first?.tornDown == true }, "teardown never ran")
        XCTAssertEqual(rec.runs.count, 1)
        XCTAssertTrue(rec.endedCalls.isEmpty)            // never programmatically ended (external teardown)
        XCTAssertEqual(c.episodeCount, 0, "no Episode leak after idempotent ends")
    }

    // MAX ONE RUN: a duplicate answer for a UUID that already has a LIVE episode is refused — no second run — and the
    // live episode is NOT orphaned (it still tears down + drains).
    @MainActor
    func test_max_one_run_refuses_a_duplicate_live_uuid_without_orphaning() async {
        let rec = Recorder(); let uuid = UUID()
        let c = make(rec, outcome: .posted, blocks: true, hydrate: { s in
            if case .needsHydration(_, let core) = s { return RenderableRing(core: core, message: "m", options: [], evidenceSeqs: [], confidence: nil) }
            return self.ring()
        })
        c.received(state("d1"), dialId: "d1")
        c.received(state("d2"), dialId: "d2")
        let t1 = Task { await c.answered(dialId: "d1", callUUID: uuid) }   // A: live, blocked
        await spin(until: { rec.runs.count == 1 }, "A never ran")

        let dup = await c.answered(dialId: "d2", callUUID: uuid)           // duplicate answer, SAME live UUID
        if case .declined = dup {} else { XCTFail("a duplicate answer for a live UUID must decline") }
        XCTAssertEqual(rec.runs.count, 1, "no second run — max one run per UUID")
        XCTAssertFalse(rec.runs.first!.cancelled, "the duplicate must not disturb the live episode A")

        // A is NOT orphaned: its own hangup still tears it down + drains.
        c.endEpisode(callUUID: uuid, dialId: "d1")
        _ = await t1.value
        await spin(until: { rec.runs.first?.tornDown == true }, "A never torn down")
        XCTAssertTrue(rec.runs.first!.cancelled)
    }

    // END DURING A NONCOOPERATIVE HYDRATE: a hangup while hydrate is blocked must create NO run (the post-hydrate guard
    // sees the episode ended and declines before makeRun).
    @MainActor
    func test_end_during_noncooperative_hydrate_creates_no_run() async {
        let rec = Recorder(); let uuid = UUID()
        let gate = Gate()
        let c = make(rec, hydrate: { _ in await gate.wait(); return self.ring() })
        c.received(state("need_1"), dialId: "need_1")
        let answerTask = Task { await c.answered(dialId: "need_1", callUUID: uuid) }
        await spin(until: { gate.entered }, "hydrate never entered")

        c.endEpisode(callUUID: uuid, dialId: "need_1")   // HANG UP while hydrate is blocked
        gate.open()                                       // hydrate returns LATE (episode already ended)
        let out = await answerTask.value

        XCTAssertTrue(rec.runs.isEmpty, "a hangup during a noncooperative hydrate must create NO run")
        if case .declined = out {} else { XCTFail("declined — episode ended before run") }
        XCTAssertTrue(rec.endedCalls.isEmpty, "external teardown does not programmatically endCall")
        XCTAssertEqual(c.episodeCount, 0, "no Episode leak even when no run was created (end-during-hydrate)")
    }

    // LEAK GUARD (Pulse round-6 #2): after an external end drains a blocked run, the Episode + run are RELEASED — the
    // coordinator retains no episodes and the run's weak ref nils (no voice/writer held indefinitely); endCall count 0.
    @MainActor
    func test_external_end_releases_episode_and_run_no_leak() async {
        let rec = Recorder(); let uuid = UUID()
        weak var weakRun: MockRun?
        let c = DialCoordinator(
            hydrate: { _ in self.ring() },
            makeRun: { r in let run = MockRun(ring: r, outcome: .posted, blocks: true); weakRun = run; return run },  // NOT retained by rec
            endCall: { rec.endedCalls.append($0) })
        c.received(state("need_1"), dialId: "need_1")
        let t = Task { await c.answered(dialId: "need_1", callUUID: uuid) }
        await spin(until: { weakRun != nil }, "run never created")

        c.endEpisode(callUUID: uuid, dialId: "need_1")   // external hangup
        _ = await t.value

        await spin(until: { c.episodeCount == 0 && weakRun == nil }, "episode/run leaked after external end")
        XCTAssertEqual(c.episodeCount, 0, "no Episode retained")
        XCTAssertNil(weakRun, "the run (holding voice + writer) must be released — no indefinite retain")
        XCTAssertTrue(rec.endedCalls.isEmpty, "external end does not programmatically endCall")
    }

    // STALE ENDED EPISODE: after A is ENDED (torn down), a NEW answer B for the same UUID is allowed; A's completion
    // must NOT clear or end the replacement B (generation guard).
    @MainActor
    func test_stale_ended_episode_cannot_clear_or_end_replacement() async {
        let rec = Recorder(); let uuid = UUID()
        let c = make(rec, outcome: .posted, blocks: true, hydrate: { s in
            if case .needsHydration(let id, let core) = s { return RenderableRing(core: core, message: "m-\(id)", options: [], evidenceSeqs: [], confidence: nil) }
            return self.ring()
        })
        c.received(state("d1"), dialId: "d1")
        c.received(state("d2"), dialId: "d2")

        let t1 = Task { await c.answered(dialId: "d1", callUUID: uuid) }   // A (gen1), blocked
        await spin(until: { rec.runs.count == 1 }, "A never ran")
        c.endEpisode(callUUID: uuid, dialId: "d1")                         // END A → A.ended (its run cancels + drains)

        let t2 = Task { await c.answered(dialId: "d2", callUUID: uuid) }   // B (gen2) allowed: A is ended, not live
        await spin(until: { rec.runs.count == 2 }, "B never ran")

        _ = await t1.value                                                 // A completes — must not touch B's slot
        XCTAssertTrue(rec.endedCalls.isEmpty, "the stale A must NOT programmatically end B's call")

        // Prove B survived: it is still the live episode → a hangup now tears it down (would no-op if A had cleared it).
        c.endEpisode(callUUID: uuid, dialId: "d2")
        _ = await t2.value
        await spin(until: { rec.runs[1].tornDown }, "B never torn down")
        XCTAssertTrue(rec.runs[1].cancelled, "replacement B must still be tearable-down (the stale A did not clear it)")
    }
}
