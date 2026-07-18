import XCTest
import PocketContracts
import PocketCall

final class PocketCallMachineTests: XCTestCase {
    private let ts = Date(timeIntervalSince1970: 1_752_835_200)

    private func bundle() -> PocketBundle {
        let summary = CheckpointSummary(checkpointId: "cp1", headline: "h", summaryBaselineSchema: "checkpoint_summary_sections_v1", grade: nil, perAgent: [], risks: [], blockers: [])
        return PocketBundle(contractsVersion: PocketContracts.version, checkpointId: "cp1", sessionId: "s1", sequenceStart: 1, sequenceEnd: 2, summary: summary, evidence: [], createdAt: ts, signature: "sig", signingKeyId: "k")
    }
    private func plan() -> BriefingPlan { BriefingPlan(checkpointId: "cp1", segments: []) }
    private func invalidProposal() -> ActionProposal {
        // explicit bad hash -> isValidForConfirmation() is false (and false on non-CryptoKit hosts too)
        ActionProposal(id: "p1", kind: .threadedReply, targetSessionId: "s1", targetSequence: 10, renderedPreview: "x", requiresConfirmation: true, createdAt: ts, sourceQuestionId: nil, proposalHash: "WRONG")
    }

    func testFlowUpToAwaitingConfirmation() {
        let s = PocketCall.run(.idle, [
            .bundleArrived(bundle()),
            .answered(plan()),
            .interrupted,
            .questionAnswered(QuestionAnswer(id: "q1", checkpointId: "cp1", question: "?", answer: "a", citations: [], answeredOffline: true, createdAt: ts)),
            .proposalDrafted(invalidProposal())
        ])
        guard case .awaitingConfirmation = s else { return XCTFail("expected awaitingConfirmation, got \(s)") }
    }

    /// SAFETY: no event can shortcut into .executing. An `.executed`/`.confirmed` before awaitingConfirmation is a no-op.
    func testCannotShortcutIntoExecuting() {
        // .confirmed while merely conversing is a no-op (never executes).
        let conversing = PocketCall.run(.idle, [.bundleArrived(bundle()), .answered(plan()), .briefingCompleted])
        XCTAssertEqual(PocketCall.reduce(conversing, .confirmed), conversing)
        XCTAssertEqual(PocketCall.reduce(conversing, .executed(receipt())), conversing)  // can't jump to completed
    }

    /// SAFETY: confirming an INVALID proposal does NOT advance to executing (fail-safe).
    func testInvalidProposalConfirmDoesNotExecute() {
        let awaiting = PocketCallState.awaitingConfirmation(bundle(), invalidProposal())
        let after = PocketCall.reduce(awaiting, .confirmed)
        if case .executing = after { XCTFail("invalid proposal must NOT execute") }
        guard case .awaitingConfirmation = after else { return XCTFail("expected to stay awaitingConfirmation") }
    }

    func testCancelReturnsToConversing() {
        let awaiting = PocketCallState.awaitingConfirmation(bundle(), invalidProposal())
        guard case .conversing = PocketCall.reduce(awaiting, .cancelled) else { return XCTFail("cancel -> conversing") }
    }

    func testDismissFromAnywhereExceptCompleted() {
        guard case .dismissed = PocketCall.reduce(.incoming(bundle()), .dismiss) else { return XCTFail() }
        guard case .dismissed = PocketCall.reduce(.awaitingConfirmation(bundle(), invalidProposal()), .dismiss) else { return XCTFail() }
        // completed is terminal — dismiss does not wipe the receipt.
        let done = PocketCallState.completed(receipt())
        guard case .completed = PocketCall.reduce(done, .dismiss) else { return XCTFail("completed is terminal") }
    }

    private func receipt() -> ActionReceipt {
        ActionReceipt(id: "p1", proposalId: "p1", status: .pendingConnectivity, resultingSequence: nil, targetSessionId: "s1", confirmedByHumanAt: ts, confirmedProposalHash: "H", executedAt: nil, failureReason: nil, signature: nil, signingKeyId: nil)
    }

    #if canImport(CryptoKit)
    /// Full happy path with a VALID proposal reaches executing -> completed.
    func testHappyPathExecutesOnlyAfterValidConfirm() {
        let valid = ActionProposal(id: "p1", kind: .threadedReply, targetSessionId: "s1", targetSequence: 10, renderedPreview: "rotate token", createdAt: ts, sourceQuestionId: nil)
        XCTAssertTrue(valid.isValidForConfirmation())
        let executing = PocketCall.run(.idle, [
            .bundleArrived(bundle()), .answered(plan()), .briefingCompleted,
            .proposalDrafted(valid), .confirmed
        ])
        guard case .executing = executing else { return XCTFail("valid confirm -> executing, got \(executing)") }
        guard case .completed = PocketCall.reduce(executing, .executed(receipt())) else { return XCTFail("executed -> completed") }
    }
    #endif
}
