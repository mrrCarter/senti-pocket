import Foundation
import PocketContracts

/// The coordinator's deterministic authorization decision for one proposal target and time window.
/// PocketUI verifies every field rather than accepting a caller-asserted `valid` enum case.
public struct ProposalAuthorizationContext: Equatable, Sendable {
    public static let maximumLifetime: TimeInterval = 5 * 60
    public static let maximumChallengeUTF8Length = 256

    public let id: String
    public let confirmationChallenge: String
    public let expectedTargetSessionId: String
    public let expectedTargetSequence: Int
    public let oldestAllowedProposalDate: Date
    public let evaluatedAt: Date
    public let validUntil: Date

    /// Internal v0.1.8 adapter only. Production code cannot self-issue an authorization context; Atlas's frozen
    /// full-authorization grant will replace this initializer. Tests/previews use it under module/test visibility.
    init(
        id: String,
        confirmationChallenge: String,
        expectedTargetSessionId: String,
        expectedTargetSequence: Int,
        oldestAllowedProposalDate: Date,
        evaluatedAt: Date,
        validUntil: Date
    ) {
        self.id = id
        self.confirmationChallenge = confirmationChallenge
        self.expectedTargetSessionId = expectedTargetSessionId
        self.expectedTargetSequence = expectedTargetSequence
        self.oldestAllowedProposalDate = oldestAllowedProposalDate
        self.evaluatedAt = evaluatedAt
        self.validUntil = validUntil
    }
}

public struct ProposalValidationState: Equatable, Sendable {
    private struct Authorization: Equatable, Sendable {
        let context: ProposalAuthorizationContext
        let proposalId: String
        let proposalHash: String
    }

    private enum Status: Equatable, Sendable {
        case authorized(Authorization)
        case invalid(reason: String)
    }

    private let status: Status

    public static func authorize(
        _ proposal: ActionProposal,
        context: ProposalAuthorizationContext
    ) -> Self {
        guard !context.id.isEmpty else {
            return .invalid(reason: "Proposal authorization is missing an identity.")
        }
        guard !context.confirmationChallenge.isEmpty,
              context.confirmationChallenge.utf8.count <= ProposalAuthorizationContext.maximumChallengeUTF8Length else {
            return .invalid(reason: "Proposal confirmation challenge is missing or unbounded.")
        }
        guard proposal.createdAt.timeIntervalSince1970.isFinite,
              context.oldestAllowedProposalDate.timeIntervalSince1970.isFinite,
              context.evaluatedAt.timeIntervalSince1970.isFinite,
              context.validUntil.timeIntervalSince1970.isFinite,
              context.oldestAllowedProposalDate <= context.evaluatedAt else {
            return .invalid(reason: "Proposal authorization contains an invalid freshness window.")
        }
        guard context.validUntil > context.evaluatedAt else {
            return .invalid(reason: "Proposal authorization is already expired.")
        }
        guard context.validUntil.timeIntervalSince(context.evaluatedAt) <= ProposalAuthorizationContext.maximumLifetime else {
            return .invalid(reason: "Proposal authorization exceeds the maximum five-minute lifetime.")
        }
        guard proposal.createdAt >= context.oldestAllowedProposalDate,
              proposal.createdAt <= context.evaluatedAt else {
            return .invalid(reason: "Proposal is outside the authorized freshness window.")
        }
        guard proposal.targetSessionId == context.expectedTargetSessionId else {
            return .invalid(reason: "Proposal target session is not authorized for this checkpoint.")
        }
        guard proposal.targetSequence == context.expectedTargetSequence else {
            return .invalid(reason: "Proposal target sequence is not authorized for this checkpoint.")
        }
        guard proposal.isValidForConfirmation() else {
            return .invalid(reason: "Proposal content integrity validation failed.")
        }

        return Self(status: .authorized(Authorization(
            context: context,
            proposalId: proposal.id,
            proposalHash: proposal.proposalHash
        )))
    }

    public static func invalid(reason: String) -> Self {
        Self(status: .invalid(reason: reason))
    }

    public func matches(_ proposal: ActionProposal, at currentDate: Date) -> Bool {
        guard case .authorized(let authorization) = status else { return false }
        return currentDate >= authorization.context.evaluatedAt
            && currentDate < authorization.context.validUntil
            && authorization.proposalId == proposal.id
            && authorization.proposalHash == proposal.proposalHash
            && authorization.context.expectedTargetSessionId == proposal.targetSessionId
            && authorization.context.expectedTargetSequence == proposal.targetSequence
    }

    public var failureReason: String? {
        if case .invalid(let reason) = status { return reason }
        return nil
    }

    fileprivate var authorizationId: String? {
        guard case .authorized(let authorization) = status else { return nil }
        return authorization.context.id
    }

    fileprivate var authorizationContext: ProposalAuthorizationContext? {
        guard case .authorized(let authorization) = status else { return nil }
        return authorization.context
    }

}

public enum ProposalReadBackState: Equatable, Sendable {
    case notStarted
    case speaking(attemptId: UUID, proposalId: String, proposalHash: String)
    case completed(attemptId: UUID, proposalId: String, proposalHash: String)
    case failed(message: String)

    public func completedExactly(_ proposal: ActionProposal) -> Bool {
        guard case .completed(_, let proposalId, let proposalHash) = self else { return false }
        return proposalId == proposal.id && proposalHash == proposal.proposalHash
    }
}

public enum ProposalConfirmationPhase: Equatable, Sendable {
    case awaitingReadBack
    case readingBack
    case ready
    case submitting
    case consumed
    case invalidated(reason: String)
}

public struct ActionConfirmationIntent: Equatable, Sendable {
    public let proposal: ActionProposal
    public let proposalId: String
    public let proposalHash: String
    public let authorizationId: String
    public let confirmationChallenge: String

    fileprivate init(proposal: ActionProposal, authorization: ProposalAuthorizationContext) {
        self.proposal = proposal
        self.proposalId = proposal.id
        self.proposalHash = proposal.proposalHash
        self.authorizationId = authorization.id
        self.confirmationChallenge = authorization.confirmationChallenge
    }
}

public struct ProposalReadBackPayload: Equatable, Sendable {
    public let proposal: ActionProposal
    public let kind: ActionKind
    public let targetSessionId: String
    public let targetSequence: Int
    public let fullMessageText: String

    public init(proposal: ActionProposal) {
        self.proposal = proposal
        self.kind = proposal.kind
        self.targetSessionId = proposal.targetSessionId
        self.targetSequence = proposal.targetSequence
        self.fullMessageText = proposal.renderedPreview
    }

    /// Deterministic speech text. `fullMessageText` is appended verbatim; it is never trimmed, parsed as
    /// Markdown, normalized, or edited. Echo/Atlas may add voice prosody but must not change these values.
    public var spokenText: String {
        "Action: \(kind.rawValue). Target session: \(targetSessionId). "
            + "Target message sequence: \(targetSequence). Full message: \(fullMessageText)"
    }
}

public struct ProposalReadBackAttempt: Equatable, Sendable {
    public let id: UUID
    public let payload: ProposalReadBackPayload

    fileprivate init(proposal: ActionProposal) {
        self.id = UUID()
        self.payload = ProposalReadBackPayload(proposal: proposal)
    }
}

public struct ConsumedProposalConfirmation: Equatable, Sendable {
    public let proposalId: String
    public let proposalHash: String

    public init(proposalId: String, proposalHash: String) {
        self.proposalId = proposalId
        self.proposalHash = proposalHash
    }
}

/// Coordinator-owned single-use memory. Retain one instance for the app process and seed it on launch from the
/// persisted pending/receipt store. It is reference-backed and lock-protected so copied Swift value state cannot
/// replay a confirmation. Reconstructing a gate for an already consumed proposal ID also remains fail-closed.
public final class ProposalConfirmationLedger: @unchecked Sendable, Equatable {
    private enum Entry {
        case available(proposalHash: String)
        case reading(proposalHash: String, attemptId: UUID)
        case ready(proposalHash: String, attemptId: UUID)
        case consumed(proposalHash: String)
        case submitting(proposalHash: String)
        case revoked
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    public init(consumedConfirmations: [ConsumedProposalConfirmation] = []) {
        for confirmation in consumedConfirmations {
            switch entries[confirmation.proposalId] {
            case nil:
                entries[confirmation.proposalId] = .consumed(proposalHash: confirmation.proposalHash)
            case .consumed(let registeredHash) where registeredHash == confirmation.proposalHash:
                break
            case .available, .reading, .ready, .consumed, .submitting, .revoked:
                entries[confirmation.proposalId] = .revoked
            }
        }
    }

    public static func == (lhs: ProposalConfirmationLedger, rhs: ProposalConfirmationLedger) -> Bool {
        lhs === rhs
    }

    fileprivate func register(proposalId: String, proposalHash: String) -> Bool {
        withLock {
            switch entries[proposalId] {
            case nil:
                entries[proposalId] = .available(proposalHash: proposalHash)
                return true
            case .available(let registeredHash),
                 .reading(let registeredHash, _),
                 .ready(let registeredHash, _):
                guard registeredHash == proposalHash else {
                    entries[proposalId] = .revoked
                    return false
                }
                return true
            case .consumed, .submitting, .revoked:
                return false
            }
        }
    }

    fileprivate func beginReadBack(proposalId: String, proposalHash: String, attemptId: UUID) -> Bool {
        withLock {
            switch entries[proposalId] {
            case .available(let registeredHash), .ready(let registeredHash, _):
                guard registeredHash == proposalHash else { return false }
                entries[proposalId] = .reading(proposalHash: proposalHash, attemptId: attemptId)
                return true
            case .reading, .consumed, .submitting, .revoked, nil:
                return false
            }
        }
    }

    fileprivate func completeReadBack(proposalId: String, proposalHash: String, attemptId: UUID) -> Bool {
        withLock {
            guard case .reading(let registeredHash, let activeAttemptId) = entries[proposalId],
                  registeredHash == proposalHash,
                  activeAttemptId == attemptId else { return false }
            entries[proposalId] = .ready(proposalHash: proposalHash, attemptId: attemptId)
            return true
        }
    }

    fileprivate func failReadBack(proposalId: String, proposalHash: String, attemptId: UUID) -> Bool {
        withLock {
            guard case .reading(let registeredHash, let activeAttemptId) = entries[proposalId],
                  registeredHash == proposalHash,
                  activeAttemptId == attemptId else { return false }
            entries[proposalId] = .available(proposalHash: proposalHash)
            return true
        }
    }

    fileprivate func consumeReady(proposalId: String, proposalHash: String, attemptId: UUID) -> Bool {
        withLock {
            guard case .ready(let registeredHash, let completedAttemptId) = entries[proposalId],
                  registeredHash == proposalHash,
                  completedAttemptId == attemptId else { return false }
            entries[proposalId] = .consumed(proposalHash: proposalHash)
            return true
        }
    }

    fileprivate func beginSubmission(proposalId: String, proposalHash: String) -> Bool {
        withLock {
            guard case .consumed(let registeredHash) = entries[proposalId],
                  registeredHash == proposalHash else { return false }
            entries[proposalId] = .submitting(proposalHash: proposalHash)
            return true
        }
    }

    fileprivate func revoke(proposalId: String) {
        withLock {
            entries[proposalId] = .revoked
        }
    }

    fileprivate func isReady(proposalId: String, proposalHash: String, attemptId: UUID) -> Bool {
        withLock {
            guard case .ready(let registeredHash, let completedAttemptId) = entries[proposalId] else { return false }
            return registeredHash == proposalHash && completedAttemptId == attemptId
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Deterministic confirmation state. It never performs a write. The only write request exposed to the host is
/// `ActionConfirmationIntent`, minted atomically by the coordinator-owned ledger after exact read-back.
public struct ProposalConfirmationGate: Equatable, Sendable {
    public private(set) var proposal: ActionProposal
    public private(set) var validation: ProposalValidationState
    public private(set) var readBack: ProposalReadBackState
    public private(set) var phase: ProposalConfirmationPhase

    private let ledger: ProposalConfirmationLedger

    public init(
        proposal: ActionProposal,
        validation: ProposalValidationState,
        ledger: ProposalConfirmationLedger,
        currentDate: Date
    ) {
        self.proposal = proposal
        self.validation = validation
        self.readBack = .notStarted
        self.ledger = ledger

        if !proposal.requiresConfirmation {
            self.phase = .invalidated(reason: "This proposal does not require the mandatory confirmation gate.")
            ledger.revoke(proposalId: proposal.id)
        } else if !proposal.isValidForConfirmation() {
            self.phase = .invalidated(reason: "Proposal content integrity validation failed.")
            ledger.revoke(proposalId: proposal.id)
        } else if !validation.matches(proposal, at: currentDate) {
            self.phase = .invalidated(reason: validation.failureReason ?? "Proposal authorization is invalid or expired.")
            ledger.revoke(proposalId: proposal.id)
        } else if !ledger.register(proposalId: proposal.id, proposalHash: proposal.proposalHash) {
            self.phase = .invalidated(reason: "This proposal confirmation was already consumed or revoked.")
        } else {
            self.phase = .awaitingReadBack
        }
    }

    @discardableResult
    public mutating func beginReadBack(
        for currentProposal: ActionProposal,
        at currentDate: Date
    ) -> ProposalReadBackAttempt? {
        guard isAuthorizedSnapshot(currentProposal, at: currentDate) else {
            invalidate(reason: "Proposal changed or authorization expired before read-back.")
            return nil
        }
        guard currentProposal.requiresConfirmation else {
            invalidate(reason: "Mandatory confirmation is missing.")
            return nil
        }
        switch phase {
        case .awaitingReadBack, .ready:
            break
        case .readingBack, .submitting, .consumed, .invalidated:
            return nil
        }

        let attempt = ProposalReadBackAttempt(proposal: currentProposal)
        guard ledger.beginReadBack(
            proposalId: currentProposal.id,
            proposalHash: currentProposal.proposalHash,
            attemptId: attempt.id
        ) else { return nil }
        readBack = .speaking(
            attemptId: attempt.id,
            proposalId: currentProposal.id,
            proposalHash: currentProposal.proposalHash
        )
        phase = .readingBack
        return attempt
    }

    @discardableResult
    public mutating func completeReadBack(
        _ attempt: ProposalReadBackAttempt,
        for currentProposal: ActionProposal,
        at currentDate: Date
    ) -> Bool {
        guard isAuthorizedSnapshot(currentProposal, at: currentDate),
              attempt.payload.proposal == currentProposal else {
            invalidate(reason: "Proposal changed or authorization expired during read-back. Review it again.")
            return false
        }
        guard case .speaking(let activeAttemptId, let proposalId, let proposalHash) = readBack,
              activeAttemptId == attempt.id,
              proposalId == currentProposal.id,
              proposalHash == currentProposal.proposalHash,
              ledger.completeReadBack(
                proposalId: proposalId,
                proposalHash: proposalHash,
                attemptId: attempt.id
              ) else {
            return false
        }

        readBack = .completed(
            attemptId: attempt.id,
            proposalId: proposalId,
            proposalHash: proposalHash
        )
        phase = .ready
        return true
    }

    public mutating func failReadBack(_ attempt: ProposalReadBackAttempt, message: String) {
        guard phase == .readingBack,
              case .speaking(let activeAttemptId, _, _) = readBack,
              activeAttemptId == attempt.id,
              ledger.failReadBack(
                proposalId: proposal.id,
                proposalHash: proposal.proposalHash,
                attemptId: attempt.id
              ) else { return }
        readBack = .failed(message: message)
        phase = .awaitingReadBack
    }

    /// Atomically mints at most one confirmation capability across all copies and reconstructions that share
    /// the coordinator ledger. Call this directly from the confirm gesture before starting asynchronous work.
    public func consume(
        currentProposal: ActionProposal,
        at currentDate: Date
    ) -> ActionConfirmationIntent? {
        guard canConfirm(currentProposal: currentProposal, at: currentDate),
              let authorization = validation.authorizationContext,
              case .completed(let attemptId, _, _) = readBack,
              ledger.consumeReady(
                proposalId: currentProposal.id,
                proposalHash: currentProposal.proposalHash,
                attemptId: attemptId
              ) else {
            return nil
        }

        return ActionConfirmationIntent(proposal: currentProposal, authorization: authorization)
    }

    /// Detects replacement or any field mutation and permanently revokes every copy of this proposal gate.
    public mutating func synchronize(
        currentProposal: ActionProposal,
        validation newValidation: ProposalValidationState,
        at currentDate: Date
    ) {
        guard currentProposal == proposal,
              newValidation == validation,
              newValidation.matches(currentProposal, at: currentDate) else {
            ledger.revoke(proposalId: proposal.id)
            proposal = currentProposal
            validation = newValidation
            readBack = .notStarted
            phase = .invalidated(reason: "Proposal changed or expired. Read-back and confirmation were invalidated.")
            return
        }
        validation = newValidation
    }

    @discardableResult
    public mutating func markSubmitting(_ intent: ActionConfirmationIntent, at currentDate: Date) -> Bool {
        guard phase == .ready,
              intent.proposal == proposal,
              intent.authorizationId == validation.authorizationId,
              intent.confirmationChallenge == validation.authorizationContext?.confirmationChallenge,
              validation.matches(proposal, at: currentDate),
              ledger.beginSubmission(proposalId: proposal.id, proposalHash: proposal.proposalHash) else { return false }
        phase = .submitting
        return true
    }

    public mutating func invalidate(reason: String) {
        ledger.revoke(proposalId: proposal.id)
        readBack = .notStarted
        phase = .invalidated(reason: reason)
    }

    public func canConfirm(
        currentProposal: ActionProposal,
        at currentDate: Date
    ) -> Bool {
        guard phase == .ready,
              case .completed(let attemptId, _, _) = readBack else { return false }
        return isAuthorizedSnapshot(currentProposal, at: currentDate)
            && readBack.completedExactly(currentProposal)
            && currentProposal.requiresConfirmation
            && ledger.isReady(
                proposalId: currentProposal.id,
                proposalHash: currentProposal.proposalHash,
                attemptId: attemptId
            )
    }

    private func isAuthorizedSnapshot(_ currentProposal: ActionProposal, at currentDate: Date) -> Bool {
        currentProposal == proposal
            && currentProposal.isValidForConfirmation()
            && validation.matches(currentProposal, at: currentDate)
    }
}
