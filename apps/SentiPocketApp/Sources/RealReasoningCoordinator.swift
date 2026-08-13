// RealReasoningCoordinator — the REAL (non-#if-DEBUG) reasoning coordinator. This is the old-screen KILL: the app
// renders/speaks ReasoningPhase outcomes produced from a real ReasoningProvider, instead of PocketAppModel's
// #if-DEBUG fixture (L446 static PocketFixtures.briefingPlan / L646 "no cache evidence" refuse).
//
// It selects the provider by connectivity (online → the verified checkpoint-bound gateway provider;
// offline/reconnecting → the honest injected fallback, cached when one exists or unavailable otherwise). It drives
// the package-tested ReasoningDriver and publishes a ReasoningPhase the view renders + LABELS by provenance
// (warden bar #1: a .cachedSample brief is
// never shown as live). Provider CONSTRUCTION is injected (`selectProvider`) so this compiles + wires today, before
// relay's concrete PocketSyncClient lands — the composition root swaps in the real Gateway client when it ships.

import Foundation
import Combine
import PocketContracts
import PocketReasoning
import PocketUI

/// A task's cancellation handler invalidates this lease synchronously, before the main-actor observation loop gets a
/// chance to unwind. Connectivity requests atomically register their pre-created task with the same lease, closing the
/// race between canceling the observation and admitting work without running app callbacks while a lock is held.
private final class ReasoningConnectivityObservationLease: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var admittedTask: Task<Void, Never>?

    init(admittedTask: Task<Void, Never>? = nil) {
        self.admittedTask = admittedTask
    }

    func invalidate() {
        let task = lock.withLock {
            active = false
            let task = admittedTask
            admittedTask = nil
            return task
        }
        task?.cancel()
    }

    func isActive() -> Bool {
        lock.withLock { active }
    }

    /// Atomically publish a pre-created request task as admitted. The caller creates this task on the MainActor, so it
    /// cannot execute until the current synchronous admission method returns. Cancellation either invalidates first
    /// and registration fails, or takes and cancels the registered task before returning. No external callback runs
    /// under this lock.
    func register(_ task: Task<Void, Never>) -> Bool {
        lock.withLock {
            guard active else { return false }
            admittedTask = task
            return true
        }
    }

    /// Observation replacement transfers ownership without canceling useful same-route work when it wins the race with
    /// cancellation. A false result means cancellation already invalidated (and canceled) the prior admission.
    func retirePreservingAdmission() -> Bool {
        lock.withLock {
            let mayPreserve = active
            active = false
            admittedTask = nil
            return mayPreserve
        }
    }
}

@MainActor
final class RealReasoningCoordinator: ObservableObject {
    @Published private(set) var phase: ReasoningPhase = .idle

    private enum ConnectivityRoute: Equatable {
        case online
        case fallback
    }

    private let sessionId: String
    private let checkpointId: String?
    /// Composition root injects only a checkpoint-bound live provider or an honest unavailable/cached fallback.
    /// A closure (not a stored provider) so connectivity is re-evaluated per request and the concrete clients stay
    /// out of this type — it is complete before relay's PocketSyncClient exists.
    private let selectProvider: @Sendable (_ isOnline: Bool) -> ReasoningProvider
    private let routeStabilizationNanoseconds: UInt64
    private let routeStabilizationDelay: @Sendable (UInt64) async throws -> Void
    private let routeTransitionDidSettle: @Sendable () -> Void
    private let routeAdmissionWillAttempt: @Sendable () -> Void
    private let routeAdmissionDidRegister: @Sendable () -> Void
    private var activeTask: Task<Void, Never>?
    private var connectivityTask: Task<Void, Never>?
    private var connectivityObservationLease: ReasoningConnectivityObservationLease?
    private var connectivityObservationRevision: UInt64 = 0
    private var deliveredConnectivityRoute: ConnectivityRoute?
    private var pendingConnectivityRoute: ConnectivityRoute?
    private var routeTransitionTask: Task<Void, Never>?
    private var routeTransitionRevision: UInt64 = 0

    init(sessionId: String,
         checkpointId: String?,
         selectProvider: @escaping @Sendable (_ isOnline: Bool) -> ReasoningProvider,
         routeStabilizationNanoseconds: UInt64 = 2_000_000_000,
         routeStabilizationDelay: @escaping @Sendable (UInt64) async throws -> Void = { nanoseconds in
             try await Task<Never, Never>.sleep(nanoseconds: nanoseconds)
         },
         routeTransitionDidSettle: @escaping @Sendable () -> Void = {},
         routeAdmissionWillAttempt: @escaping @Sendable () -> Void = {},
         routeAdmissionDidRegister: @escaping @Sendable () -> Void = {}) {
        self.sessionId = sessionId
        self.checkpointId = checkpointId
        self.selectProvider = selectProvider
        self.routeStabilizationNanoseconds = max(1, routeStabilizationNanoseconds)
        self.routeStabilizationDelay = routeStabilizationDelay
        self.routeTransitionDidSettle = routeTransitionDidSettle
        self.routeAdmissionWillAttempt = routeAdmissionWillAttempt
        self.routeAdmissionDidRegister = routeAdmissionDidRegister
    }

    deinit {
        connectivityObservationLease?.invalidate()
        routeTransitionTask?.cancel()
        connectivityTask?.cancel()
        activeTask?.cancel()
    }

    /// Observe live path changes for this selected-session coordinator. A new observation fences and cancels the old
    /// one before it starts. Offline and reconnecting share one fallback route, so noisy transitions between those
    /// states do not restart reasoning; only an online↔fallback route transition reloads the briefing.
    func observeConnectivity(
        _ updates: AsyncStream<PocketConnectivity>
    ) -> Task<Void, Never> {
        connectivityObservationRevision &+= 1
        let revision = connectivityObservationRevision
        let previousTask = connectivityTask
        let previousLease = connectivityObservationLease
        connectivityTask = nil
        connectivityObservationLease = nil
        let preservesActiveRequest = previousLease?.retirePreservingAdmission() ?? true
        previousTask?.cancel()
        // Observation ownership may change while the view remains active. Fence the old stream and discard only its
        // uncommitted candidate; retaining the delivered route + request keeps a replacement from reclaiming the
        // first-sample admission exemption or canceling useful same-route work.
        cancelPendingRouteTransition()
        if !preservesActiveRequest {
            deliveredConnectivityRoute = nil
            cancelActiveRequest()
            phase = .idle
        }

        let lease = ReasoningConnectivityObservationLease(
            admittedTask: preservesActiveRequest ? activeTask : nil
        )
        let task = Task { @MainActor [weak self] in
            await withTaskCancellationHandler {
                for await connectivity in updates {
                    guard !Task.isCancelled,
                          lease.isActive(),
                          let self,
                          self.connectivityObservationRevision == revision,
                          self.connectivityObservationLease === lease else {
                        break
                    }
                    let route = Self.route(for: connectivity)
                    self.acceptConnectivityRoute(
                        route,
                        observationRevision: revision,
                        lease: lease
                    )
                }

                lease.invalidate()
                guard let self,
                      self.connectivityObservationRevision == revision,
                      self.connectivityObservationLease === lease else { return }
                self.connectivityObservationRevision &+= 1
                self.connectivityTask = nil
                self.connectivityObservationLease = nil
                self.clearConnectivityRouting()
                self.cancelActiveRequest()
                self.phase = .idle
            } onCancel: {
                lease.invalidate()
            }
        }
        connectivityTask = task
        connectivityObservationLease = lease
        return task
    }

    /// Load the real reasoned briefing. Sets `.briefingLoading`, then publishes `.briefingReady` (with provenance)
    /// or `.failed`. Supersedes any in-flight request (a newer intent wins; the stale result is dropped).
    func loadBriefing(connectivity: PocketConnectivity) {
        activeTask?.cancel()
        phase = .briefingLoading
        let driver = ReasoningDriver(provider: selectProvider(Self.isOnline(connectivity)))
        let sid = sessionId, cid = checkpointId
        activeTask = Task { [weak self] in
            let result = await driver.loadBriefing(sessionId: sid, checkpointId: cid)
            if Task.isCancelled { return }
            self?.phase = result
        }
    }

    /// Ask a grounded question. Sets `.answerLoading`, then publishes `.answered` (answered/clarify/unavailable —
    /// never the old hard-refuse) or `.failed`.
    func ask(_ question: String, connectivity: PocketConnectivity) {
        activeTask?.cancel()
        phase = .answerLoading(question: question)
        let driver = ReasoningDriver(provider: selectProvider(Self.isOnline(connectivity)))
        let sid = sessionId, cid = checkpointId
        activeTask = Task { [weak self] in
            let result = await driver.answer(question, sessionId: sid, checkpointId: cid)
            if Task.isCancelled { return }
            self?.phase = result
        }
    }

    func reset() {
        connectivityObservationRevision &+= 1
        let observation = connectivityTask
        let lease = connectivityObservationLease
        connectivityTask = nil
        connectivityObservationLease = nil
        lease?.invalidate()
        observation?.cancel()
        clearConnectivityRouting()
        cancelActiveRequest()
        phase = .idle
    }

    /// online → Gateway (.liveReasoned); offline/reconnecting → the honest injected fallback. Reconnecting is treated
    /// as NOT-online on purpose: a flaky link never starts a live reasoned call. The fallback may serve a labeled,
    /// verified cache when one exists or may honestly report that no cache is available.
    private static func isOnline(_ connectivity: PocketConnectivity) -> Bool {
        if case .online = connectivity { return true }
        return false
    }

    private static func route(for connectivity: PocketConnectivity) -> ConnectivityRoute {
        isOnline(connectivity) ? .online : .fallback
    }

    /// The first path sample is responsive. Every later online↔fallback edge must remain the newest candidate for a
    /// complete stabilization window before it can start another provider request. This admission bound is scoped to
    /// one active lifecycle epoch; an explicit reset clears it so the next foreground activation can load immediately.
    /// A rebound to the delivered route cancels the candidate without canceling useful in-flight work; repeated
    /// offline/reconnecting samples share the same fallback route and never restart the timer. Observation + transition
    /// revisions fence a canceled timer even when an injected delay ignores cancellation.
    private func acceptConnectivityRoute(
        _ route: ConnectivityRoute,
        observationRevision: UInt64,
        lease: ReasoningConnectivityObservationLease
    ) {
        guard observationRevision == connectivityObservationRevision,
              connectivityObservationLease === lease,
              lease.isActive() else { return }

        guard let deliveredConnectivityRoute else {
            guard admitConnectivityBriefing(route: route, lease: lease) else { return }
            pendingConnectivityRoute = nil
            self.deliveredConnectivityRoute = route
            return
        }

        if route == deliveredConnectivityRoute {
            cancelPendingRouteTransition()
            return
        }
        guard route != pendingConnectivityRoute else { return }

        cancelPendingRouteTransition()
        pendingConnectivityRoute = route
        routeTransitionRevision &+= 1
        let transitionRevision = routeTransitionRevision
        let delay = routeStabilizationDelay
        let didSettle = routeTransitionDidSettle
        let nanoseconds = routeStabilizationNanoseconds

        routeTransitionTask = Task { @MainActor [weak self] in
            defer { didSettle() }
            guard !Task.isCancelled else { return }
            do {
                try await delay(nanoseconds)
            } catch {
                self?.abandonPendingConnectivityRoute(
                    route,
                    observationRevision: observationRevision,
                    transitionRevision: transitionRevision,
                    lease: lease
                )
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.commitPendingConnectivityRoute(
                route,
                observationRevision: observationRevision,
                transitionRevision: transitionRevision,
                lease: lease
            )
        }
    }

    private func commitPendingConnectivityRoute(
        _ route: ConnectivityRoute,
        observationRevision: UInt64,
        transitionRevision: UInt64,
        lease: ReasoningConnectivityObservationLease
    ) {
        guard observationRevision == connectivityObservationRevision,
              connectivityObservationLease === lease,
              transitionRevision == routeTransitionRevision,
              pendingConnectivityRoute == route,
              deliveredConnectivityRoute != route else { return }
        guard admitConnectivityBriefing(route: route, lease: lease) else { return }
        routeTransitionTask = nil
        pendingConnectivityRoute = nil
        deliveredConnectivityRoute = route
    }

    private func abandonPendingConnectivityRoute(
        _ route: ConnectivityRoute,
        observationRevision: UInt64,
        transitionRevision: UInt64,
        lease: ReasoningConnectivityObservationLease
    ) {
        guard observationRevision == connectivityObservationRevision,
              connectivityObservationLease === lease,
              lease.isActive(),
              transitionRevision == routeTransitionRevision,
              pendingConnectivityRoute == route else { return }
        routeTransitionTask = nil
        pendingConnectivityRoute = nil
    }

    private func admitConnectivityBriefing(
        route: ConnectivityRoute,
        lease: ReasoningConnectivityObservationLease
    ) -> Bool {
        let task = makeConnectivityBriefingTask(route: route)
        routeAdmissionWillAttempt()
        guard lease.register(task) else {
            task.cancel()
            return false
        }

        // Registration is the admission linearization point. Cancellation after this point takes and cancels `task`
        // before returning. All potentially re-entrant operations remain outside the lease lock.
        activeTask?.cancel()
        activeTask = task
        routeAdmissionDidRegister()
        guard lease.isActive() else {
            task.cancel()
            return false
        }
        return true
    }

    private func makeConnectivityBriefingTask(route: ConnectivityRoute) -> Task<Void, Never> {
        let isOnline = route == .online
        let selectProvider = selectProvider
        let sid = sessionId
        let cid = checkpointId
        return Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            self?.phase = .briefingLoading
            guard !Task.isCancelled else { return }
            let driver = ReasoningDriver(provider: selectProvider(isOnline))
            guard !Task.isCancelled else { return }
            let result = await driver.loadBriefing(sessionId: sid, checkpointId: cid)
            guard !Task.isCancelled else { return }
            self?.phase = result
        }
    }

    private func cancelPendingRouteTransition() {
        routeTransitionRevision &+= 1
        let transition = routeTransitionTask
        routeTransitionTask = nil
        pendingConnectivityRoute = nil
        transition?.cancel()
    }

    private func clearConnectivityRouting() {
        cancelPendingRouteTransition()
        deliveredConnectivityRoute = nil
    }

    private func cancelActiveRequest() {
        let request = activeTask
        activeTask = nil
        request?.cancel()
    }
}
