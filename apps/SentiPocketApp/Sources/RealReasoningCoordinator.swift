// RealReasoningCoordinator — the REAL (non-#if-DEBUG) reasoning coordinator. This is the old-screen KILL: the app
// renders/speaks ReasoningPhase outcomes produced from a real ReasoningProvider, instead of PocketAppModel's
// #if-DEBUG fixture (L446 static PocketFixtures.briefingPlan / L646 "no cache evidence" refuse).
//
// It selects the provider by connectivity (online → GatewayReasoningProvider over relay's gated /brief+/answer;
// offline/reconnecting → the honest CachedReasoningProvider), drives the package-tested ReasoningDriver, and
// publishes a ReasoningPhase the view renders + LABELS by provenance (warden bar #1: a .cachedSample brief is
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

    private let sessionId: String
    private let checkpointId: String?
    /// Composition root injects this: `isOnline ? GatewayReasoningProvider(client:) : CachedReasoningProvider(...)`.
    /// A closure (not a stored provider) so connectivity is re-evaluated per request and the concrete clients stay
    /// out of this type — it is complete before relay's PocketSyncClient exists.
    private let selectProvider: @Sendable (_ isOnline: Bool) -> ReasoningProvider
    private var activeTask: Task<Void, Never>?

    init(sessionId: String,
         checkpointId: String?,
         selectProvider: @escaping @Sendable (_ isOnline: Bool) -> ReasoningProvider) {
        self.sessionId = sessionId
        self.checkpointId = checkpointId
        self.selectProvider = selectProvider
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
        activeTask?.cancel()
        activeTask = nil
        phase = .idle
    }

    /// online → Gateway (.liveReasoned); offline/reconnecting → the honest Cached path. Reconnecting is treated as
    /// NOT-online on purpose: we don't attempt a live reasoned call on a flaky link, we serve the cached sample.
    private static func isOnline(_ connectivity: PocketConnectivity) -> Bool {
        if case .online = connectivity { return true }
        return false
    }
}
