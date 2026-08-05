import Foundation
import PocketContracts
import PocketReasoning
import PocketUI
import XCTest
@testable import SentiPocketApp

private enum RealReasoningCoordinatorTestError: Error {
    case timeout
}

private struct ImmediateBriefingProvider: ReasoningProvider {
    let provenance: ReasoningProvenance
    let checkpointId: String

    func briefing(sessionId: String, checkpointId: String?) async throws -> BriefingPlan {
        BriefingPlan(
            checkpointId: self.checkpointId,
            segments: [BriefingSegment(
                id: "segment-\(self.checkpointId)",
                text: self.checkpointId,
                evidenceIds: []
            )]
        )
    }

    func answer(
        _ question: String,
        sessionId: String,
        checkpointId: String?
    ) async throws -> ReasonedAnswer {
        .unavailable(nearestTopics: [])
    }
}

private actor ControlledBriefingProvider: ReasoningProvider {
    nonisolated let provenance: ReasoningProvenance
    private let plan: BriefingPlan
    private var hasStarted = false
    private var continuation: CheckedContinuation<BriefingPlan, Never>?

    init(provenance: ReasoningProvenance, checkpointId: String) {
        self.provenance = provenance
        self.plan = BriefingPlan(
            checkpointId: checkpointId,
            segments: [BriefingSegment(
                id: "segment-\(checkpointId)",
                text: checkpointId,
                evidenceIds: []
            )]
        )
    }

    func briefing(sessionId: String, checkpointId: String?) async throws -> BriefingPlan {
        hasStarted = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func answer(
        _ question: String,
        sessionId: String,
        checkpointId: String?
    ) async throws -> ReasonedAnswer {
        .unavailable(nearestTopics: [])
    }

    func started() -> Bool { hasStarted }

    func release() {
        continuation?.resume(returning: plan)
        continuation = nil
    }
}

private final class ReasoningRouteSelectionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let online: any ReasoningProvider
    private let fallback: any ReasoningProvider
    private var storedRoutes: [Bool] = []

    init(online: any ReasoningProvider, fallback: any ReasoningProvider) {
        self.online = online
        self.fallback = fallback
    }

    func select(isOnline: Bool) -> any ReasoningProvider {
        lock.lock()
        storedRoutes.append(isOnline)
        lock.unlock()
        return isOnline ? online : fallback
    }

    func routes() -> [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return storedRoutes
    }
}

@MainActor
final class RealReasoningCoordinatorTests: XCTestCase {
    func test_observation_routes_transitions_and_coalesces_offline_with_reconnecting() async throws {
        let selector = ReasoningRouteSelectionProbe(
            online: ImmediateBriefingProvider(provenance: .liveReasoned, checkpointId: "online"),
            fallback: ImmediateBriefingProvider(provenance: .cachedSample, checkpointId: "fallback")
        )
        let coordinator = makeCoordinator(selector)
        let (stream, continuation) = makeConnectivityStream()
        let observation = coordinator.observeConnectivity(stream)

        continuation.yield(.reconnecting)
        try await waitForRoutes(selector, [false])
        try await waitForPhase(
            coordinator,
            .briefingReady(plan(checkpointId: "fallback"), provenance: .cachedSample)
        )

        continuation.yield(.offline(cachedAt: Date(timeIntervalSince1970: 1)))
        continuation.yield(.reconnecting)
        continuation.yield(.online)
        try await waitForRoutes(selector, [false, true])
        try await waitForPhase(
            coordinator,
            .briefingReady(plan(checkpointId: "online"), provenance: .liveReasoned)
        )

        continuation.yield(.online)
        continuation.yield(.offline(cachedAt: nil))
        try await waitForRoutes(selector, [false, true, false])
        try await waitForPhase(
            coordinator,
            .briefingReady(plan(checkpointId: "fallback"), provenance: .cachedSample)
        )

        continuation.finish()
        await observation.value
        XCTAssertEqual(selector.routes(), [false, true, false])
    }

    func test_late_online_result_cannot_overwrite_newer_fallback_route() async throws {
        let delayedOnline = ControlledBriefingProvider(
            provenance: .liveReasoned,
            checkpointId: "late-online"
        )
        let selector = ReasoningRouteSelectionProbe(
            online: delayedOnline,
            fallback: ImmediateBriefingProvider(provenance: .cachedSample, checkpointId: "fallback")
        )
        let coordinator = makeCoordinator(selector)
        let (stream, continuation) = makeConnectivityStream()
        let observation = coordinator.observeConnectivity(stream)

        continuation.yield(.online)
        try await waitUntil { await delayedOnline.started() }
        continuation.yield(.offline(cachedAt: nil))
        try await waitForRoutes(selector, [true, false])
        try await waitForPhase(
            coordinator,
            .briefingReady(plan(checkpointId: "fallback"), provenance: .cachedSample)
        )

        await delayedOnline.release()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(
            coordinator.phase,
            .briefingReady(plan(checkpointId: "fallback"), provenance: .cachedSample)
        )

        continuation.finish()
        await observation.value
    }

    func test_superseded_observation_late_events_and_cleanup_do_not_reset_current_route() async throws {
        let selector = ReasoningRouteSelectionProbe(
            online: ImmediateBriefingProvider(provenance: .liveReasoned, checkpointId: "online"),
            fallback: ImmediateBriefingProvider(provenance: .cachedSample, checkpointId: "fallback")
        )
        let coordinator = makeCoordinator(selector)
        let (oldStream, oldContinuation) = makeConnectivityStream()
        let oldObservation = coordinator.observeConnectivity(oldStream)
        oldContinuation.yield(.online)
        try await waitForRoutes(selector, [true])

        let (currentStream, currentContinuation) = makeConnectivityStream()
        let currentObservation = coordinator.observeConnectivity(currentStream)
        currentContinuation.yield(.offline(cachedAt: nil))
        try await waitForRoutes(selector, [true, false])

        oldContinuation.yield(.online)
        oldContinuation.finish()
        await oldObservation.value
        currentContinuation.yield(.reconnecting)
        currentContinuation.yield(.online)
        try await waitForRoutes(selector, [true, false, true])

        currentContinuation.finish()
        await currentObservation.value
        XCTAssertEqual(selector.routes(), [true, false, true])
    }

    func test_replacing_observation_fences_inflight_result_before_new_stream_emits() async throws {
        let delayedOnline = ControlledBriefingProvider(
            provenance: .liveReasoned,
            checkpointId: "old-online"
        )
        let selector = ReasoningRouteSelectionProbe(
            online: delayedOnline,
            fallback: ImmediateBriefingProvider(provenance: .cachedSample, checkpointId: "fallback")
        )
        let coordinator = makeCoordinator(selector)
        let (oldStream, oldContinuation) = makeConnectivityStream()
        let oldObservation = coordinator.observeConnectivity(oldStream)
        oldContinuation.yield(.online)
        try await waitUntil { await delayedOnline.started() }

        let (currentStream, currentContinuation) = makeConnectivityStream()
        let currentObservation = coordinator.observeConnectivity(currentStream)
        XCTAssertEqual(coordinator.phase, .idle)

        await delayedOnline.release()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertEqual(selector.routes(), [true])

        oldContinuation.finish()
        await oldObservation.value
        currentContinuation.finish()
        await currentObservation.value
    }

    func test_current_observation_completion_cancels_inflight_result_and_returns_idle() async throws {
        let delayedOnline = ControlledBriefingProvider(
            provenance: .liveReasoned,
            checkpointId: "late-online"
        )
        let selector = ReasoningRouteSelectionProbe(
            online: delayedOnline,
            fallback: ImmediateBriefingProvider(provenance: .cachedSample, checkpointId: "fallback")
        )
        let coordinator = makeCoordinator(selector)
        let (stream, continuation) = makeConnectivityStream()
        let observation = coordinator.observeConnectivity(stream)
        continuation.yield(.online)
        try await waitUntil { await delayedOnline.started() }

        continuation.finish()
        await observation.value
        XCTAssertEqual(coordinator.phase, .idle)

        await delayedOnline.release()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertEqual(selector.routes(), [true])
    }

    func test_direct_observation_cancellation_cancels_inflight_result_and_returns_idle() async throws {
        let delayedOnline = ControlledBriefingProvider(
            provenance: .liveReasoned,
            checkpointId: "late-online"
        )
        let selector = ReasoningRouteSelectionProbe(
            online: delayedOnline,
            fallback: ImmediateBriefingProvider(provenance: .cachedSample, checkpointId: "fallback")
        )
        let coordinator = makeCoordinator(selector)
        let (stream, continuation) = makeConnectivityStream()
        let observation = coordinator.observeConnectivity(stream)

        continuation.yield(.online)
        try await waitUntil { await delayedOnline.started() }

        observation.cancel()
        await observation.value
        XCTAssertEqual(coordinator.phase, .idle)

        await delayedOnline.release()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertEqual(selector.routes(), [true])
    }

    func test_reset_fences_observation_and_inflight_provider_before_returning_idle() async throws {
        let delayedOnline = ControlledBriefingProvider(
            provenance: .liveReasoned,
            checkpointId: "late-online"
        )
        let selector = ReasoningRouteSelectionProbe(
            online: delayedOnline,
            fallback: ImmediateBriefingProvider(provenance: .cachedSample, checkpointId: "fallback")
        )
        let coordinator = makeCoordinator(selector)
        let (stream, continuation) = makeConnectivityStream()
        let observation = coordinator.observeConnectivity(stream)

        continuation.yield(.online)
        try await waitUntil { await delayedOnline.started() }
        coordinator.reset()
        XCTAssertEqual(coordinator.phase, .idle)

        continuation.yield(.offline(cachedAt: nil))
        await delayedOnline.release()
        continuation.finish()
        await observation.value
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(selector.routes(), [true])
        XCTAssertEqual(coordinator.phase, .idle)
    }

    private func makeCoordinator(_ selector: ReasoningRouteSelectionProbe) -> RealReasoningCoordinator {
        RealReasoningCoordinator(
            sessionId: "session-1",
            checkpointId: nil,
            selectProvider: selector.select
        )
    }

    private func makeConnectivityStream() -> (
        AsyncStream<PocketConnectivity>,
        AsyncStream<PocketConnectivity>.Continuation
    ) {
        var storedContinuation: AsyncStream<PocketConnectivity>.Continuation?
        let stream = AsyncStream<PocketConnectivity>(bufferingPolicy: .unbounded) {
            storedContinuation = $0
        }
        return (stream, storedContinuation!)
    }

    private func plan(checkpointId: String) -> BriefingPlan {
        BriefingPlan(
            checkpointId: checkpointId,
            segments: [BriefingSegment(
                id: "segment-\(checkpointId)",
                text: checkpointId,
                evidenceIds: []
            )]
        )
    }

    private func waitForRoutes(
        _ selector: ReasoningRouteSelectionProbe,
        _ expected: [Bool],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await waitUntil(file: file, line: line) { selector.routes() == expected }
    }

    private func waitForPhase(
        _ coordinator: RealReasoningCoordinator,
        _ expected: ReasoningPhase,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await waitUntil(file: file, line: line) { coordinator.phase == expected }
    }

    private func waitUntil(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ predicate: @escaping @MainActor @Sendable () async -> Bool
    ) async throws {
        for _ in 0..<1_000 {
            if await predicate() { return }
            await Task.yield()
        }
        XCTFail("condition did not become true", file: file, line: line)
        throw RealReasoningCoordinatorTestError.timeout
    }
}
