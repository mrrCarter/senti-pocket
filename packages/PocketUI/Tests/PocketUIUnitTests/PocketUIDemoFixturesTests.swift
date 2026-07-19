#if DEBUG
import Foundation
import XCTest
import PocketCall
import PocketContracts
@testable import PocketUI

final class PocketUIDemoFixturesTests: XCTestCase {
    func testVerifiedFixtureBuildsHonestOfflinePresentationStates() throws {
        let verifiedBundle = try loadVerifiedBundle()

        let initial = PocketUIDemoFixtures.initialState(verifiedBundle: verifiedBundle)
        guard case .offline(let cachedAt) = initial.connectivity,
              case .inbox(let inbox) = initial.destination else {
            return XCTFail("the demo must start from an explicitly offline fixture inbox")
        }
        XCTAssertEqual(cachedAt, verifiedBundle.bundle.createdAt)
        XCTAssertEqual(inbox.items.count, 1)
        XCTAssertTrue(inbox.items[0].integrity.allowsBriefing)

        let conversation = try XCTUnwrap(PocketUIDemoFixtures.conversationState(
            verifiedBundle: verifiedBundle,
            includesCachedAnswer: true
        ))
        XCTAssertEqual(conversation.integrity.kind, .verified)
        XCTAssertTrue(conversation.transcript.contains(.questionAnswer(PocketFixtures.questionAnswer)))
        XCTAssertTrue(conversation.transcript.contains(where: {
            guard case .notice(let notice) = $0 else { return false }
            return notice.text.contains("No live model or network")
        }))
    }

    func testProposalRequiresExactReadBackAndProducesOnlyPendingReceipt() throws {
        let verifiedBundle = try loadVerifiedBundle()
        let now = PocketFixtures.ts.addingTimeInterval(60)
        let ledger = ProposalConfirmationLedger()
        let review = try XCTUnwrap(PocketUIDemoFixtures.proposalReviewState(
            verifiedBundle: verifiedBundle,
            ledger: ledger,
            currentDate: now
        ))
        var gate = review.confirmationGate
        let proposal = gate.proposal

        XCTAssertEqual(gate.phase, .awaitingReadBack)
        XCTAssertNil(gate.consume(currentProposal: proposal, at: now))

        let attempt = try XCTUnwrap(gate.beginReadBack(for: proposal, at: now))
        XCTAssertEqual(attempt.payload.targetSessionId, proposal.targetSessionId)
        XCTAssertEqual(attempt.payload.targetSequence, proposal.targetSequence)
        XCTAssertEqual(attempt.payload.fullMessageText, proposal.renderedPreview)
        XCTAssertTrue(gate.completeReadBack(attempt, for: proposal, at: now))

        let confirmation = try XCTUnwrap(gate.consume(currentProposal: proposal, at: now))
        XCTAssertNil(gate.consume(currentProposal: proposal, at: now), "confirmation must remain single-use")

        let receipt = try XCTUnwrap(PocketUIDemoFixtures.pendingReceiptState(
            for: confirmation,
            confirmedAt: now
        ))
        XCTAssertEqual(receipt.receipt.status, .pendingConnectivity)
        XCTAssertNil(receipt.receipt.result)
        XCTAssertNil(receipt.receipt.executedAt)
        XCTAssertNil(receipt.receipt.signature)
        XCTAssertNil(receipt.receipt.signingKeyId)
        XCTAssertFalse(receipt.presentation.isPosted)
    }

    private func loadVerifiedBundle() throws -> VerifiedBundle {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("packages/PocketContracts/Fixtures/canonical_checkpoint.json")
            .standardizedFileURL
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bundle = try decoder.decode(PocketBundle.self, from: data)
        return try XCTUnwrap(VerifiedBundle.verify(bundle))
    }
}
#endif
