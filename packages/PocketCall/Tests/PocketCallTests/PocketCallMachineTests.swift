import XCTest
import PocketContracts
@testable import PocketCall   // for VerifiedBundle.makeUnverifiedForTesting (DEBUG/test-only ingress mint)
#if canImport(CryptoKit)
import CryptoKit
#endif

final class PocketCallMachineTests: XCTestCase {
    private let ts = Date(timeIntervalSince1970: 1_752_835_200)
    private let key = "AA"                     // placeholder gateway key; only consulted for a `.posted` receipt
    private let challenge = "nonce-episode-1"  // per-episode confirmation nonce

    private func bundle(session: String = "s1", checkpoint: String = "cp1", evidence: [EvidenceRef] = []) -> PocketBundle {
        let summary = CheckpointSummary(checkpointId: checkpoint, headline: "h", summaryBaselineSchema: "checkpoint_summary_sections_v1", grade: nil, perAgent: [], risks: [], blockers: [])
        return PocketBundle(contractsVersion: PocketContracts.version, checkpointId: checkpoint, sessionId: session, sequenceStart: 1, sequenceEnd: 2, summary: summary, evidence: evidence, createdAt: ts, signature: "sig", signingKeyId: "k")
    }
    private func vb(session: String = "s1", checkpoint: String = "cp1", evidence: [EvidenceRef] = []) -> VerifiedBundle {
        VerifiedBundle.makeUnverifiedForTesting(bundle(session: session, checkpoint: checkpoint, evidence: evidence))
    }
    private func plan(checkpoint: String = "cp1") -> BriefingPlan { BriefingPlan(checkpointId: checkpoint, segments: []) }
    private func invalidProposal() -> ActionProposal {
        // explicit bad hash -> isValidForConfirmation() is false (and false on non-CryptoKit hosts too)
        ActionProposal(id: "p1", kind: .threadedReply, targetSessionId: "s1", targetSequence: 10, renderedPreview: "x", requiresConfirmation: true, createdAt: ts, sourceQuestionId: nil, proposalHash: "WRONG")
    }
    private func qa(checkpoint: String = "cp1", citations: [String] = []) -> QuestionAnswer {
        QuestionAnswer(id: "q1", checkpointId: checkpoint, question: "?", answer: "a", citations: citations, answeredOffline: true, createdAt: ts)
    }
    private func boundPendingReceipt(for p: ActionProposal) -> ActionReceipt {
        ActionReceipt(id: "r1", proposalId: p.id, status: .pendingConnectivity, result: nil, targetSessionId: p.targetSessionId, confirmedByHumanAt: ts, confirmedProposalHash: p.proposalHash, executedAt: nil, failureReason: nil, signature: nil, signingKeyId: nil)
    }
    private func receipt() -> ActionReceipt {
        ActionReceipt(id: "p1", proposalId: "p1", status: .pendingConnectivity, result: nil, targetSessionId: "s1", confirmedByHumanAt: ts, confirmedProposalHash: "H", executedAt: nil, failureReason: nil, signature: nil, signingKeyId: nil)
    }

    func testFlowUpToAwaitingConfirmation() {
        let s = PocketCall.run(.idle, [
            .bundleArrived(vb()),
            .answered(plan()),
            .interrupted,
            .questionAnswered(qa()),
            .proposalDrafted(invalidProposal(), challenge: challenge)
        ], gatewayKey: key)
        guard case .awaitingConfirmation = s else { return XCTFail("expected awaitingConfirmation, got \(s)") }
    }

    /// SAFETY: no event can shortcut into .executing. A `.confirmed`/`.executed` before awaitingConfirmation is a no-op.
    func testCannotShortcutIntoExecuting() {
        let conversing = PocketCall.run(.idle, [.bundleArrived(vb()), .answered(plan()), .briefingCompleted], gatewayKey: key)
        let anyCap = ConfirmationCapability(proposalId: "x", proposalHash: "x", targetSessionId: "x", targetSequence: 1, challenge: "x")
        XCTAssertEqual(PocketCall.reduce(conversing, .confirmed(anyCap), gatewayKey: key), conversing)
        XCTAssertEqual(PocketCall.reduce(conversing, .executed(receipt()), gatewayKey: key), conversing)
    }

    /// SAFETY: confirming an INVALID proposal does NOT advance, even with a correctly-bound capability + challenge.
    func testInvalidProposalConfirmDoesNotExecute() {
        let bad = invalidProposal()
        let awaiting = PocketCallState.awaitingConfirmation(vb(), bad, challenge: challenge)
        let cap = ConfirmationCapability.forReadBack(of: bad, challenge: challenge)   // binds identity + challenge
        let after = PocketCall.reduce(awaiting, .confirmed(cap), gatewayKey: key)
        if case .executing = after { XCTFail("invalid proposal must NOT execute") }
        guard case .awaitingConfirmation = after else { return XCTFail("expected to stay awaitingConfirmation") }
    }

    /// SAFETY (Echo #4): a correctly-shaped proposal for a DIFFERENT Senti session must NOT arm confirmation.
    func testWrongSessionProposalRefused() {
        let conversing = PocketCallState.conversing(vb(session: "s1"), answers: [])
        let foreign = ActionProposal(id: "p1", kind: .threadedReply, targetSessionId: "OTHER-ROOM", targetSequence: 10, renderedPreview: "x", requiresConfirmation: true, createdAt: ts, sourceQuestionId: nil, proposalHash: "H")
        let after = PocketCall.reduce(conversing, .proposalDrafted(foreign, challenge: challenge), gatewayKey: key)
        if case .awaitingConfirmation = after { XCTFail("wrong-session proposal must NOT arm confirmation") }
        guard case .conversing = after else { return XCTFail("expected to stay conversing") }
    }

    /// SAFETY: arming confirmation requires a non-empty per-episode challenge nonce.
    func testEmptyChallengeDoesNotArm() {
        let conversing = PocketCallState.conversing(vb(), answers: [])
        if case .awaitingConfirmation = PocketCall.reduce(conversing, .proposalDrafted(invalidProposal(), challenge: ""), gatewayKey: key) {
            XCTFail("empty challenge must NOT arm confirmation")
        }
    }

    #if canImport(CryptoKit)
    /// SAFETY (Echo #231350 — the decisive one): a stale confirm for proposal A cannot confirm a same-CONTENT but
    /// different-identity displayed proposal B, and the wrong episode challenge is refused. Under v0.1.8 A/B hash differ.
    func testConfirmSwapAndChallengeRefused() {
        let displayedB = ActionProposal(id: "pB", kind: .threadedReply, targetSessionId: "s1", targetSequence: 10, renderedPreview: "rotate token", createdAt: ts, sourceQuestionId: nil)
        let proposalA = ActionProposal(id: "pA", kind: .threadedReply, targetSessionId: "s1", targetSequence: 10, renderedPreview: "rotate token", createdAt: ts, sourceQuestionId: nil)
        XCTAssertNotEqual(displayedB.proposalHash, proposalA.proposalHash)   // identical content, different id -> different hash
        let awaiting = PocketCallState.awaitingConfirmation(vb(), displayedB, challenge: challenge)
        // stale capability for A must NOT confirm displayed B
        let capA = ConfirmationCapability.forReadBack(of: proposalA, challenge: challenge)
        guard case .awaitingConfirmation = PocketCall.reduce(awaiting, .confirmed(capA), gatewayKey: key) else { return XCTFail("A's cap must not confirm B") }
        // right proposal, WRONG challenge -> refused
        let capBWrongNonce = ConfirmationCapability.forReadBack(of: displayedB, challenge: "other-nonce")
        guard case .awaitingConfirmation = PocketCall.reduce(awaiting, .confirmed(capBWrongNonce), gatewayKey: key) else { return XCTFail("wrong challenge must not confirm") }
        // exact capability for B + right challenge -> executes
        let capB = ConfirmationCapability.forReadBack(of: displayedB, challenge: challenge)
        guard case .executing = PocketCall.reduce(awaiting, .confirmed(capB), gatewayKey: key) else { return XCTFail("B's exact cap should execute") }
    }
    #endif

    /// SAFETY (Echo #2): a briefing plan for a different checkpoint must not start the briefing.
    func testPlanProvenanceMismatchRefused() {
        let incoming = PocketCallState.incoming(vb(checkpoint: "cp1"))
        let after = PocketCall.reduce(incoming, .answered(plan(checkpoint: "OTHER-CP")), gatewayKey: key)
        guard case .incoming = after else { return XCTFail("cross-checkpoint plan must be refused") }
    }

    /// SAFETY (Echo #3): Q&A for a wrong checkpoint, or citing evidence absent from the bundle, is dropped.
    func testQAProvenanceAndCitationsEnforced() {
        let ev = EvidenceRef(id: "ev_1", sessionId: "s1", sequence: 1, agentId: "a", snippet: "x", ts: ts)
        let conversing = PocketCallState.conversing(vb(evidence: [ev]), answers: [])
        XCTAssertEqual(PocketCall.reduce(conversing, .questionAnswered(qa(checkpoint: "OTHER-CP")), gatewayKey: key), conversing)
        XCTAssertEqual(PocketCall.reduce(conversing, .questionAnswered(qa(citations: ["ev_UNKNOWN"])), gatewayKey: key), conversing)
        guard case let .conversing(_, answers) = PocketCall.reduce(conversing, .questionAnswered(qa(citations: ["ev_1"])), gatewayKey: key), answers.count == 1 else {
            return XCTFail("valid cited Q&A should append")
        }
    }

    func testCancelReturnsToConversing() {
        let awaiting = PocketCallState.awaitingConfirmation(vb(), invalidProposal(), challenge: challenge)
        guard case .conversing = PocketCall.reduce(awaiting, .cancelled, gatewayKey: key) else { return XCTFail("cancel -> conversing") }
    }

    func testDismissFromAnywhereExceptCompleted() {
        guard case .dismissed = PocketCall.reduce(.incoming(vb()), .dismiss, gatewayKey: key) else { return XCTFail() }
        guard case .dismissed = PocketCall.reduce(.awaitingConfirmation(vb(), invalidProposal(), challenge: challenge), .dismiss, gatewayKey: key) else { return XCTFail() }
        let done = PocketCallState.completed(receipt())
        guard case .completed = PocketCall.reduce(done, .dismiss, gatewayKey: key) else { return XCTFail("completed is terminal") }
    }

    #if canImport(CryptoKit)
    /// SAFETY (Echo #6/#7): only a receipt BOUND to the executing proposal completes the call.
    func testReceiptMustBindToExecutingProposal() {
        let valid = ActionProposal(id: "p1", kind: .threadedReply, targetSessionId: "s1", targetSequence: 10, renderedPreview: "rotate token", createdAt: ts, sourceQuestionId: nil)
        let executing = PocketCall.run(.idle, [
            .bundleArrived(vb()), .answered(plan()), .briefingCompleted,
            .proposalDrafted(valid, challenge: challenge), .confirmed(ConfirmationCapability.forReadBack(of: valid, challenge: challenge))
        ], gatewayKey: key)
        guard case .executing = executing else { return XCTFail("valid confirm -> executing, got \(executing)") }
        let foreign = ActionReceipt(id: "r9", proposalId: "pX", status: .pendingConnectivity, result: nil, targetSessionId: "s1", confirmedByHumanAt: ts, confirmedProposalHash: valid.proposalHash, executedAt: nil, failureReason: nil, signature: nil, signingKeyId: nil)
        guard case .executing = PocketCall.reduce(executing, .executed(foreign), gatewayKey: key) else { return XCTFail("unbound receipt must NOT complete") }
        let hashMismatch = ActionReceipt(id: "r9", proposalId: "p1", status: .pendingConnectivity, result: nil, targetSessionId: "s1", confirmedByHumanAt: ts, confirmedProposalHash: "NOPE", executedAt: nil, failureReason: nil, signature: nil, signingKeyId: nil)
        guard case .executing = PocketCall.reduce(executing, .executed(hashMismatch), gatewayKey: key) else { return XCTFail("hash-mismatch receipt must NOT complete") }
        guard case .completed = PocketCall.reduce(executing, .executed(boundPendingReceipt(for: valid)), gatewayKey: key) else { return XCTFail("bound receipt -> completed") }
    }

    /// SAFETY (Echo #6): a `.posted` receipt completes ONLY if its signature verifies under the pinned gateway key.
    func testPostedReceiptRequiresVerifiedSignature() throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let pub = b64url(signingKey.publicKey.rawRepresentation)
        let valid = ActionProposal(id: "p1", kind: .threadedReply, targetSessionId: "s1", targetSequence: 10, renderedPreview: "rotate token", createdAt: ts, sourceQuestionId: nil)
        let executing = PocketCall.run(.idle, [
            .bundleArrived(vb()), .answered(plan()), .briefingCompleted,
            .proposalDrafted(valid, challenge: challenge), .confirmed(ConfirmationCapability.forReadBack(of: valid, challenge: challenge))
        ], gatewayKey: pub)
        guard case .executing = executing else { return XCTFail("expected executing") }
        // Canonical payload excludes the signature field, so compute it on a placeholder then re-wrap.
        let toSign = ActionReceipt(id: "r1", proposalId: "p1", status: .posted, result: .action(actionId: "act_p1", targetSequenceId: 10, targetCursor: nil), targetSessionId: "s1", confirmedByHumanAt: ts, confirmedProposalHash: valid.proposalHash, executedAt: ts, failureReason: nil, signature: "PLACEHOLDER", signingKeyId: "gw")
        let sig = b64url(try signingKey.signature(for: Data(toSign.canonicalReceiptPayload().utf8)))
        let signed = ActionReceipt(id: "r1", proposalId: "p1", status: .posted, result: .action(actionId: "act_p1", targetSequenceId: 10, targetCursor: nil), targetSessionId: "s1", confirmedByHumanAt: ts, confirmedProposalHash: valid.proposalHash, executedAt: ts, failureReason: nil, signature: sig, signingKeyId: "gw")
        XCTAssertEqual(signed.signatureState(gatewayPublicKeyBase64url: pub), .verified)
        guard case .completed = PocketCall.reduce(executing, .executed(signed), gatewayKey: pub) else { return XCTFail("verified posted -> completed") }
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
