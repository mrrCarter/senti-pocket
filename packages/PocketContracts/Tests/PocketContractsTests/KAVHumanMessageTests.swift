import XCTest
@testable import PocketContracts

/// KNOWN-ANSWER VECTOR for the humanMessage governed-write hash (warden gap #1 → committed CI guard).
///
/// The milestone write binds the human confirm to `proposalHash`, and the Node gateway RECOMPUTES that hash to
/// verify `confirmedProposalHash == live`. If Swift's `canonicalPayload` ever diverges from Node's (a refactor, a
/// field-order change, an encoding tweak), the confirm silently mismatches and the phone-write fails-closed — or
/// worse, subtly. This test freezes the parity: the expected hash below was computed by the gateway's OWN
/// `computeProposalHash` (Node, actions.mjs v3 domain) for the EXACT proposal here, and verified byte-equal to
/// Swift's `ActionProposal.computeHash` on 2026-07-20. A failure here means the Swift↔Node hash parity broke.
final class KAVHumanMessageTests: XCTestCase {
    #if canImport(CryptoKit)
    /// The canonical proposal fixed for the KAV (whole-second createdAt → 1_784_370_900_000 ms, deterministic).
    private func kavProposal(targetSequence: Int = 0, id: String = "kav-humanmessage-1") -> ActionProposal {
        ActionProposal(
            id: id,
            kind: .humanMessage,
            targetSessionId: "6cf7e861-546a-4b9f-b937-39182a5bd395",
            targetSequence: targetSequence,
            renderedPreview: "rotate the token and do not deploy",
            createdAt: Date(timeIntervalSince1970: 1_784_370_900),
            sourceQuestionId: nil
        )
    }

    func test_humanMessage_proposalHash_matches_node_KAV() {
        // Byte-parity with the Node gateway's computeProposalHash for the identical proposal (v3 domain).
        XCTAssertEqual(kavProposal().proposalHash, "zkGSDi8vHMs-2Oite8fqxpTX0cfK877eztNsQD8KQLw")
    }

    func test_humanMessage_hash_is_self_consistent() {
        // hashMatchesContent must hold for a producer-built humanMessage (the confirm/writeback integrity check).
        XCTAssertTrue(kavProposal().hashMatchesContent())
    }

    func test_humanMessage_sentinel_seq0_is_confirmable() {
        // The ==0 sentinel is ENFORCED (mirrors Node validateProposal `kind==='humanMessage' ? seq===0 : seq>0`).
        XCTAssertTrue(kavProposal(targetSequence: 0).isValidForConfirmation())
    }

    func test_humanMessage_nonzero_seq_is_rejected_both_sides() {
        // A humanMessage carrying a thread target (seq != 0) is NOT confirmable — neither side may accept it, else
        // Node/Swift could disagree. This guards the enforce-not-skip decision (Atlas @9842cef).
        XCTAssertFalse(kavProposal(targetSequence: 7, id: "kav-humanmessage-2").isValidForConfirmation())
    }
    #endif
}
