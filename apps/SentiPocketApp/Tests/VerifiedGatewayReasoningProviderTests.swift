import Foundation
import XCTest
import PocketContracts
import PocketReasoning
import PocketSyncClient
@testable import PocketCall
@testable import SentiPocketApp

private struct VerifiedReasoningGatewayStub: GatewayReasoningClient {
    let brief: BriefWire
    let answerWire: AnswerWire

    func postBrief(sessionId: String, checkpointId: String?) async throws -> BriefWire { brief }
    func postAnswer(question: String, sessionId: String, checkpointId: String?) async throws -> AnswerWire { answerWire }
}

private struct VerifiedReasoningCheckpointStub: CheckpointTransport {
    let result: Result<VerifiedBundle, CheckpointTransportError>

    func fetchExactCheckpoint(sessionId: String, checkpointId: String) async throws -> VerifiedBundle {
        try result.get()
    }
}

private final class VerifiedReasoningTokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    init(_ value: String?) { self.value = value }

    func load() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func store(_ value: String?) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

private struct VerifiedReasoningBriefRequest: Equatable, Sendable {
    let sessionId: String
    let checkpointId: String?
}

private struct VerifiedReasoningAnswerRequest: Equatable, Sendable {
    let question: String
    let sessionId: String
    let checkpointId: String?
}

private struct VerifiedReasoningCheckpointRequest: Equatable, Sendable {
    let sessionId: String
    let checkpointId: String
}

private enum VerifiedReasoningTestError: Error {
    case missingResponse
}

private actor VerifiedReasoningTestGate {
    private var entered = false
    private var open = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        guard !open else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func hasEntered() -> Bool { entered }

    func release() {
        open = true
        continuation?.resume()
        continuation = nil
    }
}

private actor RecordingVerifiedReasoningGateway: GatewayReasoningClient {
    private let briefResponses: [BriefWire]
    private let answerResponses: [AnswerWire]
    private let firstBriefGate: VerifiedReasoningTestGate?
    private let firstAnswerGate: VerifiedReasoningTestGate?
    private var briefRequests: [VerifiedReasoningBriefRequest] = []
    private var answerRequests: [VerifiedReasoningAnswerRequest] = []

    init(
        briefResponses: [BriefWire] = [],
        answerResponses: [AnswerWire] = [],
        firstBriefGate: VerifiedReasoningTestGate? = nil,
        firstAnswerGate: VerifiedReasoningTestGate? = nil
    ) {
        self.briefResponses = briefResponses
        self.answerResponses = answerResponses
        self.firstBriefGate = firstBriefGate
        self.firstAnswerGate = firstAnswerGate
    }

    func postBrief(sessionId: String, checkpointId: String?) async throws -> BriefWire {
        let index = briefRequests.count
        briefRequests.append(VerifiedReasoningBriefRequest(
            sessionId: sessionId,
            checkpointId: checkpointId
        ))
        if index == 0, let firstBriefGate {
            await firstBriefGate.wait()
        }
        guard !briefResponses.isEmpty else { throw VerifiedReasoningTestError.missingResponse }
        return briefResponses[min(index, briefResponses.count - 1)]
    }

    func postAnswer(question: String, sessionId: String, checkpointId: String?) async throws -> AnswerWire {
        let index = answerRequests.count
        answerRequests.append(VerifiedReasoningAnswerRequest(
            question: question,
            sessionId: sessionId,
            checkpointId: checkpointId
        ))
        if index == 0, let firstAnswerGate {
            await firstAnswerGate.wait()
        }
        guard !answerResponses.isEmpty else { throw VerifiedReasoningTestError.missingResponse }
        return answerResponses[min(index, answerResponses.count - 1)]
    }

    func recordedBriefRequests() -> [VerifiedReasoningBriefRequest] { briefRequests }
    func recordedAnswerRequests() -> [VerifiedReasoningAnswerRequest] { answerRequests }
}

private actor RecordingVerifiedReasoningCheckpointTransport: CheckpointTransport {
    private let results: [Result<VerifiedBundle, CheckpointTransportError>]
    private var requests: [VerifiedReasoningCheckpointRequest] = []

    init(results: [Result<VerifiedBundle, CheckpointTransportError>]) {
        self.results = results
    }

    func fetchExactCheckpoint(sessionId: String, checkpointId: String) async throws -> VerifiedBundle {
        let index = requests.count
        requests.append(VerifiedReasoningCheckpointRequest(
            sessionId: sessionId,
            checkpointId: checkpointId
        ))
        guard !results.isEmpty else { throw VerifiedReasoningTestError.missingResponse }
        return try results[min(index, results.count - 1)].get()
    }

    func recordedRequests() -> [VerifiedReasoningCheckpointRequest] { requests }
}

private final class VerifiedReasoningReauthenticationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedTokens: [String?] = []

    func record(_ token: String?) {
        lock.lock()
        recordedTokens.append(token)
        lock.unlock()
    }

    func values() -> [String?] {
        lock.lock()
        defer { lock.unlock() }
        return recordedTokens
    }
}

final class VerifiedGatewayReasoningProviderTests: XCTestCase {
    private let timestamp = Date(timeIntervalSince1970: 1_752_835_200)

    private func bundle(
        sessionId: String = "s1",
        checkpointId: String = "cp1",
        evidenceId: String = "ev_1"
    ) -> VerifiedBundle {
        let evidence = EvidenceRef(
            id: evidenceId,
            sessionId: sessionId,
            sequence: 1,
            agentId: "agent-a",
            snippet: "grounded evidence",
            ts: timestamp
        )
        let summary = CheckpointSummary(
            checkpointId: checkpointId,
            headline: "checkpoint",
            summaryBaselineSchema: PocketBundle.expectedSummarySchema,
            grade: nil,
            perAgent: [],
            risks: [],
            blockers: []
        )
        return VerifiedBundle.makeUnverifiedForTesting(PocketBundle(
            contractsVersion: PocketContracts.version,
            checkpointId: checkpointId,
            sessionId: sessionId,
            sequenceStart: 1,
            sequenceEnd: 2,
            summary: summary,
            evidence: [evidence],
            createdAt: timestamp,
            signature: "test-only",
            signingKeyId: "test-only"
        ))
    }

    private func brief(
        evidenceId: String = "ev_1",
        checkpointId: String = "cp1"
    ) -> BriefWire {
        BriefWire(
            segments: [BriefSegmentWire(
                text: "Grounded briefing.",
                taggedText: "[calm] Grounded briefing.",
                evidenceIds: [evidenceId]
            )],
            grounded: true,
            checkpointId: checkpointId,
            contractsVersion: PocketContracts.version
        )
    }

    private func answer(
        evidenceId: String = "ev_1",
        checkpointId: String = "cp1"
    ) -> AnswerWire {
        AnswerWire(
            status: "answered",
            answer: AnswerBodyWire(
                text: "Grounded answer.",
                taggedText: "[calm] Grounded answer.",
                evidenceIds: [evidenceId],
                llmConfidence: 0.9
            ),
            clarify: nil,
            unavailable: nil,
            checkpointId: checkpointId,
            contractsVersion: PocketContracts.version
        )
    }

    private func provider(
        tokenBox: VerifiedReasoningTokenBox,
        bundle: VerifiedBundle? = nil,
        brief: BriefWire? = nil,
        answer: AnswerWire? = nil
    ) -> VerifiedGatewayReasoningProvider {
        let admittedBundle = bundle ?? self.bundle()
        let timestamp = self.timestamp
        let client = VerifiedReasoningGatewayStub(
            brief: brief ?? self.brief(),
            answerWire: answer ?? self.answer()
        )
        return VerifiedGatewayReasoningProvider(
            expectedSessionId: "s1",
            gateway: UnboundGatewayReasoningProvider(client: client, clock: { timestamp }),
            checkpointTransport: VerifiedReasoningCheckpointStub(result: .success(admittedBundle)),
            tokenProvider: { tokenBox.load() }
        )
    }

    private func provider(
        tokenBox: VerifiedReasoningTokenBox,
        gatewayClient: any GatewayReasoningClient,
        checkpointTransport: any CheckpointTransport,
        onReauthenticationRequired: @escaping @Sendable (_ expectedToken: String?) -> Void = { _ in }
    ) -> VerifiedGatewayReasoningProvider {
        let timestamp = self.timestamp
        return VerifiedGatewayReasoningProvider(
            expectedSessionId: "s1",
            gateway: UnboundGatewayReasoningProvider(client: gatewayClient, clock: { timestamp }),
            checkpointTransport: checkpointTransport,
            tokenProvider: { tokenBox.load() },
            onReauthenticationRequired: onReauthenticationRequired
        )
    }

    func test_briefing_is_returned_only_after_exact_bundle_admission() async throws {
        let provider = provider(tokenBox: VerifiedReasoningTokenBox("token-a"))
        let plan = try await provider.briefing(sessionId: "s1", checkpointId: nil)
        XCTAssertEqual(plan.checkpointId, "cp1")
        XCTAssertEqual(plan.segments.first?.evidenceIds, ["ev_1"])
    }

    func test_briefing_rejects_foreign_citation_even_when_gateway_claims_grounded() async {
        let provider = provider(
            tokenBox: VerifiedReasoningTokenBox("token-a"),
            brief: brief(evidenceId: "ev_foreign")
        )
        await assertFails(.invalidBriefing) {
            _ = try await provider.briefing(sessionId: "s1", checkpointId: nil)
        }
    }

    func test_briefing_rejects_unicode_canonical_but_byte_distinct_citation() async {
        let composed = "ev_caf\u{00E9}"
        let decomposed = "ev_cafe\u{0301}"
        XCTAssertEqual(composed, decomposed)
        XCTAssertFalse(composed.utf8.elementsEqual(decomposed.utf8))
        let provider = provider(
            tokenBox: VerifiedReasoningTokenBox("token-a"),
            bundle: bundle(evidenceId: composed),
            brief: brief(evidenceId: decomposed)
        )
        await assertFails(.invalidBriefing) {
            _ = try await provider.briefing(sessionId: "s1", checkpointId: nil)
        }
    }

    func test_answer_uses_admitted_briefing_checkpoint_and_bundle() async throws {
        let provider = provider(tokenBox: VerifiedReasoningTokenBox("token-a"))
        _ = try await provider.briefing(sessionId: "s1", checkpointId: nil)
        let result = try await provider.answer("question", sessionId: "s1", checkpointId: nil)
        guard case .answered(let grounded) = result else { return XCTFail("expected grounded answer") }
        XCTAssertEqual(grounded.checkpointId, "cp1")
        XCTAssertEqual(grounded.evidenceIds, ["ev_1"])
        XCTAssertEqual(grounded.provenance, .liveReasoned)
    }

    func test_dial_answer_can_lazily_bind_an_explicit_exact_checkpoint() async throws {
        let provider = provider(tokenBox: VerifiedReasoningTokenBox("token-a"))
        let result = try await provider.answer("question", sessionId: "s1", checkpointId: "cp1")
        guard case .answered(let grounded) = result else { return XCTFail("expected grounded answer") }
        XCTAssertEqual(grounded.evidenceIds, ["ev_1"])
    }

    func test_phone_and_dial_forward_the_exact_verified_checkpoint_arguments() async throws {
        let phoneGateway = RecordingVerifiedReasoningGateway(
            briefResponses: [brief(checkpointId: "cp_phone")],
            answerResponses: [answer(checkpointId: "cp_phone")]
        )
        let phoneCheckpoint = RecordingVerifiedReasoningCheckpointTransport(results: [
            .success(bundle(checkpointId: "cp_phone"))
        ])
        let phoneProvider = provider(
            tokenBox: VerifiedReasoningTokenBox("token-a"),
            gatewayClient: phoneGateway,
            checkpointTransport: phoneCheckpoint
        )

        _ = try await phoneProvider.briefing(sessionId: "s1", checkpointId: nil)
        _ = try await phoneProvider.answer("phone question", sessionId: "s1", checkpointId: nil)

        let phoneBriefRequests = await phoneGateway.recordedBriefRequests()
        let phoneAnswerRequests = await phoneGateway.recordedAnswerRequests()
        let phoneCheckpointRequests = await phoneCheckpoint.recordedRequests()
        XCTAssertEqual(phoneBriefRequests, [
            VerifiedReasoningBriefRequest(sessionId: "s1", checkpointId: nil)
        ])
        XCTAssertEqual(phoneCheckpointRequests, [
            VerifiedReasoningCheckpointRequest(sessionId: "s1", checkpointId: "cp_phone")
        ])
        XCTAssertEqual(phoneAnswerRequests, [
            VerifiedReasoningAnswerRequest(
                question: "phone question",
                sessionId: "s1",
                checkpointId: "cp_phone"
            )
        ])

        let dialGateway = RecordingVerifiedReasoningGateway(
            answerResponses: [answer(checkpointId: "cp_dial")]
        )
        let dialCheckpoint = RecordingVerifiedReasoningCheckpointTransport(results: [
            .success(bundle(checkpointId: "cp_dial"))
        ])
        let dialProvider = provider(
            tokenBox: VerifiedReasoningTokenBox("token-a"),
            gatewayClient: dialGateway,
            checkpointTransport: dialCheckpoint
        )

        _ = try await dialProvider.answer(
            "dial question",
            sessionId: "s1",
            checkpointId: "cp_dial"
        )

        let dialBriefRequests = await dialGateway.recordedBriefRequests()
        let dialAnswerRequests = await dialGateway.recordedAnswerRequests()
        let dialCheckpointRequests = await dialCheckpoint.recordedRequests()
        XCTAssertTrue(dialBriefRequests.isEmpty)
        XCTAssertEqual(dialCheckpointRequests, [
            VerifiedReasoningCheckpointRequest(sessionId: "s1", checkpointId: "cp_dial")
        ])
        XCTAssertEqual(dialAnswerRequests, [
            VerifiedReasoningAnswerRequest(
                question: "dial question",
                sessionId: "s1",
                checkpointId: "cp_dial"
            )
        ])
    }

    func test_answer_without_admitted_or_explicit_checkpoint_fails_closed() async {
        let provider = provider(tokenBox: VerifiedReasoningTokenBox("token-a"))
        await assertFails(.checkpointRequired) {
            _ = try await provider.answer("question", sessionId: "s1", checkpointId: nil)
        }
    }

    func test_answer_rejects_foreign_citation_and_checkpoint_drift() async {
        let foreign = provider(
            tokenBox: VerifiedReasoningTokenBox("token-a"),
            answer: answer(evidenceId: "ev_foreign")
        )
        await assertFails(.invalidAnswer) {
            _ = try await foreign.answer("question", sessionId: "s1", checkpointId: "cp1")
        }

        let drift = provider(
            tokenBox: VerifiedReasoningTokenBox("token-a"),
            answer: answer(checkpointId: "cp_other")
        )
        do {
            _ = try await drift.answer("question", sessionId: "s1", checkpointId: "cp1")
            XCTFail("expected upstream checkpoint admission failure")
        } catch let error as GatewayReasoningProviderError {
            XCTAssertEqual(error, .checkpointMismatch)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_answer_rejects_explicit_checkpoint_mismatch_after_briefing() async throws {
        let provider = provider(tokenBox: VerifiedReasoningTokenBox("token-a"))
        _ = try await provider.briefing(sessionId: "s1", checkpointId: nil)
        await assertFails(.checkpointMismatch) {
            _ = try await provider.answer("question", sessionId: "s1", checkpointId: "cp_other")
        }
    }

    func test_answer_rejects_unicode_canonical_but_byte_distinct_citation() async {
        let composed = "ev_caf\u{00E9}"
        let decomposed = "ev_cafe\u{0301}"
        let provider = provider(
            tokenBox: VerifiedReasoningTokenBox("token-a"),
            bundle: bundle(evidenceId: composed),
            answer: answer(evidenceId: decomposed)
        )
        await assertFails(.invalidAnswer) {
            _ = try await provider.answer("question", sessionId: "s1", checkpointId: "cp1")
        }
    }

    func test_unavailable_rejects_unicode_canonical_but_byte_distinct_topic() async {
        let composed = "ev_caf\u{00E9}"
        let decomposed = "ev_cafe\u{0301}"
        let unavailable = AnswerWire(
            status: "unavailable",
            answer: nil,
            clarify: nil,
            unavailable: UnavailableWire(nearestTopics: [
                NearestTopicWire(label: "Related", evidenceId: decomposed)
            ]),
            checkpointId: "cp1",
            contractsVersion: PocketContracts.version
        )
        let provider = provider(
            tokenBox: VerifiedReasoningTokenBox("token-a"),
            bundle: bundle(evidenceId: composed),
            answer: unavailable
        )
        await assertFails(.invalidAnswer) {
            _ = try await provider.answer("question", sessionId: "s1", checkpointId: "cp1")
        }
    }

    func test_unavailable_rejects_duplicate_topics_at_unbound_boundary_and_foreign_topics_at_verified_boundary() async {
        let duplicate = AnswerWire(
            status: "unavailable",
            answer: nil,
            clarify: nil,
            unavailable: UnavailableWire(nearestTopics: [
                NearestTopicWire(label: "One", evidenceId: "ev_1"),
                NearestTopicWire(label: "Two", evidenceId: "ev_1")
            ]),
            checkpointId: "cp1",
            contractsVersion: PocketContracts.version
        )
        let foreign = AnswerWire(
            status: "unavailable",
            answer: nil,
            clarify: nil,
            unavailable: UnavailableWire(nearestTopics: [
                NearestTopicWire(label: "Other", evidenceId: "ev_foreign")
            ]),
            checkpointId: "cp1",
            contractsVersion: PocketContracts.version
        )

        let duplicateProvider = provider(
            tokenBox: VerifiedReasoningTokenBox("token-a"),
            answer: duplicate
        )
        await assertGatewayFails(.malformedAnswer) {
            _ = try await duplicateProvider.answer("question", sessionId: "s1", checkpointId: "cp1")
        }

        let foreignProvider = provider(
            tokenBox: VerifiedReasoningTokenBox("token-a"),
            answer: foreign
        )
        await assertFails(.invalidAnswer) {
            _ = try await foreignProvider.answer("question", sessionId: "s1", checkpointId: "cp1")
        }
    }

    func test_briefing_rejects_byte_distinct_checkpoint_from_verified_bundle() async {
        let composed = "cp_caf\u{00E9}"
        let decomposed = "cp_cafe\u{0301}"
        let provider = provider(
            tokenBox: VerifiedReasoningTokenBox("token-a"),
            bundle: bundle(checkpointId: composed),
            brief: brief(checkpointId: decomposed)
        )
        await assertFails(.checkpointMismatch) {
            _ = try await provider.briefing(sessionId: "s1", checkpointId: nil)
        }
    }

    func test_briefing_rejects_returned_bundle_with_wrong_session_or_checkpoint() async {
        for returnedBundle in [
            bundle(sessionId: "other"),
            bundle(checkpointId: "cp_other")
        ] {
            let provider = provider(
                tokenBox: VerifiedReasoningTokenBox("token-a"),
                bundle: returnedBundle
            )
            await assertFails(.checkpointMismatch) {
                _ = try await provider.briefing(sessionId: "s1", checkpointId: nil)
            }
        }
    }

    func test_superseded_briefing_cannot_overwrite_or_erase_newer_context() async throws {
        let firstBriefGate = VerifiedReasoningTestGate()
        let gateway = RecordingVerifiedReasoningGateway(
            briefResponses: [
                brief(checkpointId: "cp_old"),
                brief(checkpointId: "cp_new")
            ],
            answerResponses: [answer(checkpointId: "cp_new")],
            firstBriefGate: firstBriefGate
        )
        let checkpoint = RecordingVerifiedReasoningCheckpointTransport(results: [
            .success(bundle(checkpointId: "cp_new"))
        ])
        let provider = provider(
            tokenBox: VerifiedReasoningTokenBox("token-a"),
            gatewayClient: gateway,
            checkpointTransport: checkpoint
        )

        let staleTask = Task {
            try await provider.briefing(sessionId: "s1", checkpointId: nil)
        }
        let entered = await waitForGate(firstBriefGate)
        XCTAssertTrue(entered, "first briefing did not reach the controlled suspension")
        guard entered else {
            staleTask.cancel()
            await firstBriefGate.release()
            return
        }

        let latest = try await provider.briefing(sessionId: "s1", checkpointId: nil)
        XCTAssertEqual(latest.checkpointId, "cp_new")
        await firstBriefGate.release()
        do {
            _ = try await staleTask.value
            XCTFail("superseded briefing must fail closed")
        } catch let error as VerifiedGatewayReasoningError {
            XCTAssertEqual(error, .authenticationChanged)
        }

        let answer = try await provider.answer(
            "question",
            sessionId: "s1",
            checkpointId: nil
        )
        guard case .answered(let grounded) = answer else {
            return XCTFail("newer context should remain usable")
        }
        XCTAssertEqual(grounded.checkpointId, "cp_new")
        let checkpointRequests = await checkpoint.recordedRequests()
        XCTAssertEqual(checkpointRequests, [
            VerifiedReasoningCheckpointRequest(sessionId: "s1", checkpointId: "cp_new")
        ])
    }

    func test_late_success_after_credential_rotation_is_rejected_and_context_revoked() async {
        let answerGate = VerifiedReasoningTestGate()
        let gateway = RecordingVerifiedReasoningGateway(
            answerResponses: [answer()],
            firstAnswerGate: answerGate
        )
        let checkpoint = RecordingVerifiedReasoningCheckpointTransport(results: [
            .success(bundle())
        ])
        let tokenBox = VerifiedReasoningTokenBox("token-a")
        let provider = provider(
            tokenBox: tokenBox,
            gatewayClient: gateway,
            checkpointTransport: checkpoint
        )

        let inFlight = Task {
            try await provider.answer("question", sessionId: "s1", checkpointId: "cp1")
        }
        let entered = await waitForGate(answerGate)
        XCTAssertTrue(entered, "answer did not reach the controlled suspension")
        guard entered else {
            inFlight.cancel()
            await answerGate.release()
            return
        }
        tokenBox.store("token-b")
        await answerGate.release()

        do {
            _ = try await inFlight.value
            XCTFail("a response admitted under an old credential must not escape")
        } catch let error as VerifiedGatewayReasoningError {
            XCTAssertEqual(error, .authenticationChanged)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        await assertFails(.checkpointRequired) {
            _ = try await provider.answer("question", sessionId: "s1", checkpointId: nil)
        }
    }

    func test_checkpoint_auth_failures_forward_reauthentication_context() async {
        for (transportError, expectedToken) in [
            (CheckpointTransportError.notLoggedIn, Optional<String>.none),
            (CheckpointTransportError.reauthenticationRequired, Optional("token-a"))
        ] {
            let recorder = VerifiedReasoningReauthenticationRecorder()
            let gateway = RecordingVerifiedReasoningGateway(answerResponses: [answer()])
            let checkpoint = RecordingVerifiedReasoningCheckpointTransport(results: [
                .failure(transportError)
            ])
            let provider = provider(
                tokenBox: VerifiedReasoningTokenBox("token-a"),
                gatewayClient: gateway,
                checkpointTransport: checkpoint,
                onReauthenticationRequired: { recorder.record($0) }
            )
            do {
                _ = try await provider.answer("question", sessionId: "s1", checkpointId: "cp1")
                XCTFail("checkpoint auth failure must escape")
            } catch let error as CheckpointTransportError {
                XCTAssertEqual(error, transportError)
            } catch {
                XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(recorder.values(), [expectedToken])
        }
    }

    func test_authentication_change_revokes_existing_reasoning_context() async throws {
        let tokenBox = VerifiedReasoningTokenBox("token-a")
        let provider = provider(tokenBox: tokenBox)
        _ = try await provider.briefing(sessionId: "s1", checkpointId: nil)
        tokenBox.store("token-b")
        await assertFails(.authenticationChanged) {
            _ = try await provider.answer("question", sessionId: "s1", checkpointId: nil)
        }
    }

    func test_wrong_session_never_reaches_reasoning_or_checkpoint_transport() async {
        let provider = provider(tokenBox: VerifiedReasoningTokenBox("token-a"))
        await assertFails(.wrongSession) {
            _ = try await provider.briefing(sessionId: "other", checkpointId: nil)
        }
    }

    private func assertFails(
        _ expected: VerifiedGatewayReasoningError,
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("expected failure \(expected)", file: file, line: line)
        } catch let error as VerifiedGatewayReasoningError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }

    private func assertGatewayFails(
        _ expected: GatewayReasoningProviderError,
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("expected failure \(expected)", file: file, line: line)
        } catch let error as GatewayReasoningProviderError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }

    private func waitForGate(_ gate: VerifiedReasoningTestGate) async -> Bool {
        for _ in 0..<200 {
            if await gate.hasEntered() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
}
