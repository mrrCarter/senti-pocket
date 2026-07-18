import XCTest
@testable import PocketContracts   // @testable not required, but harmless; the point is this is a SEPARATE module.
import PocketContracts

/// Proves (per Echo's v0.1 blocker) that every public contract can be CONSTRUCTED from an external
/// module via its explicit `public init`, and Codable round-trips. If any public init is missing/internal,
/// this test target fails to COMPILE — which is the regression guard Echo asked for.
final class ContractsCrossModuleTests: XCTestCase {

    private let ts = Date(timeIntervalSince1970: 1_752_835_200) // fixed instant (no Date() nondeterminism)

    func testEveryContractConstructsCrossModule() throws {
        let ev = EvidenceRef(id: "ev_1", sessionId: "s1", sequence: 230141, agentId: "claude-pocket-relay", snippet: "atk_ parser matches live", ts: ts)
        let rawEvent = RawEvent(sequenceId: 230141, event: "session_message", agentId: "a1", payload: "hello", idempotencyToken: "tok1", ts: ts)
        let rawCp = RawCheckpoint(checkpointId: "cp1", sessionId: "s1", sessionTitle: "room", startSequence: 230100, endSequence: 230180, capturedAt: ts, agents: ["a1"], events: [rawEvent])
        let agentSummary = AgentSummary(agentId: "a1", summary: "did a thing", evidence: [ev])
        let summary = CheckpointSummary(checkpointId: "cp1", headline: "what happened", summaryBaselineSchema: "checkpoint_summary_sections_v1", grade: "A-", perAgent: [agentSummary], risks: ["r"], blockers: ["b"])
        let bundle = PocketBundle(contractsVersion: PocketContracts.version, checkpointId: "cp1", sessionId: "s1", sequenceStart: 230100, sequenceEnd: 230180, summary: summary, evidence: [ev], createdAt: ts, signature: "sig", signingKeyId: "k1")
        let seg = BriefingSegment(id: "b1", text: "briefing text", evidenceIds: ["ev_1"])
        let plan = BriefingPlan(checkpointId: "cp1", segments: [seg])
        let qa = QuestionAnswer(id: "q1", checkpointId: "cp1", question: "why?", answer: "because ev_1", citations: ["ev_1"], answeredOffline: true, createdAt: ts)
        let proposal = ActionProposal(id: "p1", kind: .threadedReply, targetSessionId: "s1", targetSequence: 230180, renderedPreview: "rotate token; do not deploy until Omar green", requiresConfirmation: true, createdAt: ts, sourceQuestionId: "q1")
        let receipt = ActionReceipt(id: "p1", proposalId: "p1", status: .pendingConnectivity, resultingSequence: nil, targetSessionId: "s1", confirmedByHumanAt: ts, executedAt: nil, failureReason: nil)

        XCTAssertEqual(rawCp.events.first?.sequenceId, 230141)
        XCTAssertEqual(bundle.contractsVersion, "0.1.1")
        XCTAssertEqual(plan.segments.first?.evidenceIds, ["ev_1"])
        XCTAssertTrue(qa.answeredOffline)
        XCTAssertTrue(proposal.requiresConfirmation)              // safety invariant
        XCTAssertEqual(proposal.kind, .threadedReply)
        XCTAssertEqual(receipt.status, .pendingConnectivity)      // offline never shown as sent
        XCTAssertNil(receipt.resultingSequence)
    }

    func testCodableRoundTripFromExternalModule() throws {
        let ev = EvidenceRef(id: "ev_1", sessionId: "s1", sequence: 1, agentId: "a1", snippet: "x", ts: ts)
        let enc = JSONEncoder(); let dec = JSONDecoder()
        let data = try enc.encode(ev)
        let back = try dec.decode(EvidenceRef.self, from: data)
        XCTAssertEqual(ev, back)
    }
}
