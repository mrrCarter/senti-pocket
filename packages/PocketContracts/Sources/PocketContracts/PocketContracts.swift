// PocketContracts v0.1.8 by Atlas (claude-pocket-atlas).
// v0.1.8 (Echo #231350 re-audit): canonical ActionProposal v2 -> v3 binds id + createdAt + sourceQuestionId
//   (was kind/session/sequence/preview ONLY) — two same-CONTENT proposals with different ids/times now get
//   DISTINCT hashes, killing the confirm-swap where a stale A intent confirmed a same-content displayed B.
//   proposalHash + KAV CHANGE (new HASH Wk4lhn...; sourceQuestionId presence-flagged so nil != "" per Pulse #231475).
//   isValidForConfirmation also rejects an out-of-range createdAt.
//   (Pairs with PocketCall's opaque single-use ConfirmationCapability + VerifiedBundle ingress.) Relay re-mirror.
// v0.1.7 (Relay/Echo/Pulse converged #231081-#231316): ActionReceipt.resultingSequence:Int -> `result:
//   ActionResultRef?` tagged union — a true threadedReply is an ACTION (actionId + target it threads under),
//   NOT a bare sequence; a say is a sequence. Explicit kind-discriminated Codable (Node-mirrorable). Receipt
//   canon v3->v4: `result` bound as a length-prefixed ActionResultRef.canonicalToken() — Relay re-mirror + new
//   KAVs (6:action.../8:sequence...). isStructurallyValid: .posted requires result!=nil. Pulse renders the
//   tagged result (no fake numeric sequence for a reply); Relay implements the gateway result on this.
// v0.1.6 (Echo 62e08e9 HOLD-A + tone): canonicalReceiptPayload -> v3 uses CHECKED epoch-MILLISECONDS
//   (safeEpochMillis) — never TRAPS on an extreme decoded Date (Int(hugeDouble) trap = crash/DoS) and binds
//   subsecond content; isStructurallyValid now rejects non-finite/out-of-range dates. Constrained BriefingTone
//   enum + optional BriefingSegment.tone (closed set end-to-end; non-breaking). Receipt canon v2->v3: Relay re-mirror.
//   (Relay owns the remaining gateway items B/C: require key before post; single-use pending->posted flush.)
// v0.1.5 (Echo 43b796b HOLD): canonicalReceiptPayload -> v2 binds EVERY field except `signature` (adds id,
//   confirmedByHumanAt, signingKeyId, failureReason) -> no field-substitution while ed25519 still verifies;
//   SignatureState now returns .invalid (not .unsigned) when a signature is PRESENT but the receipt is
//   structurally invalid (tamper signal). Receipt KAV + per-field tamper tests added. (Relay owns the
//   companion gateway fix: require a signing key BEFORE online execution, never post-then-unsigned.)
// v0.1.4 (Echo 84d463f HOLD): isValidForConfirmation now FAILS CLOSED without CryptoKit (was fail-open);
//   ActionReceipt gains isStructurallyValid() (.posted requires seq/executedAt/sig/key; pending forbids all) +
//   canonicalReceiptPayload() + first-class SignatureState via ed25519 verify (non-nil sig != verified); all
//   contract types are now Sendable; KAV test asserts the actual computeHash (base64url mNZp-a77...). ADDITIVE
//   except the fail-closed predicate + Sendable (both source-compatible).
// v0.1.3 (Echo 5f45364 + Pulse dea0776 reviews): INJECTION-PROOF length-prefixed canonicalPayload (was
//   delimiter-only = collision-vulnerable) -> domain sep bumped to v2, hashes CHANGE vs v0.1.2; deterministic
//   ActionProposal.isValidForConfirmation() (rejects requiresConfirmation=false / bad hash / unbounded fields);
//   ActionReceipt.signature + signingKeyId (gateway-signed .posted receipts, nil never renders as verified).
//   PocketFixtures adds typed UI scenarios (BriefingPlan/QuestionAnswer/ActionProposal/ActionReceipt) for Pulse.
// v0.1.2 (warden gate #230840): [1 REQUIRED] ActionProposal.proposalHash + ActionReceipt.confirmedProposalHash
//   = content-integrity binding for the governed write — confirm==execute at the Pulse<->Relay seam,
//   invalidate-on-change, single-use (TOCTOU-proof). [2] AgentSummary.claims (fact/inference/recommendation)
//   for grounded epistemic status. Both ADDITIVE (new fields); PocketBundle TOP-LEVEL shape unchanged, but
//   AgentSummary gains `claims` so the canonical fixture adds claims arrays (see Fixtures/canonical_checkpoint.json).
// v0.1.1 (Echo blocker @a9f5252): explicit public inits so external packages construct cross-module.
//
// Safety invariant (non-negotiable): the model may PRODUCE an ActionProposal, but deterministic code owns
// target resolution, authorization, confirmation, execution, and receipts — and proposalHash makes the core
// claim ("it cannot post what you didn't confirm") verifiable + testable across separate lanes.
// Any field change after freeze = bump version + threaded HANDOFF.
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public enum PocketContracts {
    public static let version = "0.1.8"
}

// MARK: - Source (Relay produces RawCheckpoint + CheckpointSummary; gateway summarizes)

public struct RawCheckpoint: Codable, Equatable, Sendable {
    public let checkpointId: String
    public let sessionId: String
    public let sessionTitle: String
    public let startSequence: Int
    public let endSequence: Int
    public let capturedAt: Date
    public let agents: [String]
    public let events: [RawEvent]
    public init(checkpointId: String, sessionId: String, sessionTitle: String, startSequence: Int, endSequence: Int, capturedAt: Date, agents: [String], events: [RawEvent]) {
        self.checkpointId = checkpointId; self.sessionId = sessionId; self.sessionTitle = sessionTitle
        self.startSequence = startSequence; self.endSequence = endSequence; self.capturedAt = capturedAt
        self.agents = agents; self.events = events
    }
}

public struct RawEvent: Codable, Equatable, Sendable {
    public let sequenceId: Int
    public let event: String
    public let agentId: String
    public let payload: String
    public let idempotencyToken: String?
    public let ts: Date
    public init(sequenceId: Int, event: String, agentId: String, payload: String, idempotencyToken: String?, ts: Date) {
        self.sequenceId = sequenceId; self.event = event; self.agentId = agentId
        self.payload = payload; self.idempotencyToken = idempotencyToken; self.ts = ts
    }
}

public struct CheckpointSummary: Codable, Equatable, Sendable {
    public let checkpointId: String
    public let headline: String
    public let summaryBaselineSchema: String
    public let grade: String?
    public let perAgent: [AgentSummary]
    public let risks: [String]
    public let blockers: [String]
    public init(checkpointId: String, headline: String, summaryBaselineSchema: String, grade: String?, perAgent: [AgentSummary], risks: [String], blockers: [String]) {
        self.checkpointId = checkpointId; self.headline = headline; self.summaryBaselineSchema = summaryBaselineSchema
        self.grade = grade; self.perAgent = perAgent; self.risks = risks; self.blockers = blockers
    }
}

public struct AgentSummary: Codable, Equatable, Sendable {
    public let agentId: String
    public let summary: String                  // free-text overview (per-agent; disagreement preserved, no false consensus)
    public let claims: [Claim]                  // v0.1.2: epistemic-status-tagged, evidence-cited claims (grounding wedge)
    public let evidence: [EvidenceRef]
    public init(agentId: String, summary: String, claims: [Claim], evidence: [EvidenceRef]) {
        self.agentId = agentId; self.summary = summary; self.claims = claims; self.evidence = evidence
    }
}

/// A single grounded claim with explicit epistemic status (baseline §2: distinguish fact/inference/recommendation),
/// so the grounding eval can grade honesty and the briefing can LABEL it aloud. Fact/inference MUST cite
/// EvidenceRef.ids; a recommendation may be uncited.
public struct Claim: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let text: String
    public let kind: ClaimKind
    public let evidenceIds: [String]
    public init(id: String, text: String, kind: ClaimKind, evidenceIds: [String]) {
        self.id = id; self.text = text; self.kind = kind; self.evidenceIds = evidenceIds
    }
}

public enum ClaimKind: String, Codable, Equatable, Sendable {
    case fact            // directly supported by cited evidence
    case inference       // reasoned from evidence (must still cite the basis)
    case recommendation  // suggested action/opinion (may be uncited)
}

// MARK: - Bundle (what the phone caches + briefs from)

public struct PocketBundle: Codable, Equatable, Sendable {
    public let contractsVersion: String
    public let checkpointId: String
    public let sessionId: String
    public let sequenceStart: Int
    public let sequenceEnd: Int
    public let summary: CheckpointSummary
    public let evidence: [EvidenceRef]
    public let createdAt: Date
    public let signature: String
    public let signingKeyId: String
    public init(contractsVersion: String, checkpointId: String, sessionId: String, sequenceStart: Int, sequenceEnd: Int, summary: CheckpointSummary, evidence: [EvidenceRef], createdAt: Date, signature: String, signingKeyId: String) {
        self.contractsVersion = contractsVersion; self.checkpointId = checkpointId; self.sessionId = sessionId
        self.sequenceStart = sequenceStart; self.sequenceEnd = sequenceEnd; self.summary = summary
        self.evidence = evidence; self.createdAt = createdAt; self.signature = signature; self.signingKeyId = signingKeyId
    }
}

public struct EvidenceRef: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let sessionId: String
    public let sequence: Int
    public let agentId: String
    public let snippet: String
    public let ts: Date
    public init(id: String, sessionId: String, sequence: Int, agentId: String, snippet: String, ts: Date) {
        self.id = id; self.sessionId = sessionId; self.sequence = sequence
        self.agentId = agentId; self.snippet = snippet; self.ts = ts
    }
}

// MARK: - Briefing + Q&A (Echo/Pulse consume; local, offline-capable)

public struct BriefingPlan: Codable, Equatable, Sendable {
    public let checkpointId: String
    public let segments: [BriefingSegment]
    public init(checkpointId: String, segments: [BriefingSegment]) {
        self.checkpointId = checkpointId; self.segments = segments
    }
}

public struct BriefingSegment: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let text: String
    public let evidenceIds: [String]
    public let tone: BriefingTone?              // v0.1.6 (Echo): CONSTRAINED narration tone (nil = neutral default)
    public init(id: String, text: String, evidenceIds: [String], tone: BriefingTone? = nil) {
        self.id = id; self.text = text; self.evidenceIds = evidenceIds; self.tone = tone
    }
}

/// Constrained narration tone (Echo 62e08e9): TTS/provider tone tags must be a CLOSED set end-to-end so the model
/// cannot emit a free-form voice/style string that reaches the synthesizer. Add cases here (never accept raw strings).
public enum BriefingTone: String, Codable, Equatable, Sendable {
    case neutral, urgent, calm, celebratory
}

public struct QuestionAnswer: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let checkpointId: String
    public let question: String
    public let answer: String
    public let citations: [String]
    public let answeredOffline: Bool
    public let createdAt: Date
    public init(id: String, checkpointId: String, question: String, answer: String, citations: [String], answeredOffline: Bool, createdAt: Date) {
        self.id = id; self.checkpointId = checkpointId; self.question = question; self.answer = answer
        self.citations = citations; self.answeredOffline = answeredOffline; self.createdAt = createdAt
    }
}

// MARK: - Governed write (SAFETY-CRITICAL)

public struct ActionProposal: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: ActionKind
    public let targetSessionId: String
    public let targetSequence: Int
    public let renderedPreview: String
    public let requiresConfirmation: Bool
    public let createdAt: Date
    public let sourceQuestionId: String?
    /// v0.1.2: deterministic digest binding the CONFIRMABLE content = base64url(SHA-256(UTF-8(canonicalPayload))).
    /// Pulse verifies it at read-back/confirm; Relay verifies it again at writeback; ActionReceipt.confirmedProposalHash
    /// echoes exactly this. v0.1.8 (Echo #231350): binds id + kind + targetSessionId + targetSequence + renderedPreview
    /// + createdAt + sourceQuestionId — so two same-CONTENT proposals with different ids/times get DISTINCT hashes.
    /// ANY change to those fields changes the hash and INVALIDATES a prior confirmation (single-use, TOCTOU-proof).
    public let proposalHash: String
    /// Explicit-hash init (cross-platform; used by decode + non-Apple hosts). Producers on Apple use the convenience init.
    public init(id: String, kind: ActionKind, targetSessionId: String, targetSequence: Int, renderedPreview: String, requiresConfirmation: Bool, createdAt: Date, sourceQuestionId: String?, proposalHash: String) {
        self.id = id; self.kind = kind; self.targetSessionId = targetSessionId; self.targetSequence = targetSequence
        self.renderedPreview = renderedPreview; self.requiresConfirmation = requiresConfirmation
        self.createdAt = createdAt; self.sourceQuestionId = sourceQuestionId; self.proposalHash = proposalHash
    }

    /// The EXACT canonical bytes the hash covers. INJECTION-PROOF length-prefixed encoding (Echo review 5f45364):
    /// each field is emitted as `<utf8-byte-count>:<field-bytes>`, so a field CONTAINING the delimiter cannot
    /// shift boundaries (delimiter-only canonicalization was collision-vulnerable). Order-fixed, versioned domain
    /// separator. Every lane (Swift + the Node gateway) MUST reproduce EXACTLY this — see the known-answer vector
    /// in ContractsCrossModuleTests (KAV_1) and mirror it in Relay's Node tests.
    public static func canonicalPayload(id: String, kind: ActionKind, targetSessionId: String, targetSequence: Int, renderedPreview: String, createdAt: Date, sourceQuestionId: String?) -> String {
        func lp(_ s: String) -> String { "\(s.utf8.count):\(s)" }
        // v3 (Echo #231350): bind id + createdAt + sourceQuestionId so two same-CONTENT proposals with different
        // ids/times get DISTINCT hashes (kills the confirm-swap where A's intent confirmed a same-content B).
        // createdAt as CHECKED epoch-millis (never traps; "" only for an out-of-range date, which isValidForConfirmation rejects).
        let created = ActionReceipt.safeEpochMillis(createdAt).map(String.init) ?? ""
        // presence flag so nil != some("") (Pulse #231475 — same fix as ActionResultRef's optional cursor).
        let src = sourceQuestionId.map { "1" + lp($0) } ?? "0"
        return "pocket.actionproposal.v3\n"
            + lp(id) + lp(kind.rawValue) + lp(targetSessionId) + lp(String(targetSequence))
            + lp(renderedPreview) + lp(created) + src
    }
    #if canImport(CryptoKit)
    /// proposalHash = base64url(SHA-256(UTF-8(canonicalPayload))). Producers compute; confirm + writeback verify.
    public static func computeHash(id: String, kind: ActionKind, targetSessionId: String, targetSequence: Int, renderedPreview: String, createdAt: Date, sourceQuestionId: String?) -> String {
        let bytes = Data(canonicalPayload(id: id, kind: kind, targetSessionId: targetSessionId, targetSequence: targetSequence, renderedPreview: renderedPreview, createdAt: createdAt, sourceQuestionId: sourceQuestionId).utf8)
        let d = SHA256.hash(data: bytes)
        return Data(d).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    /// Producer convenience (Apple): builds a proposal with a freshly-computed hash + requiresConfirmation = true.
    public init(id: String, kind: ActionKind, targetSessionId: String, targetSequence: Int, renderedPreview: String, createdAt: Date, sourceQuestionId: String?) {
        let h = ActionProposal.computeHash(id: id, kind: kind, targetSessionId: targetSessionId, targetSequence: targetSequence, renderedPreview: renderedPreview, createdAt: createdAt, sourceQuestionId: sourceQuestionId)
        self.init(id: id, kind: kind, targetSessionId: targetSessionId, targetSequence: targetSequence, renderedPreview: renderedPreview, requiresConfirmation: true, createdAt: createdAt, sourceQuestionId: sourceQuestionId, proposalHash: h)
    }
    /// Verify the stored hash still matches the content. Call at CONFIRM and again at WRITEBACK; refuse on mismatch.
    public func hashMatchesContent() -> Bool {
        return proposalHash == ActionProposal.computeHash(id: id, kind: kind, targetSessionId: targetSessionId, targetSequence: targetSequence, renderedPreview: renderedPreview, createdAt: createdAt, sourceQuestionId: sourceQuestionId)
    }
    #endif

    /// Deterministic pre-confirmation gate (Echo review 5f45364): the confirm UI AND the writeback MUST pass this
    /// before acting. The explicit/decoded init can carry requiresConfirmation=false or an arbitrary hash — this
    /// rejects those. On Apple/gateway (CryptoKit) it ALSO requires hashMatchesContent (full content-integrity).
    public func isValidForConfirmation() -> Bool {
        guard requiresConfirmation, targetSequence > 0,
              !id.isEmpty, id.count <= 128,
              !targetSessionId.isEmpty, targetSessionId.count <= 256,
              !renderedPreview.isEmpty, renderedPreview.count <= 4096,
              ActionReceipt.safeEpochMillis(createdAt) != nil,   // v0.1.8: createdAt is bound in the hash -> must be sane
              !proposalHash.isEmpty else { return false }
        #if canImport(CryptoKit)
        return hashMatchesContent()
        #else
        return false  // FAIL CLOSED (Echo 84d463f): no CryptoKit -> cannot verify the hash -> NOT confirmable.
                      // A security predicate must never fail open. Non-CryptoKit hosts must inject a verifier and
                      // check hashMatchesContent separately before treating a proposal as confirmable.
        #endif
    }
}

public enum ActionKind: String, Codable, Equatable, Sendable {
    case threadedReply
    case opinionRequest
    // NO destructive/deploy/tool kinds in Sunday scope.
}

/// The concrete result of a governed write, as a TAGGED UNION (v0.1.7, agreed Relay/Echo/Pulse #231081-#231316).
/// A true threaded reply is an ACTION — it has its own action id and the event it threads under — NOT a bare
/// sequence number; representing a reply as a numeric `resultingSequence` mislabels it (loses thread association)
/// and fabricates a sequence identity it does not have. A top-level say genuinely IS a new sequence.
///
/// Explicit, Node-mirrorable Codable (a `kind` discriminator — never Swift's opaque synthesized enum encoding):
///   action   -> {"kind":"action","actionId":"...","targetSequenceId":123,"targetCursor":"..."|absent}
///   sequence -> {"kind":"sequence","sequenceId":123}
public enum ActionResultRef: Codable, Equatable, Sendable {
    /// A threaded reply via the message-action channel: its own actionId + the target it threads under.
    case action(actionId: String, targetSequenceId: Int, targetCursor: String?)
    /// A top-level say: the new sequence id it created.
    case sequence(sequenceId: Int)

    private enum CodingKeys: String, CodingKey { case kind, actionId, targetSequenceId, targetCursor, sequenceId }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .action(actionId, targetSequenceId, targetCursor):
            try c.encode("action", forKey: .kind)
            try c.encode(actionId, forKey: .actionId)
            try c.encode(targetSequenceId, forKey: .targetSequenceId)
            try c.encodeIfPresent(targetCursor, forKey: .targetCursor)
        case let .sequence(sequenceId):
            try c.encode("sequence", forKey: .kind)
            try c.encode(sequenceId, forKey: .sequenceId)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "action":
            self = .action(actionId: try c.decode(String.self, forKey: .actionId),
                           targetSequenceId: try c.decode(Int.self, forKey: .targetSequenceId),
                           targetCursor: try c.decodeIfPresent(String.self, forKey: .targetCursor))
        case "sequence":
            self = .sequence(sequenceId: try c.decode(Int.self, forKey: .sequenceId))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown ActionResultRef kind \(other)")
        }
    }

    /// Deterministic, injection-proof token folded (length-prefixed) into `canonicalReceiptPayload`. Mirror
    /// byte-for-byte in the Node gateway. Optional cursor carries an explicit presence flag so nil stays distinct
    /// from "". Each variable field is itself length-prefixed; the whole token is length-prefixed by the receipt.
    public func canonicalToken() -> String {
        func lp(_ s: String) -> String { "\(s.utf8.count):\(s)" }
        switch self {
        case let .action(actionId, targetSequenceId, targetCursor):
            let cursor = targetCursor.map { "1" + lp($0) } ?? "0"
            return lp("action") + lp(actionId) + lp(String(targetSequenceId)) + cursor
        case let .sequence(sequenceId):
            return lp("sequence") + lp(String(sequenceId))
        }
    }
}

public struct ActionReceipt: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let proposalId: String
    public let status: ReceiptStatus
    public let result: ActionResultRef?         // v0.1.7: tagged union (reply=action / say=sequence), replacing
                                                // the overloaded resultingSequence:Int. Set ONLY on .posted.
    public let targetSessionId: String
    public let confirmedByHumanAt: Date
    public let confirmedProposalHash: String   // v0.1.2: the EXACT ActionProposal.proposalHash the human confirmed.
                                               // Writeback MUST refuse if the live proposal's hash != this. Proves
                                               // "what was posted == what was confirmed" (airtight core claim).
    public let executedAt: Date?
    public let failureReason: String?
    public let signature: String?              // v0.1.3 (Pulse/Echo): gateway ed25519 signature over the canonical
                                               // receipt bytes. Present ONLY on a real .posted receipt from the
                                               // gateway. The phone MUST verify it before rendering "posted"; nil
                                               // => NOT verified (pending/failed receipts are unsigned and must
                                               // NEVER render as verified/sent — same honesty rule as the bundle).
    public let signingKeyId: String?
    public init(id: String, proposalId: String, status: ReceiptStatus, result: ActionResultRef?, targetSessionId: String, confirmedByHumanAt: Date, confirmedProposalHash: String, executedAt: Date?, failureReason: String?, signature: String?, signingKeyId: String?) {
        self.id = id; self.proposalId = proposalId; self.status = status; self.result = result
        self.targetSessionId = targetSessionId; self.confirmedByHumanAt = confirmedByHumanAt
        self.confirmedProposalHash = confirmedProposalHash
        self.executedAt = executedAt; self.failureReason = failureReason
        self.signature = signature; self.signingKeyId = signingKeyId
    }

    /// Type-enforced status invariant (Echo 84d463f): .posted MUST carry result + executedAt + signature +
    /// signingKeyId (and no failureReason); .pendingConnectivity MUST carry none of them; .failed MUST carry
    /// failureReason and none of the posted fields. The phone/gateway reject a receipt that fails this.
    public func isStructurallyValid() -> Bool {
        guard hasSaneDates() else { return false }   // reject non-finite/out-of-range dates (Echo 62e08e9 A: no trap)
        switch status {
        case .posted:
            return result != nil && executedAt != nil && signature != nil && signingKeyId != nil && failureReason == nil
        case .pendingConnectivity:
            return result == nil && executedAt == nil && signature == nil && signingKeyId == nil && failureReason == nil
        case .failed:
            return failureReason != nil && result == nil && executedAt == nil && signature == nil && signingKeyId == nil
        }
    }

    /// Safe CHECKED epoch-MILLISECONDS: nil for a non-finite or out-of-range Date — never TRAPS (Echo 62e08e9 A:
    /// `Int(hugeDouble)` traps in Swift). Millis (not seconds) so subsecond Date content is actually BOUND.
    public static func safeEpochMillis(_ date: Date) -> Int64? {
        let t = date.timeIntervalSince1970
        guard t.isFinite else { return nil }
        let millis = (t * 1000).rounded()
        let bound = 253_402_300_800_000.0   // ~year 9999
        guard millis >= -bound, millis <= bound else { return nil }
        return Int64(millis)
    }
    /// All dates finite + in range, so canonicalization/signing can never trap. Folded into isStructurallyValid.
    public func hasSaneDates() -> Bool {
        guard ActionReceipt.safeEpochMillis(confirmedByHumanAt) != nil else { return false }
        if let e = executedAt, ActionReceipt.safeEpochMillis(e) == nil { return false }
        return true
    }

    /// The EXACT bytes the gateway ed25519-signs and the phone verifies. Length-prefixed (injection-proof),
    /// versioned; mirror byte-for-byte in the Node gateway. v3 (Echo 62e08e9): CHECKED epoch-MILLISECONDS (binds
    /// subsecond content + never traps on an extreme decoded Date). Binds every field EXCEPT `signature`.
    public func canonicalReceiptPayload() -> String {
        func lp(_ s: String) -> String { "\(s.utf8.count):\(s)" }
        func ms(_ d: Date?) -> String { d.flatMap(ActionReceipt.safeEpochMillis).map(String.init) ?? "" }
        return "pocket.actionreceipt.v4\n"                      // v4: `result` tagged union replaces resultingSequence:Int
            + lp(id)
            + lp(proposalId)
            + lp(status.rawValue)
            + lp(result.map { $0.canonicalToken() } ?? "")
            + lp(targetSessionId)
            + lp(confirmedProposalHash)
            + lp(ms(confirmedByHumanAt))
            + lp(ms(executedAt))
            + lp(failureReason ?? "")
            + lp(signingKeyId ?? "")
    }

    #if canImport(CryptoKit)
    /// First-class signature state (Echo 84d463f): a non-nil signature string is NOT "verified" — verification
    /// is a real ed25519 check over canonicalReceiptPayload with the trusted gateway key. The phone MUST render
    /// "sent/verified" ONLY on .verified.
    public func signatureState(gatewayPublicKeyBase64url pk: String) -> SignatureState {
        guard let sig = signature else { return .unsigned }                       // truly no signature present
        guard status == .posted, isStructurallyValid() else { return .invalid }   // sig present + bad structure = tamper (Echo)
        guard let pkData = Data(base64URLEncoded: pk),
              let sigData = Data(base64URLEncoded: sig),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pkData) else { return .invalid }
        return key.isValidSignature(sigData, for: Data(canonicalReceiptPayload().utf8)) ? .verified : .invalid
    }
    #endif
}

/// A receipt's signature status — verification is an explicit crypto result, never mere string presence.
public enum SignatureState: String, Codable, Equatable, Sendable {
    case unsigned            // no signature (pending/failed, or a .posted missing the field -> not renderable as sent)
    case verified            // ed25519 signature verified over the canonical receipt payload with the trusted key
    case invalid             // a signature is present but does NOT verify -> treat as NOT sent + surface tampering
}

private extension Data {
    /// base64url (no padding, -/_ alphabet) -> Data. Used for ed25519 keys/signatures on the wire.
    init?(base64URLEncoded s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let d = Data(base64Encoded: b) else { return nil }
        self = d
    }
}

public enum ReceiptStatus: String, Codable, Equatable, Sendable {
    case pendingConnectivity   // offline: NEVER represent as sent
    case posted                // success: result (action|sequence) is set
    case failed                // failureReason is set
}
