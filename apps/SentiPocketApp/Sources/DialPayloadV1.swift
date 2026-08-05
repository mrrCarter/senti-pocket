// DialPayloadV1 — the Pocket-RECEIVE decoder for the ring-owner APNs push (relay's #77 dialPayloadV1 wire).
// The bounded (<=5120 PushKit / 4864-byte budget) DTO the gateway pushes when Carter is needed. This is my lane:
// the phone decodes it, and — CRITICALLY — HONORS THE fetch FLAG before rendering.
//
// DECODE INVARIANT (relay spec v0.6, #318840 — load-bearing, warden-gate-worthy):
//   fetch == false  → RICH only for the display kinds info/checkpointReady. A write kind
//                     (go/decisionYours/pickOption) with fetch=false is contradictory and MUST be rejected; the client
//                     mirrors the gateway's write-kind→LEAN policy instead of trusting its flag.
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
    // Registry V2 installation proof. All four are absent on the explicit V1 migration lane; once any is present the
    // complete tuple is required. The real PushKit composition rejects absent/mismatched proofs for this app version.
    let bindingVersion: Int?
    let bindingId: String?
    let bindingRevision: String?
    let installationGeneration: String?
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
    /// Display-only RICH push (fetch == false): renderable now. Write kinds can never reach this state.
    case renderable(RenderableRing)
    /// LEAN push (fetch == true): show the ring with ONLY the core (kind/caller/priority), then hydrate via
    /// authenticated GET /dial?id= before showing message/options/evidence. `id` is the hydration key.
    case needsHydration(id: String, core: RingCore)
    /// The push failed the contract (wrong/unknown kind, contradictory write-kind shape, missing core, or an
    /// incomplete RICH push) → do NOT retain actionable state; surface for logging, never fabricate content.
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
    let bindingVersion: Int?
    let bindingId: String?
    let bindingRevision: String?
    let installationGeneration: String?

    init(
        id: String,
        kind: String,
        priority: String,
        callerName: String,
        sessionId: String,
        checkpointId: String?,
        bindingVersion: Int? = nil,
        bindingId: String? = nil,
        bindingRevision: String? = nil,
        installationGeneration: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.priority = priority
        self.callerName = callerName
        self.sessionId = sessionId
        self.checkpointId = checkpointId
        self.bindingVersion = bindingVersion
        self.bindingId = bindingId
        self.bindingRevision = bindingRevision
        self.installationGeneration = installationGeneration
    }
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
    private static let knownKinds: Set<String> = ["go", "decisionYours", "pickOption", "info", "checkpointReady"]
    private static let writeKinds: Set<String> = ["go", "decisionYours", "pickOption"]

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
        guard knownKinds.contains(payload.kind) else {
            return .rejected(reason: "dial payload has unknown kind")
        }
        let proof = [
            payload.bindingVersion != nil,
            payload.bindingId != nil,
            payload.bindingRevision != nil,
            payload.installationGeneration != nil
        ]
        if proof.contains(true) {
            guard proof.allSatisfy({ $0 }),
                  payload.bindingVersion == DeviceRingBinding.registryVersion,
                  let bindingId = payload.bindingId, !bindingId.isEmpty,
                  let bindingRevision = payload.bindingRevision, !bindingRevision.isEmpty,
                  let generation = payload.installationGeneration,
                  !generation.isEmpty,
                  generation.first != "0",
                  generation.allSatisfy(\.isNumber),
                  UInt64(generation) != nil else {
                return .rejected(reason: "dial payload has an incomplete or invalid Registry V2 binding proof")
            }
        }

        let core = RingCore(id: payload.id, kind: payload.kind, priority: payload.priority,
                            callerName: payload.callerName, sessionId: payload.sessionId,
                            checkpointId: payload.checkpointId,
                            bindingVersion: payload.bindingVersion,
                            bindingId: payload.bindingId,
                            bindingRevision: payload.bindingRevision,
                            installationGeneration: payload.installationGeneration)

        // A write-kind is always an authenticated doorbell. Reject a contradictory RICH shape instead of coercing it:
        // there is no legitimate producer for that shape, and rejection prevents raw push metadata from surviving into
        // the transient CallKit model before hydration.
        if writeKinds.contains(payload.kind), !payload.fetch {
            return .rejected(reason: "write-kind dial payload requires fetch=true")
        }

        // LEAN: the governed content was shed to fit the budget → hydrate over authenticated GET before rendering it.
        // Even if a LEAN push somehow carried a stray message field, we do NOT render it pre-auth (unauthenticated transport).
        if payload.fetch {
            return .needsHydration(id: payload.id, core: core)
        }

        // RICH: only info/checkpointReady can reach here. It must be complete, and display kinds may not smuggle a
        // write-kind options vector into spoken content.
        guard let message = payload.message, !message.isEmpty else {
            return .rejected(reason: "RICH dial payload (fetch=false) missing required message")
        }
        if let options = payload.options, !options.isEmpty {
            return .rejected(reason: "display-only RICH dial payload must not carry options")
        }
        return .renderable(RenderableRing(
            core: core, message: message, options: [],
            evidenceSeqs: payload.evidenceSeqs ?? [], confidence: payload.confidence
        ))
    }
}
