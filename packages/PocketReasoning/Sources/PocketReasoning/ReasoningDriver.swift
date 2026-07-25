// ReasoningDriver — the connectivity-agnostic orchestration core the real (non-#if-DEBUG) app coordinator drives.
// Kept in the package (UI-agnostic, no PocketUI import) so the honesty of the flow is UNIT-TESTED with a mock
// provider, no live LLM and no simulator. The app-target coordinator adds connectivity→provider selection,
// @Published state, and the speech/UI wiring on top of this.
//
// This is the piece that KILLS the old fixture screen: the app renders/speaks `ReasoningPhase` outcomes produced
// here from a real ReasoningProvider, instead of PocketAppModel's L446 static briefing / L646 hard-refuse.

import Foundation
import PocketContracts

/// What the UI renders at each step. Equatable so SwiftUI/@Published diffing + tests are cheap. `provenance` rides
/// on every ready state so the view can label a `.cachedSample` unmistakably (warden bar #1).
public enum ReasoningPhase: Sendable, Equatable {
    case idle
    case briefingLoading
    case briefingReady(BriefingPlan, provenance: ReasoningProvenance)
    case answerLoading(question: String)
    case answered(ReasonedAnswer, provenance: ReasoningProvenance)
    case failed(reason: String)
}

/// Drives one ReasoningProvider through a briefing or a question, mapping success/failure to a `ReasoningPhase`.
/// Never throws to the caller — a provider error becomes `.failed` (honest, surfaced), never a crash or a silent
/// fabricated result.
public struct ReasoningDriver: Sendable {
    private let provider: ReasoningProvider
    public init(provider: ReasoningProvider) { self.provider = provider }

    /// Provenance of the underlying provider (so the coordinator can label the loading state too, if it wants).
    public var provenance: ReasoningProvenance { provider.provenance }

    public func loadBriefing(sessionId: String, checkpointId: String?) async -> ReasoningPhase {
        do {
            let plan = try await provider.briefing(sessionId: sessionId, checkpointId: checkpointId)
            return .briefingReady(plan, provenance: provider.provenance)
        } catch {
            return .failed(reason: Self.describe(error, fallback: "Briefing unavailable."))
        }
    }

    public func answer(_ question: String, sessionId: String, checkpointId: String?) async -> ReasoningPhase {
        do {
            let result = try await provider.answer(question, sessionId: sessionId, checkpointId: checkpointId)
            return .answered(result, provenance: provider.provenance)
        } catch {
            return .failed(reason: Self.describe(error, fallback: "That could not be answered right now."))
        }
    }

    private static func describe(_ error: Error, fallback: String) -> String {
        let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        return msg.isEmpty ? fallback : msg
    }
}
