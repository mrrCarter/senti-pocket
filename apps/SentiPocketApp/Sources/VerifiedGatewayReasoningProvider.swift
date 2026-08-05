import Foundation
import PocketCall
import PocketContracts
import PocketReasoning
import PocketSyncClient

enum VerifiedGatewayReasoningError: LocalizedError, Equatable, Sendable {
    case wrongSession
    case checkpointRequired
    case checkpointMismatch
    case invalidBriefing
    case invalidAnswer
    case authenticationChanged

    var errorDescription: String? {
        switch self {
        case .wrongSession:
            return "The reasoning request does not belong to the selected session."
        case .checkpointRequired:
            return "Open a verified checkpoint before asking a grounded question."
        case .checkpointMismatch:
            return "The reasoning response does not belong to the verified checkpoint."
        case .invalidBriefing:
            return "The briefing could not be grounded in the verified checkpoint."
        case .invalidAnswer:
            return "The answer could not be grounded in the verified checkpoint."
        case .authenticationChanged:
            return "Your authorization changed while reasoning. Try again from the current session."
        }
    }
}

/// Release trust boundary for gateway reasoning.
///
/// The reasoning endpoint is membership-gated, but its `grounded` discriminator is still a server assertion. Before
/// this provider returns anything labeled live/grounded, it independently downloads the exact signed checkpoint,
/// verifies it through `CheckpointTransport`, and binds every citation to that `VerifiedBundle`. One actor owns the
/// context so Phone briefing → Q&A and Dial's exact-checkpoint Q&A share the same auth/session/checkpoint fences.
actor VerifiedGatewayReasoningProvider: ReasoningProvider {
    nonisolated let provenance: ReasoningProvenance = .liveReasoned

    private let expectedSessionId: String
    private let gateway: UnboundGatewayReasoningProvider
    private let checkpointTransport: any CheckpointTransport
    private let tokenProvider: @Sendable () -> String?
    private let onReauthenticationRequired: @Sendable (_ expectedToken: String?) -> Void

    private enum VerifiedContext: Sendable {
        case briefing(VerifiedBriefingPlan)
        case checkpoint(VerifiedBundle)

        var bundle: VerifiedBundle {
            switch self {
            case .briefing(let briefing): return briefing.bundle
            case .checkpoint(let bundle): return bundle
            }
        }
    }

    private var contextRevision: UInt64 = 0
    private var contextCredentialFingerprint: String?
    private var verifiedContext: VerifiedContext?

    init(
        expectedSessionId: String,
        gateway: UnboundGatewayReasoningProvider,
        checkpointTransport: any CheckpointTransport,
        tokenProvider: @escaping @Sendable () -> String?,
        onReauthenticationRequired: @escaping @Sendable (_ expectedToken: String?) -> Void = { _ in }
    ) {
        self.expectedSessionId = expectedSessionId
        self.gateway = gateway
        self.checkpointTransport = checkpointTransport
        self.tokenProvider = tokenProvider
        self.onReauthenticationRequired = onReauthenticationRequired
    }

    func briefing(sessionId: String, checkpointId: String?) async throws -> BriefingPlan {
        try requireExpectedSession(sessionId)
        let token = try requireCredential()
        let revision = beginContext(for: token)

        let plan = try await gateway.briefing(sessionId: sessionId, checkpointId: checkpointId)
        try Task.checkCancellation()
        try requireCurrentContext(revision, credential: token)

        let bundle = try await fetchVerifiedBundle(
            sessionId: sessionId,
            checkpointId: plan.checkpointId,
            expectedToken: token
        )
        try Task.checkCancellation()
        try requireCurrentContext(revision, credential: token)
        guard let admitted = VerifiedBriefingPlan.verify(plan, against: bundle) else {
            throw VerifiedGatewayReasoningError.invalidBriefing
        }

        verifiedContext = .briefing(admitted)
        return admitted.plan
    }

    func answer(_ question: String, sessionId: String, checkpointId: String?) async throws -> ReasonedAnswer {
        try requireExpectedSession(sessionId)
        let token = try requireCredential()

        let bundle: VerifiedBundle
        let revision: UInt64
        if let existing = verifiedContext?.bundle {
            try requireCredentialMatchesContext(token)
            if let checkpointId,
               !Self.byteExact(checkpointId, existing.bundle.checkpointId) {
                throw VerifiedGatewayReasoningError.checkpointMismatch
            }
            bundle = existing
            revision = contextRevision
        } else {
            guard let checkpointId else {
                throw VerifiedGatewayReasoningError.checkpointRequired
            }
            revision = beginContext(for: token)
            bundle = try await fetchVerifiedBundle(
                sessionId: sessionId,
                checkpointId: checkpointId,
                expectedToken: token
            )
            try Task.checkCancellation()
            try requireCurrentContext(revision, credential: token)
            verifiedContext = .checkpoint(bundle)
        }

        let exactCheckpointId = bundle.bundle.checkpointId
        let result = try await gateway.answer(
            question,
            sessionId: sessionId,
            checkpointId: exactCheckpointId
        )
        try Task.checkCancellation()
        try requireCurrentContext(revision, credential: token)
        guard let admitted = Self.admit(result, question: question, against: bundle) else {
            throw VerifiedGatewayReasoningError.invalidAnswer
        }
        return admitted
    }

    private func beginContext(for token: String) -> UInt64 {
        contextRevision &+= 1
        contextCredentialFingerprint = DeviceRingFingerprint.digest(token)
        verifiedContext = nil
        return contextRevision
    }

    private func requireExpectedSession(_ sessionId: String) throws {
        guard Self.byteExact(sessionId, expectedSessionId) else {
            throw VerifiedGatewayReasoningError.wrongSession
        }
    }

    private func requireCredential() throws -> String {
        guard let token = tokenProvider() else {
            onReauthenticationRequired(nil)
            throw VerifiedGatewayReasoningError.authenticationChanged
        }
        guard !token.isEmpty,
              token.utf8.count <= 8_192,
              token.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else {
            onReauthenticationRequired(token)
            throw VerifiedGatewayReasoningError.authenticationChanged
        }
        return token
    }

    private func requireCredentialMatchesContext(_ token: String) throws {
        guard contextCredentialFingerprint == DeviceRingFingerprint.digest(token) else {
            invalidateContext()
            throw VerifiedGatewayReasoningError.authenticationChanged
        }
    }

    private func requireCurrentContext(_ revision: UInt64, credential token: String) throws {
        try Task.checkCancellation()
        // A superseded task must never erase the newer task's context. Only credential drift in THIS revision revokes.
        guard revision == contextRevision else {
            throw VerifiedGatewayReasoningError.authenticationChanged
        }
        guard let currentToken = tokenProvider(),
              Self.byteExact(currentToken, token),
              contextCredentialFingerprint == DeviceRingFingerprint.digest(currentToken) else {
            invalidateContext()
            throw VerifiedGatewayReasoningError.authenticationChanged
        }
    }

    private func fetchVerifiedBundle(
        sessionId: String,
        checkpointId: String,
        expectedToken: String
    ) async throws -> VerifiedBundle {
        do {
            let bundle = try await checkpointTransport.fetchExactCheckpoint(
                sessionId: sessionId,
                checkpointId: checkpointId
            )
            guard Self.byteExact(bundle.bundle.sessionId, expectedSessionId),
                  Self.byteExact(bundle.bundle.checkpointId, checkpointId) else {
                throw VerifiedGatewayReasoningError.checkpointMismatch
            }
            return bundle
        } catch let error as CheckpointTransportError {
            switch error {
            case .notLoggedIn:
                onReauthenticationRequired(nil)
            case .reauthenticationRequired:
                onReauthenticationRequired(expectedToken)
            default:
                break
            }
            throw error
        }
    }

    private func invalidateContext() {
        contextRevision &+= 1
        contextCredentialFingerprint = nil
        verifiedContext = nil
    }

    private static func admit(
        _ answer: UnboundReasonedAnswer,
        question: String,
        against verifiedBundle: VerifiedBundle
    ) -> ReasonedAnswer? {
        let bundle = verifiedBundle.bundle
        let allowedEvidenceIds = Set(bundle.evidence.map { identityKey($0.id) })
        switch answer {
        case .answered(let grounded):
            guard byteExact(grounded.checkpointId, bundle.checkpointId),
                  byteExact(grounded.question, question),
                  !grounded.evidenceIds.isEmpty else { return nil }
            var seen = Set<[UInt8]>()
            guard grounded.evidenceIds.allSatisfy({
                let key = identityKey($0)
                return seen.insert(key).inserted && allowedEvidenceIds.contains(key)
            }) else { return nil }
            return .answered(ReasonedQuestionAnswer(
                id: grounded.id,
                checkpointId: grounded.checkpointId,
                question: grounded.question,
                text: grounded.text,
                taggedText: grounded.taggedText,
                evidenceIds: grounded.evidenceIds,
                llmConfidence: grounded.llmConfidence,
                provenance: .liveReasoned,
                createdAt: grounded.createdAt
            ))

        case .clarify(let prompt, let options):
            return .clarify(prompt: prompt, options: options)

        case .unavailable(let topics):
            var seen = Set<[UInt8]>()
            guard topics.allSatisfy({
                let key = identityKey($0.evidenceId)
                return seen.insert(key).inserted && allowedEvidenceIds.contains(key)
            }) else { return nil }
            return .unavailable(nearestTopics: topics)
        }
    }

    private static func identityKey(_ value: String) -> [UInt8] {
        Array(value.utf8)
    }

    private static func byteExact(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }
}
