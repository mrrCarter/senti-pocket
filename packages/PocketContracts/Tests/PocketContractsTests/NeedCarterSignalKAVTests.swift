import XCTest
import Foundation
@testable import PocketContracts

/// Cross-language wire parity, bound to the ONE shared KAV.
///
/// This reads relay's ACTUAL committed fixture — `services/pocket-gateway/test/fixtures/need-carter-signal-v1.json`
/// (PR-B3 #86) — and decodes each case's `expectedStoredSignal` (the exact bytes `GET /dial?id=` returns) THROUGH
/// NeedCarterSignal's custom Codable. There is NO copy: the same physical file is the source of truth for relay's
/// Node producer test (`mapSignalToPushInput(...).storedSignal` deep-equals `expectedStoredSignal`) and for this
/// Swift decoder test. If relay's producer changes the wire, this test re-reads the new bytes and asserts against
/// them, so relay-side and atlas-side can never silently drift — the guarantee the fixture's own `meta.note` pins.
///
/// The hand-rolled inline decode smoke-tests still live in `NeedCarterSignalTests` (fast, hermetic, and they cover
/// the createdAt-ABSENT branch this KAV intentionally never exercises); THIS file is the authoritative parity guard.
final class NeedCarterSignalKAVTests: XCTestCase {

    // MARK: - shared fixture loading (repo-root-relative, resolved from this source file's compile-time path)

    private struct KAV: Decodable {
        struct Case: Decodable {
            let name: String
            let humanId: String
            let expectedStoredSignal: NeedCarterSignal   // decoded THROUGH NeedCarterSignal.init(from:) — the code under test
            // `input` (producer-side) is intentionally NOT decoded here; asserting input→storedSignal is relay's Node test.
        }
        let cases: [Case]
    }

    /// The canonical KAV, relative to the monorepo root.
    private static let kavRelativePath = "services/pocket-gateway/test/fixtures/need-carter-signal-v1.json"

    /// Walk up from this source file until relay's canonical KAV is found, and decode its cases.
    /// Fails LOUD (never silently skips) if the monorepo sibling is absent — a silent skip would let exactly the
    /// cross-language drift this test exists to catch slip through undetected.
    private func loadCases(file: StaticString = #filePath, line: UInt = #line) throws -> [KAV.Case] {
        var dir = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent(Self.kavRelativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                let data = try Data(contentsOf: candidate)
                return try JSONDecoder().decode(KAV.self, from: data).cases
            }
            dir.deleteLastPathComponent()
        }
        XCTFail("shared KAV \(Self.kavRelativePath) not found walking up from \(file) — the atlas↔relay parity guard "
                + "requires relay's committed fixture on the monorepo checkout", file: file, line: line)
        return []
    }

    private func caseNamed(_ name: String, in cases: [KAV.Case]) -> NeedCarterSignal? {
        cases.first { $0.name == name }?.expectedStoredSignal
    }

    // MARK: - the three shared cases decode correctly through the custom Codable

    func test_KAV_decisionYours_rich_decodes() throws {
        let cases = try loadCases()
        guard let s = caseNamed("decisionYours-rich", in: cases) else { return XCTFail("missing KAV case decisionYours-rich") }
        XCTAssertEqual(s.id, "need_1")
        guard case .decisionYours = s.kind else { return XCTFail("kind: expected decisionYours, got \(s.kind)") }
        XCTAssertEqual(s.question, "Ship the consolidation to master?")
        XCTAssertEqual(s.context.sessionId, "6cf7e861")
        XCTAssertEqual(s.context.checkpointId, "cp_9")
        XCTAssertEqual(s.context.whatWeNeed, "master merge go")
        XCTAssertEqual(s.confidence, 0.9, accuracy: 1e-9)
        XCTAssertEqual(s.evidenceSeqs, [315038, 315050])                        // present, non-empty → decoded verbatim
        XCTAssertEqual(s.requestedBy, "claude-warden")
        XCTAssertEqual(s.createdAt, Date(timeIntervalSince1970: 1_784_370_900)) // Unix seconds → correct Date, no 2001 skew
    }

    func test_KAV_go_no_evidence_no_checkpoint_decodes() throws {
        let cases = try loadCases()
        guard let s = caseNamed("go-no-evidence-no-checkpoint", in: cases) else { return XCTFail("missing KAV case go-no-evidence-no-checkpoint") }
        XCTAssertEqual(s.id, "need_2")
        guard case .go = s.kind else { return XCTFail("kind: expected go, got \(s.kind)") }
        XCTAssertNil(s.context.checkpointId)                                    // omitted → nil (Swift String? optional)
        XCTAssertEqual(s.confidence, 1.0, accuracy: 1e-9)                       // JSON `1` → Double 1.0
        XCTAssertEqual(s.evidenceSeqs, [])                                      // present as [] → empty, NOT a throw (Warden #83 BUG 1)
        XCTAssertEqual(s.requestedBy, "detector")
        XCTAssertEqual(s.createdAt, Date(timeIntervalSince1970: 1_784_370_900))
    }

    func test_KAV_pickOption_with_options_decodes() throws {
        let cases = try loadCases()
        guard let s = caseNamed("pickOption-with-options", in: cases) else { return XCTFail("missing KAV case pickOption-with-options") }
        XCTAssertEqual(s.id, "need_3")
        guard case .pickOption(let labels) = s.kind else { return XCTFail("kind: expected pickOption, got \(s.kind)") }
        XCTAssertEqual(labels, ["Merge now", "Wait for forge"])                // synthesized {pickOption:{_0:[...]}} wire → associated value
        XCTAssertNil(s.context.checkpointId)
        XCTAssertEqual(s.confidence, 0.8, accuracy: 1e-9)
        XCTAssertEqual(s.evidenceSeqs, [])
        XCTAssertEqual(s.requestedBy, "atlas")
    }

    /// Belt-and-suspenders: EVERY case in the shared fixture must decode without throwing. Because `expectedStoredSignal`
    /// is a non-optional `NeedCarterSignal`, `loadCases()` throws if any case fails — so a NEW case relay adds later can
    /// never silently go unexercised on the Swift side (it'd fail this decode, not pass unnoticed).
    func test_all_KAV_cases_decode_and_target_the_owner() throws {
        let cases = try loadCases()
        XCTAssertGreaterThanOrEqual(cases.count, 3, "expected at least the 3 seeded KAV cases")
        for c in cases {
            XCTAssertFalse(c.expectedStoredSignal.id.isEmpty, "case \(c.name) decoded an empty id")
            XCTAssertEqual(c.humanId, "human-mrrcarter", "case \(c.name): every ring must target the owner (confused-deputy-safe)")
        }
    }
}
