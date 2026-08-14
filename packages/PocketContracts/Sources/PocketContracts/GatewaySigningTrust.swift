import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// The exact human confirmation sent to the gateway and retained in the durable outbox. Keeping this authority-
/// bearing value in PocketContracts lets receipt admission bind the returned proof to the actual local confirmation,
/// not merely to a caller-supplied timestamp.
public struct GovernedWriteConfirmation: Codable, Equatable, Sendable {
    public let proposalId: String
    public let confirmedProposalHash: String
    public let confirmedAt: Date

    public init(proposalId: String, confirmedProposalHash: String, confirmedAt: Date) {
        self.proposalId = proposalId
        self.confirmedProposalHash = confirmedProposalHash
        self.confirmedAt = confirmedAt
    }
}

/// A compiled gateway key is authorized for a specific proof surface. Bundle demo keys must never become receipt
/// trust anchors merely because both artifacts use Ed25519.
enum PocketGatewaySigningPurpose: Hashable, Sendable {
    case bundle
    case actionReceipt
}

/// Source form for one immutable trust anchor. The registry validates every entry as one unit; one malformed or
/// duplicate entry invalidates the entire registry instead of leaving a partially trusted set.
struct PocketGatewaySigningKey: Equatable, Sendable {
    let signingKeyId: String
    let publicKeyBase64url: String
    let publicKeySHA256Base64url: String
    let purposes: Set<PocketGatewaySigningPurpose>
}

/// The sole gateway-signing trust registry. It is internal, immutable, and has no runtime/network/environment
/// mutation path. Production verification below always uses `production`; the internal initializer exists only so
/// `@testable` cryptographic KAVs can exercise rotation and failure modes without adding a forgeable Release key.
struct PocketGatewaySigningKeyRegistry: Sendable {
    private struct ResolvedKey: Sendable {
        let rawRepresentation: Data
        let publicKeySHA256Base64url: String
        let purposes: Set<PocketGatewaySigningPurpose>
    }

    private let keysById: [OpaqueUTF8Identity: ResolvedKey]
    let isStructurallyValid: Bool

    static let production = Self(keys: [
        // Offline/demo bundle anchors are intentionally bundle-only. Production receipt trust remains empty until
        // Carter supplies reviewed PUBLIC key material plus a signed bundle+receipt canary in a data-only activation.
        PocketGatewaySigningKey(
            signingKeyId: PocketDemoGatewayKey.signingKeyId,
            publicKeyBase64url: PocketDemoGatewayKey.publicKeyBase64url,
            publicKeySHA256Base64url: "btapRpy93HFAZDJlmN8omu0_vHmCbyGufM1k9IgHmPY",
            purposes: [.bundle]
        ),
        PocketGatewaySigningKey(
            signingKeyId: "pocket-demo-app-fixture",
            publicKeyBase64url: "SehNmI_dP9XFonEUXzmoDA7B0wCAss_JbVbbM4L0Y94",
            publicKeySHA256Base64url: "0TlrCO0wTvwvF3ugD_FiIh64TM8_UYVRqnpkmVM_i1s",
            purposes: [.bundle]
        ),
    ])

    init(keys: [PocketGatewaySigningKey]) {
        var resolved: [OpaqueUTF8Identity: ResolvedKey] = [:]
        var valid = true

        for key in keys {
            let idBytes = Array(key.signingKeyId.utf8)
            guard (1...256).contains(idBytes.count),
                  idBytes.allSatisfy({ (0x21...0x7e).contains($0) }),
                  !key.purposes.isEmpty,
                  let rawKey = PocketBase64URL.decodeCanonicalUnpadded(key.publicKeyBase64url),
                  rawKey.count == 32,
                  let fingerprint = PocketBase64URL.sha256(rawKey),
                  fingerprint == key.publicKeySHA256Base64url else {
                valid = false
                break
            }

            let identity = OpaqueUTF8Identity(key.signingKeyId)
            guard resolved[identity] == nil else {
                valid = false
                break
            }
            resolved[identity] = ResolvedKey(
                rawRepresentation: rawKey,
                publicKeySHA256Base64url: fingerprint,
                purposes: key.purposes
            )
        }

        keysById = valid ? resolved : [:]
        isStructurallyValid = valid
    }

    func rawPublicKey(signingKeyId: String, purpose: PocketGatewaySigningPurpose) -> Data? {
        guard isStructurallyValid,
              let key = keysById[OpaqueUTF8Identity(signingKeyId)],
              key.purposes.contains(purpose) else { return nil }
        return key.rawRepresentation
    }

    func fingerprint(signingKeyId: String, purpose: PocketGatewaySigningPurpose) -> String? {
        guard isStructurallyValid,
              let key = keysById[OpaqueUTF8Identity(signingKeyId)],
              key.purposes.contains(purpose) else { return nil }
        return key.publicKeySHA256Base64url
    }

    func hasKey(for purpose: PocketGatewaySigningPurpose) -> Bool {
        isStructurallyValid && keysById.values.contains(where: { $0.purposes.contains(purpose) })
    }
}

/// A posted receipt that passed the complete immutable trust decision. Its initializer is private, so downstream UI
/// and state machines cannot relabel an untrusted wire `ActionReceipt` as verified.
public struct VerifiedActionReceipt: Equatable, Sendable {
    private static let maximumSafeSequence = 9_007_199_254_740_991

    public let receipt: ActionReceipt
    public let result: ActionResultRef
    public let signingKeyId: String

    private init(receipt: ActionReceipt, result: ActionResultRef, signingKeyId: String) {
        self.receipt = receipt
        self.result = result
        self.signingKeyId = signingKeyId
    }

    /// Mints only through the compiled production receipt registry. There is intentionally no caller-supplied key or
    /// public trust-store overload: an attacker-controlled receipt can choose an id, never the key behind that id.
    public static func verify(
        _ receipt: ActionReceipt,
        for proposal: ActionProposal,
        confirmation: GovernedWriteConfirmation
    ) -> Self? {
        verify(receipt, for: proposal, confirmation: confirmation, registry: .production)
    }

    static func verify(
        _ receipt: ActionReceipt,
        for proposal: ActionProposal,
        confirmation: GovernedWriteConfirmation,
        registry: PocketGatewaySigningKeyRegistry
    ) -> Self? {
        guard proposal.isValidForConfirmation(),
              OpaqueUTF8Identity.matches(confirmation.proposalId, proposal.id),
              OpaqueUTF8Identity.matches(confirmation.confirmedProposalHash, proposal.proposalHash),
              receipt.status == .posted,
              receipt.isStructurallyValid(),
              // `id` is the independent, signature-bound server receipt identity. The reviewed proposal is bound
              // through `proposalId`; existing wire/KAV fixtures intentionally permit those two identities to differ.
              (1...256).contains(receipt.id.utf8.count),
              OpaqueUTF8Identity.matches(receipt.proposalId, proposal.id),
              OpaqueUTF8Identity.matches(receipt.targetSessionId, proposal.targetSessionId),
              OpaqueUTF8Identity.matches(receipt.confirmedProposalHash, proposal.proposalHash),
              let proposalMillis = ActionReceipt.safeEpochMillis(proposal.createdAt),
              let expectedConfirmationMillis = ActionReceipt.safeEpochMillis(confirmation.confirmedAt),
              let receiptConfirmationMillis = ActionReceipt.safeEpochMillis(receipt.confirmedByHumanAt),
              expectedConfirmationMillis == receiptConfirmationMillis,
              receiptConfirmationMillis >= proposalMillis,
              let executedAt = receipt.executedAt,
              let executedMillis = ActionReceipt.safeEpochMillis(executedAt),
              executedMillis >= receiptConfirmationMillis,
              let result = receipt.result,
              resultIsBound(result, to: proposal),
              let signingKeyId = receipt.signingKeyId,
              (1...256).contains(signingKeyId.utf8.count),
              signingKeyId.utf8.allSatisfy({ (0x21...0x7e).contains($0) }),
              let publicKey = registry.rawPublicKey(
                  signingKeyId: signingKeyId,
                  purpose: .actionReceipt
              ) else { return nil }

        #if canImport(CryptoKit)
        guard let signature = receipt.signature,
              let signatureData = PocketBase64URL.decodeCanonicalUnpadded(signature),
              signatureData.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              key.isValidSignature(signatureData, for: Data(receipt.canonicalReceiptPayload().utf8)) else {
            return nil
        }
        return Self(receipt: receipt, result: result, signingKeyId: signingKeyId)
        #else
        return nil
        #endif
    }

    private static func resultIsBound(_ result: ActionResultRef, to proposal: ActionProposal) -> Bool {
        switch (proposal.kind, result) {
        case (.humanMessage, .sequence(let sequenceId)):
            return (1...maximumSafeSequence).contains(sequenceId)

        case (.threadedReply, .action(let actionId, let targetSequenceId, let targetCursor)),
             (.opinionRequest, .action(let actionId, let targetSequenceId, let targetCursor)):
            guard (1...256).contains(actionId.utf8.count),
                  (1...maximumSafeSequence).contains(targetSequenceId),
                  targetSequenceId == proposal.targetSequence else { return false }
            if let targetCursor {
                // The wire deliberately preserves nil vs some(""); both are valid and signature-distinct.
                guard targetCursor.utf8.count <= 256 else { return false }
            }
            return true

        default:
            return false
        }
    }
}

private enum PocketBase64URL {
    static func decodeCanonicalUnpadded(_ value: String) -> Data? {
        guard !value.isEmpty,
              !value.contains("="),
              value.utf8.allSatisfy({ byte in
                  (0x30...0x39).contains(byte)
                      || (0x41...0x5a).contains(byte)
                      || (0x61...0x7a).contains(byte)
                      || byte == 0x2d
                      || byte == 0x5f
              }) else { return nil }
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64), encode(data) == value else { return nil }
        return data
    }

    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func sha256(_ data: Data) -> String? {
        #if canImport(CryptoKit)
        return encode(Data(SHA256.hash(data: data)))
        #else
        return nil
        #endif
    }
}
