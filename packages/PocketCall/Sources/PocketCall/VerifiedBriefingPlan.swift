import Foundation
import PocketContracts

/// Trust-boundary wrapper for a briefing that is safe to present beside one exact, signature-verified bundle.
///
/// `BriefingPlan` is deliberately a transport-neutral value type, so decoding one does not make it grounded. This
/// wrapper has no public initializer: callers can mint it only by proving that the plan is bounded, structurally
/// usable, checkpoint-bound, and cites evidence contained by the exact `VerifiedBundle` already admitted by the
/// phone. A future durable cache can therefore accept this wrapper instead of persisting an unchecked plan.
public struct VerifiedBriefingPlan: Equatable, Sendable {
    /// The exact signature-verified authority against which `plan` was admitted. Keeping it inseparable prevents a
    /// caller (or future cache adapter) from pairing a plan verified for principal/session/checkpoint A with bundle B.
    public let bundle: VerifiedBundle
    public let plan: BriefingPlan

    private init(bundle: VerifiedBundle, plan: BriefingPlan) {
        self.bundle = bundle
        self.plan = plan
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.bundle == rhs.bundle,
              OpaqueUTF8Identity.matches(lhs.plan.checkpointId, rhs.plan.checkpointId),
              lhs.plan.segments.count == rhs.plan.segments.count else { return false }
        return zip(lhs.plan.segments, rhs.plan.segments).allSatisfy { pair in
            let (left, right) = pair
            guard OpaqueUTF8Identity.matches(left.id, right.id),
                  OpaqueUTF8Identity.matches(left.text, right.text),
                  left.tone == right.tone,
                  OpaqueUTF8Identity.matches(left.taggedText, right.taggedText),
                  left.evidenceIds.count == right.evidenceIds.count else { return false }
            return zip(left.evidenceIds, right.evidenceIds).allSatisfy { evidencePair in
                OpaqueUTF8Identity.matches(evidencePair.0, evidencePair.1)
            }
        }
    }

    /// Admit a plan only when every visible segment is grounded in `verifiedBundle`.
    public static func verify(_ plan: BriefingPlan, against verifiedBundle: VerifiedBundle) -> VerifiedBriefingPlan? {
        let bundle = verifiedBundle.bundle
        guard byteExact(plan.checkpointId, bundle.checkpointId),
              isWellFormedIdentity(plan.checkpointId, maxBytes: PocketBundle.capId),
              !plan.segments.isEmpty,
              plan.segments.count <= PocketBundle.capEvidence else { return nil }

        let allowedEvidenceIds = Set(bundle.evidence.map { identityKey($0.id) })
        guard !allowedEvidenceIds.isEmpty else { return nil }

        var segmentIds = Set<[UInt8]>()
        var totalElements = plan.segments.count
        var totalBytes = plan.checkpointId.utf8.count

        for segment in plan.segments {
            guard isWellFormedIdentity(segment.id, maxBytes: PocketBundle.capEvId),
                  segmentIds.insert(identityKey(segment.id)).inserted,
                  hasVisibleText(segment.text, maxBytes: PocketBundle.capSummary),
                  segment.taggedText.map({ hasVisibleText($0, maxBytes: PocketBundle.capSummary) }) ?? true,
                  taggedTextMatchesPlain(segment.taggedText, plain: segment.text),
                  !segment.evidenceIds.isEmpty,
                  segment.evidenceIds.count <= PocketBundle.capEvidence else { return nil }

            var citedIds = Set<[UInt8]>()
            for evidenceId in segment.evidenceIds {
                guard isWellFormedIdentity(evidenceId, maxBytes: PocketBundle.capEvId) else { return nil }
                let evidenceKey = identityKey(evidenceId)
                guard citedIds.insert(evidenceKey).inserted,
                      allowedEvidenceIds.contains(evidenceKey) else { return nil }
            }

            guard consume(segment.evidenceIds.count, into: &totalElements, limit: PocketBundle.maxTotalElements),
                  consume(segment.id.utf8.count, into: &totalBytes, limit: PocketBundle.maxTotalBytes),
                  consume(segment.text.utf8.count, into: &totalBytes, limit: PocketBundle.maxTotalBytes),
                  consume(segment.taggedText?.utf8.count ?? 0, into: &totalBytes, limit: PocketBundle.maxTotalBytes) else {
                return nil
            }
            for evidenceId in segment.evidenceIds {
                guard consume(evidenceId.utf8.count, into: &totalBytes, limit: PocketBundle.maxTotalBytes) else {
                    return nil
                }
            }
        }

        return VerifiedBriefingPlan(bundle: verifiedBundle, plan: plan)
    }

    private static func isWellFormedIdentity(_ value: String, maxBytes: Int) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maxBytes else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && byteExact(trimmed, value)
    }

    private static func hasVisibleText(_ value: String, maxBytes: Int) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maxBytes else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The gateway authors one source string, then strips its bounded lowercase audio tags to produce `text`.
    /// Repeating that deterministic transform prevents display/cache text from diverging from future premium TTS.
    private static func taggedTextMatchesPlain(_ taggedText: String?, plain: String) -> Bool {
        guard let taggedText else { return true }
        let stripped = taggedText.replacingOccurrences(
            of: #"\[[a-z][a-z0-9 _-]{0,24}\]"#,
            with: " ",
            options: .regularExpression
        )
        return normalizedWhitespace(stripped) == normalizedWhitespace(plain)
    }

    private static func normalizedWhitespace(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Swift `String` equality is Unicode-canonical. Signed checkpoint/evidence identifiers are opaque UTF-8, so
    /// both equality and hashed membership must operate on their original bytes.
    private static func identityKey(_ value: String) -> [UInt8] {
        Array(value.utf8)
    }

    private static func byteExact(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    /// Adds against a small frozen budget without risking `Int` overflow on hostile decoded input.
    private static func consume(_ amount: Int, into total: inout Int, limit: Int) -> Bool {
        guard amount >= 0, total <= limit, amount <= limit - total else { return false }
        total += amount
        return true
    }
}
