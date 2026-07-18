import Foundation
import XCTest
import PocketContracts
#if canImport(CryptoKit)
import CryptoKit
#endif
@testable import PocketUI

#if canImport(CryptoKit)
final class ReceiptPresentationTests: XCTestCase {
    func testPendingConnectivityIsNeverPosted() {
        let proposal = PocketUITestFactory.proposal()
        let receipt = PocketUITestFactory.receipt(proposal: proposal, status: .pendingConnectivity)
        let presentation = evaluate(receipt, proposal: proposal)

        XCTAssertFalse(presentation.isPosted)
        XCTAssertNil(presentation.verifiedResult)
        XCTAssertEqual(presentation.title, "PENDING CONNECTIVITY")
        XCTAssertTrue(presentation.detail.localizedCaseInsensitiveContains("not sent"))
        XCTAssertTrue(presentation.detail.localizedCaseInsensitiveContains("does not prove durable"))
    }

    func testPendingReceiptWithExecutionFieldsIsInvalid() {
        let proposal = PocketUITestFactory.proposal()
        let receipt = PocketUITestFactory.receipt(
            proposal: proposal,
            status: .pendingConnectivity,
            result: actionResult(for: proposal),
            executedAt: PocketUITestFactory.date
        )

        XCTAssertEqual(evaluate(receipt, proposal: proposal).title, "Receipt verification error")
    }

    func testPostedRequiresConcreteBoundResultExecutionTimeAndTrustedSignature() {
        let proposal = PocketUITestFactory.proposal()
        let missingResult = PocketUITestFactory.receipt(
            proposal: proposal,
            status: .posted,
            executedAt: PocketUITestFactory.date,
            signature: "signature",
            signingKeyId: "key-1"
        )
        let untrusted = PocketUITestFactory.receipt(
            proposal: proposal,
            status: .posted,
            result: actionResult(for: proposal),
            executedAt: PocketUITestFactory.date,
            signature: "signature",
            signingKeyId: "key-1"
        )
        let nonPositiveTarget = PocketUITestFactory.receipt(
            proposal: proposal,
            status: .posted,
            result: .action(actionId: "action-1", targetSequenceId: 0, targetCursor: nil),
            executedAt: PocketUITestFactory.date,
            signature: "signature",
            signingKeyId: "key-1"
        )
        let wrongThreadTarget = PocketUITestFactory.receipt(
            proposal: proposal,
            status: .posted,
            result: .action(
                actionId: "action-1",
                targetSequenceId: proposal.targetSequence + 1,
                targetCursor: nil
            ),
            executedAt: PocketUITestFactory.date,
            signature: "signature",
            signingKeyId: "key-1"
        )

        for receipt in [missingResult, untrusted, nonPositiveTarget, wrongThreadTarget] {
            XCTAssertFalse(evaluate(receipt, proposal: proposal).isPosted)
        }
    }

    func testMalformedActionProofFieldsFailClosed() {
        let proposal = PocketUITestFactory.proposal()
        let invalidResults: [ActionResultRef] = [
            .action(actionId: "", targetSequenceId: proposal.targetSequence, targetCursor: nil),
            .action(
                actionId: String(repeating: "a", count: 257),
                targetSequenceId: proposal.targetSequence,
                targetCursor: nil
            ),
            .action(actionId: "action-1", targetSequenceId: proposal.targetSequence, targetCursor: ""),
            .action(
                actionId: "action-1",
                targetSequenceId: proposal.targetSequence,
                targetCursor: String(repeating: "c", count: 1_025)
            )
        ]

        for result in invalidResults {
            let receipt = PocketUITestFactory.receipt(
                proposal: proposal,
                status: .posted,
                result: result,
                executedAt: PocketUITestFactory.date,
                signature: "signature",
                signingKeyId: "key-1"
            )
            XCTAssertFalse(evaluate(receipt, proposal: proposal).isPosted)
        }
    }

    func testUnanchoredCallerKeyCannotAssertVerifiedForSyntheticSignature() {
        let proposal = PocketUITestFactory.proposal()
        let receipt = PocketUITestFactory.receipt(
            proposal: proposal,
            status: .posted,
            result: actionResult(for: proposal),
            executedAt: PocketUITestFactory.date,
            signature: "synthetic-signature",
            signingKeyId: "receipt-key-1"
        )
        let presentation = ReceiptPresentation.evaluate(
            receipt: receipt,
            proposal: proposal,
            trustStore: ReceiptTrustStore()
        )

        XCTAssertFalse(presentation.isPosted)
        XCTAssertNil(presentation.verifiedResult)
    }

    func testExactActionReceiptEd25519VerificationProducesPostedPresentation() throws {
        let proposal = PocketUITestFactory.proposal()
        let expectedResult = actionResult(for: proposal)
        let (receipt, trustedKey) = try signedReceipt(proposal: proposal, result: expectedResult)

        let presentation = ReceiptPresentation.evaluate(
            receipt: receipt,
            proposal: proposal,
            trustStore: ReceiptTrustStore(signingKeys: [trustedKey])
        )

        XCTAssertTrue(presentation.isPosted)
        XCTAssertEqual(presentation.verifiedResult, expectedResult)
        XCTAssertEqual(presentation.verifiedSigningKeyId, "receipt-key-1")
        XCTAssertTrue(presentation.detail.contains("action-1"))
        XCTAssertTrue(presentation.detail.contains(String(proposal.targetSequence)))
    }

    func testSelfSignedReceiptRemainsUnpostedWithoutOpaqueAnchor() throws {
        let proposal = PocketUITestFactory.proposal()
        let (receipt, _) = try signedReceipt(proposal: proposal, result: actionResult(for: proposal))

        let presentation = ReceiptPresentation.evaluate(
            receipt: receipt,
            proposal: proposal,
            trustStore: ReceiptTrustStore()
        )

        XCTAssertFalse(presentation.isPosted)
        XCTAssertNil(presentation.verifiedResult)
    }

    func testDuplicateSigningKeyIdentifiersFailClosed() throws {
        let proposal = PocketUITestFactory.proposal()
        let (receipt, trustedKey) = try signedReceipt(proposal: proposal, result: actionResult(for: proposal))
        let duplicateStore = ReceiptTrustStore(signingKeys: [trustedKey, trustedKey])

        XCTAssertFalse(ReceiptPresentation.evaluate(
            receipt: receipt,
            proposal: proposal,
            trustStore: duplicateStore
        ).isPosted)
    }

    func testCryptographicallyValidImpossibleTimelineRemainsUnposted() throws {
        let proposal = PocketUITestFactory.proposal()
        let signingKey = Curve25519.Signing.PrivateKey()
        let confirmedAt = PocketUITestFactory.date.addingTimeInterval(2)
        let executedAt = PocketUITestFactory.date.addingTimeInterval(1)
        let draft = PocketUITestFactory.receipt(
            proposal: proposal,
            status: .posted,
            result: actionResult(for: proposal),
            confirmedByHumanAt: confirmedAt,
            executedAt: executedAt,
            signature: "placeholder",
            signingKeyId: "receipt-key-1"
        )
        let signature = try signingKey.signature(
            for: Data(draft.canonicalReceiptPayload().utf8)
        ).base64URLEncodedString()
        let receipt = PocketUITestFactory.receipt(
            proposal: proposal,
            status: .posted,
            result: actionResult(for: proposal),
            confirmedByHumanAt: confirmedAt,
            executedAt: executedAt,
            signature: signature,
            signingKeyId: "receipt-key-1"
        )
        let trustStore = ReceiptTrustStore(signingKeys: [TrustedReceiptSigningKey(
            signingKeyId: "receipt-key-1",
            publicKeyBase64url: signingKey.publicKey.rawRepresentation.base64URLEncodedString()
        )])

        XCTAssertFalse(ReceiptPresentation.evaluate(
            receipt: receipt,
            proposal: proposal,
            trustStore: trustStore
        ).isPosted)
    }

    func testExactSequenceReceiptEd25519VerificationProducesPostedPresentation() throws {
        let proposal = PocketUITestFactory.proposal(kind: .opinionRequest)
        let expectedResult = ActionResultRef.sequence(sequenceId: 230181)
        let (receipt, trustedKey) = try signedReceipt(proposal: proposal, result: expectedResult)

        let presentation = ReceiptPresentation.evaluate(
            receipt: receipt,
            proposal: proposal,
            trustStore: ReceiptTrustStore(signingKeys: [trustedKey])
        )

        XCTAssertTrue(presentation.isPosted)
        XCTAssertEqual(presentation.verifiedResult, expectedResult)
        XCTAssertTrue(presentation.detail.contains("230181"))
    }

    func testThreadedReplyCannotRenderSequenceResultAsPosted() throws {
        let proposal = PocketUITestFactory.proposal(kind: .threadedReply)
        let (receipt, trustedKey) = try signedReceipt(
            proposal: proposal,
            result: .sequence(sequenceId: 230181)
        )

        let presentation = ReceiptPresentation.evaluate(
            receipt: receipt,
            proposal: proposal,
            trustStore: ReceiptTrustStore(signingKeys: [trustedKey])
        )

        XCTAssertFalse(presentation.isPosted)
        XCTAssertNil(presentation.verifiedResult)
    }

    func testSignatureProofCannotBeReusedForMutatedResult() throws {
        let proposal = PocketUITestFactory.proposal()
        let (signed, trustedKey) = try signedReceipt(proposal: proposal, result: actionResult(for: proposal))
        let mutated = PocketUITestFactory.receipt(
            proposal: proposal,
            status: .posted,
            result: .action(
                actionId: "action-2",
                targetSequenceId: proposal.targetSequence,
                targetCursor: "cursor-1"
            ),
            executedAt: signed.executedAt,
            signature: signed.signature,
            signingKeyId: signed.signingKeyId
        )

        XCTAssertFalse(ReceiptPresentation.evaluate(
            receipt: mutated,
            proposal: proposal,
            trustStore: ReceiptTrustStore(signingKeys: [trustedKey])
        ).isPosted)
    }

    func testReceiptScreenStateComputesBoundPresentationInternally() throws {
        let proposal = PocketUITestFactory.proposal()
        let (receipt, trustedKey) = try signedReceipt(proposal: proposal, result: actionResult(for: proposal))

        let state = ReceiptScreenState(
            proposal: proposal,
            receipt: receipt,
            trustStore: ReceiptTrustStore(signingKeys: [trustedKey])
        )

        XCTAssertTrue(state.presentation.isPosted)
        XCTAssertEqual(state.presentation.verifiedResult, receipt.result)
    }

    func testWrongSessionOrHashCannotRenderPosted() {
        let proposal = PocketUITestFactory.proposal()
        let wrongSession = PocketUITestFactory.receipt(
            proposal: proposal,
            status: .posted,
            result: actionResult(for: proposal),
            targetSessionId: "wrong-session",
            executedAt: PocketUITestFactory.date,
            signature: "signature",
            signingKeyId: "key-1"
        )
        let wrongHash = PocketUITestFactory.receipt(
            proposal: proposal,
            status: .posted,
            result: actionResult(for: proposal),
            confirmedProposalHash: "wrong-hash",
            executedAt: PocketUITestFactory.date,
            signature: "signature",
            signingKeyId: "key-1"
        )

        for receipt in [wrongSession, wrongHash] {
            let presentation = evaluate(receipt, proposal: proposal)
            XCTAssertFalse(presentation.isPosted, "Wrong target/hash receipt must fail closed")
            XCTAssertEqual(presentation.title, "Receipt verification error")
        }
    }

    func testFailedReceiptAlwaysStatesNotSent() {
        let proposal = PocketUITestFactory.proposal()
        let receipt = PocketUITestFactory.receipt(
            proposal: proposal,
            status: .failed,
            failureReason: "authorization expired"
        )

        let presentation = evaluate(receipt, proposal: proposal)
        XCTAssertFalse(presentation.isPosted)
        XCTAssertEqual(presentation.title, "Failed — not sent")
        XCTAssertTrue(presentation.detail.contains("authorization expired"))
    }

    private func signedReceipt(
        proposal: ActionProposal,
        result: ActionResultRef
    ) throws -> (ActionReceipt, TrustedReceiptSigningKey) {
        let signingKey = Curve25519.Signing.PrivateKey()
        let draft = PocketUITestFactory.receipt(
            proposal: proposal,
            status: .posted,
            result: result,
            executedAt: PocketUITestFactory.date,
            signature: "placeholder",
            signingKeyId: "receipt-key-1"
        )
        let signature = try signingKey.signature(
            for: Data(draft.canonicalReceiptPayload().utf8)
        ).base64URLEncodedString()
        let receipt = PocketUITestFactory.receipt(
            proposal: proposal,
            status: .posted,
            result: result,
            executedAt: PocketUITestFactory.date,
            signature: signature,
            signingKeyId: "receipt-key-1"
        )
        let trustedKey = TrustedReceiptSigningKey(
            signingKeyId: "receipt-key-1",
            publicKeyBase64url: signingKey.publicKey.rawRepresentation.base64URLEncodedString()
        )
        return (receipt, trustedKey)
    }

    private func actionResult(for proposal: ActionProposal) -> ActionResultRef {
        .action(
            actionId: "action-1",
            targetSequenceId: proposal.targetSequence,
            targetCursor: "cursor-1"
        )
    }

    private func evaluate(
        _ receipt: ActionReceipt,
        proposal: ActionProposal
    ) -> ReceiptPresentation {
        ReceiptPresentation.evaluate(
            receipt: receipt,
            proposal: proposal,
            trustStore: ReceiptTrustStore()
        )
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
#endif
