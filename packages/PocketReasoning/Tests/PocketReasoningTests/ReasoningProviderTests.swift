// Proof-of-behavior for the reasoning seam's app-shell side. Mocks the gateway client (relay owns the concrete
// PocketSyncClient) and asserts the wire→domain mapping + the honesty guarantees hold WITHOUT a live LLM:
//   - grounded "answered" maps through with its grounded evidenceIds
//   - an empty-evidence "answered" is DOWNGRADED to .unavailable (defense-in-depth vs a gateway regression)
//   - clarify/unavailable map faithfully; unknown status fails safe to .unavailable (never fabricates)
//   - /brief segments get synthesized ids + taggedText==plain normalizes to nil
//   - /brief is admitted only when the envelope is grounded, version/checkpoint-bound, well-formed, and bounded
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

final class UnboundGatewayReasoningProviderTests: XCTestCase {
    func testNearestTopicSwiftUIIdentityIsUTF8ByteExact() {
        let composed = NearestTopic(label: "first", evidenceId: "ev-caf\u{00E9}")
        let decomposed = NearestTopic(label: "second", evidenceId: "ev-cafe\u{0301}")
        XCTAssertEqual(composed.evidenceId, decomposed.evidenceId, "precondition: String is canonical")
        XCTAssertNotEqual(composed.id, decomposed.id)
        XCTAssertNotEqual(composed, decomposed)
    }

    private func provider(_ client: MockGatewayClient) -> UnboundGatewayReasoningProvider {
        UnboundGatewayReasoningProvider(client: client, clock: { Date(timeIntervalSince1970: 1_784_370_900) })
    }

    private func assertBriefingFails(
        _ brief: BriefWire,
        as expected: GatewayReasoningProviderError,
        requestedCheckpointId: String? = "cp_1",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        var client = MockGatewayClient()
        client.brief = brief
        do {
            _ = try await provider(client).briefing(
                sessionId: "s1",
                checkpointId: requestedCheckpointId
            )
            XCTFail("expected briefing admission to fail", file: file, line: line)
        } catch let error as GatewayReasoningProviderError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }

    private func validBrief(
        segments: [BriefSegmentWire] = [
            BriefSegmentWire(text: "grounded", taggedText: "[calm] grounded", evidenceIds: ["ev_1"])
        ],
        grounded: Bool = true,
        checkpointId: String = "cp_1",
        contractsVersion: String? = PocketContracts.version
    ) -> BriefWire {
        BriefWire(
            segments: segments,
            grounded: grounded,
            checkpointId: checkpointId,
            contractsVersion: contractsVersion
        )
    }

    private func assertAnswerFails(
        _ answer: AnswerWire,
        as expected: GatewayReasoningProviderError,
        requestedCheckpointId: String? = "cp_1",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        var client = MockGatewayClient()
        client.answerWire = answer
        do {
            _ = try await provider(client).answer(
                "question",
                sessionId: "s1",
                checkpointId: requestedCheckpointId
            )
            XCTFail("expected answer admission to fail", file: file, line: line)
        } catch let error as GatewayReasoningProviderError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }

    private func validAnsweredWire(
        body: AnswerBodyWire = AnswerBodyWire(
            text: "grounded answer",
            taggedText: "[calm] grounded answer",
            evidenceIds: ["ev_1"],
            llmConfidence: 0.9
        ),
        checkpointId: String = "cp_1",
        contractsVersion: String? = PocketContracts.version
    ) -> AnswerWire {
        AnswerWire(
            status: "answered",
            answer: body,
            clarify: nil,
            unavailable: nil,
            checkpointId: checkpointId,
            contractsVersion: contractsVersion
        )
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
        let _: UnboundReasonedQuestionAnswer = a
        // This low-level result intentionally has no provenance; only a signed-checkpoint boundary may promote it.
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

    func test_answer_rejects_incompatible_contract_or_requested_checkpoint_drift() async {
        await assertAnswerFails(
            validAnsweredWire(contractsVersion: "future"),
            as: .incompatibleContractsVersion(actual: "future")
        )
        await assertAnswerFails(
            validAnsweredWire(checkpointId: "cp_other"),
            as: .checkpointMismatch
        )
        let composed = "cp_caf\u{00E9}"
        let decomposed = "cp_cafe\u{0301}"
        XCTAssertEqual(composed, decomposed)
        XCTAssertFalse(composed.utf8.elementsEqual(decomposed.utf8))
        await assertAnswerFails(
            validAnsweredWire(checkpointId: decomposed),
            as: .checkpointMismatch,
            requestedCheckpointId: composed
        )
    }

    func test_answer_rejects_malformed_grounded_body() async {
        let malformed = [
            AnswerBodyWire(text: "  ", taggedText: nil, evidenceIds: ["ev_1"], llmConfidence: 0.9),
            AnswerBodyWire(text: "safe", taggedText: "[calm] different", evidenceIds: ["ev_1"], llmConfidence: 0.9),
            AnswerBodyWire(text: "words", taggedText: nil, evidenceIds: ["ev_1", "ev_1"], llmConfidence: 0.9),
            AnswerBodyWire(text: "words", taggedText: nil, evidenceIds: [" ev_1"], llmConfidence: 0.9),
            AnswerBodyWire(
                text: String(repeating: "x", count: PocketBundle.capSummary + 1),
                taggedText: nil,
                evidenceIds: ["ev_1"],
                llmConfidence: 0.9
            )
        ]
        for body in malformed {
            await assertAnswerFails(validAnsweredWire(body: body), as: .malformedAnswer)
        }
    }

    func test_answer_rejects_malformed_unavailable_topics() async {
        let wire = AnswerWire(
            status: "unavailable",
            answer: nil,
            clarify: nil,
            unavailable: UnavailableWire(nearestTopics: [
                NearestTopicWire(label: "related", evidenceId: " ev_1")
            ]),
            checkpointId: "cp_1",
            contractsVersion: PocketContracts.version
        )
        await assertAnswerFails(wire, as: .malformedAnswer)
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

    func test_brief_rejects_explicitly_ungrounded_envelope() async {
        await assertBriefingFails(
            validBrief(segments: [], grounded: false),
            as: .ungroundedBriefing
        )
    }

    func test_brief_rejects_missing_or_incompatible_contract_version() async {
        await assertBriefingFails(
            validBrief(contractsVersion: nil),
            as: .incompatibleContractsVersion(actual: nil)
        )
        await assertBriefingFails(
            validBrief(contractsVersion: "future"),
            as: .incompatibleContractsVersion(actual: "future")
        )
    }

    func test_brief_rejects_requested_checkpoint_drift() async {
        await assertBriefingFails(
            validBrief(checkpointId: "cp_other"),
            as: .checkpointMismatch
        )
        let composed = "cp_caf\u{00E9}"
        let decomposed = "cp_cafe\u{0301}"
        XCTAssertEqual(composed, decomposed)
        XCTAssertFalse(composed.utf8.elementsEqual(decomposed.utf8))
        await assertBriefingFails(
            validBrief(checkpointId: decomposed),
            as: .checkpointMismatch,
            requestedCheckpointId: composed
        )
    }

    func test_brief_accepts_valid_latest_checkpoint_when_request_omits_id() async throws {
        var client = MockGatewayClient()
        client.brief = validBrief(checkpointId: "cp_latest")
        let plan = try await provider(client).briefing(sessionId: "s1", checkpointId: nil)
        XCTAssertEqual(plan.checkpointId, "cp_latest")
    }

    func test_brief_rejects_empty_or_malformed_grounded_segments() async {
        let malformed: [[BriefSegmentWire]] = [
            [],
            [BriefSegmentWire(text: "  \n ", taggedText: nil, evidenceIds: ["ev_1"])],
            [BriefSegmentWire(text: "words", taggedText: nil, evidenceIds: [])],
            [BriefSegmentWire(text: "words", taggedText: nil, evidenceIds: ["ev_1", "ev_1"])],
            [BriefSegmentWire(text: "words", taggedText: nil, evidenceIds: [" ev_1"])],
            [BriefSegmentWire(text: "safe displayed words", taggedText: "[calm] different spoken words", evidenceIds: ["ev_1"])],
            [BriefSegmentWire(
                text: String(repeating: "x", count: PocketBundle.capSummary + 1),
                taggedText: nil,
                evidenceIds: ["ev_1"]
            )]
        ]
        for segments in malformed {
            await assertBriefingFails(validBrief(segments: segments), as: .malformedBriefing)
        }
    }

    func test_brief_rejects_segment_count_above_frozen_bundle_budget() async {
        let segments = (0...PocketBundle.capEvidence).map { index in
            BriefSegmentWire(text: "segment \(index)", taggedText: nil, evidenceIds: ["ev_1"])
        }
        await assertBriefingFails(validBrief(segments: segments), as: .malformedBriefing)
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
