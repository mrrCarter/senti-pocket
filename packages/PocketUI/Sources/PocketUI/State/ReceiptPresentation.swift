import Foundation
import PocketContracts

/// A non-forgeable presentation trust boundary. v0.1.8 does not yet expose an Atlas-owned pinned gateway-key type,
/// so production callers can construct only the fail-closed empty store. The internal populated initializer exists
/// for cryptographic unit vectors; it must be replaced by Atlas's frozen trust-anchor contract before integration.
public struct ReceiptTrustStore: Equatable, Sendable {
    fileprivate let signingKeys: [TrustedReceiptSigningKey]
    fileprivate let isStructurallyValid: Bool

    public init() {
        self.signingKeys = []
        self.isStructurallyValid = true
    }

    init(signingKeys: [TrustedReceiptSigningKey]) {
        let ids = signingKeys.map(\.signingKeyId)
        self.signingKeys = signingKeys
        self.isStructurallyValid = !ids.contains(where: \.isEmpty) && Set(ids).count == ids.count
    }
}

struct TrustedReceiptSigningKey: Equatable, Sendable {
    let signingKeyId: String
    fileprivate let publicKeyBase64url: String

    init(signingKeyId: String, publicKeyBase64url: String) {
        self.signingKeyId = signingKeyId
        self.publicKeyBase64url = publicKeyBase64url
    }
}

public struct ReceiptPresentation: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case pendingConnectivity(detail: String)
        case posted(result: ActionResultRef, signingKeyId: String)
        case failed(detail: String)
        case invalid(detail: String)
    }

    let status: Status

    private init(status: Status) {
        self.status = status
    }

    public static func evaluate(
        receipt: ActionReceipt,
        proposal: ActionProposal,
        trustStore: ReceiptTrustStore
    ) -> Self {
        guard proposal.isValidForConfirmation() else {
            return Self(status: .invalid(detail: "The original proposal no longer passes content-integrity validation."))
        }
        guard receipt.isStructurallyValid() else {
            return Self(status: .invalid(detail: "Receipt fields do not match its declared status."))
        }
        guard receipt.proposalId == proposal.id else {
            return Self(status: .invalid(detail: "Receipt proposal identity does not match the reviewed proposal."))
        }
        guard receipt.targetSessionId == proposal.targetSessionId else {
            return Self(status: .invalid(detail: "Receipt target session does not match the reviewed proposal."))
        }
        guard receipt.confirmedProposalHash == proposal.proposalHash else {
            return Self(status: .invalid(detail: "Receipt hash does not match the proposal you confirmed."))
        }
        guard receipt.confirmedByHumanAt >= proposal.createdAt else {
            return Self(status: .invalid(detail: "Receipt confirmation predates the reviewed proposal."))
        }
        if let executedAt = receipt.executedAt, executedAt < receipt.confirmedByHumanAt {
            return Self(status: .invalid(detail: "Receipt execution predates its confirmation."))
        }

        switch receipt.status {
        case .pendingConnectivity:
            return Self(status: .pendingConnectivity(
                detail: "Not sent. This wire receipt does not prove durable queue persistence; reconcile the action before retrying or posting."
            ))

        case .failed:
            return Self(status: .failed(
                detail: receipt.failureReason ?? "The action failed and was not sent."
            ))

        case .posted:
            guard let result = receipt.result,
                  let signingKeyId = receipt.signingKeyId,
                  !signingKeyId.isEmpty else {
                return Self(status: .invalid(detail: "Posted receipt is missing required proof fields."))
            }
            if let resultFailure = validate(result: result, for: proposal) {
                return Self(status: .invalid(detail: resultFailure))
            }
            guard trustStore.isStructurallyValid else {
                return Self(status: .invalid(detail: "Receipt trust store contains duplicate or invalid key identities."))
            }
            guard let trustedKey = trustStore.signingKeys.first(where: { $0.signingKeyId == signingKeyId }) else {
                return Self(status: .invalid(detail: "Receipt signing key is not trusted."))
            }

            #if canImport(CryptoKit)
            switch receipt.signatureState(gatewayPublicKeyBase64url: trustedKey.publicKeyBase64url) {
            case .verified:
                return Self(status: .posted(result: result, signingKeyId: signingKeyId))
            case .unsigned:
                return Self(status: .invalid(detail: "Posted receipt is unsigned and cannot be verified."))
            case .invalid:
                return Self(status: .invalid(detail: "Receipt signature verification failed."))
            }
            #else
            return Self(status: .invalid(detail: "Receipt signature verification is unavailable on this platform."))
            #endif
        }
    }

    private static func validate(result: ActionResultRef, for proposal: ActionProposal) -> String? {
        switch result {
        case .action(let actionId, let targetSequenceId, let targetCursor):
            guard !actionId.isEmpty, actionId.utf8.count <= 256 else {
                return "Thread action identity is missing or unbounded."
            }
            guard targetSequenceId > 0, targetSequenceId == proposal.targetSequence else {
                return "Thread action target does not match the sequence you confirmed."
            }
            if let targetCursor,
               targetCursor.isEmpty || targetCursor.utf8.count > 1_024 {
                return "Thread action cursor is empty or unbounded."
            }
            return nil

        case .sequence(let sequenceId):
            guard sequenceId > 0 else {
                return "Resulting sequence is not a positive sequence identity."
            }
            guard proposal.kind != .threadedReply else {
                return "A threaded reply returned a sequence result instead of a thread action reference."
            }
            return nil
        }
    }

    public var isPosted: Bool {
        if case .posted = status { return true }
        return false
    }

    public var title: String {
        switch status {
        case .pendingConnectivity: return "PENDING CONNECTIVITY"
        case .posted: return "Posted"
        case .failed: return "Failed — not sent"
        case .invalid: return "Receipt verification error"
        }
    }

    public var detail: String {
        switch status {
        case .pendingConnectivity(let detail):
            return detail
        case .posted(let result, let signingKeyId):
            switch result {
            case .action(let actionId, let targetSequenceId, _):
                return "Verified receipt. Senti created thread action \(actionId) under sequence \(targetSequenceId). Signing key: \(signingKeyId)."
            case .sequence(let sequenceId):
                return "Verified receipt. Senti created sequence \(sequenceId). Signing key: \(signingKeyId)."
            }
        case .failed(let detail):
            return detail
        case .invalid(let detail):
            return "Do not treat this action as sent. \(detail)"
        }
    }

    /// Present only after the receipt signature and proposal/result bindings verify.
    public var verifiedResult: ActionResultRef? {
        if case .posted(let result, _) = status { return result }
        return nil
    }

    public var verifiedSigningKeyId: String? {
        if case .posted(_, let signingKeyId) = status { return signingKeyId }
        return nil
    }
}
