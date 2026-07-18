import XCTest
@testable import PocketActionsClient

// Interface-compile + safety-invariant smoke (Atlas runs on the Mac).
final class PocketActionsClientTests: XCTestCase {
    private func prepared(hash: String = "h1", seq: Int = 100, session: String = "sid") -> PreparedAction {
        PreparedAction(
            target: ResolvedTarget(sessionId: session, sequenceId: seq, cursor: "\(seq):aa", bundleId: "pb"),
            bodyText: "hi", readBack: "reply to #\(seq): hi", proposalHash: hash)
    }
    private func receipt(hash: String = "h1", seq: Int = 100, session: String = "sid", dup: Bool = false) -> ActionReceipt {
        ActionReceipt(actionId: "act", targetSessionId: session, targetSequenceId: seq,
                      idempotencyKey: "cli:reply:seq:\(seq):a:\(hash)", duplicate: dup, proposalHash: hash,
                      actingAgentId: "relay", createdAt: Date(timeIntervalSince1970: 0),
                      signature: BundleSignature(alg: "sha256-unsigned", value: "deadbeef"))
    }

    func testMatchingReceiptPasses() {
        XCTAssertNil(DefaultReceiptChecks().targetAndHashMatch(receipt(), prepared()))
    }

    func testWrongSequenceIsRejected() {
        let err = DefaultReceiptChecks().targetAndHashMatch(receipt(seq: 999), prepared(seq: 100))
        XCTAssertEqual(err, .targetMismatch(expected: prepared(seq: 100).target, receiptSequenceId: 999))
    }

    func testTamperedProposalHashIsRejected() {
        let err = DefaultReceiptChecks().targetAndHashMatch(receipt(hash: "evil"), prepared(hash: "h1"))
        XCTAssertEqual(err, .proposalHashMismatch)
    }

    func testProposalCarriesNoAuthority() {
        // A proposal is just data — no target resolution, no credentials.
        let p = ActionProposal(kind: .reply, targetSessionId: "sid", targetSequenceId: 100, bodyText: "hi")
        XCTAssertEqual(p.kind, .reply)
    }
}
