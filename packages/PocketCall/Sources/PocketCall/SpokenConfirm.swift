import Foundation

/// SpokenConfirm — the deterministic safety core of warden's voice-GO consent bar 2b (DIALS "Senti Pocket dials
/// Carter"). The app reads back the EXACT message ("I'll post as you: '<message>'. Say 'confirm' to send.") and feeds
/// the recognized speech here. Only an EXPLICIT, unambiguous "confirm" returns `.confirmed`; ambient "go"/"yes"/keyword
/// speech, a negated confirm, or nothing → `.unclear` (the caller RE-ASKS, NEVER posts); an explicit refusal → `.declined`.
/// Fail-safe by construction: the default is never `.confirmed`. This is the LEAF the DialOrchestrator calls; the write
/// itself still flows through the existing proposal-hash gate (bar 2c) unchanged.
public enum SpokenConfirmVerdict: Equatable, Sendable {
    case confirmed                  // explicit unambiguous confirm → the write may proceed (2b satisfied)
    case declined                   // explicit cancel/refusal → abort the write
    case unclear(reason: String)    // ambiguous / no explicit confirm → RE-ASK, never post
}

public enum SpokenConfirm {
    /// The exact confirm tokens the app asks for. Deterministic — NOT ambient "go"/"yes"/keyword detection.
    static let confirmTokens: Set<String> = ["confirm", "confirmed"]
    /// Explicit refusals + negations. Any present means the result is NEVER `.confirmed` (fail-safe toward not-posting).
    static let declineTokens: Set<String> = [
        "cancel", "stop", "abort", "no", "nope",
        "not", "dont", "do not", "cant", "cannot", "wont", "will not", "never", "nevermind", "never mind",
    ]
    /// A confirm must be a FOCUSED response (the app asked for one word); 'confirm' buried in a long utterance is not
    /// the deterministic response we asked for → re-ask. Bounds the risk of a missed negation hiding in a ramble.
    static let maxConfirmWords = 6

    /// Fail-safe verdict for bar 2b. `.confirmed` requires an explicit confirm token, NO decline/negation present, and
    /// a focused (short) utterance; a decline/negation → `.declined` (or `.unclear` if it collides with a confirm
    /// token); anything else → `.unclear`. The default is never `.confirmed`.
    public static func verdict(for transcript: String) -> SpokenConfirmVerdict {
        let words = normalizedWords(transcript)
        guard !words.isEmpty else { return .unclear(reason: "no speech recognized") }
        let padded = " " + words.joined(separator: " ") + " "

        let hasDecline = declineTokens.contains { padded.contains(" " + $0 + " ") }
        let hasConfirm = confirmTokens.contains { padded.contains(" " + $0 + " ") }

        if hasDecline {
            // A decline/negation NEVER reads as confirm. Colliding with a confirm token ("don't confirm") → re-ask
            // rather than guess intent; a clean refusal aborts.
            return hasConfirm ? .unclear(reason: "confirm heard alongside a negation") : .declined
        }
        guard hasConfirm else { return .unclear(reason: "no explicit 'confirm' heard") }
        guard words.count <= maxConfirmWords else { return .unclear(reason: "'confirm' buried in a long utterance") }
        return .confirmed
    }

    /// Lowercase, drop apostrophes (so "don't" → "dont"), map every other non-alphanumeric to a break, split on runs.
    static func normalizedWords(_ s: String) -> [String] {
        let deApos = s.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
        let cleaned = String(deApos.map { ($0.isLetter || $0.isNumber) ? $0 : " " })
        return cleaned.split(separator: " ").map(String.init)
    }
}
