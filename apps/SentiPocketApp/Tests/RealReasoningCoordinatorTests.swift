import Foundation
import Dispatch
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

/// A deterministic, cancellation-cooperative replacement for `Task.sleep`. Tests settle each superseded waiter before
/// advancing the next edge and advance the current stabilization window without wall-clock sleeps.
private actor ManualRouteStabilizationDelay {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var requestedNanoseconds: [UInt64] = []
    private var waiters: [Waiter] = []
    private var maxWaiterCount = 0
    private var cancellationCount = 0

    func wait(_ nanoseconds: UInt64) async throws {
        let id = UUID()
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                requestedNanoseconds.append(nanoseconds)
                waiters.append(Waiter(id: id, continuation: continuation))
                maxWaiterCount = max(maxWaiterCount, waiters.count)
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func snapshot() -> (requests: [UInt64], waiters: Int, maxWaiters: Int, cancellations: Int) {
        (requestedNanoseconds, waiters.count, maxWaiterCount, cancellationCount)
    }

    func advanceNext() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().continuation.resume()
    }

    func advanceAll() {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.continuation.resume() }
    }

    private func cancel(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        cancellationCount += 1
        waiter.continuation.resume(throwing: CancellationError())
    }
}

private final class ReasoningRouteTransitionSettlementProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0

    func record() {
        lock.withLock { storedCount += 1 }
    }

    func count() -> Int {
        lock.withLock { storedCount }
    }
}

/// Forces cancellation to win immediately before the coordinator attempts its lease-gated admission. This closes the
/// exact check-then-use window that an ordinary cancel-before-delay test cannot deterministically reach.
private final class ReasoningAdmissionAttemptBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let reached = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private var armed = false
    private var timedOut = false

    func arm() {
        lock.withLock { armed = true }
    }

    func blockIfArmed() {
        let shouldBlock = lock.withLock {
            guard armed else { return false }
            armed = false
            return true
        }
        guard shouldBlock else { return }
        reached.signal()
        if release.wait(timeout: .now() + 5) != .success {
            lock.withLock { timedOut = true }
        }
    }

    func waitUntilReached() -> Bool {
        reached.wait(timeout: .now() + 5) == .success
    }

    func allowAdmissionAttempt() {
        release.signal()
    }

    func didTimeOut() -> Bool {
        lock.withLock { timedOut }
    }
}

/// Used only for lease/revision tests: it deliberately violates the production delay's cooperative-cancellation
/// contract so a canceled transition can be released late and forced through every admission guard.
private actor CancellationInsensitiveRouteStabilizationDelay {
    private var requestedNanoseconds: [UInt64] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait(_ nanoseconds: UInt64) async throws {
        requestedNanoseconds.append(nanoseconds)
        await withCheckedContinuation { waiters.append($0) }
    }

    func snapshot() -> (requests: [UInt64], waiters: Int) {
        (requestedNanoseconds, waiters.count)
    }

    func advanceNext() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }

    func advanceAll() {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private final class ReasoningConnectivityStreamFactoryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncStream<PocketConnectivity>.Continuation] = []
    private var terminationCount = 0

    func makeStream() -> AsyncStream<PocketConnectivity> {
        AsyncStream<PocketConnectivity>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            lock.withLock { continuations.append(continuation) }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { self.terminationCount += 1 }
            }
        }
    }

    func yield(_ connectivity: PocketConnectivity, streamIndex: Int = 0) {
        let continuation = lock.withLock {
            continuations.indices.contains(streamIndex) ? continuations[streamIndex] : nil
        }
        continuation?.yield(connectivity)
    }

    func finish(streamIndex: Int = 0) {
        let continuation = lock.withLock {
            continuations.indices.contains(streamIndex) ? continuations[streamIndex] : nil
        }
        continuation?.finish()
    }

    func snapshot() -> (streams: Int, terminations: Int) {
        lock.withLock { (continuations.count, terminationCount) }
    }
}

@MainActor
final class RealReasoningCoordinatorTests: XCTestCase {
    func test_route_flapping_starts_no_new_provider_until_final_route_is_stable() async throws {
        let selector = ReasoningRouteSelectionProbe(
            online: ImmediateBriefingProvider(provenance: .liveReasoned, checkpointId: "online"),
            fallback: ImmediateBriefingProvider(provenance: .cachedSample, checkpointId: "fallback")
        )
        let delay = ManualRouteStabilizationDelay()
        let settlements = ReasoningRouteTransitionSettlementProbe()
        let coordinator = makeCoordinator(selector, delay: delay, settlements: settlements)
        let (stream, continuation) = makeConnectivityStream()
        let observation = coordinator.observeConnectivity(stream)

        continuation.yield(.online)
        try await waitForRoutes(selector, [true])

        for index in 0..<100 {
            continuation.yield(.offline(cachedAt: nil))
            try await waitUntil {
                let snapshot = await delay.snapshot()
                return snapshot.requests.count == index + 1 && snapshot.waiters == 1
            }
            continuation.yield(.online)
            try await waitUntil {
                let snapshot = await delay.snapshot()
                return snapshot.cancellations == index + 1
                    && snapshot.waiters == 0
                    && settlements.count() == index + 1
            }
        }
        XCTAssertEqual(selector.routes(), [true], "route churn must not admit another provider request")

        continuation.yield(.offline(cachedAt: nil))
        try await waitUntil {
            let snapshot = await delay.snapshot()
            return snapshot.requests.count == 101 && snapshot.waiters == 1
        }
        let delaySnapshot = await delay.snapshot()
        XCTAssertEqual(delaySnapshot.requests, Array(repeating: 2_000_000_000, count: 101))
        XCTAssertEqual(
            delaySnapshot.maxWaiters,
            1,
            "each cooperative delay waiter must settle before this serialized test advances to the next edge"
        )
        XCTAssertEqual(selector.routes(), [true])

        await delay.advanceNext()
        try await waitForRoutes(selector, [true, false])
        try await waitUntil { settlements.count() == 101 }

        continuation.finish()
        await observation.value
    }

    func test_duplicate_fallback_samples_share_one_original_stabilization_window() async throws {
        let selector = ReasoningRouteSelectionProbe(
            online: ImmediateBriefingProvider(provenance: .liveReasoned, checkpointId: "online"),
            fallback: ImmediateBriefingProvider(provenance: .cachedSample, checkpointId: "fallback")
        )
        let delay = ManualRouteStabilizationDelay()
        let settlements = ReasoningRouteTransitionSettlementProbe()
        let coordinator = makeCoordinator(selector, delay: delay, settlements: settlements)
        let (stream, continuation) = makeConnectivityStream()
        let observation = coordinator.observeConnectivity(stream)

        continuation.yield(.online)
        try await waitForRoutes(selector, [true])
        continuation.yield(.offline(cachedAt: nil))
        try await waitUntil { await delay.snapshot().waiters == 1 }

        for index in 0..<100 {
            continuation.yield(index.isMultiple(of: 2)
                ? .reconnecting
                : .offline(cachedAt: Date(timeIntervalSince1970: TimeInterval(index))))
        }
        continuation.yield(.online)
        try await waitUntil {
            let snapshot = await delay.snapshot()
            return snapshot.cancellations == 1 && snapshot.waiters == 0 && settlements.count() == 1
        }
        let delaySnapshot = await delay.snapshot()
        XCTAssertEqual(delaySnapshot.requests.count, 1, "duplicate fallback states must not restart delay")
        XCTAssertEqual(selector.routes(), [true])

        continuation.finish()
        await observation.value
    }

    func test_successive_committed_routes_each_require_a_full_stabilization_window() async throws {
        let selector = ReasoningRouteSelectionProbe(
            online: ImmediateBriefingProvider(provenance: .liveReasoned, checkpointId: "online"),
            fallback: ImmediateBriefingProvider(provenance: .cachedSample, checkpointId: "fallback")
        )
        let delay = ManualRouteStabilizationDelay()
        let coordinator = makeCoordinator(selector, delay: delay)
        let (stream, continuation) = makeConnectivityStream()
        let observation = coordinator.observeConnectivity(stream)

        continuation.yield(.online)
        try await waitForRoutes(selector, [true])

        continuation.yield(.offline(cachedAt: nil))
        try await waitUntil { await delay.snapshot().waiters == 1 }
        XCTAssertEqual(selector.routes(), [true])
        await delay.advanceNext()
        try await waitForRoutes(selector, [true, false])

        continuation.yield(.online)
        try await waitUntil { await delay.snapshot().requests.count == 2 }
        XCTAssertEqual(selector.routes(), [true, false])
        await delay.advanceNext()
        try await waitForRoutes(selector, [true, false, true])

        continuation.finish()
        await observation.value
    }

    func test_cancellation_insensitive_old_transition_cannot_win_aba_race() async throws {
        let selector = ReasoningRouteSelectionProbe(
            online: ImmediateBriefingProvider(provenance: .liveReasoned, checkpointId: "online"),
            fallback: ImmediateBriefingProvider(provenance: .cachedSample, checkpointId: "fallback")
        )
        let delay = CancellationInsensitiveRouteStabilizationDelay()
        let settlements = ReasoningRouteTransitionSettlementProbe()
        let coordinator = makeCoordinator(
            selector,
            nonCooperativeDelay: delay,
            settlements: settlements
        )
        let (stream, continuation) = makeConnectivityStream()
        let observation = coordinator.observeConnectivity(stream)

        continuation.yield(.online)
        try await waitForRoutes(selector, [true])
        continuation.yield(.offline(cachedAt: nil))
        try await waitUntil { await delay.snapshot().waiters == 1 }
        continuation.yield(.online)
        continuation.yield(.offline(cachedAt: nil))
        try await waitUntil { await delay.snapshot().waiters == 2 }

        await delay.advanceNext()
        try await waitUntil { settlements.count() == 1 }
        XCTAssertEqual(selector.routes(), [true], "canceled transition A must not commit candidate B")

        await delay.advanceNext()
        try await waitForRoutes(selector, [true, false])
        try await waitUntil { settlements.count() == 2 }
        continuation.finish()
        await observation.value
    }

    func test_replacement_fences_cancellation_insensitive_pending_transition() async throws {
        let selector = ReasoningRouteSelectionProbe(
            online: ImmediateBriefingProvider(provenance: .liveReasoned, checkpointId: "online"),
            fallback: ImmediateBriefingProvider(provenance: .cachedSample, checkpointId: "fallback")
        )
        let delay = CancellationInsensitiveRouteStabilizationDelay()
        let settlements = ReasoningRouteTransitionSettlementProbe()
        let coordinator = makeCoordinator(
            selector,
            nonCooperativeDelay: delay,
            settlements: settlements
        )
        let (oldStream, oldContinuation) = makeConnectivityStream()
        let oldObservation = coordinator.observeConnectivity(oldStream)

        oldContinuation.yield(.online)
        try await waitForRoutes(selector, [true])
        oldContinuation.yield(.offline(cachedAt: nil))
        try await waitUntil { await delay.snapshot().waiters == 1 }

        let (newStream, newContinuation) = makeConnectivityStream()
        let newObservation = coordinator.observeConnectivity(newStream)
        newContinuation.yield(.online)
        newContinuation.yield(.offline(cachedAt: nil))
        try await waitUntil { await delay.snapshot().waiters == 2 }

        await delay.advanceNext()
        try await waitUntil { settlements.count() == 1 }
        XCTAssertEqual(selector.routes(), [true], "old observation timer must not mutate its replacement")

        await delay.advanceNext()
        try await waitForRoutes(selector, [true, false])
        try await waitUntil { settlements.count() == 2 }

        oldContinuation.finish()
        await oldObservation.value
        newContinuation.finish()
        await newObservation.value
    }

    func test_repeated_replacement_cannot_reclaim_first_sample_admission() async throws {
        let selector = ReasoningRouteSelectionProbe(
            online: ImmediateBriefingProvider(provenance: .liveReasoned, checkpointId: "online"),
            fallback: ImmediateBriefingProvider(provenance: .cachedSample, checkpointId: "fallback")
        )
        let delay = ManualRouteStabilizationDelay()
        let settlements = ReasoningRouteTransitionSettlementProbe()
        let coordinator = makeCoordinator(selector, delay: delay, settlements: settlements)
        let (initialStream, initialContinuation) = makeConnectivityStream()
        var currentObservation = coordinator.observeConnectivity(initialStream)

        initialContinuation.yield(.online)
        try await waitForRoutes(selector, [true])

        for index in 0..<100 {
            let (replacementStream, replacementContinuation) = makeConnectivityStream()
            let replacementObservation = coordinator.observeConnectivity(replacementStream)
            await currentObservation.value
            if index > 0 {
                try await waitUntil {
                    let snapshot = await delay.snapshot()
                    return snapshot.cancellations == index && settlements.count() == index
                }
            }

            replacementContinuation.yield(.offline(cachedAt: nil))
            try await waitUntil {
                let snapshot = await delay.snapshot()
                return snapshot.requests.count == index + 1 && snapshot.waiters == 1
            }
            XCTAssertEqual(selector.routes(), [true], "a replacement must retain the prior admission ledger")
            currentObservation = replacementObservation
        }

        coordinator.reset()
        await currentObservation.value
        try await waitUntil {
            let snapshot = await delay.snapshot()
            return snapshot.cancellations == 100
                && snapshot.waiters == 0
                && settlements.count() == 100
        }
        XCTAssertEqual(selector.routes(), [true])
    }

    func test_initial_route_cancellation_wins_atomic_admission_before_provider_selection() async throws {
        let barrier = ReasoningAdmissionAttemptBarrier()
        barrier.arm()
        let selector = ReasoningRouteSelectionProbe(
            online: ImmediateBriefingProvider(provenance: .liveReasoned, checkpointId: "online"),
            fallback: ImmediateBriefingProvider(provenance: .cachedSample, checkpointId: "fallback")
        )
        let coordinator = makeCoordinator(selector, admissionBarrier: barrier)
        let (stream, continuation) = makeConnectivityStream()
        let observation = coordinator.observeConnectivity(stream)
        let cancellation = Task.detached {
            let reached = barrier.waitUntilReached()
            observation.cancel()
            barrier.allowAdmissionAttempt()
            return reached
        }

        continuation.yield(.online)
        let didCancel = await cancellation.value
        XCTAssertTrue(didCancel)
        await observation.value

        XCTAssertFalse(barrier.didTimeOut())
        XCTAssertEqual(selector.routes(), [], "cancellation that owns the lease first must prevent initial admission")
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func test_stabilized_route_cancellation_wins_atomic_admission_before_provider_selection() async throws {
        let barrier = ReasoningAdmissionAttemptBarrier()
        let selector = ReasoningRouteSelectionProbe(
            online: ImmediateBriefingProvider(provenance: .liveReasoned, checkpointId: "online"),
            fallback: ImmediateBriefingProvider(provenance: .cachedSample, checkpointId: "fallback")
        )
        let delay = ManualRouteStabilizationDelay()
        let coordinator = makeCoordinator(selector, delay: delay, admissionBarrier: barrier)
        let (stream, continuation) = makeConnectivityStream()
        let observation = coordinator.observeConnectivity(stream)

        continuation.yield(.online)
        try await waitForRoutes(selector, [true])
        continuation.yield(.offline(cachedAt: nil))
        try await waitUntil { await delay.snapshot().waiters == 1 }

        barrier.arm()
        let cancellation = Task.detached {
            let reached = barrier.waitUntilReached()
            observation.cancel()
            barrier.allowAdmissionAttempt()
            return reached
        }
        await delay.advanceNext()

        let didCancel = await cancellation.value
        XCTAssertTrue(didCancel)
        await observation.value
        XCTAssertFalse(barrier.didTimeOut())
        XCTAssertEqual(selector.routes(), [true], "cancellation that owns the lease first must reject the stable route")
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func test_registered_route_is_cancelled_before_provider_selection_can_start() async throws {
        let barrier = ReasoningAdmissionAttemptBarrier()
        barrier.arm()
        let selector = ReasoningRouteSelectionProbe(
            online: ImmediateBriefingProvider(provenance: .liveReasoned, checkpointId: "online"),
            fallback: ImmediateBriefingProvider(provenance: .cachedSample, checkpointId: "fallback")
        )
        let coordinator = makeCoordinator(selector, registrationBarrier: barrier)
        let (stream, continuation) = makeConnectivityStream()
        let observation = coordinator.observeConnectivity(stream)
        let cancellation = Task.detached {
            let reached = barrier.waitUntilReached()
            observation.cancel()
            barrier.allowAdmissionAttempt()
            return reached
        }

        continuation.yield(.online)
        let didCancel = await cancellation.value
        XCTAssertTrue(didCancel)
        await observation.value

        XCTAssertFalse(barrier.didTimeOut())
        XCTAssertEqual(
            selector.routes(),
            [],
            "the registered task must observe cancellation before selecting a provider"
        )
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func test_direct_observation_cancellation_invalidates_pending_transition_before_cleanup() async throws {
        let selector = ReasoningRouteSelectionProbe(
            online: ImmediateBriefingProvider(provenance: .liveReasoned, checkpointId: "online"),
            fallback: ImmediateBriefingProvider(provenance: .cachedSample, checkpointId: "fallback")
        )
        let delay = CancellationInsensitiveRouteStabilizationDelay()
        let settlements = ReasoningRouteTransitionSettlementProbe()
        let coordinator = makeCoordinator(
            selector,
            nonCooperativeDelay: delay,
            settlements: settlements
        )
        let (stream, continuation) = makeConnectivityStream()
        let observation = coordinator.observeConnectivity(stream)

        continuation.yield(.online)
        try await waitForRoutes(selector, [true])
        continuation.yield(.offline(cachedAt: nil))
        try await waitUntil { await delay.snapshot().waiters == 1 }

        observation.cancel()
        await delay.advanceNext()
        try await waitUntil { settlements.count() == 1 }
        await observation.value

        XCTAssertEqual(selector.routes(), [true], "a canceled observation lease must reject a late timer")
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func test_pending_transition_does_not_cancel_useful_active_provider() async throws {
        let delayedOnline = ControlledBriefingProvider(
            provenance: .liveReasoned,
            checkpointId: "online"
        )
        let selector = ReasoningRouteSelectionProbe(
            online: delayedOnline,
            fallback: ImmediateBriefingProvider(provenance: .cachedSample, checkpointId: "fallback")
        )
        let delay = ManualRouteStabilizationDelay()
        let coordinator = makeCoordinator(selector, delay: delay)
        let (stream, continuation) = makeConnectivityStream()
        let observation = coordinator.observeConnectivity(stream)

        continuation.yield(.online)
        try await waitUntil { await delayedOnline.started() }
        continuation.yield(.offline(cachedAt: nil))
        try await waitUntil { await delay.snapshot().waiters == 1 }

        await delayedOnline.release()
        try await waitForPhase(
            coordinator,
            .briefingReady(plan(checkpointId: "online"), provenance: .liveReasoned)
        )
        XCTAssertEqual(selector.routes(), [true])

        await delay.advanceNext()
        try await waitForRoutes(selector, [true, false])
        continuation.finish()
        await observation.value
    }

    func test_phone_lifecycle_active_cancellation_terminates_exact_observation() async throws {
        let selector = ReasoningRouteSelectionProbe(
            online: ImmediateBriefingProvider(provenance: .liveReasoned, checkpointId: "online"),
            fallback: ImmediateBriefingProvider(provenance: .cachedSample, checkpointId: "fallback")
        )
        let delay = CancellationInsensitiveRouteStabilizationDelay()
        let settlements = ReasoningRouteTransitionSettlementProbe()
        let coordinator = makeCoordinator(
            selector,
            nonCooperativeDelay: delay,
            settlements: settlements
        )
        let factory = ReasoningConnectivityStreamFactoryProbe()
        let lifecycle = PocketPhoneReasoningLifecycle(reasoning: coordinator, makeUpdates: { factory.makeStream() })
        let lifecycleTask = Task { @MainActor in await lifecycle.run(isActive: true) }

        try await waitUntil { factory.snapshot().streams == 1 }
        factory.yield(.online)
        try await waitForRoutes(selector, [true])
        factory.yield(.offline(cachedAt: nil))
        try await waitUntil { await delay.snapshot().waiters == 1 }

        lifecycleTask.cancel()
        await delay.advanceNext()
        try await waitUntil { settlements.count() == 1 }
        await lifecycleTask.value
        try await waitUntil { factory.snapshot().terminations == 1 }
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertEqual(selector.routes(), [true])
    }

    func test_phone_lifecycle_inactive_and_stop_fence_observation_without_extra_stream() async throws {
        let selector = ReasoningRouteSelectionProbe(
            online: ImmediateBriefingProvider(provenance: .liveReasoned, checkpointId: "online"),
            fallback: ImmediateBriefingProvider(provenance: .cachedSample, checkpointId: "fallback")
        )
        let delay = CancellationInsensitiveRouteStabilizationDelay()
        let settlements = ReasoningRouteTransitionSettlementProbe()
        let coordinator = makeCoordinator(
            selector,
            nonCooperativeDelay: delay,
            settlements: settlements
        )
        let factory = ReasoningConnectivityStreamFactoryProbe()
        let lifecycle = PocketPhoneReasoningLifecycle(reasoning: coordinator, makeUpdates: { factory.makeStream() })

        await lifecycle.run(isActive: false)
        XCTAssertEqual(factory.snapshot().streams, 0)
        XCTAssertEqual(coordinator.phase, .idle)

        let lifecycleTask = Task { @MainActor in await lifecycle.run(isActive: true) }
        try await waitUntil { factory.snapshot().streams == 1 }
        factory.yield(.online)
        try await waitForRoutes(selector, [true])
        factory.yield(.offline(cachedAt: nil))
        try await waitUntil { await delay.snapshot().waiters == 1 }

        lifecycle.stop()
        await delay.advanceNext()
        try await waitUntil { settlements.count() == 1 }
        await lifecycleTask.value
        try await waitUntil { factory.snapshot().terminations == 1 }
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertEqual(factory.snapshot().streams, 1)
        XCTAssertEqual(selector.routes(), [true])

        let resumedLifecycleTask = Task { @MainActor in await lifecycle.run(isActive: true) }
        try await waitUntil { factory.snapshot().streams == 2 }
        factory.yield(.online, streamIndex: 1)
        try await waitForRoutes(selector, [true, true])
        resumedLifecycleTask.cancel()
        await resumedLifecycleTask.value
        try await waitUntil { factory.snapshot().terminations == 2 }
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func test_current_observation_completion_fences_pending_transition() async throws {
        let selector = ReasoningRouteSelectionProbe(
            online: ImmediateBriefingProvider(provenance: .liveReasoned, checkpointId: "online"),
            fallback: ImmediateBriefingProvider(provenance: .cachedSample, checkpointId: "fallback")
        )
        let delay = CancellationInsensitiveRouteStabilizationDelay()
        let settlements = ReasoningRouteTransitionSettlementProbe()
        let coordinator = makeCoordinator(
            selector,
            nonCooperativeDelay: delay,
            settlements: settlements
        )
        let (stream, continuation) = makeConnectivityStream()
        let observation = coordinator.observeConnectivity(stream)

        continuation.yield(.online)
        try await waitForRoutes(selector, [true])
        continuation.yield(.offline(cachedAt: nil))
        try await waitUntil { await delay.snapshot().waiters == 1 }

        continuation.finish()
        await observation.value
        await delay.advanceNext()
        try await waitUntil { settlements.count() == 1 }

        XCTAssertEqual(selector.routes(), [true])
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func test_pending_transition_does_not_retain_coordinator_after_deinit() async throws {
        let selector = ReasoningRouteSelectionProbe(
            online: ImmediateBriefingProvider(provenance: .liveReasoned, checkpointId: "online"),
            fallback: ImmediateBriefingProvider(provenance: .cachedSample, checkpointId: "fallback")
        )
        let delay = CancellationInsensitiveRouteStabilizationDelay()
        let settlements = ReasoningRouteTransitionSettlementProbe()
        var coordinator: RealReasoningCoordinator? = makeCoordinator(
            selector,
            nonCooperativeDelay: delay,
            settlements: settlements
        )
        weak var weakCoordinator = coordinator
        let (stream, continuation) = makeConnectivityStream()
        let observation = coordinator!.observeConnectivity(stream)

        continuation.yield(.online)
        try await waitForRoutes(selector, [true])
        continuation.yield(.offline(cachedAt: nil))
        try await waitUntil { await delay.snapshot().waiters == 1 }

        coordinator = nil
        for _ in 0..<1_000 {
            if weakCoordinator == nil { break }
            await Task.yield()
        }
        guard weakCoordinator == nil else {
            XCTFail("pending transition retained the coordinator")
            throw RealReasoningCoordinatorTestError.timeout
        }
        await delay.advanceNext()
        try await waitUntil { settlements.count() == 1 }
        continuation.finish()
        await observation.value

        XCTAssertEqual(selector.routes(), [true])
    }

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

    func test_replacing_observation_preserves_committed_inflight_result_until_new_route() async throws {
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
        XCTAssertEqual(coordinator.phase, .briefingLoading)

        await delayedOnline.release()
        try await waitForPhase(
            coordinator,
            .briefingReady(plan(checkpointId: "old-online"), provenance: .liveReasoned)
        )
        XCTAssertEqual(selector.routes(), [true])

        currentContinuation.yield(.online)
        currentContinuation.yield(.offline(cachedAt: nil))
        try await waitForRoutes(selector, [true, false])

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

    private func makeCoordinator(
        _ selector: ReasoningRouteSelectionProbe,
        delay: ManualRouteStabilizationDelay? = nil,
        nonCooperativeDelay: CancellationInsensitiveRouteStabilizationDelay? = nil,
        settlements: ReasoningRouteTransitionSettlementProbe? = nil,
        admissionBarrier: ReasoningAdmissionAttemptBarrier? = nil,
        registrationBarrier: ReasoningAdmissionAttemptBarrier? = nil
    ) -> RealReasoningCoordinator {
        RealReasoningCoordinator(
            sessionId: "session-1",
            checkpointId: nil,
            selectProvider: selector.select,
            routeStabilizationDelay: { nanoseconds in
                if let delay {
                    try await delay.wait(nanoseconds)
                } else if let nonCooperativeDelay {
                    try await nonCooperativeDelay.wait(nanoseconds)
                }
            },
            routeTransitionDidSettle: {
                settlements?.record()
            },
            routeAdmissionWillAttempt: {
                admissionBarrier?.blockIfArmed()
            },
            routeAdmissionDidRegister: {
                registrationBarrier?.blockIfArmed()
            }
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
