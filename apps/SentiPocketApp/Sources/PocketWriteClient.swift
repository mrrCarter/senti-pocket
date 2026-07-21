// PocketWriteClient — the app-shell GOVERNED WRITE flow (the milestone: Carter's phone writes into a live Senti
// session as human-mrrcarter). Composes a humanMessage ActionProposal, and once the human REALLY confirms, POSTs
// {proposal, confirmation} to the live-demo gateway's /actions/execute with the USER's Bearer session token; the
// gateway authors via /human-message, mints a signed ActionReceipt, and read-back-verifies it landed under the
// human identity. Pairs with relay's actions.mjs humanMessage mode + my hash mirror (PocketContracts @9842cef).
//
// ⚠ WIRE-DATE CONTRACT (careful-wire, byte-exact hashing): the gateway recomputes proposalHash from the posted
// fields and must get the SAME createdAt the Swift hash used. Swift's canonicalPayload binds
// `safeEpochMillis(createdAt)` (epoch-MILLIS). So this client encodes ALL dates as epoch-millis INTEGERS via the
// SAME `ActionReceipt.safeEpochMillis` — the gateway's `new Date(ms).getTime()` then equals the Swift hash's millis
// exactly, regardless of sub-millisecond Date precision. (The signed BUNDLE uses whole-second ISO-8601; a proposal
// made at Date() is sub-second, so ISO-no-fractional would truncate and break the hash — epoch-millis avoids that.)

import Foundation
import PocketContracts

/// The explicit human confirmation the gateway binds against (actions.mjs L430-433): proposalId + the EXACT hash the
/// human confirmed + when. `confirmedProposalHash` MUST equal the proposal's live hash or the gateway fails-closed.
/// Codable so a confirmed-but-offline intent can be persisted in the durable outbox for retry-after-reconnect.
struct GovernedWriteConfirmation: Codable, Sendable, Equatable {
    let proposalId: String
    let confirmedProposalHash: String
    let confirmedAt: Date
}

private struct ExecuteRequest: Encodable {
    let proposal: ActionProposal
    let confirmation: GovernedWriteConfirmation
}

enum PocketWriteError: LocalizedError, Equatable {
    case notLoggedIn
    case network(String)
    case retryable(String)       // TRANSIENT gateway response (409 in-progress / 5xx / 503 checkpoint-not-available) — queue + retry
    case rejected(String)        // TERMINAL 4xx (proposal_rejected / hash mismatch / not a known session / auth) — won't succeed on retry
    case malformedResponse
    case notPosted(String)       // a receipt came back but not a verified .posted (pending/failed) — NEVER render as sent
    var errorDescription: String? {
        switch self {
        case .notLoggedIn:       return "Sign in first — the write needs your Senti session."
        case .network(let m):    return "Write network error: \(m)"
        case .retryable(let m):  return "The gateway is busy — will retry: \(m)"
        case .rejected(let m):   return "The gateway rejected the write: \(m)"
        case .malformedResponse: return "The gateway returned an unexpected response."
        case .notPosted(let m):  return "Not sent: \(m)"
        }
    }
}

@MainActor
final class PocketWriteClient {
    private let apiBaseURL: URL
    private let urlSession: URLSession

    init(apiBaseURL: URL, urlSession: URLSession = .shared) {
        self.apiBaseURL = apiBaseURL
        self.urlSession = urlSession
    }

    /// Compose the humanMessage proposal for a top-level say. targetSequence is the SENTINEL 0 (mirrored + enforced
    /// on both sides). The producer init computes proposalHash from these fields; the gateway recomputes + binds it.
    static func makeHumanMessageProposal(sessionId: String, message: String, at now: Date = Date()) -> ActionProposal {
        ActionProposal(
            id: UUID().uuidString,
            kind: .humanMessage,
            targetSessionId: sessionId,
            targetSequence: 0,                 // top-level say sentinel — canonicalPayload binds lp("0")="1:0"
            renderedPreview: message,
            createdAt: now,
            sourceQuestionId: nil
        )
    }

    /// POST the CONFIRMED write. Returns the signed ActionReceipt ONLY when it is a verified `.posted`; otherwise
    /// throws (never lets a pending/failed receipt read as sent). The caller still verifies the signature against the
    /// gateway public key before rendering "sent — appeared in the room as you".
    func execute(proposal: ActionProposal, confirmation: GovernedWriteConfirmation) async throws -> ActionReceipt {
        guard let token = SessionTokenStore.load(), !token.isEmpty else { throw PocketWriteError.notLoggedIn }
        guard let url = URL(string: "/actions/execute", relativeTo: apiBaseURL) else {
            throw PocketWriteError.network("bad execute url")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")  // the USER's session token = human-<you>
        req.httpBody = try Self.encoder.encode(ExecuteRequest(proposal: proposal, confirmation: confirmation))

        let (data, response): (Data, URLResponse)
        do { (data, response) = try await urlSession.data(for: req) }
        catch { throw PocketWriteError.network(error.localizedDescription) }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // The gateway returns a typed error envelope (e.g. {error, reason, retryable}). Decode a tolerant subset —
            // NOT [String:String] (that fails when `retryable` is a bool, silently dropping the reason).
            struct ErrorEnvelope: Decodable { let error: String?; let reason: String? }
            let env = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
            let reason = env?.reason ?? env?.error ?? "HTTP \(http.statusCode)"
            // 409 (execution-in-progress / reconcile) + any 5xx (transient / 503 checkpoint-not-available, retryable)
            // → RETRYABLE (queue + retry, never terminal-refuse a write that could still land). Other 4xx → terminal.
            if http.statusCode == 409 || (500..<600).contains(http.statusCode) {
                throw PocketWriteError.retryable(reason)
            }
            throw PocketWriteError.rejected(reason)
        }

        let receipt: ActionReceipt
        do { receipt = try Self.decoder.decode(ActionReceipt.self, from: data) }
        catch { throw PocketWriteError.malformedResponse }

        // Honesty gate (mirrors the bundle discipline): only a structurally-valid .posted may be treated as sent.
        // A .pendingConnectivity or .failed receipt is NEVER "sent". Signature verification (SignatureState) is the
        // caller's final step with the gateway public key — this client refuses to hand back a non-posted as success.
        guard receipt.status == .posted, receipt.isStructurallyValid() else {
            throw PocketWriteError.notPosted(receipt.failureReason ?? "receipt is not a verified posted state")
        }
        return receipt
    }

    // MARK: - epoch-millis JSON (byte-exact with the gateway's `new Date(ms)` + the Swift hash's safeEpochMillis)

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            // The SAME millis the proposalHash binds — so the gateway's recompute matches byte-for-byte.
            guard let ms = ActionReceipt.safeEpochMillis(date) else {
                throw EncodingError.invalidValue(date, .init(codingPath: enc.codingPath,
                    debugDescription: "date out of range for epoch-millis encoding"))
            }
            try c.encode(ms)
        }
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        // ASYMMETRIC-but-source-correct: the proposal leg SENDS epoch-millis (gateway validateProposal L118 accepts a
        // NUMBER createdAt), but the RECEIPT leg comes back with ISO-8601-WITH-milliseconds dates — the gateway's
        // normalizeSaneDate → `new Date(ms).toISOString()` always emits fractional seconds. So decode ISO-with-fraction
        // first (preserving the millis the signature covers), with an epoch-millis fallback for robustness.
        let isoFrac = ISO8601DateFormatter(); isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoWhole = ISO8601DateFormatter(); isoWhole.formatOptions = [.withInternetDateTime]
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            if let s = try? c.decode(String.self) {
                if let dt = isoFrac.date(from: s) { return dt }
                if let dt = isoWhole.date(from: s) { return dt }
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "unparseable receipt date: \(s)")
            }
            let ms = try c.decode(Int64.self)   // fallback: epoch-millis integer
            return Date(timeIntervalSince1970: Double(ms) / 1000.0)
        }
        return d
    }()
}
