import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// ReceiptVerifier — owner: claude-pocket-relay
//
// Before the phone shows "sent", the returned receipt is re-checked against the
// exact prepared action: same target, same proposal hash, and a valid signature.
// A receipt that does not verify is treated as failure — the phone must not claim
// success. Verification is designed to work OFFLINE (no network) so cached receipts
// can be re-validated after sync.
// ─────────────────────────────────────────────────────────────────────────────

public enum ReceiptVerificationError: Error, Equatable, Sendable {
    case targetMismatch(expected: ResolvedTarget, receiptSequenceId: Int)
    case proposalHashMismatch
    case signatureInvalid
    case sessionMismatch(expected: String, got: String)
}

public protocol ReceiptVerifier: Sendable {
    /// Verify the receipt binds to this prepared action. Throws on any mismatch. Offline-safe.
    func verify(_ receipt: ActionReceipt, boundTo prepared: PreparedAction) throws

    /// Verify only the signature/integrity of a receipt (e.g. re-validating a cached receipt).
    func verifySignature(_ receipt: ActionReceipt) throws
}

/// Reference deterministic checks that any conforming verifier MUST enforce. The signature check
/// is a stub (interim `sha256-unsigned`); P3 swaps in ed25519 over the canonical receipt.
public struct DefaultReceiptChecks {
    public init() {}

    public func targetAndHashMatch(_ receipt: ActionReceipt, _ prepared: PreparedAction) -> ReceiptVerificationError? {
        if receipt.targetSessionId != prepared.target.sessionId {
            return .sessionMismatch(expected: prepared.target.sessionId, got: receipt.targetSessionId)
        }
        if receipt.targetSequenceId != prepared.target.sequenceId {
            return .targetMismatch(expected: prepared.target, receiptSequenceId: receipt.targetSequenceId)
        }
        if receipt.proposalHash != prepared.proposalHash {
            return .proposalHashMismatch
        }
        return nil
    }
}
