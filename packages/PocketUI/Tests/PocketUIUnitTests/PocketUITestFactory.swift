import Foundation
import PocketContracts

enum PocketUITestFactory {
    static let date = Date(timeIntervalSince1970: 1_752_835_200)

    static func proposal(
        id: String = "proposal-1",
        kind: ActionKind = .threadedReply,
        sessionId: String = "954233b7-1822-42bc-9cfe-1eb95eb0357a",
        sequence: Int = 230180,
        message: String = "Hold AUTH-1C until billing and CI are green.",
        requiresConfirmation: Bool = true,
        createdAt: Date = date,
        sourceQuestionId: String? = "question-1",
        proposalHash: String? = nil
    ) -> ActionProposal {
        let resolvedHash: String
        if let proposalHash {
            resolvedHash = proposalHash
        } else {
            #if canImport(CryptoKit)
            resolvedHash = ActionProposal.computeHash(
                id: id,
                kind: kind,
                targetSessionId: sessionId,
                targetSequence: sequence,
                renderedPreview: message,
                createdAt: createdAt,
                sourceQuestionId: sourceQuestionId
            )
            #else
            resolvedHash = "UNCOMPUTED_ON_NON_CRYPTO_HOST"
            #endif
        }
        return ActionProposal(
            id: id,
            kind: kind,
            targetSessionId: sessionId,
            targetSequence: sequence,
            renderedPreview: message,
            requiresConfirmation: requiresConfirmation,
            createdAt: createdAt,
            sourceQuestionId: sourceQuestionId,
            proposalHash: resolvedHash
        )
    }

    static func receipt(
        proposal: ActionProposal = PocketUITestFactory.proposal(),
        status: ReceiptStatus,
        result: ActionResultRef? = nil,
        targetSessionId: String? = nil,
        confirmedProposalHash: String? = nil,
        confirmedByHumanAt: Date? = nil,
        executedAt: Date? = nil,
        failureReason: String? = nil,
        signature: String? = nil,
        signingKeyId: String? = nil
    ) -> ActionReceipt {
        ActionReceipt(
            id: "receipt-1",
            proposalId: proposal.id,
            status: status,
            result: result,
            targetSessionId: targetSessionId ?? proposal.targetSessionId,
            confirmedByHumanAt: confirmedByHumanAt ?? date,
            confirmedProposalHash: confirmedProposalHash ?? proposal.proposalHash,
            executedAt: executedAt,
            failureReason: failureReason,
            signature: signature,
            signingKeyId: signingKeyId
        )
    }

    static func evidence(id: String = "ev_1") -> EvidenceRef {
        EvidenceRef(
            id: id,
            sessionId: "954233b7-1822-42bc-9cfe-1eb95eb0357a",
            sequence: 230141,
            agentId: "claude-pocket-relay",
            snippet: "ACCESS_TOKEN_PATTERN now matches the live token format",
            ts: date
        )
    }
}
