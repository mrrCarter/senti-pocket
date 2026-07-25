import Foundation

// Atlas-owned NONVISUAL session types (V4 §85 ownership, reconciled per #239876):
//   Relay = wire DTOs + SessionTransport/SessionRepository.
//   Pulse = ALL view-models, fallbacks, copy, badges, and the factory off the repository snapshot.
//   Atlas = the bare shell + these two nonvisual types. **THIS LAYER DEFINES NO PRESENTATION TYPES.**
//
// Neither type formats, truncates, falls back, or produces display strings — that is Pulse's factory/view-models.
// Both are LOSSLESS (they never discard a wire value) and DECODE-ONLY (no fetch — live data arrives via Relay's
// gated Repository). The prior SessionRow/CheckpointContent projection is removed: SessionRow was a presentation
// view-model (Pulse's), and CheckpointContent was lossful + used a hardcoded-false bool.

/// A wire timestamp with its RAW String preserved (lossless) plus a best-effort tolerant-ISO8601 parse.
///
/// Nonvisual/data-only: it does NOT format or localize (that is Pulse's). The raw value is the authority and is never
/// discarded, so a parse miss — or a future server format this build doesn't recognize — still round-trips the exact
/// wire bytes. `date` is a convenience only; consumers that need fidelity use `raw`.
public struct ParsedSessionTimestamp: Equatable, Sendable {
    /// The exact wire string — never discarded (the lossless guarantee).
    public let raw: String
    /// Best-effort parse; `nil` when unrecognized. `raw` remains authoritative regardless.
    public let date: Date?

    public init(_ raw: String) {
        self.raw = raw
        self.date = ParsedSessionTimestamp.parse(raw)
    }
    /// Convenience for optional wire fields (e.g. `SessionSummary.lastActivityAt`): nil in ⇒ nil out.
    public init?(_ raw: String?) {
        guard let raw else { return nil }
        self.init(raw)
    }

    /// Tolerant ISO-8601: fractional seconds OR plain, UTC offset or `Z`. Pure; no shared mutable state.
    static func parse(_ s: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }
}

/// A session checkpoint wrapped to make the TRUST BOUNDARY explicit at the type level.
///
/// LOSSLESS: it carries the FULL `SessionCheckpointDTO`, dropping nothing. NONVISUAL: no display strings, badges, or
/// fallbacks (Pulse's factory formats `checkpoint.title`/`summary`/`grade` for the UI).
///
/// TRUST GUARANTEE (structural, not a flag): a `MembershipAuthorizedCheckpoint` is a DIFFERENT TYPE from a
/// `VerifiedBundle`, and there is NO API here that yields verification. A room checkpoint is membership-authorized
/// CONTENT — it renders NEUTRAL, never GREEN. GREEN (cryptographically verified) belongs EXCLUSIVELY to a
/// `VerifiedBundle` (the separately-signed Pocket briefing, in PocketCall), which this type never imports, produces,
/// or imitates. The absence of any verified affordance IS the boundary — no hardcoded-false bool.
public struct MembershipAuthorizedCheckpoint: Identifiable, Equatable, Sendable {
    /// The full wire DTO — lossless.
    public let checkpoint: SessionCheckpointDTO

    public var id: String { checkpoint.checkpointId }
    /// The checkpoint's created-at, raw-preserved. Data-only; Pulse formats it for display.
    public var createdAt: ParsedSessionTimestamp { ParsedSessionTimestamp(checkpoint.createdAt) }

    public init(_ checkpoint: SessionCheckpointDTO) { self.checkpoint = checkpoint }
}
