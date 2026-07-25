import XCTest
import PocketContracts
import PocketBriefing

final class BriefingBuilderTests: XCTestCase {
    private let ts = Date(timeIntervalSince1970: 1_752_835_200)

    private func summary() -> CheckpointSummary {
        let ev = EvidenceRef(id: "ev_1", sessionId: "s", sequence: 1, agentId: "a", snippet: "x", ts: ts)
        let a1 = AgentSummary(agentId: "claude-pocket-relay", summary: "s", claims: [
            Claim(id: "c1", text: "Extraction works.", kind: .fact, evidenceIds: ["ev_1"]),
            Claim(id: "c2", text: "Freeze contracts first.", kind: .recommendation, evidenceIds: [])
        ], evidence: [ev])
        return CheckpointSummary(checkpointId: "cp1", headline: "Progress made.", summaryBaselineSchema: "checkpoint_summary_sections_v1", grade: "A", perAgent: [a1], risks: [], blockers: ["billing"])
    }

    func testDeterministicPlanOrderAndGrounding() {
        let plan = BriefingBuilder.plan(from: summary())
        XCTAssertEqual(plan.segments.first?.id, "seg-headline")                 // headline first
        let agentSeg = plan.segments.first { $0.id == "seg-agent-claude-pocket-relay" }
        XCTAssertNotNil(agentSeg)
        XCTAssertTrue(agentSeg!.text.contains("Extraction works."))             // fact spoken
        XCTAssertFalse(agentSeg!.text.contains("Freeze contracts first."))      // recommendation held back
        XCTAssertEqual(agentSeg!.evidenceIds, ["ev_1"])                         // evidence carried for the card
        let recSeg = plan.segments.first { $0.id == "seg-recommendations" }
        XCTAssertTrue(recSeg?.text.contains("Freeze contracts first.") ?? false) // rec framed as suggestion, separate
        XCTAssertEqual(plan.segments.last?.id, "seg-blockers")                  // blockers last
        XCTAssertEqual(plan.checkpointId, "cp1")
        XCTAssertEqual(plan, BriefingBuilder.plan(from: summary()))            // deterministic
    }
}
