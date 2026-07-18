import XCTest
import PocketContracts
import PocketCall
#if canImport(CryptoKit)
import CryptoKit
#endif

final class PocketCallMachineTests: XCTestCase {
    private let ts = Date(timeIntervalSince1970: 1_752_835_200)
    private let key = "AA"   // placeholder gateway key; only consulted when verifying a `.posted` receipt

    private func bundle(session: String = "s1", checkpoint: String = "cp1", evidence: [EvidenceRef] = []) -> PocketBundle {
        let summary = CheckpointSummary(checkpointId: checkpoint, headline: "h", summaryBaselineSchema: "checkpoint_summary_sections_v1", grade: nil, perAgent: [], risks: [], blockers: [])
        return PocketBundle(contractsVersion: PocketContracts.version, checkpointId: checkpoint, sessionId: session, sequenceStart: 1, sequenceEnd: 2, summary: summary, evidence: evidence, createdAt: ts, signature: "sig", signingKeyId: "k")
    }
    private func plan(checkpoint: String = "cp1") -> BriefingPlan { BriefingPlan(checkpointId: checkpoint, segments: []) }
    private func invalidProposal() -> ActionProposal {
        // explicit bad hash -> isValidForConfirmation() is false (and false on non-CryptoKit hosts too)
        ActionProposal(id: "p1", kind: .threadedReply, targetSessionId: "s1", targetSequence: 10, renderedPreview: "x", requiresConfirmation: true, createdAt: ts, sourceQuestionId: nil, proposalHash: "WRONG")
    }
    private func qa(checkpoint: String = "cp1", citations: [String] = []) -> QuestionAnswer {
        QuestionAnswer(id: "q1", checkpointId: checkpoint, question: "?", answer: "a", citations: citations, answeredOffline: true, createdAt: ts)
    }
    /// A pending receipt correctly bound to a given proposal (offline-first queue; never signed).
    private func boundPendingReceipt(for p: ActionProposal) -> ActionReceipt {
        ActionReceipt(id: "r1", proposalId: p.id, status: .pendingConnectivity, result: nil, targetSessionId: p.targetSessionId, confirmedByHumanAt: ts, confirmedProposalHash: p.proposalHash, executedAt: nil, failureReason: nil, signature: nil, signingKeyId: nil)
    }
    private func receipt() -> ActionReceipt {
        ActionReceipt(id: "p1", proposalId: "p1", status: .pendingConnectivity, result: nil, targetSessionId: "s1", confirmedByHumanAt: ts, confirmedProposalHash: "H", executedAt: nil, failureReason: nil, signature: nil, signingKeyId: nil)
    }

    func testFlowUpToAwaitingConfirmation() {
        let s = PocketCall.run(.idle, [
            .bundleArrived(bundle()),
            .answered(plan()),
            .interrupted,
            .questionAnswered(qa()),
            .proposalDrafted(invalidProposal())
        ], gatewayKey: key)
        guard case .awaitingConfirmation = s else { return XCTFail("expected awaitingConfirmation, got \(s)") }
    }

    /// SAFETY: no event can shortcut into .executing. A `.confirmed`/`.executed` before awaitingConfirmation is a no-op.
    func testCannotShortcutIntoExecuting() {
        let conversing = PocketCall.run(.idle, [.bundleArrived(bundle()), .answered(plan()), .briefingCompleted], gatewayKey: key)
        XCTAssertEqual(PocketCall.reduce(conversing, .confirmed(ConfirmationIntent(proposalHash: "anything")), gatewayKey: key), conversing)
        XCTAssertEqual(PocketCall.reduce(conversing, .executed(receipt()), gatewayKey: key), conversing)  // can't jump to completed
    }

    /// SAFETY: confirming an INVALID proposal does NOT advance to executing, even if the intent "matches" its bad hash.
    func testInvalidProposalConfirmDoesNotExecute() {
        let awaiting = PocketCallState.awaitingConfirmation(bundle(), invalidProposal())
        let after = PocketCall.reduce(awaiting, .confirmed(ConfirmationIntent(proposalHash: "WRONG")), gatewayKey: key)
        if case .executing = after { XCTFail("invalid proposal must NOT execute") }
        guard case .awaitingConfirmation = after else { return XCTFail("expected to stay awaitingConfirmation") }
    }

    /// SAFETY (Echo #4): a correctly-shaped proposal for a DIFFERENT Senti session must NOT arm confirmation.
    func testWrongSessionProposalRefused() {
        let conversing = PocketCallState.conversing(bundle(session: "s1"), answers: [])
        let foreign = ActionProposal(id: "p1", kind: .threadedReply, targetSessionId: "OTHER-ROOM", targetSequence: 10, renderedPreview: "x", requiresConfirmation: true, createdAt: ts, sourceQuestionId: nil, proposalHash: "H")
        let after = PocketCall.reduce(conversing, .proposalDrafted(foreign), gatewayKey: key)
        if case .awaitingConfirmation = after { XCTFail("wrong-session proposal must NOT arm confirmation") }
        guard case .conversing = after else { return XCTFail("expected to stay conversing") }
    }

    #if canImport(CryptoKit)
    /// SAFETY (Echo #5 / Pulse): a stale confirm bound to proposal A cannot confirm a displayed proposal B.
    func testConfirmSwapRefused() {
        let displayedB = ActionProposal(id: "pB", kind: .threadedReply, targetSessionId: "s1", targetSequence: 10, renderedPreview: "rotate token", createdAt: ts, sourceQuestionId: nil)
        let proposalA = ActionProposal(id: "pA", kind: .threadedReply, targetSessionId: "s1", targetSequence: 11, renderedPreview: "delete everything", createdAt: ts, sourceQuestionId: nil)
        XCTAssertNotEqual(displayedB.proposalHash, proposalA.proposalHash)
        let awaiting = PocketCallState.awaitingConfirmation(bundle(), displayedB)
        // The human never read back A; an intent carrying A's hash must not confirm B.
        let after = PocketCall.reduce(awaiting, .confirmed(ConfirmationIntent(proposalHash: proposalA.proposalHash)), gatewayKey: key)
        guard case .awaitingConfirmation = after else { return XCTFail("confirm-swap must be refused") }
        // The matching intent for B DOES advance.
        guard case .executing = PocketCall.reduce(awaiting, .confirmed(ConfirmationIntent(proposalHash: displayedB.proposalHash)), gatewayKey: key) else {
            return XCTFail("exact read-back intent for B should execute")
        }
    }
    #endif

    /// SAFETY (Echo #2): a briefing plan for a different checkpoint must not start the briefing.
    func testPlanProvenanceMismatchRefused() {
        let incoming = PocketCallState.incoming(bundle(checkpoint: "cp1"))
        let after = PocketCall.reduce(incoming, .answered(plan(checkpoint: "OTHER-CP")), gatewayKey: key)
        guard case .incoming = after else { return XCTFail("cross-checkpoint plan must be refused") }
    }

    /// SAFETY (Echo #3): Q&A for a wrong checkpoint, or citing evidence absent from the bundle, is dropped.
    func testQAProvenanceAndCitationsEnforced() {
        let ev = EvidenceRef(id: "ev_1", sessionId: "s1", sequence: 1, agentId: "a", snippet: "x", ts: ts)
        let conversing = PocketCallState.conversing(bundle(evidence: [ev]), answers: [])
        // wrong checkpoint -> dropped
        XCTAssertEqual(PocketCall.reduce(conversing, .questionAnswered(qa(checkpoint: "OTHER-CP")), gatewayKey: key), conversing)
        // unknown citation -> dropped
        XCTAssertEqual(PocketCall.reduce(conversing, .questionAnswered(qa(citations: ["ev_UNKNOWN"])), gatewayKey: key), conversing)
        // known citation -> appended
        guard case let .conversing(_, answers) = PocketCall.reduce(conversing, .questionAnswered(qa(citations: ["ev_1"])), gatewayKey: key), answers.count == 1 else {
            return XCTFail("valid cited Q&A should append")
        }
    }

    func testCancelReturnsToConversing() {
        let awaiting = PocketCallState.awaitingConfirmation(bundle(), invalidProposal())
        guard case .conversing = PocketCall.reduce(awaiting, .cancelled, gatewayKey: key) else { return XCTFail("cancel -> conversing") }
    }

    func testDismissFromAnywhereExceptCompleted() {
        guard case .dismissed = PocketCall.reduce(.incoming(bundle()), .dismiss, gatewayKey: key) else { return XCTFail() }
        guard case .dismissed = PocketCall.reduce(.awaitingConfirmation(bundle(), invalidProposal()), .dismiss, gatewayKey: key) else { return XCTFail() }
        let done = PocketCallState.completed(receipt())
        guard case .completed = PocketCall.reduce(done, .dismiss, gatewayKey: key) else { return XCTFail("completed is terminal") }
    }

    #if canImport(CryptoKit)
    /// SAFETY (Echo #6/#7): only a receipt BOUND to the executing proposal completes the call.
    func testReceiptMustBindToExecutingProposal() {
        let valid = ActionProposal(id: "p1", kind: .threadedReply, targetSessionId: "s1", targetSequence: 10, renderedPreview: "rotate token", createdAt: ts, sourceQuestionId: nil)
        let executing = PocketCall.run(.idle, [
            .bundleArrived(bundle()), .answered(plan()), .briefingCompleted,
            .proposalDrafted(valid), .confirmed(ConfirmationIntent(proposalHash: valid.proposalHash))
        ], gatewayKey: key)
        guard case .executing = executing else { return XCTFail("valid confirm -> executing, got \(executing)") }
        // A receipt for a DIFFERENT proposal id must NOT complete the call.
        let foreign = ActionReceipt(id: "r9", proposalId: "pX", status: .pendingConnectivity, result: nil, targetSessionId: "s1", confirmedByHumanAt: ts, confirmedProposalHash: valid.proposalHash, executedAt: nil, failureReason: nil, signature: nil, signingKeyId: nil)
        guard case .executing = PocketCall.reduce(executing, .executed(foreign), gatewayKey: key) else { return XCTFail("unbound receipt must NOT complete") }
        // A receipt with a mismatched confirmedProposalHash must NOT complete either.
        let hashMismatch = ActionReceipt(id: "r9", proposalId: "p1", status: .pendingConnectivity, result: nil, targetSessionId: "s1", confirmedByHumanAt: ts, confirmedProposalHash: "NOPE", executedAt: nil, failureReason: nil, signature: nil, signingKeyId: nil)
        guard case .executing = PocketCall.reduce(executing, .executed(hashMismatch), gatewayKey: key) else { return XCTFail("hash-mismatch receipt must NOT complete") }
        // The correctly-bound pending receipt completes.
        guard case .completed = PocketCall.reduce(executing, .executed(boundPendingReceipt(for: valid)), gatewayKey: key) else { return XCTFail("bound receipt -> completed") }
    }

    /// SAFETY (Echo #6): a `.posted` receipt completes ONLY if its signature verifies under the pinned gateway key.
    func testPostedReceiptRequiresVerifiedSignature() throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let pub = b64url(signingKey.publicKey.rawRepresentation)
        let valid = ActionProposal(id: "p1", kind: .threadedReply, targetSessionId: "s1", targetSequence: 10, renderedPreview: "rotate token", createdAt: ts, sourceQuestionId: nil)
        let executing = PocketCall.run(.idle, [
            .bundleArrived(bundle()), .answered(plan()), .briefingCompleted,
            .proposalDrafted(valid), .confirmed(ConfirmationIntent(proposalHash: valid.proposalHash))
        ], gatewayKey: pub)
        guard case .executing = executing else { return XCTFail("expected executing") }
        // Canonical payload excludes the signature field, so we can compute it on a placeholder then re-wrap.
        let toSign = ActionReceipt(id: "r1", proposalId: "p1", status: .posted, result: .action(actionId: "act_p1", targetSequenceId: 10, targetCursor: nil), targetSessionId: "s1", confirmedByHumanAt: ts, confirmedProposalHash: valid.proposalHash, executedAt: ts, failureReason: nil, signature: "PLACEHOLDER", signingKeyId: "gw")
        let sig = b64url(try signingKey.signature(for: Data(toSign.canonicalReceiptPayload().utf8)))
        let signed = ActionReceipt(id: "r1", proposalId: "p1", status: .posted, result: .action(actionId: "act_p1", targetSequenceId: 10, targetCursor: nil), targetSessionId: "s1", confirmedByHumanAt: ts, confirmedProposalHash: valid.proposalHash, executedAt: ts, failureReason: nil, signature: sig, signingKeyId: "gw")
        XCTAssertEqual(signed.signatureState(gatewayPublicKeyBase64url: pub), .verified)
        // Correct pinned key -> completes.
        guard case .completed = PocketCall.reduce(executing, .executed(signed), gatewayKey: pub) else { return XCTFail("verified posted -> completed") }
        // A DIFFERENT pinned key -> signature does not verify -> never completes (never shows "sent").
        let wrong = b64url(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        guard case .executing = PocketCall.reduce(executing, .executed(signed), gatewayKey: wrong) else { return XCTFail("wrong key must NOT complete") }
    }

    private func b64url(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    #endif
}
