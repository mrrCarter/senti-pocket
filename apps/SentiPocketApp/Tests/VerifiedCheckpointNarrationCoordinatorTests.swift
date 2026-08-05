import Foundation
import PocketContracts
import PocketVoice
import XCTest
@testable import PocketCall
@testable import SentiPocketApp

private enum NarrationTestError: Error {
    case timeout
}

private actor ControlledNarrationSynthesizer: SpeechSynthesizer {
    private struct Pending {
        let id: UUID
        let continuation: CheckedContinuation<SpeechPlaybackMetrics, Error>
    }

    private let stopCompletesPending: Bool
    private var requests: [SpeechSynthesisRequest] = []
    private var pending: [Pending] = []
    private var stops = 0

    init(stopCompletesPending: Bool = true) {
        self.stopCompletesPending = stopCompletesPending
    }

    func speak(_ request: SpeechSynthesisRequest) async throws -> SpeechPlaybackMetrics {
        requests.append(request)
        return try await withCheckedThrowingContinuation { continuation in
            pending.append(Pending(id: request.id, continuation: continuation))
        }
    }

    func stop() async {
        stops += 1
        guard stopCompletesPending else { return }
        let cancelled = pending
        pending.removeAll()
        for item in cancelled {
            item.continuation.resume(throwing: VoiceError.cancelled)
        }
    }

    func requestSnapshot() -> [SpeechSynthesisRequest] { requests }
    func stopCount() -> Int { stops }

    func complete(_ id: UUID, result: Result<SpeechPlaybackMetrics, VoiceError>) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let item = pending.remove(at: index)
        switch result {
        case .success(let metrics): item.continuation.resume(returning: metrics)
        case .failure(let error): item.continuation.resume(throwing: error)
        }
    }
}

@MainActor
final class VerifiedCheckpointNarrationCoordinatorTests: XCTestCase {
    func test_plan_projects_signed_summary_in_deterministic_epistemic_order() throws {
        let verified = try loadVerifiedBundle()
        let first = VerifiedCheckpointNarrationPlan(verifiedBundle: verified)
        let second = VerifiedCheckpointNarrationPlan(verifiedBundle: verified)

        XCTAssertEqual(first, second)
        XCTAssertLessThanOrEqual(
            first.spokenText.count,
            VerifiedCheckpointNarrationPlan.maximumCharacterCount
        )
        assertOrdered(
            [
                verified.bundle.summary.headline,
                "Agent claude-pocket-relay.",
                "Fact: Live checkpoint extraction works on room 954233b7 (41 auto-checkpoints).",
                "Recommendation: Freeze contracts before broad writeback to avoid rework.",
                "Agent claude-warden.",
                "Inference: The stack is safe to merge once billing/CI returns.",
                "Risks.",
                "Blockers."
            ],
            in: first.spokenText
        )
        XCTAssertFalse(
            first.spokenText.contains("ACCESS_TOKEN_PATTERN"),
            "narration projects the visible signed summary, not raw evidence snippets"
        )
    }

    func test_plan_caps_adversarial_signed_fields_and_emits_honest_notice() throws {
        let verified = try oversizedVerifiedBundle()
        let plan = VerifiedCheckpointNarrationPlan(verifiedBundle: verified)

        XCTAssertLessThanOrEqual(
            plan.spokenText.count,
            VerifiedCheckpointNarrationPlan.maximumCharacterCount
        )
        XCTAssertTrue(plan.spokenText.hasSuffix(VerifiedCheckpointNarrationPlan.omittedContentNotice))
        XCTAssertNoThrow(try SpeechSynthesisRequest(text: plan.spokenText))
    }

    func test_tampered_raw_bundle_cannot_mint_the_required_input() throws {
        let original = try loadPocketBundle()
        let summary = CheckpointSummary(
            checkpointId: original.summary.checkpointId,
            headline: original.summary.headline + " tampered",
            summaryBaselineSchema: original.summary.summaryBaselineSchema,
            grade: original.summary.grade,
            perAgent: original.summary.perAgent,
            risks: original.summary.risks,
            blockers: original.summary.blockers
        )
        let tampered = replacingSummary(summary, in: original)

        XCTAssertNil(VerifiedBundle.verify(tampered))
    }

    func test_start_speaks_only_the_exact_plan_and_completes() async throws {
        let verified = try loadVerifiedBundle()
        let synthesizer = ControlledNarrationSynthesizer()
        let coordinator = VerifiedCheckpointNarrationCoordinator(
            verifiedBundle: verified,
            synthesizer: synthesizer
        )

        let operation = try XCTUnwrap(coordinator.start())
        let request = try await waitForRequest(synthesizer, count: 1)
        XCTAssertEqual(coordinator.phase, .speaking)
        XCTAssertEqual(request.text, coordinator.plan.spokenText)

        await synthesizer.complete(request.id, result: .success(playbackMetrics(for: request)))
        await operation.value
        XCTAssertEqual(coordinator.phase, .completed)
    }

    func test_revoke_fences_late_success_and_stops_playback() async throws {
        let synthesizer = ControlledNarrationSynthesizer(stopCompletesPending: false)
        let coordinator = VerifiedCheckpointNarrationCoordinator(
            verifiedBundle: try loadVerifiedBundle(),
            synthesizer: synthesizer
        )
        let revocationRelay = VerifiedCheckpointNarrationRevocationRelay()
        revocationRelay.install(coordinator)

        let operation = try XCTUnwrap(coordinator.start())
        let request = try await waitForRequest(synthesizer, count: 1)
        let stop = try XCTUnwrap(revocationRelay.revoke())
        await stop.value
        XCTAssertEqual(coordinator.phase, .idle)

        await synthesizer.complete(request.id, result: .success(playbackMetrics(for: request)))
        await operation.value
        XCTAssertEqual(coordinator.phase, .idle, "a completion after revocation must not restore protected audio state")
        let stopCount = await synthesizer.stopCount()
        XCTAssertGreaterThanOrEqual(stopCount, 2)
        revocationRelay.remove(coordinator)
    }

    func test_new_start_supersedes_old_request_without_stale_state() async throws {
        let synthesizer = ControlledNarrationSynthesizer()
        let coordinator = VerifiedCheckpointNarrationCoordinator(
            verifiedBundle: try loadVerifiedBundle(),
            synthesizer: synthesizer
        )

        let first = try XCTUnwrap(coordinator.start())
        _ = try await waitForRequest(synthesizer, count: 1)
        let second = try XCTUnwrap(coordinator.start())
        let latest = try await waitForRequest(synthesizer, count: 2)
        await first.value
        XCTAssertEqual(coordinator.phase, .speaking)

        await synthesizer.complete(latest.id, result: .success(playbackMetrics(for: latest)))
        await second.value
        XCTAssertEqual(coordinator.phase, .completed)
    }

    func test_synthesis_failure_is_generic_and_keeps_verified_view_authoritative() async throws {
        let synthesizer = ControlledNarrationSynthesizer()
        let coordinator = VerifiedCheckpointNarrationCoordinator(
            verifiedBundle: try loadVerifiedBundle(),
            synthesizer: synthesizer
        )

        let operation = try XCTUnwrap(coordinator.start())
        let request = try await waitForRequest(synthesizer, count: 1)
        await synthesizer.complete(request.id, result: .failure(.synthesisFailed("sensitive-driver-detail")))
        await operation.value

        XCTAssertEqual(coordinator.phase, .failed)
    }

    private func waitForRequest(
        _ synthesizer: ControlledNarrationSynthesizer,
        count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> SpeechSynthesisRequest {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let requests = await synthesizer.requestSnapshot()
            if requests.count == count, let latest = requests.last { return latest }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("narration requests did not reach \(count)", file: file, line: line)
        throw NarrationTestError.timeout
    }

    private func assertOrdered(
        _ values: [String],
        in text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var searchStart = text.startIndex
        for value in values {
            guard let range = text.range(of: value, range: searchStart..<text.endIndex) else {
                XCTFail("missing or out-of-order narration segment: \(value)", file: file, line: line)
                return
            }
            searchStart = range.upperBound
        }
    }

    private func oversizedVerifiedBundle() throws -> VerifiedBundle {
        let original = try loadPocketBundle()
        let oversized = CheckpointSummary(
            checkpointId: original.summary.checkpointId,
            headline: String(repeating: "oversized verified headline ", count: 300),
            summaryBaselineSchema: original.summary.summaryBaselineSchema,
            grade: original.summary.grade,
            perAgent: original.summary.perAgent,
            risks: Array(repeating: "bounded verified risk", count: 100),
            blockers: original.summary.blockers
        )
        return VerifiedBundle.makeUnverifiedForTesting(replacingSummary(oversized, in: original))
    }

    private func replacingSummary(_ summary: CheckpointSummary, in bundle: PocketBundle) -> PocketBundle {
        PocketBundle(
            contractsVersion: bundle.contractsVersion,
            checkpointId: bundle.checkpointId,
            sessionId: bundle.sessionId,
            sequenceStart: bundle.sequenceStart,
            sequenceEnd: bundle.sequenceEnd,
            summary: summary,
            evidence: bundle.evidence,
            createdAt: bundle.createdAt,
            signature: bundle.signature,
            signingKeyId: bundle.signingKeyId
        )
    }

    private func loadVerifiedBundle() throws -> VerifiedBundle {
        try XCTUnwrap(VerifiedBundle.verify(loadPocketBundle()))
    }

    private func loadPocketBundle() throws -> PocketBundle {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PocketBundle.self, from: Data(contentsOf: canonicalFixtureURL))
    }

    private var canonicalFixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("packages/PocketContracts/Fixtures/canonical_checkpoint.json")
            .standardizedFileURL
    }

    private func playbackMetrics(for request: SpeechSynthesisRequest) -> SpeechPlaybackMetrics {
        SpeechPlaybackMetrics(
            backend: .avSpeechOffline,
            firstAudioMeasurement: .avSpeechDidStartCallback,
            firstAudioMilliseconds: 1,
            totalMilliseconds: 2,
            characterCount: request.text.count,
            residentMemoryBytes: nil,
            thermalState: .nominal
        )
    }
}
