import XCTest
@testable import SentiPocketApp

/// CallEndRouter (spec B): the ONE idempotent teardown path CXEndCallAction, providerDidReset, AND a
/// reportNewIncomingCall failure all funnel through — so every way a call dies runs identical cleanup EXACTLY once.
/// Pure (no CallKit), so it is unit-testable without a live CXProvider. These tests drive it directly; SentiCallManager
/// forwards its resolved CallEndEvent to `onEndEvent` (the last test), and its CXEndCallAction/providerDidReset/
/// report-failure paths all call `teardown`/`teardownAll` on this same router.
@MainActor
final class SentiCallEndRouterTests: XCTestCase {

    func test_teardown_fires_once_with_the_resolved_event_then_is_idempotent() {
        let router = CallEndRouter()
        var events: [CallEndEvent] = []
        router.onEnd = { events.append($0) }
        let u = UUID()
        router.track(callUUID: u, dialId: "dial_1")
        XCTAssertEqual(router.trackedCount, 1)

        router.teardown(callUUID: u)
        XCTAssertEqual(events, [CallEndEvent(callUUID: u, dialId: "dial_1")])  // dialId resolved BEFORE the call is forgotten
        XCTAssertEqual(router.trackedCount, 0)

        router.teardown(callUUID: u)                 // second end for the same UUID — harmless no-op
        XCTAssertEqual(events.count, 1, "teardown must fire at most once per call")
    }

    // providerDidReset fans out over ALL tracked calls through the SAME idempotent teardown.
    func test_teardownAll_fans_out_over_every_tracked_call() {
        let router = CallEndRouter()
        var ended: Set<UUID> = []
        router.onEnd = { ended.insert($0.callUUID) }
        let a = UUID(), b = UUID()
        router.track(callUUID: a, dialId: "da")
        router.track(callUUID: b, dialId: "db")

        router.teardownAll()
        XCTAssertEqual(ended, [a, b], "a reset must tear down every live call")
        XCTAssertEqual(router.trackedCount, 0)
    }

    // A flow-initiated (programmatic) end is SWALLOWED — the completing episode must not be recursively self-cancelled.
    func test_programmatic_end_swallows_the_following_teardown() {
        let router = CallEndRouter()
        var events: [CallEndEvent] = []
        router.onEnd = { events.append($0) }
        let u = UUID()
        router.track(callUUID: u, dialId: "d")
        router.markProgrammaticEnd(callUUID: u)      // SentiCallManager.end → the flow's OWN terminal hangup
        router.teardown(callUUID: u)                 // the follow-on end must NOT fan out
        XCTAssertTrue(events.isEmpty, "a programmatic end must not fire an external teardown")
        XCTAssertEqual(router.trackedCount, 0)
    }

    func test_teardown_of_untracked_call_is_noop() {
        let router = CallEndRouter()
        var count = 0
        router.onEnd = { _ in count += 1 }
        router.teardown(callUUID: UUID())            // never tracked
        XCTAssertEqual(count, 0)
    }

    // SentiCallManager forwards the router's resolved end to onEndEvent (the init wiring that DialHost.endEpisode reads).
    func test_manager_forwards_router_end_to_onEndEvent() {
        let cm = SentiCallManager()
        var events: [CallEndEvent] = []
        cm.onEndEvent = { events.append($0) }
        let u = UUID()
        cm.endRouter.track(callUUID: u, dialId: "d")
        cm.endRouter.teardown(callUUID: u)
        XCTAssertEqual(events, [CallEndEvent(callUUID: u, dialId: "d")])
    }
}
