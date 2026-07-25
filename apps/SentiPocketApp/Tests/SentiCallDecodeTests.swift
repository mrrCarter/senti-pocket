#if canImport(CallKit) && canImport(PushKit)
import XCTest
@testable import SentiPocketApp

/// Locks SentiCallManager.decode's CallKit-ring DISPLAY choice (part-b minor): prefer the nicer `callerName` over
/// the terse `who`, then fall back. The push fields are display-only — none of these drive the governed write
/// (that's the hydrated ring, via DialCoordinator), so this is a UX assertion, not a consent one.
final class SentiCallDecodeTests: XCTestCase {

    func test_decode_prefers_callerName_over_who() {
        let call = SentiCallManager.decode([
            "id": "dial_1",
            "callerName": "claude-warden needs your decision",
            "who": "senti-pocket",
            "message": "",              // write-kinds ship LEAN → message shed; must NOT crash the display
            "priority": "high"
        ])
        XCTAssertEqual(call.dialId, "dial_1")
        XCTAssertEqual(call.callerDisplayName, "claude-warden needs your decision")
        XCTAssertEqual(call.priority, "high")
        XCTAssertEqual(call.message, "")   // sanity: a LEAN write-kind carries no push message
    }

    func test_decode_falls_back_who_then_default() {
        let noName = SentiCallManager.decode(["id": "dial_2", "who": "senti-pocket", "message": "", "priority": "low"])
        XCTAssertEqual(noName.callerDisplayName, "senti-pocket")   // no callerName → who

        let bare = SentiCallManager.decode(["id": "dial_3", "message": "", "priority": "medium"])
        XCTAssertEqual(bare.callerDisplayName, "Senti — decision needed")   // no callerName/who/message → default
    }

    func test_decode_invalid_priority_defaults_medium() {
        let call = SentiCallManager.decode(["id": "dial_4", "callerName": "Senti", "message": "", "priority": "BOGUS"])
        XCTAssertEqual(call.priority, "medium")
    }
}
#endif
