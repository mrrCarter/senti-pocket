import XCTest
import PocketContracts
@testable import PocketReasoning

/// Locks the DialReasoner honesty invariant: a grounded answer speaks the answer + carries evidence; clarify/
/// unavailable/error are spoken as HONEST non-grounded results — never fabricated as if from the session.
private struct StubProvider: ReasoningProvider {
    let provenance: ReasoningProvenance = .liveReasoned
    let result: ReasonedAnswer
    var throwsError = false
    func briefing(sessionId: String, checkpointId: String?) async throws -> BriefingPlan {
        BriefingPlan(checkpointId: "cp", segments: [])
    }
    func answer(_ q: String, sessionId: String, checkpointId: String?) async throws -> ReasonedAnswer {
        if throwsError { throw NSError(domain: "x", code: 1) }
        return result
    }
}

final class DialReasonerTests: XCTestCase {
    private func reasoner(_ r: ReasonedAnswer, throwsError: Bool = false) -> ProviderDialReasoner {
        ProviderDialReasoner(provider: StubProvider(result: r, throwsError: throwsError))
    }

    func test_answered_is_grounded_and_carries_evidence() async {
        let qa = ReasonedQuestionAnswer(id: "a", checkpointId: "cp", question: "q", text: "The token was rotated.",
                                        taggedText: nil, evidenceIds: ["ev_1"], llmConfidence: 0.9,
                                        provenance: .liveReasoned, createdAt: Date(timeIntervalSince1970: 1))
        let out = await reasoner(.answered(qa)).answerFollowUp("did the token rotate?", sessionId: "s", checkpointId: "cp")
        XCTAssertTrue(out.grounded)
        XCTAssertEqual(out.spokenText, "The token was rotated.")
        XCTAssertEqual(out.evidenceIds, ["ev_1"])
    }

    func test_unavailable_is_not_grounded_and_never_invents() async {
        let out = await reasoner(.unavailable(nearestTopics: [NearestTopic(label: "auth-scope decision", evidenceId: "ev_2")]))
            .answerFollowUp("what about billing?", sessionId: "s", checkpointId: "cp")
        XCTAssertFalse(out.grounded)                              // honest — not presented as a session answer
        XCTAssertTrue(out.spokenText.contains("closest context"))
        XCTAssertTrue(out.evidenceIds.isEmpty)                    // no fabricated citations
    }

    func test_clarify_asks_not_guesses() async {
        let out = await reasoner(.clarify(prompt: "Which checkpoint did you mean?", options: ["tonight's", "the earlier one"]))
            .answerFollowUp("that one", sessionId: "s", checkpointId: nil)
        XCTAssertFalse(out.grounded)
        XCTAssertTrue(out.spokenText.contains("Which checkpoint"))
    }

    func test_reasoning_failure_is_honest_never_fabricated() async {
        let qa = ReasonedQuestionAnswer(id: "a", checkpointId: "cp", question: "q", text: "x", taggedText: nil,
                                        evidenceIds: ["ev_1"], llmConfidence: nil, provenance: .liveReasoned,
                                        createdAt: Date(timeIntervalSince1970: 1))
        let out = await reasoner(.answered(qa), throwsError: true).answerFollowUp("q", sessionId: "s", checkpointId: "cp")
        XCTAssertFalse(out.grounded)
        XCTAssertTrue(out.spokenText.contains("couldn't reach"))  // honest failure, not a made-up answer
    }
}
