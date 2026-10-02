// OutboxStore — DURABLE offline write outbox (closes the B2 gap: the pending intent was in-memory only, so an
// offline write was LOST if the app was killed before reconnect). Persists the ONE pending {proposal, confirmation}
// to Application Support and reloads it on launch, so a governed write dictated + confirmed offline survives a kill
// and retries after reconnect. It stores an ALREADY-CONFIRMED intent only — the human already tapped Send; a retry
// resends the identical confirmed bytes (the gateway is idempotent by proposal id), so no re-consent is needed.
//
// Dates are epoch-millis (via safeEpochMillis) so the persisted proposal round-trips MILLISECOND-exact — the
// proposalHash stays valid when the gateway recomputes it on resend (same discipline as PocketWriteClient's wire).

import Foundation
import PocketContracts

/// A confirmed-but-unsent write, persisted for retry-after-reconnect.
struct PersistedWriteIntent: Codable, Sendable, Equatable {
    let proposal: ActionProposal
    let confirmation: GovernedWriteConfirmation

    enum SelectionBinding: Equatable {
        case matching
        case foreignSession(String)
        case invalid
    }

    /// A decoded file is not trusted merely because it came from Application Support. Re-verify the complete
    /// proposal hash/shape and the explicit confirmation binding before any selected session may expose a retry.
    func binding(to selectedSessionId: String) -> SelectionBinding {
        guard proposal.kind == .humanMessage,
              proposal.isValidForConfirmation(),
              confirmation.proposalId == proposal.id,
              confirmation.confirmedProposalHash == proposal.proposalHash,
              ActionReceipt.safeEpochMillis(confirmation.confirmedAt) != nil else {
            return .invalid
        }
        guard proposal.targetSessionId == selectedSessionId else {
            return .foreignSession(proposal.targetSessionId)
        }
        return .matching
    }
}

enum OutboxStore {
    enum ClaimResult: Equatable {
        case claimed
        case occupied(targetSessionId: String)
        case storageUnavailable
    }

    private static let lock = NSLock()

    private static var fileURL: URL? {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        return dir.appendingPathComponent("senti-pocket-outbox.json")
    }

    static func save(_ intent: PersistedWriteIntent) {
        lock.lock()
        defer { lock.unlock() }
        _ = saveUnlocked(intent)
    }

    /// Compare-and-set the one durable slot. A second live composition may not overwrite a different confirmed
    /// proposal, even if it was created before the first proposal reached disk.
    static func claim(_ intent: PersistedWriteIntent) -> ClaimResult {
        lock.lock()
        defer { lock.unlock() }
        if let existing = loadUnlocked() {
            guard durablyMatches(existing, intent) else {
                return .occupied(targetSessionId: existing.proposal.targetSessionId)
            }
            return .claimed
        }
        return saveUnlocked(intent) ? .claimed : .storageUnavailable
    }

    private static func saveUnlocked(_ intent: PersistedWriteIntent) -> Bool {
        guard let url = fileURL, let data = try? encoder.encode(intent) else { return false }
        // Protected until first unlock (survives relaunch, never leaves the device); best-effort — an outbox write
        // failing must not crash the send path (the in-memory retry still works this session).
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            return false
        }
    }

    static func load() -> PersistedWriteIntent? {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked()
    }

    private static func loadUnlocked() -> PersistedWriteIntent? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(PersistedWriteIntent.self, from: data)
    }

    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        clearUnlocked()
    }

    /// A late response from proposal A must never delete a newer proposal B that now owns the global slot.
    static func clear(matching intent: PersistedWriteIntent) {
        lock.lock()
        defer { lock.unlock() }
        guard let existing = loadUnlocked(), durablyMatches(existing, intent) else { return }
        clearUnlocked()
    }

    /// Disk dates are deliberately normalized to epoch milliseconds. Compare the same canonical bytes used for
    /// persistence, not synthesized Date equality, so a live sub-millisecond intent owns its own round-tripped slot.
    private static func durablyMatches(_ lhs: PersistedWriteIntent, _ rhs: PersistedWriteIntent) -> Bool {
        guard let left = try? encoder.encode(lhs),
              let right = try? encoder.encode(rhs) else { return false }
        return left == right
    }

    private static func clearUnlocked() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // Epoch-millis dates (ms-exact) so the persisted proposal's createdAt/confirmedAt round-trip identically to the
    // hash + the wire — a reloaded proposal recomputes to the SAME proposalHash on the gateway.
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            guard let ms = ActionReceipt.safeEpochMillis(date) else {
                throw EncodingError.invalidValue(date, .init(codingPath: enc.codingPath, debugDescription: "date out of range"))
            }
            try c.encode(ms)
        }
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let ms = try c.decode(Int64.self)
            return Date(timeIntervalSince1970: Double(ms) / 1000.0)
        }
        return d
    }()
}
