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
    private var activeTask: Task<Void, Never>?
    private var connectivityTask: Task<Void, Never>?
    private var connectivityObservationRevision: UInt64 = 0
    private var connectivityRoute: ConnectivityRoute?

    init(sessionId: String,
         checkpointId: String?,
         selectProvider: @escaping @Sendable (_ isOnline: Bool) -> ReasoningProvider) {
        self.sessionId = sessionId
        self.checkpointId = checkpointId
        self.selectProvider = selectProvider
    }

    deinit {
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
        connectivityTask = nil
        connectivityRoute = nil
        previousTask?.cancel()
        cancelActiveRequest()
        phase = .idle

        let task = Task { @MainActor [weak self] in
            for await connectivity in updates {
                guard !Task.isCancelled,
                      let self,
                      self.connectivityObservationRevision == revision else {
                    break
                }
                let route = Self.route(for: connectivity)
                guard self.connectivityRoute != route else { continue }
                self.connectivityRoute = route
                self.loadBriefing(connectivity: connectivity)
            }

            guard let self,
                  self.connectivityObservationRevision == revision else { return }
            self.connectivityTask = nil
            self.connectivityRoute = nil
            self.cancelActiveRequest()
            self.phase = .idle
        }
        connectivityTask = task
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
        connectivityTask = nil
        connectivityRoute = nil
        observation?.cancel()
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

    private func cancelActiveRequest() {
        let request = activeTask
        activeTask = nil
        request?.cancel()
    }
}
