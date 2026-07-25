// CachedReasoningProvider — the OFFLINE fallback (.cachedSample). Serves the LAST-SYNCED briefing and, for Q&A,
// honestly surfaces the nearest cached topics — it NEVER reasons and NEVER fabricates an answer offline. This is
// the honest floor beneath the online GatewayReasoningProvider; Echo's on-device E4B is the future .liveReasoned
// OFFLINE provider that will replace this for real offline reasoning.
//
// Warden bar #1 (honest labeling): `provenance == .cachedSample`. The coordinator/UI renders that unmistakably as a
// cached sample — a cached brief is NEVER shown as a live reasoned brief, and offline Q&A never emits `.answered`.

import Foundation
import PocketContracts

public struct CachedReasoningProvider: ReasoningProvider {
    public let provenance: ReasoningProvenance = .cachedSample

    /// The last briefing successfully produced online (persisted at sync). Replayed verbatim, labeled cached.
    private let cachedBriefing: BriefingPlan
    /// The verified checkpoint's evidence — used ONLY to surface honest nearest-topics for offline Q&A (never to
    /// fabricate an answer). Empty ⇒ offline Q&A returns `.unavailable([])` (honest "nothing cached to point at").
    private let cachedEvidence: [EvidenceRef]
    private let maxTopics: Int

    public init(cachedBriefing: BriefingPlan, cachedEvidence: [EvidenceRef], maxTopics: Int = 4) {
        self.cachedBriefing = cachedBriefing
        self.cachedEvidence = cachedEvidence
        self.maxTopics = max(0, maxTopics)
    }

    public func briefing(sessionId: String, checkpointId: String?) async throws -> BriefingPlan {
        // Replay the cached briefing. provenance == .cachedSample makes the UI label it; we never claim it is live.
        cachedBriefing
    }

    public func answer(_ question: String, sessionId: String, checkpointId: String?) async throws -> ReasonedAnswer {
        // Offline + no LLM → we do NOT reason. Honest behavior = surface the nearest cached topics, never a fabricated
        // answer and never a flat refuse (the old L646 dead-end). Same shape as the gateway's `unavailable`, so the UI
        // renders one consistent "here's the closest cached context" affordance online or offline.
        let topics = cachedEvidence.prefix(maxTopics).map {
            NearestTopic(label: Self.topicLabel(from: $0.snippet), evidenceId: $0.id)
        }
        return .unavailable(nearestTopics: Array(topics))
    }

    /// A compact topic label from an evidence snippet (single line, bounded) — a pointer, not the full evidence.
    private static func topicLabel(from snippet: String, limit: Int = 80) -> String {
        let oneLine = snippet
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard oneLine.count > limit else { return oneLine }
        return String(oneLine.prefix(limit)) + "…"
    }
}
