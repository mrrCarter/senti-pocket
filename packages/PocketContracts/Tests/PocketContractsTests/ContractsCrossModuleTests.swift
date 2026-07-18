import XCTest
import PocketContracts   // SEPARATE module — this test IS the external-consumer proof (v0.1.1 fix).

/// Proves: every contract constructs cross-module (compile-fails if any public init regresses); Codable round-trips;
/// the v0.1.2 hash binding invalidates on any content change; and the v0.1.3 canonicalization is injection-proof
/// with a published known-answer vector (KAV_1) for Relay's Node gateway to mirror.
final class ContractsCrossModuleTests: XCTestCase {

    private let ts = Date(timeIntervalSince1970: 1_752_835_200)

    func testEveryContractConstructsCrossModule() throws {
        let ev = EvidenceRef(id: "ev_1", sessionId: "s1", sequence: 230141, agentId: "claude-pocket-relay", snippet: "atk_ parser matches live", ts: ts)
        let rawEvent = RawEvent(sequenceId: 230141, event: "session_message", agentId: "a1", payload: "hello", idempotencyToken: "tok1", ts: ts)
        let rawCp = RawCheckpoint(checkpointId: "cp1", sessionId: "s1", sessionTitle: "room", startSequence: 230100, endSequence: 230180, capturedAt: ts, agents: ["a1"], events: [rawEvent])
        let claim = Claim(id: "c1", text: "atk_ parser now matches live", kind: .fact, evidenceIds: ["ev_1"])
        let agentSummary = AgentSummary(agentId: "a1", summary: "did a thing", claims: [claim], evidence: [ev])
        let summary = CheckpointSummary(checkpointId: "cp1", headline: "what happened", summaryBaselineSchema: "checkpoint_summary_sections_v1", grade: "A-", perAgent: [agentSummary], risks: ["r"], blockers: ["b"])
        let bundle = PocketBundle(contractsVersion: PocketContracts.version, checkpointId: "cp1", sessionId: "s1", sequenceStart: 230100, sequenceEnd: 230180, summary: summary, evidence: [ev], createdAt: ts, signature: "sig", signingKeyId: "k1")
        let seg = BriefingSegment(id: "b1", text: "briefing text", evidenceIds: ["ev_1"])
        let plan = BriefingPlan(checkpointId: "cp1", segments: [seg])
        let qa = QuestionAnswer(id: "q1", checkpointId: "cp1", question: "why?", answer: "because ev_1", citations: ["ev_1"], answeredOffline: true, createdAt: ts)
        let proposal = ActionProposal(id: "p1", kind: .threadedReply, targetSessionId: "s1", targetSequence: 230180, renderedPreview: "rotate token", requiresConfirmation: true, createdAt: ts, sourceQuestionId: "q1", proposalHash: "PLACEHOLDER")
        let receipt = ActionReceipt(id: "p1", proposalId: "p1", status: .pendingConnectivity, resultingSequence: nil, targetSessionId: "s1", confirmedByHumanAt: ts, confirmedProposalHash: "PLACEHOLDER", executedAt: nil, failureReason: nil, signature: nil, signingKeyId: nil)

        XCTAssertEqual(rawCp.events.first?.sequenceId, 230141)
        XCTAssertEqual(bundle.contractsVersion, "0.1.3")
        XCTAssertEqual(agentSummary.claims.first?.kind, .fact)
        XCTAssertEqual(plan.segments.first?.evidenceIds, ["ev_1"])
        XCTAssertTrue(qa.answeredOffline)
        XCTAssertTrue(proposal.requiresConfirmation)
        XCTAssertEqual(receipt.status, .pendingConnectivity)      // offline never shown as sent
        XCTAssertNil(receipt.signature)                           // pending receipt is unsigned -> never "verified"
    }

    func testCodableRoundTripFromExternalModule() throws {
        let ev = EvidenceRef(id: "ev_1", sessionId: "s1", sequence: 1, agentId: "a1", snippet: "x", ts: ts)
        let data = try JSONEncoder().encode(ev)
        XCTAssertEqual(ev, try JSONDecoder().decode(EvidenceRef.self, from: data))
    }

    /// KAV_1 — Relay's Node gateway MUST produce this EXACT canonicalPayload string for the same inputs, or the
    /// cross-lane hash binding is broken. Length-prefixed: "<utf8-byte-count>:<bytes>" per field, v2 domain sep.
    func testKnownAnswerVectorCanonicalPayload() {
        let cp = ActionProposal.canonicalPayload(kind: .threadedReply, targetSessionId: "s1", targetSequence: 100, renderedPreview: "post X")
        XCTAssertEqual(cp, "pocket.actionproposal.v2\n13:threadedReply2:s13:1006:post X")
    }

    /// Injection resistance: under the OLD newline-delimiting these two collide ("...s\\n1\\n1\\nX"); length-prefix
    /// keeps them distinct. This is the collision Echo flagged (5f45364).
    func testCanonicalizationIsInjectionProof() {
        let a = ActionProposal.canonicalPayload(kind: .threadedReply, targetSessionId: "s", targetSequence: 1, renderedPreview: "1\nX")
        let b = ActionProposal.canonicalPayload(kind: .threadedReply, targetSessionId: "s\n1", targetSequence: 1, renderedPreview: "X")
        XCTAssertNotEqual(a, b)
    }

    #if canImport(CryptoKit)
    func testProposalHashBindingAndConfirmationGate() {
        let p = ActionProposal(id: "p1", kind: .threadedReply, targetSessionId: "s1", targetSequence: 100, renderedPreview: "post X", createdAt: ts, sourceQuestionId: nil)
        XCTAssertTrue(p.hashMatchesContent())
        XCTAssertTrue(p.isValidForConfirmation())                 // requiresConfirmation==true + hash matches + bounded
        // Swap the preview, keep the human-confirmed hash -> must NOT verify (TOCTOU-proof).
        let swapped = ActionProposal(id: "p1", kind: .threadedReply, targetSessionId: "s1", targetSequence: 100, renderedPreview: "post EVIL", createdAt: ts, sourceQuestionId: nil, proposalHash: p.proposalHash)
        XCTAssertFalse(swapped.hashMatchesContent())
        XCTAssertFalse(swapped.isValidForConfirmation())
        // requiresConfirmation=false is rejected even with a correct hash.
        let noConfirm = ActionProposal(id: "p1", kind: .threadedReply, targetSessionId: "s1", targetSequence: 100, renderedPreview: "post X", requiresConfirmation: false, createdAt: ts, sourceQuestionId: nil, proposalHash: p.proposalHash)
        XCTAssertFalse(noConfirm.isValidForConfirmation())
        // targetSequence <= 0 is rejected.
        let badSeq = ActionProposal(id: "p1", kind: .threadedReply, targetSessionId: "s1", targetSequence: 0, renderedPreview: "post X", createdAt: ts, sourceQuestionId: nil)
        XCTAssertFalse(badSeq.isValidForConfirmation())
    }
    #endif
}
