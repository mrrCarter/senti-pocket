import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// SentiActionClient — owner: claude-pocket-relay
//
// The governed writeback interface. The local model only produces an ActionProposal
// (free text + intended target). DETERMINISTIC code (the gateway behind this protocol)
// owns target resolution, the confirmation gate, idempotent execution via the EXISTING
// Senti reply action, and the receipt. No speech reaches a tool call directly.
//
// Execution is P3 and WARDEN-GATED — this file is the interface + safety types only.
// Idempotency + target binding here mirror the live-verified `sl session reply` action
// (see services/pocket-gateway/CHECKPOINT_ACCESS.md §4).
// ─────────────────────────────────────────────────────────────────────────────

/// What the local model may emit. Text + intent ONLY — carries no authority.
public struct ActionProposal: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case reply, requestOpinions }
    public let kind: Kind
    public let targetSessionId: String
    public let targetSequenceId: Int          // must exist within the briefed bundle range
    public let bodyText: String
    public init(kind: Kind, targetSessionId: String, targetSequenceId: Int, bodyText: String) {
        self.kind = kind; self.targetSessionId = targetSessionId
        self.targetSequenceId = targetSequenceId; self.bodyText = bodyText
    }
}

/// Deterministically resolved target — proves the proposal points inside the briefed checkpoint.
public struct ResolvedTarget: Equatable, Sendable {
    public let sessionId: String
    public let sequenceId: Int
    public let cursor: String                 // "seq:hash" — always carried, never a bare sequence
    public let bundleId: String
    public init(sessionId: String, sequenceId: Int, cursor: String, bundleId: String) {
        self.sessionId = sessionId; self.sequenceId = sequenceId
        self.cursor = cursor; self.bundleId = bundleId
    }
}

/// A prepared write awaiting explicit human confirmation. `proposalHash` binds the confirmation.
public struct PreparedAction: Equatable, Sendable {
    public let target: ResolvedTarget
    public let bodyText: String
    public let readBack: String               // exact message + thread shown/spoken to the human
    public let proposalHash: String           // sha256(canonical(proposal)); any edit changes it
    public init(target: ResolvedTarget, bodyText: String, readBack: String, proposalHash: String) {
        self.target = target; self.bodyText = bodyText
        self.readBack = readBack; self.proposalHash = proposalHash
    }
}

/// Single-use, hash-bound, expiring confirmation. Consumed on first use or on any proposal change.
public struct ConfirmationToken: Equatable, Sendable {
    public let proposalHash: String
    public let nonce: String
    public let expiresAt: Date
    public init(proposalHash: String, nonce: String, expiresAt: Date) {
        self.proposalHash = proposalHash; self.nonce = nonce; self.expiresAt = expiresAt
    }
}

/// Built from the REAL Senti reply response. Never synthesized on failure.
public struct ActionReceipt: Codable, Equatable, Sendable {
    public let actionId: String               // action.id from the reply response
    public let targetSessionId: String
    public let targetSequenceId: Int
    public let idempotencyKey: String         // cli:reply:seq:<target>:<actor>:<hash>
    public let duplicate: Bool                // true => this confirm posted exactly once already
    public let proposalHash: String
    public let actingAgentId: String          // ideally a scoped AIdenID; see DESIGN.md §3
    public let createdAt: Date
    public let signature: BundleSignature
    public init(actionId: String, targetSessionId: String, targetSequenceId: Int,
                idempotencyKey: String, duplicate: Bool, proposalHash: String,
                actingAgentId: String, createdAt: Date, signature: BundleSignature) {
        self.actionId = actionId; self.targetSessionId = targetSessionId
        self.targetSequenceId = targetSequenceId; self.idempotencyKey = idempotencyKey
        self.duplicate = duplicate; self.proposalHash = proposalHash
        self.actingAgentId = actingAgentId; self.createdAt = createdAt; self.signature = signature
    }
}

public struct BundleSignature: Codable, Equatable, Sendable {
    public let alg: String
    public let value: String
    public init(alg: String, value: String) { self.alg = alg; self.value = value }
}

/// A confirmed-but-unsent write held offline. UI shows PENDING — NEVER "sent".
public struct PendingIntent: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case pendingConnectivity, needsReconfirm, sent, failed }
    public let proposalHash: String
    public let targetSessionId: String
    public let targetSequenceId: Int
    public let bodyText: String
    public let confirmedAt: Date
    public var state: State
    public init(proposalHash: String, targetSessionId: String, targetSequenceId: Int,
                bodyText: String, confirmedAt: Date, state: State) {
        self.proposalHash = proposalHash; self.targetSessionId = targetSessionId
        self.targetSequenceId = targetSequenceId; self.bodyText = bodyText
        self.confirmedAt = confirmedAt; self.state = state
    }
}

public enum ActionError: Error, Equatable, Sendable {
    case targetOutOfScope(sequenceId: Int)    // proposal points outside the briefed bundle
    case wrongSession(expected: String, got: String)
    case staleConfirmation                    // token expired
    case replayedConfirmation                 // token already consumed
    case proposalMismatch                     // token's hash != current proposal hash
    case offline                              // queued as PendingIntent instead
    case remoteFailure(String)                // explicit failure; NOT a synthesized success
}

/// Governed writeback. Implementations are deterministic and P3/warden-gated.
public protocol SentiActionClient: Sendable {
    /// Resolve + validate the proposed target against the briefed bundle. Throws if out of scope.
    func resolveTarget(_ proposal: ActionProposal, in bundle: Data) throws -> ResolvedTarget

    /// Render the read-back and compute the binding hash. No write happens here.
    func prepare(_ proposal: ActionProposal, target: ResolvedTarget) -> PreparedAction

    /// Execute the idempotent write iff the confirmation is valid, single-use, and hash-bound.
    /// Returns a receipt built from the REAL response, or throws an explicit ActionError.
    func confirmAndPost(_ prepared: PreparedAction, confirmation: ConfirmationToken) async throws -> ActionReceipt

    /// Offline: persist a confirmed intent as PENDING_CONNECTIVITY (never shown as sent).
    func queuePending(_ prepared: PreparedAction, confirmation: ConfirmationToken) throws -> PendingIntent

    /// On reconnect: freshness-check each pending intent, then post the still-valid ones exactly once.
    func reconcilePending() async throws -> [ActionReceipt]
}
