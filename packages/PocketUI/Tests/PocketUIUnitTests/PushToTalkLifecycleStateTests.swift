#if canImport(SwiftUI)
import XCTest
@testable import PocketUI

final class PushToTalkLifecycleStateTests: XCTestCase {
    func testPendingBeginIsEndedBeforeParentPublishesActiveState() {
        var state = PushToTalkLifecycleState()
        state.requestBegin()

        XCTAssertTrue(state.takeEndRequest(isActive: false, touchIsDown: false))
        XCTAssertFalse(state.takeEndRequest(isActive: false, touchIsDown: false))
    }

    func testActiveCaptureEndsExactlyOnceAcrossCompetingLifecycleCallbacks() {
        var state = PushToTalkLifecycleState()
        state.requestBegin()
        XCTAssertFalse(state.activeStateChanged(true))

        XCTAssertTrue(state.takeEndRequest(isActive: true, touchIsDown: false))
        XCTAssertFalse(state.takeEndRequest(isActive: true, touchIsDown: false))
        XCTAssertFalse(state.activeStateChanged(true))
    }

    func testLateActivationAfterPendingCancellationIsEndedExactlyOnce() {
        var state = PushToTalkLifecycleState()
        state.requestBegin()

        XCTAssertTrue(state.takeEndRequest(isActive: false, touchIsDown: false))
        XCTAssertFalse(state.takeEndRequest(isActive: false, touchIsDown: false))

        XCTAssertTrue(state.activeStateChanged(true))
        XCTAssertFalse(state.activeStateChanged(true))
        XCTAssertFalse(state.takeEndRequest(isActive: true, touchIsDown: false))
        XCTAssertFalse(state.takeEndRequest(isActive: true, touchIsDown: false))

        XCTAssertFalse(state.activeStateChanged(false))
        XCTAssertFalse(state.takeEndRequest(isActive: false, touchIsDown: false))
    }

    func testInactiveAcknowledgementAllowsFreshCapture() {
        var state = PushToTalkLifecycleState()
        state.requestBegin()
        XCTAssertTrue(state.takeEndRequest(isActive: false, touchIsDown: false))
        XCTAssertFalse(state.activeStateChanged(false))

        state.requestBegin()
        XCTAssertFalse(state.activeStateChanged(true))
        XCTAssertTrue(state.takeEndRequest(isActive: true, touchIsDown: false))
        XCTAssertFalse(state.takeEndRequest(isActive: true, touchIsDown: false))
    }

    func testInactiveControlDoesNotEmitSpuriousEnd() {
        var state = PushToTalkLifecycleState()

        XCTAssertFalse(state.takeEndRequest(isActive: false, touchIsDown: false))
    }
}
#endif
