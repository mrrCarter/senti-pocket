import Foundation
import PocketContracts

/// Deterministically turns a grounded CheckpointSummary into an ordered spoken BriefingPlan (Atlas-owned).
/// NO model here — the online grounded summarizer already produced the evidence-cited, epistemic-typed claims;
/// this just orders them for narration, keeps it short (bounded), holds RECOMMENDATIONS back for the governed
/// proposal step (never spoken as if already decided), and carries evidenceIds so the phone shows the right card.
public enum BriefingBuilder {

    public static func plan(from summary: CheckpointSummary, maxClaimsPerAgent: Int = 3) -> BriefingPlan {
        var segments: [BriefingSegment] = []

        segments.append(BriefingSegment(
            id: "seg-headline",
            text: "Here's what happened while you were away. \(summary.headline)",
            evidenceIds: []))

        // Per agent: speak FACT + INFERENCE claims (bounded). Recommendations are held for the proposal step.
        for agent in summary.perAgent {
            let spoken = Array(agent.claims.filter { $0.kind != .recommendation }.prefix(maxClaimsPerAgent))
            guard !spoken.isEmpty else { continue }
            let text = "\(displayName(agent.agentId)): " + spoken.map { $0.text }.joined(separator: " ")
            segments.append(BriefingSegment(
                id: "seg-agent-\(agent.agentId)",
                text: text,
                evidenceIds: dedup(spoken.flatMap { $0.evidenceIds })))
        }

        // Recommendations across all agents -> a single "suggested next steps" segment (framed as suggestions,
        // NOT actions taken; the human still dictates + confirms any write).
        let recs = summary.perAgent.flatMap { $0.claims }.filter { $0.kind == .recommendation }
        if !recs.isEmpty {
            segments.append(BriefingSegment(
                id: "seg-recommendations",
                text: "Suggested next steps you could give: " + recs.map { $0.text }.joined(separator: " "),
                evidenceIds: dedup(recs.flatMap { $0.evidenceIds })))
        }

        if !summary.blockers.isEmpty {
            segments.append(BriefingSegment(
                id: "seg-blockers",
                text: "Blockers right now: " + summary.blockers.joined(separator: " "),
                evidenceIds: []))
        }

        return BriefingPlan(checkpointId: summary.checkpointId, segments: segments)
    }

    private static func dedup(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }

    /// "claude-pocket-relay" -> "Relay"; "codex-01" -> "Codex-01"; unknown -> raw id. Deterministic, no I/O.
    private static func displayName(_ agentId: String) -> String {
        guard let last = agentId.split(separator: "-").last, !last.isEmpty else { return agentId }
        return last.prefix(1).uppercased() + last.dropFirst()
    }
}
