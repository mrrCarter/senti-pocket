// Proof the driver maps provider outcomes to phases honestly: success → ready/answered (carrying provenance),
// a thrown error → .failed (surfaced, never a crash or a fabricated result). No live LLM, no simulator.

import XCTest
import PocketContracts
@testable import PocketReasoning

private struct MockProvider: ReasoningProvider {
    let provenance: ReasoningProvenance
    var briefingResult: Result<BriefingPlan, Error>
    var answerResult: Result<ReasonedAnswer, Error>
    func briefing(sessionId: String, checkpointId: String?) async throws -> BriefingPlan {
        try briefingResult.get()
    }
    func answer(_ question: String, sessionId: String, checkpointId: String?) async throws -> ReasonedAnswer {
        try answerResult.get()
    }
}

private struct BoomError: Error {}

final class ReasoningDriverTests: XCTestCase {
    private let plan = BriefingPlan(checkpointId: "cp_1", segments: [
        BriefingSegment(id: "seg-0", text: "reasoned briefing", evidenceIds: ["ev_1"])
    ])
    private let answered = ReasonedAnswer.answered(ReasonedQuestionAnswer(
        id: "a1", checkpointId: "cp_1", question: "q", text: "grounded answer", taggedText: nil,
        evidenceIds: ["ev_1"], llmConfidence: 0.9, provenance: .liveReasoned,
        createdAt: Date(timeIntervalSince1970: 1_784_370_900)))

    func test_briefing_success_carries_plan_and_provenance() async {
        let p = MockProvider(provenance: .liveReasoned, briefingResult: .success(plan), answerResult: .failure(BoomError()))
        let phase = await ReasoningDriver(provider: p).loadBriefing(sessionId: "s1", checkpointId: "cp_1")
        XCTAssertEqual(phase, .briefingReady(plan, provenance: .liveReasoned))
    }

    func test_answer_success_carries_result_and_provenance() async {
        let p = MockProvider(provenance: .liveReasoned, briefingResult: .failure(BoomError()), answerResult: .success(answered))
        let phase = await ReasoningDriver(provider: p).answer("q", sessionId: "s1", checkpointId: "cp_1")
        XCTAssertEqual(phase, .answered(answered, provenance: .liveReasoned))
    }

    func test_provider_error_becomes_failed_not_a_crash() async {
        let p = MockProvider(provenance: .liveReasoned, briefingResult: .failure(BoomError()), answerResult: .failure(BoomError()))
        let phase = await ReasoningDriver(provider: p).loadBriefing(sessionId: "s1", checkpointId: nil)
        guard case .failed = phase else { return XCTFail("provider error must surface as .failed, got \(phase)") }
    }

    func test_cached_provenance_is_surfaced_so_ui_can_label_it() async {
        // A cached provider drives the same way but stamps .cachedSample -> the view labels it, never "live".
        let p = MockProvider(provenance: .cachedSample, briefingResult: .success(plan), answerResult: .failure(BoomError()))
        let phase = await ReasoningDriver(provider: p).loadBriefing(sessionId: "s1", checkpointId: "cp_1")
        XCTAssertEqual(phase, .briefingReady(plan, provenance: .cachedSample))
    }
}
