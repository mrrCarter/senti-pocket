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

    func test_dialFields_pickOption_speaks_the_options() {
        // #17: a pickOption ring carries the choice labels, but the down-mapped message dropped them — so the pickup
        // spoke "needs you to choose" + the question yet never the choices. dialFields must now READ them aloud.
        let f = signal(kind: .pickOption(["Merge now", "Wait for forge", "Split the PR"]),
                       confidence: 0.8, requestedBy: "claude-pocket-relay").dialFields()
        XCTAssertEqual(
            f.message,
            "Ship the consolidation to master? Your options are: A, Merge now. B, Wait for forge. C, Split the PR.")
        XCTAssertEqual(f.callerName, "Senti · claude-pocket-relay needs you to choose")
        XCTAssertEqual(f.priority, "medium")                                 // pickOption → medium
    }

    func test_dialFields_non_pickOption_message_stays_the_bare_question() {
        // Only pickOption folds options; every other kind's spoken message is unchanged (no stray "options are").
        for kind in [NeedCarterKind.go, .decisionYours, .info, .checkpointReady] {
            let f = signal(kind: kind, confidence: 0.9).dialFields()
            XCTAssertEqual(f.message, "Ship the consolidation to master?", "kind \(kind.slug) must not fold options")
        }
    }

    func test_dialSpokenMessage_empty_options_is_identity() {
        XCTAssertEqual(dialSpokenMessage(message: "GO?", options: []), "GO?")
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

    // Decode relay's gateway storedSignal wire (PR-B2 #83): createdAt = UNIX-epoch INT, evidenceSeqs OMITTED.
    // This is the exact shape GET /dial?id= returns; my custom Codable must decode it (Swift's default would skew
    // createdAt by 31yrs on a Unix int, and THROW on the missing non-optional evidenceSeqs/createdAt).
    // NOTE: the AUTHORITATIVE cross-language parity guard is now NeedCarterSignalKAVTests, which decodes relay's
    // ACTUAL committed fixture (need-carter-signal-v1.json) so the two sides can't drift. This inline case stays as
    // a fast, hermetic smoke test of the same decode path.
    func test_decodes_relay_wire_unix_epoch_and_omitted_optionals() throws {
        let wire = """
        {"id":"need_1","kind":{"decisionYours":{}},"question":"Ship the consolidation to master?",
         "context":{"sessionId":"6cf7e861","checkpointId":"cp_9","whatWeNeed":"master merge go"},
         "confidence":0.9,"requestedBy":"claude-warden","createdAt":1784370900}
        """
        let s = try JSONDecoder().decode(NeedCarterSignal.self, from: Data(wire.utf8))
        XCTAssertEqual(s.id, "need_1")
        guard case .decisionYours = s.kind else { return XCTFail("kind decode") }
        XCTAssertEqual(s.evidenceSeqs, [])                                   // omitted → default [], not a throw
        XCTAssertEqual(s.createdAt, Date(timeIntervalSince1970: 1_784_370_900))  // Unix int → correct Date (no 2001 skew)
        XCTAssertEqual(s.context.checkpointId, "cp_9")
    }

    func test_decodes_wire_with_createdAt_absent_entirely() throws {
        // relay omits createdAt when absent; a non-optional Date default would throw — we default to .distantPast.
        let wire = #"{"id":"need_2","kind":{"go":{}},"question":"GO?","context":{"sessionId":"s","whatWeNeed":"ship"},"confidence":0.9,"requestedBy":"detector"}"#
        let s = try JSONDecoder().decode(NeedCarterSignal.self, from: Data(wire.utf8))
        XCTAssertEqual(s.createdAt, .distantPast)                            // absent → sentinel, never a decode throw
        XCTAssertEqual(s.evidenceSeqs, [])
    }

}
