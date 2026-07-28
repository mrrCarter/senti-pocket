// OutboxStore — DURABLE offline write outbox (closes the B2 gap: the pending intent was in-memory only, so an
// offline write was LOST if the app was killed before reconnect). Persists the ONE pending {proposal, confirmation}
// to Application Support and reloads it on launch, so a governed write dictated + confirmed offline survives a kill
// and retries after reconnect. It stores an ALREADY-CONFIRMED intent only — the human already tapped Send; a retry
// resends the identical confirmed bytes (the gateway is idempotent by proposal id), so no re-consent is needed.
//
// DURABLE OWNERSHIP (Pulse review): `save` returns whether we now DURABLY own the single slot — it SERIALIZES a second
// owner (a different confirmed write already owning the slot → refuse) AND requires a successful, verifiable persist
// (a failed write returns false, never false ownership). Callers MUST NOT send a governed write unless save()==true.
//
// Dates are epoch-millis (via safeEpochMillis) so the persisted proposal round-trips MILLISECOND-exact — the
// proposalHash stays valid when the gateway recomputes it on resend (same discipline as PocketWriteClient's wire).

import Foundation
import PocketContracts

/// A confirmed-but-unsent write, persisted for retry-after-reconnect.
struct PersistedWriteIntent: Codable, Sendable, Equatable {
    let proposal: ActionProposal
    let confirmation: GovernedWriteConfirmation
}

/// The raw-bytes storage behind OutboxStore — injectable so the durable-ownership contract (a save that FAILS to
/// persist must not claim ownership) is testable without the real filesystem. Default = Application Support file.
protocol OutboxStorage: AnyObject {
    func write(_ data: Data) -> Bool   // true IFF the bytes are durably persisted
    func read() -> Data?
    func remove()
}

/// Production storage: an atomic, protected-until-first-unlock file in Application Support.
final class FileOutboxStorage: OutboxStorage {
    private var fileURL: URL? {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        return dir.appendingPathComponent("senti-pocket-outbox.json")
    }
    func write(_ data: Data) -> Bool {
        guard let url = fileURL else { return false }
        // Protected until first unlock (survives relaunch, never leaves the device). A FAILED write returns false —
        // the caller must NOT claim durable ownership (so it must not send a write it can't crash-recover).
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            return false
        }
    }
    func read() -> Data? {
        guard let url = fileURL else { return nil }
        return try? Data(contentsOf: url)
    }
    func remove() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

enum OutboxStore {
    /// Injectable storage (default: durable Application Support file). Tests swap a double (in-memory / failing).
    static var storage: OutboxStorage = FileOutboxStorage()

    /// Persist the ONE confirmed intent; return whether we now DURABLY own the single slot. SERIALIZES a second owner
    /// (a DIFFERENT confirmed intent already owns the slot → refuse, never clobber) AND requires a successful,
    /// verifiable persist (encode + write + read-back-as-ours). A failed persist returns false — NO false ownership.
    /// Re-saving the SAME proposal id (idempotent) is allowed. Callers MUST NOT send a write unless this returns true.
    @discardableResult
    static func save(_ intent: PersistedWriteIntent) -> Bool {
        if let existing = load(), existing.proposal.id != intent.proposal.id { return false }  // a different write owns it
        guard let data = try? encoder.encode(intent), storage.write(data) else { return false }  // encode/persist failed
        return load()?.proposal.id == intent.proposal.id  // verify durability — it must read back as OURS
    }

    static func load() -> PersistedWriteIntent? {
        guard let data = storage.read() else { return nil }
        return try? decoder.decode(PersistedWriteIntent.self, from: data)
    }

    /// Clear STRICTLY by matching proposal id: a no-op when the slot holds a DIFFERENT proposal, so a dial hangup
    /// cleaning up its OWN draft can never wipe an unrelated confirmed pending write that owns the global slot.
    static func clear(proposalId: String) {
        guard let existing = load(), existing.proposal.id == proposalId else { return }
        storage.remove()
    }

    /// Unconditional clear — a full reset (test setup/teardown, an explicit "discard everything"). The write path
    /// should prefer clear(proposalId:) so it can never erase a foreign owner.
    static func clear() { storage.remove() }

    // Epoch-millis dates (ms-exact) so the persisted proposal's createdAt/confirmedAt round-trip identically to the
    // hash + the wire — a reloaded proposal recomputes to the SAME proposalHash on the gateway.
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
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
