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
}

enum OutboxStore {
    private static var fileURL: URL? {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        return dir.appendingPathComponent("senti-pocket-outbox.json")
    }

    static func save(_ intent: PersistedWriteIntent) {
        guard let url = fileURL, let data = try? encoder.encode(intent) else { return }
        // Protected until first unlock (survives relaunch, never leaves the device); best-effort — an outbox write
        // failing must not crash the send path (the in-memory retry still works this session).
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func load() -> PersistedWriteIntent? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(PersistedWriteIntent.self, from: data)
    }

    static func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

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
