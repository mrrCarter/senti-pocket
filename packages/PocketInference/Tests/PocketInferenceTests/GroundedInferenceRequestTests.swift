import Foundation
@testable import PocketCall
import PocketContracts
@testable import PocketInference
import XCTest

final class GroundedInferenceRequestTests: XCTestCase {
    func testPublicInitializerBindsRequestToVerifiedBundleType() throws {
        let item = evidence(id: "ev_1", sessionId: "session_1", sequence: 12)
        let verifiedBundle = verifiedBundle(evidence: [item], sequenceStart: 10, sequenceEnd: 20)
        let bundle = verifiedBundle.bundle

        let request = try GroundedInferenceRequest(
            verifiedBundle: verifiedBundle,
            question: "What changed?"
        )

        XCTAssertEqual(request.checkpointId, bundle.checkpointId)
        XCTAssertEqual(request.sessionId, bundle.sessionId)
        XCTAssertEqual(request.sequenceStart, bundle.sequenceStart)
        XCTAssertEqual(request.sequenceEnd, bundle.sequenceEnd)
        XCTAssertEqual(request.evidence, bundle.evidence)
    }

    func testDefaultSelectionIsDeterministicAndKeepsTheMostRecent32Entries() throws {
        let evidence = (1...40).map { sequence in
            self.evidence(
                id: "ev_\(String(format: "%02d", sequence))",
                sessionId: "session_1",
                sequence: sequence
            )
        }
        let forward = verifiedBundle(evidence: evidence, sequenceStart: 1, sequenceEnd: 40)
        let reversed = verifiedBundle(evidence: evidence.reversed(), sequenceStart: 1, sequenceEnd: 40)

        let forwardRequest = try GroundedInferenceRequest(
            verifiedBundle: forward,
            question: "What changed?"
        )
        let reversedRequest = try GroundedInferenceRequest(
            verifiedBundle: reversed,
            question: "What changed?"
        )

        XCTAssertEqual(forwardRequest.evidence.count, GroundedInferenceRequest.maximumEvidenceCount)
        XCTAssertEqual(forwardRequest.evidence.map(\.sequence), Array(9...40))
        XCTAssertEqual(reversedRequest.evidence.map(\.id), forwardRequest.evidence.map(\.id))
    }

    func testInternalInitializerRejectsEvidenceNotPresentInBundle() throws {
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

    private func verifiedBundle<S: Sequence>(
        evidence: S,
        sequenceStart: Int,
        sequenceEnd: Int
    ) -> VerifiedBundle where S.Element == EvidenceRef {
        let evidence = Array(evidence)
        let testBundle = bundle(
            evidence: evidence,
            sequenceStart: sequenceStart,
            sequenceEnd: sequenceEnd,
            signature: "test-only",
            signingKeyId: "test-key"
        )
        return VerifiedBundle.makeUnverifiedForTesting(testBundle)
    }

    private func bundle(
        evidence: [EvidenceRef],
        sequenceStart: Int,
        sequenceEnd: Int,
        signature: String,
        signingKeyId: String
    ) -> PocketBundle {
        PocketBundle(
            contractsVersion: PocketContracts.version,
            checkpointId: "cp_1",
            sessionId: "session_1",
            sequenceStart: sequenceStart,
            sequenceEnd: sequenceEnd,
            summary: CheckpointSummary(
                checkpointId: "cp_1",
                headline: "Checkpoint",
                summaryBaselineSchema: "checkpoint_summary_sections_v1",
                grade: nil,
                perAgent: [],
                risks: [],
                blockers: []
            ),
            evidence: evidence,
            createdAt: Date(timeIntervalSince1970: 1_784_371_200),
            signature: signature,
            signingKeyId: signingKeyId
        )
    }
}
