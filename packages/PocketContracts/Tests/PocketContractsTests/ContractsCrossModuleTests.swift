import XCTest
import PocketContracts   // SEPARATE module — this test IS the external-consumer proof (v0.1.1 fix).

/// Cross-module construction (compile-guard on public inits); Codable round-trip; hash binding invalidates on
/// change; injection-proof canonicalization + a published known-answer HASH (Echo 84d463f) mirrored by Node;
/// isValidForConfirmation fails closed; ActionReceipt structural + signature invariants.
final class ContractsCrossModuleTests: XCTestCase {

    private let ts = Date(timeIntervalSince1970: 1_752_835_200)

    func testEveryContractConstructsCrossModule() throws {
        let ev = EvidenceRef(id: "ev_1", sessionId: "s1", sequence: 230141, agentId: "a", snippet: "x", ts: ts)
        let rawEvent = RawEvent(sequenceId: 230141, event: "session_message", agentId: "a1", payload: "hello", idempotencyToken: "tok1", ts: ts)
        let rawCp = RawCheckpoint(checkpointId: "cp1", sessionId: "s1", sessionTitle: "room", startSequence: 230100, endSequence: 230180, capturedAt: ts, agents: ["a1"], events: [rawEvent])
        let claim = Claim(id: "c1", text: "fact", kind: .fact, evidenceIds: ["ev_1"])
        let agentSummary = AgentSummary(agentId: "a1", summary: "s", claims: [claim], evidence: [ev])
        let summary = CheckpointSummary(checkpointId: "cp1", headline: "h", summaryBaselineSchema: "checkpoint_summary_sections_v1", grade: "A-", perAgent: [agentSummary], risks: ["r"], blockers: ["b"])
        let bundle = PocketBundle(contractsVersion: PocketContracts.version, checkpointId: "cp1", sessionId: "s1", sequenceStart: 230100, sequenceEnd: 230180, summary: summary, evidence: [ev], createdAt: ts, signature: "sig", signingKeyId: "k1")
        _ = BriefingPlan(checkpointId: "cp1", segments: [BriefingSegment(id: "b1", text: "t", evidenceIds: ["ev_1"])])
        _ = QuestionAnswer(id: "q1", checkpointId: "cp1", question: "?", answer: "a", citations: ["ev_1"], answeredOffline: true, createdAt: ts)
        _ = ActionProposal(id: "p1", kind: .threadedReply, targetSessionId: "s1", targetSequence: 230180, renderedPreview: "x", requiresConfirmation: true, createdAt: ts, sourceQuestionId: "q1", proposalHash: "H")

        XCTAssertEqual(rawCp.events.first?.sequenceId, 230141)
        XCTAssertEqual(bundle.contractsVersion, "0.1.4")
        XCTAssertEqual(agentSummary.claims.first?.kind, .fact)
    }

    func testCodableRoundTripFromExternalModule() throws {
        let ev = EvidenceRef(id: "ev_1", sessionId: "s1", sequence: 1, agentId: "a1", snippet: "x", ts: ts)
        let data = try JSONEncoder().encode(ev)
        XCTAssertEqual(ev, try JSONDecoder().decode(EvidenceRef.self, from: data))
    }

    /// KAV_1 — the exact canonicalPayload string. Relay's Node gateway MUST match this byte-for-byte.
    func testKnownAnswerVectorCanonicalPayload() {
        XCTAssertEqual(
            ActionProposal.canonicalPayload(kind: .threadedReply, targetSessionId: "s1", targetSequence: 100, renderedPreview: "post X"),
            "pocket.actionproposal.v2\n13:threadedReply2:s13:1006:post X")
    }

    /// Injection resistance: under OLD newline-delimiting these collide; length-prefix keeps them distinct.
    func testCanonicalizationIsInjectionProof() {
        let a = ActionProposal.canonicalPayload(kind: .threadedReply, targetSessionId: "s", targetSequence: 1, renderedPreview: "1\nX")
        let b = ActionProposal.canonicalPayload(kind: .threadedReply, targetSessionId: "s\n1", targetSequence: 1, renderedPreview: "X")
        XCTAssertNotEqual(a, b)
    }

    func testReceiptStructuralInvariants() {
        // pending: no posted fields -> valid.
        let pending = ActionReceipt(id: "p1", proposalId: "p1", status: .pendingConnectivity, resultingSequence: nil, targetSessionId: "s1", confirmedByHumanAt: ts, confirmedProposalHash: "H", executedAt: nil, failureReason: nil, signature: nil, signingKeyId: nil)
        XCTAssertTrue(pending.isStructurallyValid())
        // pending WITH a signature -> invalid (a pending write must never look sent/signed).
        let pendingSigned = ActionReceipt(id: "p1", proposalId: "p1", status: .pendingConnectivity, resultingSequence: nil, targetSessionId: "s1", confirmedByHumanAt: ts, confirmedProposalHash: "H", executedAt: nil, failureReason: nil, signature: "sig", signingKeyId: "k")
        XCTAssertFalse(pendingSigned.isStructurallyValid())
        // posted MISSING signature/seq -> invalid.
        let postedBad = ActionReceipt(id: "p1", proposalId: "p1", status: .posted, resultingSequence: nil, targetSessionId: "s1", confirmedByHumanAt: ts, confirmedProposalHash: "H", executedAt: nil, failureReason: nil, signature: nil, signingKeyId: nil)
        XCTAssertFalse(postedBad.isStructurallyValid())
        // fully-formed posted -> valid.
        let postedGood = ActionReceipt(id: "p1", proposalId: "p1", status: .posted, resultingSequence: 200, targetSessionId: "s1", confirmedByHumanAt: ts, confirmedProposalHash: "H", executedAt: ts, failureReason: nil, signature: "sig", signingKeyId: "k")
        XCTAssertTrue(postedGood.isStructurallyValid())
    }

    #if canImport(CryptoKit)
    func testProposalHashBindingAndConfirmationGate() {
        let p = ActionProposal(id: "p1", kind: .threadedReply, targetSessionId: "s1", targetSequence: 100, renderedPreview: "post X", createdAt: ts, sourceQuestionId: nil)
        XCTAssertTrue(p.hashMatchesContent())
        XCTAssertTrue(p.isValidForConfirmation())
        // Echo 84d463f KAV HASH: SHA-256(base64url) of the v2 payload for ('threadedReply','s1',100,'post X').
        XCTAssertEqual(p.proposalHash, "mNZp-a77Q1I1LSKOyhsEqjb60JW7Z3Cim_bzmCI_sqc")
        let swapped = ActionProposal(id: "p1", kind: .threadedReply, targetSessionId: "s1", targetSequence: 100, renderedPreview: "post EVIL", createdAt: ts, sourceQuestionId: nil, proposalHash: p.proposalHash)
        XCTAssertFalse(swapped.isValidForConfirmation())
        let noConfirm = ActionProposal(id: "p1", kind: .threadedReply, targetSessionId: "s1", targetSequence: 100, renderedPreview: "post X", requiresConfirmation: false, createdAt: ts, sourceQuestionId: nil, proposalHash: p.proposalHash)
        XCTAssertFalse(noConfirm.isValidForConfirmation())
    }
    #endif
}
