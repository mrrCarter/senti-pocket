import XCTest
@testable import PocketReasoning

/// Locks the Stage-1 gate's load-bearing property: it stays SILENT on normal chatter (near-zero false candidates →
/// the LLM confirm rarely runs) but fires on real need-cues, and it NEVER rings on its own (only produces a
/// candidate for Stage-2).
final class NeedCarterPatternGateTests: XCTestCase {
    private let gate = NeedCarterPatternGate()

    private func tail(_ pairs: [(Int, String, String)]) -> [TailMessage] {
        pairs.map { TailMessage(sequenceId: $0.0, author: $0.1, text: $0.2) }
    }

    func test_normal_chatter_produces_no_candidate() {
        // The common case: crew shipping/reviewing, no need for Carter → nil (zero LLM cost).
        let t = tail([
            (1, "claude-pocket-relay", "GATE #70 MERGED @ 161dfb80, 389/389 green"),
            (2, "pocket-forge", "Mac-build of the salvage branch running now"),
            (3, "claude-warden", "+1 gated on the consent boundary, land it"),
        ])
        XCTAssertNil(gate.scan(t))
    }

    func test_direct_mention_of_owner_fires_a_candidate() {
        let t = tail([
            (10, "claude-warden", "shipping the consolidation"),
            (11, "claude-pocket-relay", "@human-mrrcarter this one is your call — merge to master now or wait?"),
        ])
        let c = gate.scan(t)
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.matchedSequenceIds, [11])
        XCTAssertEqual(c?.likelyKindSlug, "decision-yours")   // @-mention + "your call" both vote decision-yours
    }

    func test_option_cue_classifies_pick_option() {
        let t = tail([(20, "claude-pocket-relay", "Do you want option A (merge now) or option B (wait for forge)?")])
        XCTAssertEqual(gate.scan(t)?.likelyKindSlug, "pick-option")
    }

    func test_checkpoint_ready_cue_classifies_checkpoint() {
        let t = tail([(30, "pocket-forge", "milestone reached — the checkpoint is ready for review")])
        XCTAssertEqual(gate.scan(t)?.likelyKindSlug, "checkpoint-ready")
    }

    func test_owner_own_message_mentioning_himself_does_not_fire() {
        // Carter talking (even saying "your call" quoting someone) is NOT a request FOR Carter — author is the owner.
        let t = tail([(40, "human-mrrcarter", "I'll make the call on the merge, give me a sec")])
        XCTAssertNil(gate.scan(t))
    }

    func test_candidate_carries_cues_for_audit() {
        let t = tail([(50, "claude-warden", "@carter waiting on you — need a go on the deploy")])
        let c = gate.scan(t)
        XCTAssertNotNil(c)
        XCTAssertFalse(c!.cues.isEmpty)   // cues feed the Stage-2 prompt + the audit trail
    }
}
