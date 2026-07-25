#if canImport(CallKit) && canImport(PushKit)
import XCTest
@testable import SentiPocketApp

/// Locks SentiCallManager.decode's CallKit-ring DISPLAY choice (part-b minor): prefer the nicer `callerName` over
/// the terse `who`, then fall back. The push fields are display-only — none of these drive the governed write
/// (that's the hydrated ring, via DialCoordinator), so this is a UX assertion, not a consent one.
@MainActor
final class SentiCallDecodeTests: XCTestCase {   // SentiCallManager is @MainActor, so its static decode() is too

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

    // relay's find: the DEVICE receives an APNs-ENVELOPED dict { aps:{…}, <dial DTO top-level> }. receiveState must
    // serialize that + decode the top-level dial fields (aps ignored) → the LEAN write-kind ring. This is the
    // dict→Data→DialReceive.receive round-trip #96 (bare JSON) does NOT cover.
    func test_receiveState_from_enveloped_push_decodes_top_level_writekind_as_needsHydration() {
        let dict: [AnyHashable: Any] = [
            "aps": ["content-available": 1],
            "v": 1, "id": "dial_1", "kind": "decisionYours", "fetch": true,
            "priority": "high", "callerName": "claude-warden", "who": "senti-pocket",
            "sessionId": "6cf7e861", "ts": "2026-07-25T20:00:00Z"
        ]
        guard let (state, dialId) = SentiCallManager.receiveState(from: dict) else {
            return XCTFail("enveloped push should decode")
        }
        XCTAssertEqual(dialId, "dial_1")
        guard case .needsHydration(let id, _) = state else {
            return XCTFail("a LEAN write-kind must be .needsHydration, got \(state)")
        }
        XCTAssertEqual(id, "dial_1")   // top-level dial fields decoded; the `aps` envelope is ignored
    }

    // The DEPLOY-CONTRACT precondition: if the deploy NESTS the DTO ({aps, payload:{…}}) instead of top-level,
    // top-level `id` is absent → nil (no ring stored), NOT a silent wrong-decode. Pins apnsSend top-level placement.
    func test_receiveState_nil_when_dto_nested_not_top_level() {
        let nested: [AnyHashable: Any] = ["aps": ["content-available": 1], "payload": ["v": 1, "id": "dial_1", "fetch": true]]
        XCTAssertNil(SentiCallManager.receiveState(from: nested))
    }
}
#endif
