import Foundation
import PocketContracts
@testable import PocketInference
import XCTest

final class GroundedInferenceRequestTests: XCTestCase {
    func testPublicInitializerBindsRequestToOneBundle() throws {
        let item = evidence(id: "ev_1", sessionId: "session_1", sequence: 12)
        let summary = CheckpointSummary(
            checkpointId: "cp_1",
            headline: "Checkpoint",
            summaryBaselineSchema: "checkpoint_summary_sections_v1",
            grade: nil,
            perAgent: [],
            risks: [],
            blockers: []
        )
        let bundle = PocketBundle(
            contractsVersion: PocketContracts.version,
            checkpointId: "cp_1",
            sessionId: "session_1",
            sequenceStart: 10,
            sequenceEnd: 20,
            summary: summary,
            evidence: [item],
            createdAt: Date(timeIntervalSince1970: 0),
            signature: "fixture",
            signingKeyId: "fixture-key"
        )

        let request = try GroundedInferenceRequest(bundle: bundle, question: "What changed?")

        XCTAssertEqual(request.checkpointId, bundle.checkpointId)
        XCTAssertEqual(request.sessionId, bundle.sessionId)
        XCTAssertEqual(request.sequenceStart, bundle.sequenceStart)
        XCTAssertEqual(request.sequenceEnd, bundle.sequenceEnd)
        XCTAssertEqual(request.evidence, bundle.evidence)
    }

    func testPublicInitializerRejectsEvidenceNotPresentInBundle() throws {
        let bundledEvidence = evidence(id: "ev_1", sessionId: "session_1", sequence: 12)
        let bundle = PocketBundle(
            contractsVersion: PocketContracts.version,
            checkpointId: "cp_1",
            sessionId: "session_1",
            sequenceStart: 10,
            sequenceEnd: 20,
            summary: CheckpointSummary(
                checkpointId: "cp_1",
                headline: "Checkpoint",
                summaryBaselineSchema: "checkpoint_summary_sections_v1",
                grade: nil,
                perAgent: [],
                risks: [],
                blockers: []
            ),
            evidence: [bundledEvidence],
            createdAt: Date(timeIntervalSince1970: 0),
            signature: "fixture",
            signingKeyId: "fixture-key"
        )
        let forgedEvidence = EvidenceRef(
            id: bundledEvidence.id,
            sessionId: bundledEvidence.sessionId,
            sequence: bundledEvidence.sequence,
            agentId: bundledEvidence.agentId,
            snippet: "Forged replacement content",
            ts: bundledEvidence.ts
        )

        XCTAssertThrowsError(
            try GroundedInferenceRequest(
                bundle: bundle,
                question: "What changed?",
                evidence: [forgedEvidence]
            )
        ) { error in
            XCTAssertEqual(
                error as? InferenceError,
                .invalidRequest("evidence must be an exact subset of the supplied bundle")
            )
        }
    }

    func testTrimsQuestionAndCheckpoint() throws {
        let request = try GroundedInferenceRequest(
            checkpointId: " cp_1 ",
            sessionId: " session_1 ",
            sequenceStart: 1,
            sequenceEnd: 10,
            question: " What changed? ",
            evidence: [evidence(id: "ev_1")]
        )

        XCTAssertEqual(request.checkpointId, "cp_1")
        XCTAssertEqual(request.sessionId, "session_1")
        XCTAssertEqual(request.question, "What changed?")
    }

    func testRejectsDuplicateEvidenceIdentifiers() {
        XCTAssertThrowsError(
            try GroundedInferenceRequest(
                checkpointId: "cp_1",
                sessionId: "session_1",
                sequenceStart: 1,
                sequenceEnd: 10,
                question: "What changed?",
                evidence: [evidence(id: "ev_1"), evidence(id: "ev_1")]
            )
        ) { error in
            XCTAssertEqual(error as? InferenceError, .invalidRequest("evidence IDs must be unique"))
        }
    }

    func testRejectsEvidenceFromAnotherSessionOrOutsideCheckpointRange() {
        XCTAssertThrowsError(
            try GroundedInferenceRequest(
                checkpointId: "cp_1",
                sessionId: "session_1",
                sequenceStart: 10,
                sequenceEnd: 20,
                question: "What changed?",
                evidence: [evidence(id: "ev_foreign", sessionId: "session_2", sequence: 12)]
            )
        )
        XCTAssertThrowsError(
            try GroundedInferenceRequest(
                checkpointId: "cp_1",
                sessionId: "session_1",
                sequenceStart: 10,
                sequenceEnd: 20,
                question: "What changed?",
                evidence: [evidence(id: "ev_outside", sessionId: "session_1", sequence: 21)]
            )
        )
    }

    private func evidence(id: String, sessionId: String = "session_1", sequence: Int = 1) -> EvidenceRef {
        EvidenceRef(
            id: id,
            sessionId: sessionId,
            sequence: sequence,
            agentId: "agent_1",
            snippet: "Grounded evidence",
            ts: Date(timeIntervalSince1970: 0)
        )
    }
}
