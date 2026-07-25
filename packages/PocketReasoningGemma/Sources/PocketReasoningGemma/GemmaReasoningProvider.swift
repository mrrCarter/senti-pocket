// GemmaReasoningProvider — the ON-DEVICE Gemma provider (.liveReasoned, OFFLINE). Bridges echo's PocketInference
// (LiteRT-LM running Gemma E4B on the phone) into the ReasoningProvider abstraction, so the app reasons over the
// VERIFIED checkpoint with Gemma ON-DEVICE — no cloud, no OpenAI key. This is the concrete "Gemma is actually used"
// path for reasoning: the coordinator injects it as the OFFLINE provider (online → GatewayReasoningProvider).
//
// The engine must already have prepareModel'd a verified Gemma artifact (ModelArtifactStore) before this runs;
// otherwise engine.answer throws and the driver surfaces `.failed` honestly (never a fabricated brief).

import Foundation
import PocketContracts
import PocketCall
import PocketReasoning
import PocketInference

public struct GemmaReasoningProvider: ReasoningProvider {
    public let provenance: ReasoningProvenance = .liveReasoned

    private let engine: LocalInferenceEngine
    private let bundle: VerifiedBundle            // the verified checkpoint Gemma grounds on (never unverified input)
    private let clock: @Sendable () -> Date

    public init(engine: LocalInferenceEngine,
                verifiedBundle: VerifiedBundle,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.engine = engine
        self.bundle = verifiedBundle
        self.clock = clock
    }

    public func briefing(sessionId: String, checkpointId: String?) async throws -> BriefingPlan {
        let request = try GroundedInferenceRequest(verifiedBundle: bundle, question: Self.briefingQuestion)
        let qa = try await engine.answer(request).questionAnswer
        // The grounded brief = Gemma's answer as one segment, citing the evidence it grounded on. If Gemma had no
        // grounded answer, emit an EMPTY plan (the driver/UI treats an empty brief honestly) rather than a fabrication.
        guard !qa.citations.isEmpty, qa.answer != GroundedAnswerDecoder.noEvidenceAnswer else {
            return BriefingPlan(checkpointId: bundle.bundle.checkpointId, segments: [])
        }
        return BriefingPlan(checkpointId: bundle.bundle.checkpointId, segments: [
            BriefingSegment(id: "gemma-0", text: qa.answer, evidenceIds: qa.citations)
        ])
    }

    public func answer(_ question: String, sessionId: String, checkpointId: String?) async throws -> ReasonedAnswer {
        let request = try GroundedInferenceRequest(verifiedBundle: bundle, question: question)
        let qa = try await engine.answer(request).questionAnswer
        // Grounding-first honesty (same discipline as the gateway routeAnswer): no grounded citation ⇒ NOT answered.
        guard !qa.citations.isEmpty, qa.answer != GroundedAnswerDecoder.noEvidenceAnswer else {
            return .unavailable(nearestTopics: bundle.bundle.evidence.prefix(4).map {
                NearestTopic(label: Self.topicLabel($0.snippet), evidenceId: $0.id)
            })
        }
        return .answered(ReasonedQuestionAnswer(
            id: qa.id,
            checkpointId: qa.checkpointId,
            question: question,
            text: qa.answer,
            taggedText: nil,                      // on-device audio-tags are a later pass; plain text now
            evidenceIds: qa.citations,            // Gemma's grounded citations (the decoder bounds them to the bundle)
            llmConfidence: nil,                   // grounding is the signal, not a self-reported score
            provenance: .liveReasoned,
            createdAt: clock()
        ))
    }

    private static let briefingQuestion =
        "Give a concise, grounded briefing of this checkpoint — the key decisions, risks, and who did what — citing the evidence."

    private static func topicLabel(_ snippet: String, limit: Int = 80) -> String {
        let oneLine = snippet.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return oneLine.count > limit ? String(oneLine.prefix(limit)) + "…" : oneLine
    }
}
