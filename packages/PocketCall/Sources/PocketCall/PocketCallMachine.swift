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
///   • `.answered(plan)`  → plan.checkpointId == bundle.checkpointId.
///   • `.questionAnswered`→ qa.checkpointId == bundle.checkpointId AND citations ⊆ this bundle's evidence.
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
    case incoming(PocketBundle)                                       // "Senti is calling"
    case briefing(PocketBundle, BriefingPlan)                        // narrating (Echo speaks; barge-in interrupts)
    case conversing(PocketBundle, answers: [QuestionAnswer])          // barge-in Q&A over cached evidence
    case awaitingConfirmation(PocketBundle, ActionProposal, challenge: String)  // preview + read-back; awaiting confirm
    case executing(PocketBundle, ActionProposal)                     // governed writeback in flight
    case completed(ActionReceipt)                                    // receipt (posted / pendingConnectivity / failed)
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
            return .incoming(verified.bundle)

        case let (.incoming(bundle), .answered(plan)):
            return plan.checkpointId == bundle.checkpointId
                ? .briefing(bundle, plan)
                : .incoming(bundle)   // provenance mismatch: refuse

        case let (.briefing(bundle, _), .interrupted),
             let (.briefing(bundle, _), .briefingCompleted):
            return .conversing(bundle, answers: [])

        case let (.conversing(bundle, answers), .questionAnswered(qa)):
            guard qa.checkpointId == bundle.checkpointId,
                  Self.citationsWithinBundle(qa.citations, bundle) else { return state }
            return .conversing(bundle, answers: answers + [qa])

        // Arm confirmation ONLY for a proposal that targets THIS bundle's session AND with a real episode nonce.
        case let (.conversing(bundle, _), .proposalDrafted(proposal, challenge)):
            return (proposal.targetSessionId == bundle.sessionId && !challenge.isEmpty)
                ? .awaitingConfirmation(bundle, proposal, challenge: challenge)
                : .conversing(bundle, answers: [])

        // SAFETY-CRITICAL: confirm -> execute ONLY when the capability echoes the EXACT awaiting proposal's full
        // identity + this episode's challenge, the proposal is valid-for-confirmation, and target == bundle.session.
        case let (.awaitingConfirmation(bundle, proposal, challenge), .confirmed(cap)):
            let boundToReadback =
                cap.proposalId == proposal.id
                && cap.proposalHash == proposal.proposalHash
                && cap.targetSessionId == proposal.targetSessionId
                && cap.targetSequence == proposal.targetSequence
                && cap.challenge == challenge
            let ok = boundToReadback
                && proposal.isValidForConfirmation()
                && proposal.targetSessionId == bundle.sessionId
            return ok ? .executing(bundle, proposal)
                      : .awaitingConfirmation(bundle, proposal, challenge: challenge)   // refuse (fail-safe)

        case let (.awaitingConfirmation(bundle, _, _), .cancelled):
            return .conversing(bundle, answers: [])

        case let (.executing(bundle, proposal), .executed(receipt)):
            return Self.receiptBinds(receipt, to: proposal, bundle: bundle, gatewayKey: gatewayKey)
                ? .completed(receipt)
                : .executing(bundle, proposal)   // unbound/unverified receipt: stay in-flight, do not complete

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
        let known = Set(bundle.evidence.map { $0.id })
        return citations.allSatisfy { known.contains($0) }
    }

    static func receiptBinds(_ receipt: ActionReceipt,
                             to proposal: ActionProposal,
                             bundle: PocketBundle,
                             gatewayKey: String) -> Bool {
        guard receipt.isStructurallyValid(),
              receipt.proposalId == proposal.id,
              receipt.confirmedProposalHash == proposal.proposalHash,
              receipt.targetSessionId == proposal.targetSessionId,
              proposal.targetSessionId == bundle.sessionId else { return false }
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

/// Trust-boundary wrapper: a `PocketBundle` may drive the call ONLY after its gateway ed25519 signature verifies.
/// `VerifiedBundle` has NO public memberwise init — it is mintable ONLY through `verify(_:gatewayPublicKeyBase64url:)`,
/// so an unverified bundle cannot be wrapped in a `.bundleArrived` event as a matter of TYPE (not convention).
///
/// The crypto body is completed against Relay's bundle-signing canonical KAV (services/pocket-gateway/src/bundle.mjs;
/// Relay's narrow cross-language commit is pending — one ISO8601-ms date form, versioned domain separator, base64url
/// signature, schema/key validation, frozen test-key KAV). Until that lands `verify` returns nil (fails closed),
/// so in a release build NOTHING can start a call — the correct honest state while bundle verification is unfinished.
public struct VerifiedBundle: Equatable, Sendable {
    public let bundle: PocketBundle
    private init(bundle: PocketBundle) { self.bundle = bundle }

    /// The ONLY ingress mint (P1 re-audit — no caller-supplied key/anchor). Mints ONLY if the bundle is SEMANTICALLY
    /// VALID (FIX3) AND its ed25519 signature verifies under the PINNED key resolved INTERNALLY from `signingKeyId`
    /// (FIX1 — `PocketBundle.verifiesSignature()` uses the fixed, non-injectable trust store; an attacker cannot pin
    /// its own key). An unknown signingKeyId, malformed content, or a bad/foreign signature all fail closed.
    public static func verify(_ bundle: PocketBundle) -> VerifiedBundle? {
        #if canImport(CryptoKit)
        // P1.4 — cheap reject FIRST: an UNTRUSTED signingKeyId never reaches the (bounded) semantic scan or any crypto.
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
