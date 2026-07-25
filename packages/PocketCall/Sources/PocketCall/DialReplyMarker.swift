import Foundation

/// DialReplyMarker — the DETERMINISTIC consent seam of the DIALS conversing phase: the ONLY way an utterance
/// exits the Q&A loop into a governed write.
///
/// Rule (gated with Atlas, the 4 conversing-phase invariants): a transcript is a dictated REPLY only if it
/// BEGINS WITH (prefix-match, case-insensitive) one of a small CLOSED set of explicit markers. Prefix, NOT
/// contains — so "what should my reply be?" and "what did you mean by 'my reply is'?" stay QUESTIONS. With no
/// marker the orchestrator answers the utterance aloud and NEVER posts. Ambiguity ALWAYS resolves toward
/// "answer," never "post": an accidental post is the unrecoverable error; an accidental answer is harmless —
/// the user simply re-states with the marker. This is the inverse-safe of LiveDialVoice.listen()'s determinism.
///
/// NB: even a matched marker only ever routes to DICTATING -> the SAME governed PhoneWriteAdapter.confirmAndPost
/// a tap uses (read-back + explicit confirm). A false marker-trigger drafts-then-confirms; it never auto-posts.
public enum DialReplyMarker {

    /// The closed, bounded marker set (lowercased, no trailing punctuation). EXTEND ONLY WITH REVIEW — every
    /// entry is a new path from speech into a write.
    public static let markers: [String] = [
        "my reply is",
        "here is my reply",
        "here's my reply",
        "post this",
        "reply:"
    ]

    /// Classification of a conversing-phase utterance.
    public enum Classification: Equatable, Sendable {
        /// No marker — treat as a follow-up QUESTION: answer aloud, NEVER post.
        case question
        /// A marker followed by dictated text — that text is the verbatim reply to draft -> confirm.
        case reply(String)
        /// A BARE marker (nothing usable after it) — the caller takes the NEXT listen() verbatim as the reply.
        case awaitingReply
    }

    /// Deterministically classify a transcript. Never throws; empty/whitespace -> `.question`.
    public static func classify(_ transcript: String) -> Classification {
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return .question }
        let lower = normalized.lowercased()

        for marker in markers where lower.hasPrefix(marker) {
            // Markers are ASCII, so the lowercased prefix has the same Character count as the original —
            // slice the ORIGINAL-case remainder by the marker's Character count to preserve the reply's casing.
            let remainderStart = normalized.index(normalized.startIndex, offsetBy: marker.count)
            let remainder = normalized[remainderStart...].trimmingCharacters(in: separators)
            return remainder.isEmpty ? .awaitingReply : .reply(remainder)
        }
        return .question
    }

    /// Leading punctuation/whitespace stripped between a marker and its dictated reply (e.g. "reply:  ship it").
    private static let separators = CharacterSet(charactersIn: " ,:.-—").union(.whitespacesAndNewlines)
}
