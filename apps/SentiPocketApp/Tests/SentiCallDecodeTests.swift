#if canImport(CallKit) && canImport(PushKit)
import XCTest
@testable import SentiPocketApp

/// Locks SentiCallManager's decode (CallKit-ring DISPLAY) + receiveState (the DialReceiveState surfaced at push-receive).
/// The push fields are display-only — none drive the governed write (that's the hydrated ring via DialCoordinator).
@MainActor
final class SentiCallDecodeTests: XCTestCase {   // SentiCallManager is @MainActor, so its static decode()/receiveState() are too

    // MARK: - decode display (part-b minor)

    func test_decode_prefers_callerName_over_who() {
        let call = SentiCallManager.decode([
            "id": "dial_1", "callerName": "claude-warden needs your decision", "who": "senti-pocket",
            "message": "", "priority": "high"
        ])
        XCTAssertEqual(call.dialId, "dial_1")
        XCTAssertEqual(call.callerDisplayName, "claude-warden needs your decision")
        XCTAssertEqual(call.priority, "high")
        XCTAssertEqual(call.message, "")   // a LEAN write-kind carries no push message
    }

    func test_decode_falls_back_who_then_default() {
        let noName = SentiCallManager.decode(["id": "dial_2", "who": "senti-pocket", "message": "", "priority": "low"])
        XCTAssertEqual(noName.callerDisplayName, "senti-pocket")
        let bare = SentiCallManager.decode(["id": "dial_3", "message": "", "priority": "medium"])
        XCTAssertEqual(bare.callerDisplayName, "Senti — decision needed")
    }

    func test_decode_invalid_priority_defaults_medium() {
        let call = SentiCallManager.decode(["id": "dial_4", "callerName": "Senti", "message": "", "priority": "BOGUS"])
        XCTAssertEqual(call.priority, "medium")
    }

    // MARK: - receiveState: the ENVELOPED device round-trip (part-b criterion #6, relay's shared fixture)

    /// Walk up from this source file to relay's committed gateway fixtures (zero-copy, single source of truth).
    private func loadFixture(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        var dir = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("services/pocket-gateway/test/fixtures/\(name)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let data = try Data(contentsOf: candidate)
                return try (JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            }
            dir.deleteLastPathComponent()
        }
        XCTFail("fixture \(name) not found walking up from \(file) — needs relay's committed gateway fixture", file: file, line: line)
        return [:]
    }

    /// POSITIVE (test b): the deploy wraps the BARE buildDialPayload DTO as { aps, ...dial-fields-TOP-LEVEL }. For every
    /// #96 KAV case, receiveState must serialize + decode that envelope → dialId == payload.id and state == (fetch ?
    /// .needsHydration : .renderable). Covers rich_info (fetch=false → .renderable), which the inline LEAN test did not.
    func test_receiveState_enveloped_roundtrip_covers_all_KAV_cases() throws {
        let env = try loadFixture("dial-push-envelope-v1.json")
        let src = try loadFixture("dial-payload-v1.json")
        guard let aps = env["apsEnvelope"] as? [String: Any] else { return XCTFail("envelope fixture missing apsEnvelope") }
        guard let cases = src["cases"] as? [String: Any], !cases.isEmpty else { return XCTFail("source KAV cases missing") }
        for (name, raw) in cases {
            guard let c = raw as? [String: Any], let payload = c["payload"] as? [String: Any] else {
                return XCTFail("case \(name): missing payload")
            }
            var enveloped: [AnyHashable: Any] = payload   // dial fields spread TOP-LEVEL...
            enveloped["aps"] = aps                         // ...alongside the aps envelope (the real device shape)
            guard let (state, dialId) = SentiCallManager.receiveState(from: enveloped) else {
                return XCTFail("case \(name): enveloped push should decode")
            }
            XCTAssertEqual(dialId, payload["id"] as? String, "case \(name): dialId")
            let fetch = (payload["fetch"] as? Bool) ?? false
            if fetch {
                guard case .needsHydration = state else { return XCTFail("case \(name): fetch=true must be .needsHydration, got \(state)") }
            } else {
                guard case .renderable = state else { return XCTFail("case \(name): fetch=false must be .renderable, got \(state)") }
            }
        }
    }

    /// NEGATIVE (test b): nesting the DTO under a wrong-placement key ({aps, payload:<DTO>}) → top-level id absent →
    /// nil (no ring stored). The naive apnsSend that nests under the field literally named `payload` would silently
    /// drop EVERY ring in production — this catches it. Keys single-sourced from the fixture's wrongPlacementKeys.
    func test_receiveState_nil_when_dto_nested_under_wrong_key() throws {
        let env = try loadFixture("dial-push-envelope-v1.json")
        let src = try loadFixture("dial-payload-v1.json")
        guard let aps = env["apsEnvelope"] as? [String: Any],
              let wrongKeys = env["wrongPlacementKeys"] as? [String],
              let anyCase = (src["cases"] as? [String: Any])?.values.first as? [String: Any],
              let payload = anyCase["payload"] as? [String: Any] else { return XCTFail("fixtures missing fields") }
        XCTAssertFalse(wrongKeys.isEmpty)
        for k in wrongKeys {
            let nested: [AnyHashable: Any] = ["aps": aps, k: payload]
            XCTAssertNil(SentiCallManager.receiveState(from: nested), "nesting under \(k) must yield nil (no top-level id)")
        }
    }

    // THROW-GUARD (warden #5b; atlas + relay independently): data(withJSONObject:) raises an NSException — NOT a Swift
    // error, so try? would NOT catch it → CRASH on a malformed push. isValidJSONObject guards it to the fail-safe nil.
    func test_receiveState_nil_on_nonconforming_dict_no_crash() {
        let bad: [AnyHashable: Any] = ["id": "dial_x", "createdAt": Date()]  // Date is not JSON-serializable
        XCTAssertNil(SentiCallManager.receiveState(from: bad))               // fail-safe nil, NEVER a crash
    }
}
#endif
