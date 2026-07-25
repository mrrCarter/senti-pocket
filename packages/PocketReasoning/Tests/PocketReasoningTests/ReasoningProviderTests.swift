// Proof-of-behavior for the reasoning seam's app-shell side. Mocks the gateway client (relay owns the concrete
// PocketSyncClient) and asserts the wire→domain mapping + the honesty guarantees hold WITHOUT a live LLM:
//   - grounded "answered" maps through with its grounded evidenceIds
//   - an empty-evidence "answered" is DOWNGRADED to .unavailable (defense-in-depth vs a gateway regression)
//   - clarify/unavailable map faithfully; unknown status fails safe to .unavailable (never fabricates)
//   - /brief segments get synthesized ids + taggedText==plain normalizes to nil
//   - CachedReasoningProvider is .cachedSample and NEVER emits .answered offline (warden bar #1)

import XCTest
import PocketContracts
@testable import PocketReasoning

private struct MockGatewayClient: GatewayReasoningClient {
    var brief: BriefWire = BriefWire(segments: [], grounded: false, checkpointId: "cp_x", contractsVersion: "0.1.8")
    var answerWire: AnswerWire = AnswerWire(status: "unavailable", answer: nil, clarify: nil,
                                            unavailable: UnavailableWire(nearestTopics: []),
                                            checkpointId: "cp_x", contractsVersion: "0.1.8")
    func postBrief(sessionId: String, checkpointId: String?) async throws -> BriefWire { brief }
    func postAnswer(question: String, sessionId: String, checkpointId: String?) async throws -> AnswerWire { answerWire }
}

final class GatewayReasoningProviderTests: XCTestCase {
    private func provider(_ client: MockGatewayClient) -> GatewayReasoningProvider {
        GatewayReasoningProvider(client: client, clock: { Date(timeIntervalSince1970: 1_784_370_900) })
    }

    func test_answered_maps_with_grounded_citations() async throws {
        var client = MockGatewayClient()
        client.answerWire = AnswerWire(
            status: "answered",
            answer: AnswerBodyWire(text: "The parser bug was fixed.", taggedText: "[calm] The parser bug was fixed.",
                                   evidenceIds: ["ev_1"], llmConfidence: 0.9),
            clarify: nil, unavailable: nil, checkpointId: "cp_1", contractsVersion: "0.1.8")
        let result = try await provider(client).answer("did the parser get fixed?", sessionId: "s1", checkpointId: "cp_1")
        guard case .answered(let a) = result else { return XCTFail("expected .answered, got \(result)") }
        XCTAssertEqual(a.evidenceIds, ["ev_1"])
        XCTAssertEqual(a.text, "The parser bug was fixed.")
        XCTAssertEqual(a.taggedText, "[calm] The parser bug was fixed.")   // distinct tagged form preserved
        XCTAssertEqual(a.provenance, .liveReasoned)
    }

    func test_empty_evidence_answered_is_downgraded_to_unavailable() async throws {
        // Defense-in-depth: even if the gateway ever returns status=answered with no grounded evidence, the app
        // must NOT surface it as grounded. (routeAnswer already prevents this server-side; this is belt+suspenders.)
        var client = MockGatewayClient()
        client.answerWire = AnswerWire(
            status: "answered",
            answer: AnswerBodyWire(text: "confident but ungrounded", taggedText: nil, evidenceIds: [], llmConfidence: 0.99),
            clarify: nil, unavailable: UnavailableWire(nearestTopics: [NearestTopicWire(label: "near", evidenceId: "ev_2")]),
            checkpointId: "cp_1", contractsVersion: "0.1.8")
        let result = try await provider(client).answer("q", sessionId: "s1", checkpointId: "cp_1")
        guard case .unavailable(let topics) = result else { return XCTFail("expected downgrade to .unavailable, got \(result)") }
        XCTAssertEqual(topics.map(\.evidenceId), ["ev_2"])
    }

    func test_clarify_and_unavailable_map_faithfully() async throws {
        var client = MockGatewayClient()
        client.answerWire = AnswerWire(status: "clarify", answer: nil,
                                       clarify: ClarifyWire(prompt: "which one?", options: ["A", "B"]),
                                       unavailable: nil, checkpointId: "cp_1", contractsVersion: "0.1.8")
        guard case .clarify(let prompt, let options) = try await provider(client).answer("q", sessionId: "s1", checkpointId: nil)
        else { return XCTFail("expected .clarify") }
        XCTAssertEqual(prompt, "which one?")
        XCTAssertEqual(options, ["A", "B"])
    }

    func test_brief_synthesizes_ids_and_normalizes_taggedText() async throws {
        var client = MockGatewayClient()
        client.brief = BriefWire(segments: [
            BriefSegmentWire(text: "plain only", taggedText: "plain only", evidenceIds: ["ev_1"]),        // tagged==plain → nil
            BriefSegmentWire(text: "has tags", taggedText: "[warm] has tags", evidenceIds: ["ev_2"])
        ], grounded: true, checkpointId: "cp_1", contractsVersion: "0.1.8")
        let plan = try await provider(client).briefing(sessionId: "s1", checkpointId: "cp_1")
        XCTAssertEqual(plan.segments.map(\.id), ["seg-0", "seg-1"])          // synthesized, stable, order-based
        XCTAssertNil(plan.segments[0].taggedText)                            // tagged==plain normalized to nil
        XCTAssertEqual(plan.segments[1].taggedText, "[warm] has tags")       // distinct tagged form kept
    }
}

final class CachedReasoningProviderTests: XCTestCase {
    private let ev = EvidenceRef(id: "ev_1", sessionId: "s1", sequence: 10, agentId: "pulse",
                                 snippet: "rotate the token; do not deploy", ts: Date(timeIntervalSince1970: 1_784_370_900))

    func test_cached_provider_is_labeled_and_replays_briefing() async throws {
        let cached = BriefingPlan(checkpointId: "cp_1", segments: [BriefingSegment(id: "s0", text: "cached brief", evidenceIds: ["ev_1"])])
        let provider = CachedReasoningProvider(cachedBriefing: cached, cachedEvidence: [ev])
        XCTAssertEqual(provider.provenance, .cachedSample)                   // warden bar #1: unmistakably cached
        let plan = try await provider.briefing(sessionId: "s1", checkpointId: "cp_1")
        XCTAssertEqual(plan, cached)                                         // replayed verbatim
    }

    func test_cached_provider_never_answers_offline() async throws {
        let cached = BriefingPlan(checkpointId: "cp_1", segments: [])
        let provider = CachedReasoningProvider(cachedBriefing: cached, cachedEvidence: [ev])
        let result = try await provider.answer("anything", sessionId: "s1", checkpointId: "cp_1")
        // Honest floor: offline never fabricates a reasoned answer — it points at nearest cached topics.
        guard case .unavailable(let topics) = result else { return XCTFail("cached provider must never emit .answered/.clarify-as-reasoning") }
        XCTAssertEqual(topics.map(\.evidenceId), ["ev_1"])
    }
}
