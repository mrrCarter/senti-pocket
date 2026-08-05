import XCTest
import PocketCall
@testable import SentiPocketApp

final class DialCoordinatorTests: XCTestCase {

    /// Records what the coordinator did: which rings reached the governed run, and which calls were ended.
    final class Recorder: @unchecked Sendable {
        var ranRings: [RenderableRing] = []
        var endedCalls: [UUID] = []
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
                      hydrate: @escaping (DialReceiveState) async throws -> RenderableRing) -> DialCoordinator {
        DialCoordinator(
            hydrate: hydrate,
            runDial: { r, _ in rec.ranRings.append(r); return outcome },
            endCall: { rec.endedCalls.append($0) }
        )
    }

    // CRITICAL: no stored state (a stray/duplicate answer) → declined, the governed run is NEVER reached, call ends.
    @MainActor
    func test_answered_without_stored_state_declines_and_never_runs() async {
        let rec = Recorder(); let uuid = UUID()
        let c = make(rec, hydrate: { _ in XCTFail("must not hydrate without stored state"); return self.ring() })
        let out = await c.answered(dialId: "need_x", callUUID: uuid)
        if case .declined = out {} else { return XCTFail("expected declined") }
        XCTAssertTrue(rec.ranRings.isEmpty)     // never posted
        XCTAssertEqual(rec.endedCalls, [uuid])  // call ended
    }

    // CRITICAL: a hydration failure (substitution refusal / 410 unavailable / notLoggedIn) → declined, NEVER runs.
    // This is the security gate: a refused/absent hydrate posts nothing.
    @MainActor
    func test_answered_hydration_failure_declines_and_never_runs() async {
        struct Boom: Error {}
        let rec = Recorder(); let uuid = UUID()
        let c = make(rec, hydrate: { _ in throw Boom() })
        c.received(state("need_1"), dialId: "need_1", callUUID: uuid)
        let out = await c.answered(dialId: "need_1", callUUID: uuid)
        if case .declined = out {} else { return XCTFail("hydration failure must decline") }
        XCTAssertTrue(rec.ranRings.isEmpty)     // NEVER posted on a refused/failed hydrate
        XCTAssertEqual(rec.endedCalls, [uuid])
    }

    // Happy path: hydrate → run the HYDRATED ring → return its outcome → end the call.
    @MainActor
    func test_answered_happy_hydrates_runs_and_ends() async {
        let rec = Recorder(); let uuid = UUID()
        let r = ring("need_1", message: "Rotate the token?")
        let c = make(rec, outcome: .posted, hydrate: { _ in r })
        c.received(state("need_1"), dialId: "need_1", callUUID: uuid)
        let out = await c.answered(dialId: "need_1", callUUID: uuid)
        XCTAssertEqual(out, .posted)
        XCTAssertEqual(rec.ranRings.count, 1)
        XCTAssertEqual(rec.ranRings.first?.message, "Rotate the token?")  // the HYDRATED ring reached runDial
        XCTAssertEqual(rec.endedCalls, [uuid])
    }

    // The runDial outcome is what the coordinator returns (e.g. offline → pending, refused → declined) — passthrough.
    @MainActor
    func test_answered_passes_through_the_run_outcome() async {
        let rec = Recorder()
        let c = make(rec, outcome: .pending("offline"), hydrate: { _ in self.ring() })
        let uuid = UUID()
        c.received(state("need_1"), dialId: "need_1", callUUID: uuid)
        let out = await c.answered(dialId: "need_1", callUUID: uuid)
        XCTAssertEqual(out, .pending("offline"))
    }

    // The stored state is consumed once — a second answer for the same dialId finds nothing (no double-post).
    @MainActor
    func test_answered_consumes_stored_state_once() async {
        let rec = Recorder()
        let c = make(rec, hydrate: { _ in self.ring() })
        let uuid = UUID()
        c.received(state("need_1"), dialId: "need_1", callUUID: uuid)
        _ = await c.answered(dialId: "need_1", callUUID: uuid)
        let out2 = await c.answered(dialId: "need_1", callUUID: uuid)
        if case .declined = out2 {} else { return XCTFail("2nd answer must find no state") }
        XCTAssertEqual(rec.ranRings.count, 1)  // ran exactly once — no double-post
    }

    @MainActor
    func test_same_dial_id_cannot_cross_callkit_episode() async {
        let rec = Recorder()
        let storedUUID = UUID()
        let foreignUUID = UUID()
        let c = make(rec, hydrate: { _ in self.ring() })
        c.received(state("need_1"), dialId: "need_1", callUUID: storedUUID)

        let foreign = await c.answered(dialId: "need_1", callUUID: foreignUUID)
        if case .declined = foreign {} else { return XCTFail("foreign UUID must not consume a repeated dial id") }
        XCTAssertTrue(rec.ranRings.isEmpty)

        let owner = await c.answered(dialId: "need_1", callUUID: storedUUID)
        XCTAssertEqual(owner, .posted)
        XCTAssertEqual(rec.ranRings.count, 1)
    }

    @MainActor
    func test_unicode_canonical_but_byte_distinct_dial_id_is_rejected() async {
        let composed = "need-caf\u{00E9}"
        let decomposed = "need-cafe\u{0301}"
        let rec = Recorder()
        let uuid = UUID()
        let coordinator = make(rec, hydrate: { _ in
            XCTFail("byte-distinct dial id must not hydrate")
            return self.ring()
        })
        coordinator.received(state(composed), dialId: composed, callUUID: uuid)

        let outcome = await coordinator.answered(dialId: decomposed, callUUID: uuid)
        if case .declined = outcome {} else { return XCTFail("byte-distinct dial id must decline") }
        XCTAssertTrue(rec.ranRings.isEmpty)

        var lifecycle = DialCallLifecycle()
        XCTAssertTrue(lifecycle.reported(callUUID: uuid, dialId: composed))
        XCTAssertEqual(
            lifecycle.answered(callUUID: uuid, dialId: decomposed, revision: 1),
            .rejected
        )
    }

    @MainActor
    func test_discarded_episode_cannot_hydrate_or_run() async {
        let rec = Recorder()
        let uuid = UUID()
        let c = make(rec, hydrate: { _ in
            XCTFail("discarded episode must not hydrate")
            return self.ring()
        })
        c.received(state("need_1"), dialId: "need_1", callUUID: uuid)
        c.discard(callUUID: uuid)

        let outcome = await c.answered(dialId: "need_1", callUUID: uuid)
        if case .declined = outcome {} else { return XCTFail("discarded episode must decline") }
        XCTAssertTrue(rec.ranRings.isEmpty)
        XCTAssertEqual(rec.endedCalls, [uuid])
    }
}
