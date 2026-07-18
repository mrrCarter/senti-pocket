import Foundation
import PocketContracts

/// The deterministic end-to-end call flow (Atlas-owned). Pure `reduce(state, event, gatewayKey) -> state` — the
/// UI (Pulse) renders `state`, the lanes emit `event`s. The SAFETY INVARIANT is encoded HERE, not just in the UI.
///
/// v0.2 (Echo #231216 + Pulse cross-lane HOLD): blocking the `.confirmed` *shortcut* is necessary but not
/// sufficient — the authority-bearing INPUTS must be bound too. This reducer now enforces, at the flow level:
///   • `.answered(plan)`         → plan describes THIS bundle's checkpoint (no cross-checkpoint briefing).
///   • `.questionAnswered(qa)`   → qa describes THIS checkpoint and cites ONLY this bundle's evidence.
///   • `.proposalDrafted`        → proposal.targetSessionId == bundle.sessionId (NO wrong-session write, even
///                                 for a correctly-hashed proposal minted for a different known Senti room).
///   • `.confirmed(intent)`      → intent binds the EXACT proposal the human read back (intent.proposalHash ==
///                                 awaiting proposal's hash) AND the proposal isValidForConfirmation(). A stale
///                                 confirm for proposal A cannot confirm a displayed proposal B. Single-use is
///                                 structural: leaving `.awaitingConfirmation` makes any replayed intent a no-op.
///   • `.executed(receipt)`      → receipt binds to the EXACT executing proposal (proposalId / confirmedProposal
///                                 Hash / targetSessionId) AND is structurally valid; a `.posted` receipt must
///                                 additionally carry a signature that VERIFIES under the pinned gateway key.
///
/// TRUST-BOUNDARY (narrowed, NOT hand-waved): the pure reducer owns cross-field authority binding + exact-read
/// back confirmation + posted-receipt signature verification (via the pinned `gatewayKey`). The remaining crypto
/// check — verifying the *bundle's* own gateway ed25519 signature at ingest — is `VerifiedBundle` (below): a
/// bundle enters the machine ONLY as a VerifiedBundle, mintable ONLY by a verifier. Its crypto body is completed
/// against Relay's bundle-signing canonical KAV (pending); until then it fails closed. So "unverified/unbound
/// input cannot drive a governed write" is a TYPE + reducer guarantee, not a coordinator convention.
public enum PocketCallState: Equatable, Sendable {
    case idle
    case incoming(PocketBundle)                              // "Senti is calling"
    case briefing(PocketBundle, BriefingPlan)               // narrating (Echo speaks; barge-in interrupts)
    case conversing(PocketBundle, answers: [QuestionAnswer]) // barge-in Q&A over cached evidence
    case awaitingConfirmation(PocketBundle, ActionProposal)  // proposal preview + read-back; awaiting EXPLICIT confirm
    case executing(PocketBundle, ActionProposal)             // governed writeback in flight
    case completed(ActionReceipt)                            // receipt (posted / pendingConnectivity / failed)
    case dismissed
}

/// The human's confirmation, bound to the EXACT proposal they read back. Pulse mints its
/// `ActionConfirmationIntent` and maps it onto `ConfirmationIntent(proposalHash:)` — a payloadless confirm can
/// no longer confirm "whatever happens to be displayed." PocketCall-owned so there is no UI→flow dependency cycle.
public struct ConfirmationIntent: Equatable, Sendable {
    public let proposalHash: String
    public init(proposalHash: String) { self.proposalHash = proposalHash }
}

public enum PocketCallEvent: Sendable {
    case bundleArrived(PocketBundle)
    case answered(BriefingPlan)          // user answered the call -> start the briefing
    case interrupted                     // barge-in during briefing -> go to Q&A
    case briefingCompleted               // briefing finished naturally -> Q&A
    case questionAnswered(QuestionAnswer)// a local Q&A turn (stays in conversing)
    case proposalDrafted(ActionProposal) // dictated instruction -> typed proposal preview
    case confirmed(ConfirmationIntent)   // the human EXPLICITLY confirmed the EXACT read-back proposal
    case cancelled                       // the human rejected the proposal -> back to Q&A
    case executed(ActionReceipt)         // writeback returned a receipt (posted/pending/failed)
    case dismiss                         // end the call from anywhere
}

public enum PocketCall {
    /// Pure, total transition, parameterized by the pinned gateway public key (used ONLY to verify a `.posted`
    /// receipt's signature). Unrecognized/authority-failing (state,event) pairs are no-ops (return the same
    /// state) — the flow never lands in an undefined place, and no event can shortcut OR mis-bind into a write.
    public static func reduce(_ state: PocketCallState,
                              _ event: PocketCallEvent,
                              gatewayKey: String) -> PocketCallState {
        // `.dismiss` always ends the call (except once completed, where the receipt is the terminal UI).
        if case .dismiss = event {
            if case .completed = state { return state }
            return .dismissed
        }

        switch (state, event) {
        case let (.idle, .bundleArrived(bundle)):
            return .incoming(bundle)

        // The briefing plan must describe THIS bundle's checkpoint (no cross-checkpoint narration).
        case let (.incoming(bundle), .answered(plan)):
            return plan.checkpointId == bundle.checkpointId
                ? .briefing(bundle, plan)
                : .incoming(bundle)   // provenance mismatch: refuse

        case let (.briefing(bundle, _), .interrupted),
             let (.briefing(bundle, _), .briefingCompleted):
            return .conversing(bundle, answers: [])

        // A Q&A turn must describe THIS checkpoint and cite ONLY evidence present in THIS bundle.
        case let (.conversing(bundle, answers), .questionAnswered(qa)):
            guard qa.checkpointId == bundle.checkpointId,
                  Self.citationsWithinBundle(qa.citations, bundle) else { return state }
            return .conversing(bundle, answers: answers + [qa])

        // Arm confirmation ONLY for a proposal that targets THIS bundle's Senti session (no wrong-session write).
        case let (.conversing(bundle, _), .proposalDrafted(proposal)):
            return proposal.targetSessionId == bundle.sessionId
                ? .awaitingConfirmation(bundle, proposal)
                : .conversing(bundle, answers: [])   // wrong-session proposal: refuse to arm

        // SAFETY-CRITICAL: confirm -> execute ONLY when the intent binds the EXACT read-back proposal, the
        // proposal is valid-for-confirmation, and its target still equals this bundle's session.
        case let (.awaitingConfirmation(bundle, proposal), .confirmed(intent)):
            let boundToReadback = intent.proposalHash == proposal.proposalHash
            let ok = boundToReadback
                && proposal.isValidForConfirmation()
                && proposal.targetSessionId == bundle.sessionId
            return ok ? .executing(bundle, proposal)
                      : .awaitingConfirmation(bundle, proposal)   // mismatch/invalid: refuse (fail-safe)

        case let (.awaitingConfirmation(bundle, _), .cancelled):
            return .conversing(bundle, answers: [])

        // The receipt must bind to the EXACT executing proposal; a `.posted` receipt must ALSO verify under the
        // pinned gateway key. A mismatched/unverifiable receipt does NOT complete the call (never show "sent").
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

    /// Every citation on a Q&A turn must reference evidence actually present in the bundle.
    static func citationsWithinBundle(_ citations: [String], _ bundle: PocketBundle) -> Bool {
        guard !citations.isEmpty else { return true }   // an honest "no evidence" answer is allowed
        let known = Set(bundle.evidence.map { $0.id })
        return citations.allSatisfy { known.contains($0) }
    }

    /// A receipt legitimately completes the call ONLY if it is structurally valid, binds to the exact executing
    /// proposal (which itself targets this bundle's session), and — when `.posted` — carries a signature that
    /// verifies under the pinned gateway key. Fails closed where CryptoKit is unavailable.
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
/// so an unverified bundle cannot reach `.bundleArrived` as a matter of TYPE (not coordinator convention).
///
/// The crypto body below is completed against Relay's bundle-signing canonical KAV (coordination pending); until
/// that canonical payload is byte-agreed cross-lane, `verify` returns nil (fails closed) rather than trusting an
/// unverifiable bundle. See the HOLD-response thread.
public struct VerifiedBundle: Equatable, Sendable {
    public let bundle: PocketBundle
    private init(bundle: PocketBundle) { self.bundle = bundle }

    public static func verify(_ bundle: PocketBundle, gatewayPublicKeyBase64url key: String) -> VerifiedBundle? {
        // TODO(Relay bundle-signing KAV): verify `bundle.signature` (ed25519) over the agreed canonical bundle
        // payload using `key`. Until the canonical payload is byte-matched cross-lane, fail closed.
        return nil
    }
}
