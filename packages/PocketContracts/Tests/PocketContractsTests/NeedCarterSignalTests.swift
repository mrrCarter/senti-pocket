import XCTest
@testable import PocketContracts

/// Locks the two load-bearing invariants of the ring-the-owner signal:
///  1. the superset maps DOWN to forge's DialRequest fields (dialId/message/callerName/priority) faithfully, so the
///     detection contract EXTENDS the shipped dial flow rather than forking a second ring type;
///  2. the anti-false-ring confidence floor — a low-confidence "maybe needed" NEVER clears the ring gate.
final class NeedCarterSignalTests: XCTestCase {
    private func signal(kind: NeedCarterKind, confidence: Double, requestedBy: String = "detector") -> NeedCarterSignal {
        NeedCarterSignal(
            id: "need_1", kind: kind, question: "Ship the consolidation to master?",
            context: NeedCarterContext(sessionId: "6cf7e861", checkpointId: "cp_9", whatWeNeed: "master merge go"),
            confidence: confidence, evidenceSeqs: [315038, 315050], requestedBy: requestedBy,
            createdAt: Date(timeIntervalSince1970: 1_784_370_900)
        )
    }

    func test_dialFields_map_to_DialRequest_shape() {
        let f = signal(kind: .decisionYours, confidence: 0.9, requestedBy: "claude-warden").dialFields()
        XCTAssertEqual(f.dialId, "need_1")
        XCTAssertEqual(f.message, "Ship the consolidation to master?")
        XCTAssertEqual(f.priority, "high")                                   // decisionYours → high
        XCTAssertEqual(f.callerName, "Senti · claude-warden needs your decision")
    }

    func test_priority_mapping_per_kind() {
        XCTAssertEqual(NeedCarterKind.decisionYours.dialPriority, "high")
        XCTAssertEqual(NeedCarterKind.go.dialPriority, "medium")
        XCTAssertEqual(NeedCarterKind.pickOption(["A", "B"]).dialPriority, "medium")
        XCTAssertEqual(NeedCarterKind.info.dialPriority, "medium")
        XCTAssertEqual(NeedCarterKind.checkpointReady.dialPriority, "medium")
    }

    func test_confidence_floor_blocks_a_low_confidence_ring() {
        // The magical detector must NOT ring Carter on a weak "maybe needed" — the anti-false-ring gate.
        XCTAssertFalse(signal(kind: .go, confidence: 0.4).clearsRingFloor)
        XCTAssertTrue(signal(kind: .go, confidence: 0.6).clearsRingFloor)   // exactly at the floor clears
        XCTAssertTrue(signal(kind: .go, confidence: 0.95).clearsRingFloor)
    }

    func test_pickOption_carries_labels_and_round_trips_codable() throws {
        let s = signal(kind: .pickOption(["Merge now", "Wait for forge", "Split the PR"]), confidence: 0.8)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(NeedCarterSignal.self, from: data)
        XCTAssertEqual(s, back)                                             // rides the /dial wire + VoIP push verbatim
        guard case .pickOption(let labels) = back.kind else { return XCTFail("kind lost in round-trip") }
        XCTAssertEqual(labels, ["Merge now", "Wait for forge", "Split the PR"])
    }
}
