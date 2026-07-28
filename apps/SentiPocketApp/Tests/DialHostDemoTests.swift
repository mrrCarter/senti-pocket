#if canImport(CallKit) && canImport(PushKit)
import XCTest
@testable import SentiPocketApp

/// DialHost foreground demo gate (spec A, P0-3): the demo-dial trigger is DEFAULT OFF — with the app's committed
/// Info.plist (POCKET_DEMO_DIAL_ENABLED = false) there is NO ring and no self-ring path. A dedicated demo build flips
/// the flag to expose the trigger.
@MainActor
final class DialHostDemoTests: XCTestCase {

    func test_demo_dial_disabled_by_default() {
        XCTAssertFalse(DialHost.demoDialEnabled, "POCKET_DEMO_DIAL_ENABLED must default OFF in the committed build")
    }

    func test_triggerDemoDialIfEnabled_presents_no_ring_when_disabled() {
        let host = DialHost()
        XCTAssertFalse(host.triggerDemoDialIfEnabled(), "disabled → no ring presented (returns false)")
        XCTAssertEqual(host.callManager.endRouter.trackedCount, 0, "no call was tracked — nothing rang")
    }
}
#endif
