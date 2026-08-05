import XCTest
import Foundation
@testable import SentiPocketApp

/// Cross-language wire parity for the RECEIVE decoder, bound to the ONE shared KAV.
///
/// Reads relay's ACTUAL committed fixture — `services/pocket-gateway/test/fixtures/dial-payload-v1.json` (the
/// buildDialPayload output, doorbell producer #93) — and feeds each case's `payload` object (the exact bytes APNs
/// pushes) THROUGH `DialReceive.receive`, asserting the resulting `DialReceiveState`. There is NO copy: the same
/// physical file is relay's Node producer KAV and this Swift decoder KAV, so the two sides can't silently drift —
/// the same one-source-of-truth pattern as NeedCarterSignalKAVTests (#89). Loud-fails if the sibling is absent.
///
/// Invariant under test (relay spec + warden doorbell gate): write-kinds (decisionYours/pickOption/go) ALWAYS ship
/// LEAN (fetch=true) → `.needsHydration` (governed content shed, never rendered from the unauthenticated push);
/// low-sensitivity info/checkpointReady MAY ship RICH (fetch=false) → `.renderable`.
final class DialPayloadV1KAVTests: XCTestCase {

    // MARK: - shared fixture loading (repo-root-relative, resolved from this source file's compile-time path)

    private static let kavRelativePath = "services/pocket-gateway/test/fixtures/dial-payload-v1.json"

    /// Walk up from this source file until relay's canonical dial-payload KAV is found; return its `cases` dict.
    /// Fails LOUD (never silently skips) if the monorepo sibling is absent — a skip would let the very drift this
    /// test exists to catch slip through.
    private func loadCases(file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        var dir = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent(Self.kavRelativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                let raw = try Data(contentsOf: candidate)
                let root = try JSONSerialization.jsonObject(with: raw) as? [String: Any] ?? [:]
                return (root["cases"] as? [String: Any]) ?? [:]
            }
            dir.deleteLastPathComponent()
        }
        XCTFail("shared KAV \(Self.kavRelativePath) not found walking up from \(file) — the atlas↔relay dial-payload "
                + "parity guard requires relay's committed fixture on the monorepo checkout", file: file, line: line)
        return [:]
    }

    private func payloadObject(_ name: String, in cases: [String: Any]) -> [String: Any]? {
        guard let c = cases[name] as? [String: Any], let p = c["payload"] as? [String: Any] else {
            XCTFail("KAV case \(name) missing a payload object")
            return nil
        }
        return p
    }

    /// Extract a case's `payload` sub-object and re-serialize it to the exact bytes DialReceive.receive consumes.
    private func payloadData(_ name: String, in cases: [String: Any]) throws -> Data {
        guard let payload = payloadObject(name, in: cases) else { return Data() }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    // MARK: - write-kinds are ALWAYS LEAN → needsHydration (governed content shed, never pre-auth)

    func test_writekind_decision_lean_needs_hydration() throws {
        let cases = try loadCases()
        let s = DialReceive.receive(try payloadData("writekind_decision_lean", in: cases))
        guard case .needsHydration(let id, let core) = s else { return XCTFail("expected needsHydration, got \(s)") }
        XCTAssertEqual(id, "need_1")
        XCTAssertEqual(core.kind, "decisionYours")          // plain-string kind → RingCore.kind:String
        XCTAssertEqual(core.checkpointId, "cp_9")           // checkpoint is CORE (routing), governed content is not
        XCTAssertEqual(core.sessionId, "6cf7e861")
    }

    func test_writekind_pickOption_lean_needs_hydration_options_never_on_push() throws {
        let cases = try loadCases()
        let s = DialReceive.receive(try payloadData("writekind_pickOption_lean", in: cases))
        guard case .needsHydration(let id, let core) = s else { return XCTFail("expected needsHydration, got \(s)") }
        XCTAssertEqual(id, "need_2")
        XCTAssertEqual(core.kind, "pickOption")
        XCTAssertNil(core.checkpointId)                     // omitted → nil; options are hydrated, never on the push
    }

    func test_adversarial_rich_write_kinds_are_rejected_before_governed_content() throws {
        let cases = try loadCases()
        guard let seed = payloadObject("rich_info", in: cases) else { return }

        for kind in ["go", "decisionYours", "pickOption"] {
            var payload = seed
            payload["kind"] = kind
            payload["fetch"] = false
            payload["message"] = "UNTRUSTED PUSH CONTENT"
            payload["options"] = ["Approve attacker content"]

            let state = DialReceive.receive(try JSONSerialization.data(withJSONObject: payload))
            guard case .rejected(let reason) = state else {
                return XCTFail("rich write-kind \(kind) must be rejected, got \(state)")
            }
            XCTAssertEqual(reason, "write-kind dial payload requires fetch=true")
        }
    }

    func test_unknown_kind_is_rejected_for_both_fetch_shapes() throws {
        let cases = try loadCases()
        guard let seed = payloadObject("rich_info", in: cases) else { return }

        for fetch in [false, true] {
            var payload = seed
            payload["kind"] = "futureWriteKind"
            payload["fetch"] = fetch
            let state = DialReceive.receive(try JSONSerialization.data(withJSONObject: payload))
            guard case .rejected(let reason) = state else {
                return XCTFail("unknown kind with fetch=\(fetch) must be rejected, got \(state)")
            }
            XCTAssertEqual(reason, "dial payload has unknown kind")
        }
    }

    // MARK: - low-sensitivity RICH → renderable (governed content rides the push, decoded directly)

    func test_rich_info_is_renderable_with_governed_content() throws {
        let cases = try loadCases()
        let s = DialReceive.receive(try payloadData("rich_info", in: cases))
        guard case .renderable(let r) = s else { return XCTFail("expected renderable, got \(s)") }
        XCTAssertEqual(r.core.id, "need_4")
        XCTAssertEqual(r.core.kind, "info")
        XCTAssertEqual(r.core.checkpointId, "cp_12")
        XCTAssertEqual(r.message, "Deploy finished; all green.")
        XCTAssertEqual(r.options, [])                       // non-pickOption → no options
        XCTAssertEqual(r.evidenceSeqs, [511, 520])          // producer dedup+sort applied
        XCTAssertEqual(r.confidence ?? -1, 0.8, accuracy: 1e-9)
    }

    func test_rich_display_kind_cannot_smuggle_options_into_spoken_content() throws {
        let cases = try loadCases()
        guard var payload = payloadObject("rich_info", in: cases) else { return }
        payload["options"] = ["UNTRUSTED OPTION"]

        let state = DialReceive.receive(try JSONSerialization.data(withJSONObject: payload))
        guard case .rejected(let reason) = state else {
            return XCTFail("display-only RICH payload with options must be rejected, got \(state)")
        }
        XCTAssertEqual(reason, "display-only RICH dial payload must not carry options")
    }

    // MARK: - overflow + hostile-byte cases still decode (fetch=true → hydrate regardless of kind/bytes)

    func test_lean_overflow_forces_hydration() throws {
        let cases = try loadCases()
        let s = DialReceive.receive(try payloadData("lean_overflow", in: cases))
        guard case .needsHydration(let id, _) = s else { return XCTFail("expected needsHydration, got \(s)") }
        XCTAssertEqual(id, "need_3")                        // an info that overflowed the budget → forced LEAN
    }

    func test_worst_byte_unicode_needs_hydration() throws {
        let cases = try loadCases()
        let s = DialReceive.receive(try payloadData("worst_byte", in: cases))
        guard case .needsHydration = s else { return XCTFail("expected needsHydration, got \(s)") }  // 中… decodes as Swift String
    }

    func test_max_core_needs_hydration() throws {
        let cases = try loadCases()
        let s = DialReceive.receive(try payloadData("max_core", in: cases))
        guard case .needsHydration = s else { return XCTFail("expected needsHydration, got \(s)") }  // 😀 + escaped-quote strings
    }

    // MARK: - sweep: no valid KAV payload is ever rejected (a new relay case can't silently fail to decode)

    func test_no_KAV_payload_is_rejected() throws {
        let cases = try loadCases()
        XCTAssertGreaterThanOrEqual(cases.count, 6, "expected at least the 6 seeded dial-payload cases")
        for name in cases.keys {
            let s = DialReceive.receive(try payloadData(name, in: cases))
            if case .rejected(let reason) = s { XCTFail("KAV case \(name) was rejected by the decoder: \(reason)") }
        }
    }
}
