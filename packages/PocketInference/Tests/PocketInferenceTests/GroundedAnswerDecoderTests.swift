import Foundation
import PocketContracts
import PocketInference
import XCTest

final class GroundedAnswerDecoderTests: XCTestCase {
    func testAcceptsAnswerWithKnownCitation() throws {
        let answer = try GroundedAnswerDecoder().decode(
            Data(#"{"answer":"The canary cleared review.","citations":["ev_1"]}"#.utf8),
            checkpointId: "cp_1",
            question: "What happened?",
            allowedEvidenceIds: ["ev_1"],
            answerId: "qa_1",
            createdAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(answer.answer, "The canary cleared review.")
        XCTAssertEqual(answer.citations, ["ev_1"])
        XCTAssertTrue(answer.answeredOffline)
    }

    func testRejectsUnknownCitation() {
        XCTAssertThrowsError(
            try GroundedAnswerDecoder().decode(
                Data(#"{"answer":"Unsupported.","citations":["ev_unknown"]}"#.utf8),
                checkpointId: "cp_1",
                question: "What happened?",
                allowedEvidenceIds: ["ev_1"]
            )
        ) { error in
            XCTAssertEqual(error as? InferenceError, .unknownCitation("ev_unknown"))
        }
    }

    func testRequiresExactNoEvidenceAnswerWhenCitationsAreEmpty() {
        XCTAssertThrowsError(
            try GroundedAnswerDecoder().decode(
                Data(#"{"answer":"Probably safe.","citations":[]}"#.utf8),
                checkpointId: "cp_1",
                question: "Is it safe?",
                allowedEvidenceIds: ["ev_1"]
            )
        ) { error in
            XCTAssertEqual(error as? InferenceError, .ungroundedAnswer)
        }
    }

    func testAcceptsExactNoEvidenceAnswer() throws {
        let answer = try GroundedAnswerDecoder().decode(
            Data(#"{"answer":"I do not have evidence for that.","citations":[]}"#.utf8),
            checkpointId: "cp_1",
            question: "Is it safe?",
            allowedEvidenceIds: ["ev_1"]
        )

        XCTAssertEqual(answer.answer, GroundedAnswerDecoder.noEvidenceAnswer)
        XCTAssertTrue(answer.citations.isEmpty)
    }

    func testRejectsDuplicateCitation() {
        XCTAssertThrowsError(
            try GroundedAnswerDecoder().decode(
                Data(#"{"answer":"Supported.","citations":["ev_1","ev_1"]}"#.utf8),
                checkpointId: "cp_1",
                question: "Is it safe?",
                allowedEvidenceIds: ["ev_1"]
            )
        ) { error in
            XCTAssertEqual(error as? InferenceError, .duplicateCitation("ev_1"))
        }
    }

    func testRejectsExtraOutputFields() {
        XCTAssertThrowsError(
            try GroundedAnswerDecoder().decode(
                Data(#"{"answer":"Safe.","citations":["ev_1"],"tool":"deploy"}"#.utf8),
                checkpointId: "cp_1",
                question: "Is it safe?",
                allowedEvidenceIds: ["ev_1"]
            )
        ) { error in
            XCTAssertEqual(error as? InferenceError, .unsupportedModelOutputField("tool"))
        }
    }
}
