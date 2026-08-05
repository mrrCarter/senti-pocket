import Foundation
import PocketContracts

/// The deterministic end-to-end call flow (Atlas-owned). Pure `reduce(state, event, gatewayKey) -> state` — the
/// UI (Pulse) renders `state`, the lanes emit `event`s. The SAFETY INVARIANT is encoded HERE, not just in the UI.
///
/// v0.3 (Echo #231350 re-audit): the authority-bearing INPUTS are bound, not just the transition:
///   • Ingress            → `.bundleArrived` takes a `VerifiedBundle` (mintable ONLY by verifying the gateway
///                          signature). No EVENT can introduce an unverified bundle into a live call. (Direct
///                          `PocketCallState` construction stays a UI-preview affordance — the production
///                          coordinator only ever feeds states produced by `reduce` from verified events.)
///   • `.answered(plan)`  → plan is bounded, non-empty, checkpoint-bound, and every citation resolves in the exact
///                          `VerifiedBundle` already held by the incoming call.
///   • `.questionAnswered`→ checkpoint identity is UTF-8 exact and bounded citations resolve in this bundle.
///   • `.proposalDrafted` → proposal.targetSessionId == bundle.sessionId (no wrong-session write) AND a non-empty
///                          per-episode `challenge` nonce the coordinator minted for THIS confirm screen.
///   • `.confirmed(cap)`  → an opaque single-use `ConfirmationCapability` echoing the awaiting proposal's FULL
///                          identity (id + hash + session + sequence) AND that episode's challenge. Because the
///                          v0.1.8 proposalHash now binds id/createdAt/provenance, two same-CONTENT proposals get
///                          distinct hashes; and the challenge makes a blind/stale caller unable to forge a valid
///                          capability. Single-use is structural (leaving `.awaitingConfirmation` no-ops replays).
///   • `.executed(rcpt)`  → receipt binds proposalId/confirmedProposalHash/targetSessionId to the executing
///                          proposal AND is structurally valid; a `.posted` receipt must ALSO verify under the
///                          pinned gateway key.
public enum PocketCallState: Equatable, Sendable {
    case idle
    // v0.4 (Pulse/Echo #235653 demo-blocker #1): every LIVE state holds a `VerifiedBundle`, NOT a raw PocketBundle.
    // A `VerifiedBundle` is mintable ONLY via VerifiedBundle.verify (real ed25519) — so a live call state is
    // UNCONSTRUCTABLE from an unverified bundle even by a misbehaving caller. This closes the "public raw state is
    // an authority transition" bypass at the TYPE level (was: `.conversing(rawBundle,[])` could reach `.executing`).
    case incoming(VerifiedBundle)                                            // "Senti is calling"
    case briefing(VerifiedBriefingPlan)                                     // narrating (Echo speaks; barge-in interrupts)
    case conversing(VerifiedBundle, answers: [QuestionAnswer])              // barge-in Q&A over cached evidence
    case awaitingConfirmation(VerifiedBundle, ActionProposal, challenge: String)  // preview + read-back; awaiting confirm
    case executing(VerifiedBundle, ActionProposal)                         // governed writeback in flight
    case completed(ActionReceipt)                                          // receipt (posted / pendingConnectivity / failed)
    case dismissed
}

/// Opaque single-use confirmation capability (Echo #231350 / Pulse #231216). The human's confirmation is bound to
/// the EXACT proposal they read back AND to the per-episode challenge — a payloadless or content-only confirm can
/// no longer confirm "whatever is displayed," and a same-content different-id proposal is distinguished. Pulse
/// mints it from the displayed proposal + the challenge it received via `forReadBack`. PocketCall-owned (no cycle).
public struct ConfirmationCapability: Equatable, Sendable {
    public let proposalId: String
    public let proposalHash: String
    public let targetSessionId: String
    public let targetSequence: Int
    public let challenge: String
    public init(proposalId: String, proposalHash: String, targetSessionId: String, targetSequence: Int, challenge: String) {
        self.proposalId = proposalId; self.proposalHash = proposalHash
        self.targetSessionId = targetSessionId; self.targetSequence = targetSequence; self.challenge = challenge
    }
    /// The capability that legitimately confirms `proposal` under episode `challenge` (the UI adapter uses this).
    public static func forReadBack(of proposal: ActionProposal, challenge: String) -> ConfirmationCapability {
        ConfirmationCapability(proposalId: proposal.id, proposalHash: proposal.proposalHash,
                               targetSessionId: proposal.targetSessionId, targetSequence: proposal.targetSequence,
                               challenge: challenge)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        OpaqueUTF8Identity.matches(lhs.proposalId, rhs.proposalId)
            && OpaqueUTF8Identity.matches(lhs.proposalHash, rhs.proposalHash)
            && OpaqueUTF8Identity.matches(lhs.targetSessionId, rhs.targetSessionId)
            && lhs.targetSequence == rhs.targetSequence
            && OpaqueUTF8Identity.matches(lhs.challenge, rhs.challenge)
    }
}

public enum PocketCallEvent: Sendable {
    case bundleArrived(VerifiedBundle)             // ingress: a VERIFIED bundle only
    case answered(BriefingPlan)                    // user answered the call -> start the briefing
    case interrupted                               // barge-in during briefing -> go to Q&A
    case briefingCompleted                         // briefing finished naturally -> Q&A
    case questionAnswered(QuestionAnswer)          // a local Q&A turn (stays in conversing)
    case proposalDrafted(ActionProposal, challenge: String)  // dictated instruction -> preview; coordinator mints challenge
    case confirmed(ConfirmationCapability)         // the human EXPLICITLY confirmed the EXACT read-back proposal
    case cancelled                                 // the human rejected the proposal -> back to Q&A
    case executed(ActionReceipt)                   // writeback returned a receipt (posted/pending/failed)
    case dismiss                                   // end the call from anywhere
}

public enum PocketCall {
    /// Pure, total transition, parameterized by the pinned gateway public key (used ONLY to verify a `.posted`
    /// receipt's signature). Unrecognized/authority-failing (state,event) pairs are no-ops.
    public static func reduce(_ state: PocketCallState,
                              _ event: PocketCallEvent,
                              gatewayKey: String) -> PocketCallState {
        if case .dismiss = event {
            if case .completed = state { return state }
            return .dismissed
        }

        switch (state, event) {
        case let (.idle, .bundleArrived(verified)):
            return .incoming(verified)   // carry the VerifiedBundle through every live state

        case let (.incoming(vb), .answered(plan)):
            guard let verifiedPlan = VerifiedBriefingPlan.verify(plan, against: vb) else {
                return .incoming(vb)   // ungrounded/malformed/cross-checkpoint plan: refuse
            }
            return .briefing(verifiedPlan)

        case let (.briefing(verifiedPlan), .interrupted),
             let (.briefing(verifiedPlan), .briefingCompleted):
            return .conversing(verifiedPlan.bundle, answers: [])

        case let (.conversing(vb, answers), .questionAnswered(qa)):
            guard Self.byteExact(qa.checkpointId, vb.bundle.checkpointId),
                  Self.citationsWithinBundle(qa.citations, vb.bundle) else { return state }
            return .conversing(vb, answers: answers + [qa])

        // Arm confirmation ONLY for a proposal that targets THIS bundle's session AND with a real episode nonce.
        case let (.conversing(vb, _), .proposalDrafted(proposal, challenge)):
            return (Self.byteExact(proposal.targetSessionId, vb.bundle.sessionId) && !challenge.isEmpty)
                ? .awaitingConfirmation(vb, proposal, challenge: challenge)
                : .conversing(vb, answers: [])

        // SAFETY-CRITICAL: confirm -> execute ONLY when the capability echoes the EXACT awaiting proposal's full
        // identity + this episode's challenge, the proposal is valid-for-confirmation, and target == bundle.session.
        case let (.awaitingConfirmation(vb, proposal, challenge), .confirmed(cap)):
            let boundToReadback =
                Self.byteExact(cap.proposalId, proposal.id)
                && Self.byteExact(cap.proposalHash, proposal.proposalHash)
                && Self.byteExact(cap.targetSessionId, proposal.targetSessionId)
                && cap.targetSequence == proposal.targetSequence
                && Self.byteExact(cap.challenge, challenge)
            let ok = boundToReadback
                && proposal.isValidForConfirmation()
                && Self.byteExact(proposal.targetSessionId, vb.bundle.sessionId)
            return ok ? .executing(vb, proposal)
                      : .awaitingConfirmation(vb, proposal, challenge: challenge)   // refuse (fail-safe)

        case let (.awaitingConfirmation(vb, _, _), .cancelled):
            return .conversing(vb, answers: [])

        case let (.executing(vb, proposal), .executed(receipt)):
            return Self.receiptBinds(receipt, to: proposal, bundle: vb.bundle, gatewayKey: gatewayKey)
                ? .completed(receipt)
                : .executing(vb, proposal)   // unbound/unverified receipt: stay in-flight, do not complete

        default:
            return state   // no-op: undefined transition (incl. any attempt to skip confirmation)
        }
    }

    /// Convenience: fold a sequence of events from an initial state. Deterministic.
    public static func run(_ initial: PocketCallState = .idle,
                           _ events: [PocketCallEvent],
                           gatewayKey: String) -> PocketCallState {
        events.reduce(initial) { reduce($0, $1, gatewayKey: gatewayKey) }
    }

    // MARK: - Authority binding (pure)

    static func citationsWithinBundle(_ citations: [String], _ bundle: PocketBundle) -> Bool {
        guard !citations.isEmpty else { return true }   // an honest "no evidence" answer is allowed
        guard citations.count <= PocketBundle.capEvidence else { return false }
        let known = Set(bundle.evidence.map { Array($0.id.utf8) })
        var seen = Set<[UInt8]>()
        var totalBytes = 0
        return citations.allSatisfy { citation in
            guard isWellFormedIdentity(citation, maxBytes: PocketBundle.capEvId),
                  citation.utf8.count <= PocketBundle.maxTotalBytes - totalBytes else { return false }
            totalBytes += citation.utf8.count
            let key = Array(citation.utf8)
            return seen.insert(key).inserted && known.contains(key)
        }
    }

    private static func byteExact(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    private static func isWellFormedIdentity(_ value: String, maxBytes: Int) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maxBytes else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && byteExact(trimmed, value)
    }

    static func receiptBinds(_ receipt: ActionReceipt,
                             to proposal: ActionProposal,
                             bundle: PocketBundle,
                             gatewayKey: String) -> Bool {
        guard receipt.isStructurallyValid(),
              byteExact(receipt.proposalId, proposal.id),
              byteExact(receipt.confirmedProposalHash, proposal.proposalHash),
              byteExact(receipt.targetSessionId, proposal.targetSessionId),
              byteExact(proposal.targetSessionId, bundle.sessionId) else { return false }
        if receipt.status == .posted {
            #if canImport(CryptoKit)
            return receipt.signatureState(gatewayPublicKeyBase64url: gatewayKey) == .verified
            #else
            return false   // cannot verify a posted receipt's signature without crypto -> fail closed
            #endif
        }
        return true   // pending/failed: structurally must NOT be signed; no server signature to verify
    }
}

/// Trust-boundary wrapper: a `PocketBundle` may drive the call ONLY after it is trusted + verified.
/// `VerifiedBundle` has NO public memberwise init — it is mintable ONLY through `verify(_:)`, so an unverified bundle
/// cannot be wrapped in a `.bundleArrived` event NOR held in any live PocketCallState (v0.4) as a matter of TYPE.
///
/// Converged onto warden/bundle-kav-fix's NON-INJECTABLE trust model (P1 re-audit): there is NO caller-supplied key.
/// `verify` resolves the pinned ed25519 key INTERNALLY from the bundle's `signingKeyId` (fixed, file-private trust
/// store in PocketContracts), rejects an untrusted id BEFORE any crypto, requires SEMANTIC validity (a trusted key
/// signing malformed content still yields malformed content), then verifies the ed25519 signature. Fails closed.
public struct VerifiedBundle: Equatable, Sendable {
    public let bundle: PocketBundle
    private init(bundle: PocketBundle) { self.bundle = bundle }

    /// Compares the bytes covered by the gateway signature plus the signature bytes themselves. Swift `String ==`
    /// performs Unicode canonical equivalence, so synthesized `PocketBundle` equality is not an authority boundary:
    /// composed and decomposed spellings can compare equal even though they produce different signed UTF-8 payloads.
    public func exactlyMatches(_ candidate: PocketBundle) -> Bool {
        // Raw public callers do not receive the minting guarantee carried by `self`. Validate first both to reject
        // semantically invalid aliases (notably sub-millisecond Dates that round to the same signed epoch millis) and
        // to bound the canonicalization work before materializing the candidate payload.
        guard candidate.isSemanticallyValid() else { return false }
        return hasSameSignedBytes(as: candidate)
    }

    private func hasSameSignedBytes(as candidate: PocketBundle) -> Bool {
        OpaqueUTF8Identity.matches(
            bundle.canonicalBundlePayload(),
            candidate.canonicalBundlePayload()
        ) && OpaqueUTF8Identity.matches(bundle.signature, candidate.signature)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        // Equality must remain reflexive even for DEBUG-only invalid test wrappers. Authority admission goes through
        // `exactlyMatches(_:)`, which additionally requires raw-candidate semantic validity.
        lhs.hasSameSignedBytes(as: rhs.bundle)
    }

    /// The ONLY ingress mint — no caller-supplied key/anchor (closes the caller-key-injection bypass).
    public static func verify(_ bundle: PocketBundle) -> VerifiedBundle? {
        #if canImport(CryptoKit)
        // cheap reject FIRST: an UNTRUSTED signingKeyId never reaches the bounded semantic scan or any crypto.
        guard bundle.hasTrustedSigningKeyId(),
              bundle.isSemanticallyValid(),
              bundle.verifiesSignature() else { return nil }
        return VerifiedBundle(bundle: bundle)
        #else
        return nil
        #endif
    }

    #if DEBUG
    /// TEST/PREVIEW ONLY — wrap a bundle WITHOUT verification. `internal` + DEBUG-only, so it is unreachable from a
    /// production `import PocketCall` build; only `@testable import PocketCall` (tests) can call it. Never use it in
    /// app/coordinator code — the real path is `verify()`.
    static func makeUnverifiedForTesting(_ bundle: PocketBundle) -> VerifiedBundle { VerifiedBundle(bundle: bundle) }
    #endif
}
