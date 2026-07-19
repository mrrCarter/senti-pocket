import Foundation

// Atlas-owned THIN TYPED PROJECTION over the Relay-owned SessionWire DTOs (warden step 1, #239244).
//
// It does three things and nothing more:
//   1. Parses the wire's RAW-String timestamps into `Date` (the wire keeps them as String by design; parsing is
//      the projection's job — a fractional-second or offset variance must never break a screen).
//   2. Applies stable DISPLAY fallbacks (a room with a nil title still shows something deterministic).
//   3. Makes the TRUST BOUNDARY type-explicit — the load-bearing part.
//
// TRUST BOUNDARY (warden source-verified #239214): a session checkpoint is membership-authorized CONTENT, NOT
// verify-gated. `CheckpointContent.isCryptographicallyVerified` is ALWAYS `false` by construction and there is no
// API here that yields a "verified" value. The GREEN verified affordance belongs EXCLUSIVELY to a `VerifiedBundle`
// (the separately-signed Pocket briefing, in PocketCall) — a UI must bind its verified chip to `VerifiedBundle`,
// never to any type in this file. No projection here imports, produces, or imitates `VerifiedBundle`.
//
// DECODE-ONLY: nothing here fetches. It projects already-decoded DTOs; live data arrives via Relay's step-2 gated,
// membership-authorized fetch — do not wire a live fetch onto this surface until that gate clears.

/// Tolerant ISO-8601 parsing for the wire's raw-String timestamps — fractional seconds OR plain, UTC offset or `Z`.
public enum SessionDate {
    public static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: raw) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

/// A view-ready row for the [Sessions] list, projected from a `SessionSummary` wire DTO. Pure data (no UI); the
/// designed screen is Pulse's. Applies a deterministic title fallback so a nil-title room still renders stably.
public struct SessionRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayTitle: String
    public let subtitle: String?
    public let lastActivity: Date?
    public let agentCount: Int
    public let eventCount: Int
    public let membershipRole: String

    public init(_ dto: SessionSummary) {
        id = dto.sessionId
        // title -> first 60 chars of summaryText -> "Session <short id>". Never empty.
        if let t = dto.title, !t.isEmpty {
            displayTitle = t
        } else if let s = dto.summaryText, !s.isEmpty {
            displayTitle = String(s.prefix(60))
        } else {
            displayTitle = "Session \(dto.sessionId.prefix(8))"
        }
        subtitle = dto.summaryText
        lastActivity = SessionDate.parse(dto.lastActivityAt)
        agentCount = dto.agentCount
        eventCount = dto.eventCount
        membershipRole = dto.membershipRole
    }
}

/// A view-ready projection of a session checkpoint — EXPLICITLY UNVERIFIED, membership-authorized content.
///
/// Carries NO verification state and offers NO route to a "verified" affordance. `title`/`summary`/`grade` are the
/// checkpoint author's own words and the server's grade — informational, NOT cryptographically attested here. A
/// screen rendering this MUST NOT show the GREEN verified chip; that is reserved for a `VerifiedBundle` (PocketCall),
/// which is fetched + verified SEPARATELY and keyed to a checkpoint, never derived from this content.
public struct CheckpointContent: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    public let grade: String
    public let gradeScore: Int
    public let created: Date?

    /// Always `false`, by construction — the type-level trust boundary. Session checkpoint content is never
    /// cryptographically verified at this layer; only a `VerifiedBundle` (signed Pocket briefing) is.
    public var isCryptographicallyVerified: Bool { false }

    public init(_ dto: SessionCheckpointDTO) {
        id = dto.checkpointId
        title = dto.title
        summary = dto.summary
        grade = dto.grade
        gradeScore = dto.gradeScore
        created = SessionDate.parse(dto.createdAt)
    }
}
