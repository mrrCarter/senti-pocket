#if canImport(CallKit) && canImport(PushKit)
import XCTest
@testable import SentiPocketApp

/// DialHost foreground demo gate (spec A + Pulse round-7 #3): DEFAULT OFF (no ring); when ENABLED the trigger fires
/// EXACTLY ONE ring and marks the dialId read-only (mark-demo → seed/received → ring, via presentForegroundDial). The
/// enabled path is exercised via the test override — the SAME `demoDialEnabled` gate the demo button reads.
@MainActor
final class DialHostDemoTests: XCTestCase {

    override func tearDown() { DialHost.demoDialEnabledOverride = nil; super.tearDown() }

    func test_demo_dial_disabled_by_default() {
        DialHost.demoDialEnabledOverride = nil
        XCTAssertFalse(DialHost.demoDialEnabled, "POCKET_DEMO_DIAL_ENABLED must default OFF in the committed build")
    }

    func test_triggerDemoDialIfEnabled_presents_no_ring_when_disabled() {
        DialHost.demoDialEnabledOverride = false
        let host = DialHost()
        XCTAssertFalse(host.triggerDemoDialIfEnabled(), "disabled → no ring presented (returns false)")
        XCTAssertEqual(host.callManager.endRouter.trackedCount, 0, "no call was tracked — nothing rang")
        XCTAssertEqual(host.demoRegistry.ids.count, 0, "nothing marked read-only")
    }

    // ENABLED demo: the gate ON → the trigger fires EXACTLY ONE ring and marks the dialId read-only (mark-demo happens
    // synchronously BEFORE the ring, so the ring can never be built as a writing episode). This is the actual trigger
    // the demo button invokes.
    func test_enabled_demo_triggers_exactly_one_ring_and_marks_read_only() {
        DialHost.demoDialEnabledOverride = true
        let host = DialHost()
        XCTAssertTrue(DialHost.demoDialEnabled, "the override enables the gate")
        XCTAssertTrue(host.triggerDemoDialIfEnabled(), "enabled → the trigger fires")
        XCTAssertEqual(host.callManager.endRouter.trackedCount, 1, "exactly ONE ring presented")
        XCTAssertEqual(host.demoRegistry.ids.count, 1, "the dialId is marked read-only (mark-demo happened before ring)")
    }
}
#endif
