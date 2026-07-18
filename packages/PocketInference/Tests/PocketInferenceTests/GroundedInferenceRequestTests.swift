import Foundation
import PocketContracts
import PocketInference
import XCTest

final class GroundedInferenceRequestTests: XCTestCase {
    func testTrimsQuestionAndCheckpoint() throws {
        let request = try GroundedInferenceRequest(
            checkpointId: " cp_1 ",
            question: " What changed? ",
            evidence: [evidence(id: "ev_1")]
        )

        XCTAssertEqual(request.checkpointId, "cp_1")
        XCTAssertEqual(request.question, "What changed?")
    }

    func testRejectsDuplicateEvidenceIdentifiers() {
        XCTAssertThrowsError(
            try GroundedInferenceRequest(
                checkpointId: "cp_1",
                question: "What changed?",
                evidence: [evidence(id: "ev_1"), evidence(id: "ev_1")]
            )
        ) { error in
            XCTAssertEqual(error as? InferenceError, .invalidRequest("evidence IDs must be unique"))
        }
    }

    private func evidence(id: String) -> EvidenceRef {
        EvidenceRef(
            id: id,
            sessionId: "session_1",
            sequence: 1,
            agentId: "agent_1",
            snippet: "Grounded evidence",
            ts: Date(timeIntervalSince1970: 0)
        )
    }
}
