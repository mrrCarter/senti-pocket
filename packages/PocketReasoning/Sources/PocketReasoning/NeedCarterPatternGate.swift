// NeedCarterPatternGate — STAGE 1 of the ring-the-owner detector (Carter's "pattern match, free ML"). A cheap,
// deterministic, LLM-FREE filter over the recent chat tail: it runs on every poll and kills ~99% of tail noise
// before any model is invoked, so the expensive Stage-2 LLM confirm only runs on a plausible hit. NO ring fires from
// this stage alone — a Stage-1 hit is a CANDIDATE, not a decision; Stage-2 (the LLM reading the surrounding tail)
// decides if Carter is GENUINELY needed. This mirrors the ENGRAM recall discipline: cheap filter, expensive confirm.
//
// Pure + Sendable + fully unit-testable (no network, no model). Owns only the pattern layer; emits a candidate the
// gateway/app feeds to Stage-2.

import Foundation

/// A minimal view of a chat message the gate scans (decoupled from any transport DTO).
public struct TailMessage: Equatable, Sendable {
    public let sequenceId: Int
    public let author: String       // agent id, or a human id like "human-mrrcarter"
    public let text: String
    public init(sequenceId: Int, author: String, text: String) {
        self.sequenceId = sequenceId; self.author = author; self.text = text
    }
}

/// A Stage-1 hit: which messages tripped which signals. Feeds Stage-2 (never rings on its own).
public struct NeedCarterCandidate: Equatable, Sendable {
    public let matchedSequenceIds: [Int]
    public let cues: [String]           // the human-readable cues that fired (for audit + the Stage-2 prompt)
    public let likelyKindSlug: String   // a cheap first guess: "go" | "decision-yours" | "pick-option" | "info" | "checkpoint-ready"
    public init(matchedSequenceIds: [Int], cues: [String], likelyKindSlug: String) {
        self.matchedSequenceIds = matchedSequenceIds; self.cues = cues; self.likelyKindSlug = likelyKindSlug
    }
}

public struct NeedCarterPatternGate: Sendable {
    /// The human whose attention is being detected (default Carter). A direct @-mention of them is the strongest cue.
    private let ownerHandles: [String]
    public init(ownerHandles: [String] = ["@human-mrrcarter", "@carter", "@mrrcarter"]) {
        self.ownerHandles = ownerHandles.map { $0.lowercased() }
    }

    // Cue phrases, grouped by the kind they most suggest. All matched case-insensitively as substrings — the gate is
    // intentionally GENEROUS (high recall); Stage-2 supplies the precision (kills false positives). Adding a cue here
    // widens what reaches Stage-2, never what rings.
    private static let decisionCues = ["your call", "your decision", "decision is yours", "you decide", "up to you", "need a decision", "needs your decision", "waiting on carter", "waiting on you", "need carter", "carter's call"]
    private static let goCues = ["say go", "give the go", "greenlight", "green light", "ok to proceed", "go or no", "go/no", "shall we proceed", "need a go", "your go"]
    private static let optionCues = ["option a", "option b", "option c", "a/b/c", "which one", "pick one", "choose between", "which do you want"]
    private static let checkpointCues = ["checkpoint ready", "checkpoint is ready", "milestone reached", "ready for review", "ready to review", "checkpoint complete"]

    /// Scan a tail window → a candidate, or nil if nothing tripped. `nil` is the overwhelmingly common result
    /// (that's the point — near-zero cost when Carter is NOT needed).
    public func scan(_ tail: [TailMessage]) -> NeedCarterCandidate? {
        var matched = Set<Int>()
        var cues: [String] = []
        var kindVotes: [String: Int] = [:]

        for msg in tail {
            let lower = msg.text.lowercased()
            // Strongest cue: a direct @-mention of the owner by someone who is NOT the owner.
            if !isOwner(msg.author), ownerHandles.contains(where: { lower.contains($0) }) {
                matched.insert(msg.sequenceId); cues.append("@-mention of owner"); bump(&kindVotes, "decision-yours")
            }
            hit(Self.decisionCues, in: lower, msg, &matched, &cues, &kindVotes, "decision-yours")
            hit(Self.goCues,        in: lower, msg, &matched, &cues, &kindVotes, "go")
            hit(Self.optionCues,    in: lower, msg, &matched, &cues, &kindVotes, "pick-option")
            hit(Self.checkpointCues,in: lower, msg, &matched, &cues, &kindVotes, "checkpoint-ready")
        }

        guard !matched.isEmpty else { return nil }
        let likely = kindVotes.max(by: { $0.value < $1.value })?.key ?? "info"
        return NeedCarterCandidate(matchedSequenceIds: matched.sorted(), cues: dedupe(cues), likelyKindSlug: likely)
    }

    private func isOwner(_ author: String) -> Bool {
        let a = author.lowercased()
        return a.contains("human") || a.contains("carter") || a.contains("mrrcarter")
    }

    private func hit(_ phrases: [String], in lower: String, _ msg: TailMessage,
                     _ matched: inout Set<Int>, _ cues: inout [String], _ votes: inout [String: Int], _ kind: String) {
        for p in phrases where lower.contains(p) {
            matched.insert(msg.sequenceId); cues.append("\"\(p)\""); bump(&votes, kind)
            break   // one cue-hit per phrase-group per message is enough to flag it
        }
    }

    private func bump(_ votes: inout [String: Int], _ k: String) { votes[k, default: 0] += 1 }
    private func dedupe(_ xs: [String]) -> [String] { var seen = Set<String>(); return xs.filter { seen.insert($0).inserted } }
}
