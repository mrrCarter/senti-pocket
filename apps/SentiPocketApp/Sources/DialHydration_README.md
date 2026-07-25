# DialHydration merge — tests (Atlas)

Staged for the app test target (forge wires it on Mac). Covers the LEAN→hydrate merge + the security invariant
(refuse a fetched signal that doesn't match the ring the push announced).

```swift
import XCTest
import PocketContracts
@testable import SentiPocketApp

final class DialHydrationTests: XCTestCase {
    private func signal(id: String = "need_1", session: String = "6cf7e861", cp: String? = "cp_9",
                        kind: NeedCarterKind = .decisionYours) -> NeedCarterSignal {
        NeedCarterSignal(id: id, kind: kind, question: "Ship the consolidation to master?",
                         context: NeedCarterContext(sessionId: session, checkpointId: cp, whatWeNeed: "master merge go"),
                         confidence: 0.9, evidenceSeqs: [315038, 315050], requestedBy: "claude-warden",
                         createdAt: Date(timeIntervalSince1970: 1_784_370_900))
    }
    private func core(id: String = "need_1", session: String = "6cf7e861", cp: String? = "cp_9") -> RingCore {
        RingCore(id: id, kind: "decisionYours", priority: "high",
                 callerName: "Senti · claude-warden needs your decision", sessionId: session, checkpointId: cp)
    }

    func test_merge_produces_renderable_from_authed_signal() throws {
        let r = try DialHydration.merge(core: core(), fetched: signal())
        XCTAssertEqual(r.message, "Ship the consolidation to master?")   // governed content from the AUTHED fetch only
        XCTAssertEqual(r.evidenceSeqs, [315038, 315050])
        XCTAssertEqual(r.confidence, 0.9)
        XCTAssertEqual(r.options, [])                                    // decisionYours → no options
    }

    func test_pickOption_labels_come_from_the_fetched_signal() throws {
        let s = signal(kind: .pickOption(["Merge now", "Wait for forge"]))
        let r = try DialHydration.merge(core: core(), fetched: s)
        XCTAssertEqual(r.options, ["Merge now", "Wait for forge"])
    }

    // SECURITY: a fetched signal whose id ≠ the push core's id is REFUSED — never paint a substituted signal.
    func test_id_mismatch_is_refused() {
        XCTAssertThrowsError(try DialHydration.merge(core: core(id: "need_1"), fetched: signal(id: "need_999"))) { err in
            guard case DialHydrationError.idMismatch = err else { return XCTFail("expected idMismatch") }
        }
    }

    func test_session_mismatch_is_refused() {
        XCTAssertThrowsError(try DialHydration.merge(core: core(session: "6cf7e861"), fetched: signal(session: "OTHER"))) { err in
            guard case DialHydrationError.contextMismatch = err else { return XCTFail("expected contextMismatch") }
        }
    }

    func test_checkpoint_mismatch_is_refused_when_both_present() {
        XCTAssertThrowsError(try DialHydration.merge(core: core(cp: "cp_9"), fetched: signal(cp: "cp_OTHER"))) { err in
            guard case DialHydrationError.contextMismatch = err else { return XCTFail("expected contextMismatch") }
        }
    }
}
```
