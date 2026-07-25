// DialPayloadV1 — the Pocket-RECEIVE decoder for the ring-owner APNs push (relay's #77 dialPayloadV1 wire).
// The bounded (<=5120 PushKit / 4864-byte budget) DTO the gateway pushes when Carter is needed. This is my lane:
// the phone decodes it, and — CRITICALLY — HONORS THE fetch FLAG before rendering.
//
// DECODE INVARIANT (relay spec v0.6, #318840 — load-bearing, warden-gate-worthy):
//   fetch == false  → RICH: the push is COMPLETE + renderable as-is. message present; options present+non-empty iff
//                     kind == .pickOption. Render directly.
//   fetch == true   → LEAN: the gateway SHED the governed content to fit the PushKit budget. The push is CORE-ONLY
//                     (no message/options/evidenceSeqs). The app MUST hydrate the full NeedCarterSignal via the
//                     AUTHENTICATED GET /dial?id= (#78 dial-signal-store) BEFORE rendering evidence/options — NEVER
//                     render push-delivered governed content pre-auth (a push is unauthenticated transport).
//
// Byte-parity target: services/pocket-gateway/test/fixtures/dial-payload-v1.json (6 cases post-#93 doorbell:
// writekind_decision_lean / writekind_pickOption_lean / rich_info / lean_overflow / worst_byte / max_core) — the
// SAME physical fixture relay's Node producer test locks. DialPayloadV1KAVTests reads it via a #filePath repo-root
// walk (zero copy) and asserts each `payload` decodes to the right DialReceiveState, so the two sides can't drift.

import Foundation

/// The APNs push DTO (relay's buildDialPayload v1 output). Optionals are the governed fields the LEAN path sheds.
struct DialPayloadV1: Decodable, Equatable, Sendable {
    let v: Int
    let id: String
    let kind: String            // "go"|"decisionYours"|"pickOption"|"info"|"checkpointReady" (Swift Codable case names)
    let priority: String        // "high"|"medium"
    let callerName: String
    let who: String             // always "senti-pocket" (the ring source; NOT the requesting agent — that's requestedBy, hydrated)
    let sessionId: String
    let checkpointId: String?
    let fetch: Bool             // true ⇒ LEAN/core-only ⇒ MUST hydrate before rendering governed content
    let ts: String              // ISO-8601 with millis + Z
    // governed content — present ONLY on the RICH (fetch == false) path:
    let message: String?
    let options: [String]?
    let evidenceSeqs: [Int]?
    let confidence: Double?
}

/// What the receive layer produces after applying the fetch invariant. The coordinator/CallKit ring reads this.
enum DialReceiveState: Equatable, Sendable {
    /// RICH push (fetch == false): renderable now. Carries the display essentials straight from the push.
    case renderable(RenderableRing)
    /// LEAN push (fetch == true): show the ring with ONLY the core (kind/caller/priority), then hydrate via
    /// authenticated GET /dial?id= before showing message/options/evidence. `id` is the hydration key.
    case needsHydration(id: String, core: RingCore)
    /// The push failed the contract (wrong version, missing core, or a RICH push missing its required governed
    /// fields) → do NOT ring on malformed transport; surface for logging, never fabricate content.
    case rejected(reason: String)
}

/// The always-present core (safe to show pre-hydration — no governed content).
struct RingCore: Equatable, Sendable {
    let id: String
    let kind: String
    let priority: String
    let callerName: String
    let sessionId: String
    let checkpointId: String?
}

/// A fully renderable ring (RICH path, or a LEAN push after hydration merges the governed fields back in).
struct RenderableRing: Equatable, Sendable {
    let core: RingCore
    let message: String
    let options: [String]      // non-empty iff kind == "pickOption"
    let evidenceSeqs: [Int]
    let confidence: Double?
}

enum DialReceive {
    static let currentVersion = 1

    /// Decode + apply the fetch invariant. Never renders governed content that arrived on a LEAN push (returns
    /// `.needsHydration` instead), and never treats a malformed push as a valid ring.
    static func receive(_ data: Data) -> DialReceiveState {
        let payload: DialPayloadV1
        do { payload = try JSONDecoder().decode(DialPayloadV1.self, from: data) }
        catch { return .rejected(reason: "undecodable dial payload: \(error)") }

        guard payload.v == currentVersion else {
            return .rejected(reason: "unsupported dial payload version \(payload.v) (expected \(currentVersion))")
        }
        guard !payload.id.isEmpty, !payload.kind.isEmpty, !payload.sessionId.isEmpty else {
            return .rejected(reason: "dial payload missing required core (id/kind/sessionId)")
        }

        let core = RingCore(id: payload.id, kind: payload.kind, priority: payload.priority,
                            callerName: payload.callerName, sessionId: payload.sessionId,
                            checkpointId: payload.checkpointId)

        // LEAN: the governed content was shed to fit the budget → hydrate over authenticated GET before rendering it.
        // Even if a LEAN push somehow carried a stray message field, we do NOT render it pre-auth (unauthenticated transport).
        if payload.fetch {
            return .needsHydration(id: payload.id, core: core)
        }

        // RICH: must be complete. A RICH push missing its required governed fields is a contract violation — reject
        // (never fabricate a message). pickOption requires non-empty options.
        guard let message = payload.message, !message.isEmpty else {
            return .rejected(reason: "RICH dial payload (fetch=false) missing required message")
        }
        let options = payload.options ?? []
        if payload.kind == "pickOption" && options.isEmpty {
            return .rejected(reason: "RICH pickOption payload missing non-empty options")
        }
        return .renderable(RenderableRing(
            core: core, message: message, options: options,
            evidenceSeqs: payload.evidenceSeqs ?? [], confidence: payload.confidence
        ))
    }
}
