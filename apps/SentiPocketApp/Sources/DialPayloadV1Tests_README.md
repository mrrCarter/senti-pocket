# DialPayloadV1 decoder — byte-parity + invariant tests (Atlas)

These tests belong in the app test target (forge wires the SentiPocketApp test target on Mac). They byte-match
relay's shared fixtures `services/pocket-gateway/test/fixtures/dial-payload-v1.json` (the KAV the gateway test locks),
and assert the load-bearing **fetch invariant** (LEAN → hydrate, never render pre-auth).

Because the app currently has no unit-test target wired (forge owns that), the test source is staged here as a
markdown-embedded Swift block so it's committed + reviewable now, and forge drops it into the test target when it
lands. The 5 fixture cases are the exact decode targets.

```swift
import XCTest
@testable import SentiPocketApp   // or the module that hosts DialPayloadV1

final class DialPayloadV1Tests: XCTestCase {
    private func decode(_ json: String) -> DialReceiveState {
        DialReceive.receive(Data(json.utf8))
    }

    // Fixture rich_decision (bytes 326): fetch=false, RICH → renderable with message + evidenceSeqs (deduped by gateway).
    func test_rich_decision_is_renderable() {
        let json = """
        {"v":1,"id":"need_1","kind":"decisionYours","priority":"high",
         "callerName":"Senti · claude-warden needs your decision","who":"senti-pocket",
         "sessionId":"6cf7e861","checkpointId":"cp_9","fetch":false,"ts":"2026-02-02T02:40:00.000Z",
         "message":"Ship the consolidation to master?","evidenceSeqs":[315038,315050],"confidence":0.9}
        """
        guard case .renderable(let r) = decode(json) else { return XCTFail("expected renderable") }
        XCTAssertEqual(r.core.kind, "decisionYours")
        XCTAssertEqual(r.core.priority, "high")
        XCTAssertEqual(r.message, "Ship the consolidation to master?")
        XCTAssertEqual(r.evidenceSeqs, [315038, 315050])
        XCTAssertEqual(r.confidence, 0.9)
        XCTAssertEqual(r.options, [])                       // not pickOption → no options
    }

    // Fixture rich_pickOption (bytes 309): fetch=false, options present + non-empty.
    func test_rich_pickOption_carries_options() {
        let json = """
        {"v":1,"id":"need_2","kind":"pickOption","priority":"medium",
         "callerName":"Senti · atlas needs you to choose","who":"senti-pocket","sessionId":"6cf7e861",
         "fetch":false,"ts":"2026-02-02T02:40:00.000Z","message":"Which adapter?",
         "options":["Merge now","Wait for forge","Split the PR"],"evidenceSeqs":[400,401]}
        """
        guard case .renderable(let r) = decode(json) else { return XCTFail("expected renderable") }
        XCTAssertEqual(r.options, ["Merge now", "Wait for forge", "Split the PR"])
    }

    // Fixture lean_overflow (bytes 168): fetch=true, CORE-ONLY (no message/options) → MUST hydrate, NEVER render content.
    func test_lean_overflow_requires_hydration_and_never_renders_content() {
        let json = """
        {"v":1,"id":"need_3","kind":"info","priority":"medium","callerName":"Senti needs you",
         "who":"senti-pocket","sessionId":"s","fetch":true,"ts":"2026-02-02T02:40:00.000Z"}
        """
        guard case .needsHydration(let id, let core) = decode(json) else {
            return XCTFail("LEAN push MUST require hydration, never render pre-auth")
        }
        XCTAssertEqual(id, "need_3")                        // the GET /dial?id= hydration key
        XCTAssertEqual(core.kind, "info")
    }

    // Contract guards: wrong version, and a RICH push missing its required message, are rejected (never a fake ring).
    func test_wrong_version_rejected() {
        guard case .rejected = decode(#"{"v":2,"id":"x","kind":"go","priority":"medium","callerName":"c","who":"senti-pocket","sessionId":"s","fetch":false,"ts":"t"}"#)
        else { return XCTFail("wrong version must be rejected") }
    }

    func test_rich_missing_message_rejected() {
        guard case .rejected = decode(#"{"v":1,"id":"x","kind":"go","priority":"medium","callerName":"c","who":"senti-pocket","sessionId":"s","fetch":false,"ts":"t"}"#)
        else { return XCTFail("RICH push missing message must be rejected, never fabricated") }
    }

    // A LEAN push that (wrongly) carries a stray message must STILL require hydration — never render push content pre-auth.
    func test_lean_with_stray_message_still_hydrates() {
        let json = #"{"v":1,"id":"x","kind":"go","priority":"medium","callerName":"c","who":"senti-pocket","sessionId":"s","fetch":true,"ts":"t","message":"leaked?"}"#
        guard case .needsHydration = decode(json) else { return XCTFail("fetch=true must hydrate regardless of stray fields") }
    }
}
```
