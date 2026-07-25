import Foundation
import XCTest
import PocketContracts
@testable import PocketUI

#if canImport(CryptoKit)
final class ProposalConfirmationGateTests: XCTestCase {
    func testReadBackIsRequiredBeforeConfirmation() {
        let proposal = PocketUITestFactory.proposal()
        let gate = makeGate(proposal: proposal)

        XCTAssertFalse(gate.canConfirm(currentProposal: proposal, at: now))
        XCTAssertNil(gate.consume(currentProposal: proposal, at: now))
        XCTAssertEqual(gate.phase, .awaitingReadBack)
    }

    func testCompletedExactReadBackAllowsOnlyOneConsumption() throws {
        let proposal = PocketUITestFactory.proposal()
        var gate = makeGate(proposal: proposal)
        let attempt = try XCTUnwrap(gate.beginReadBack(for: proposal, at: now))

        XCTAssertTrue(gate.completeReadBack(attempt, for: proposal, at: now))
        XCTAssertTrue(gate.canConfirm(currentProposal: proposal, at: now))

        let intent = try XCTUnwrap(gate.consume(currentProposal: proposal, at: now))
        XCTAssertEqual(intent.proposal, proposal)
        XCTAssertEqual(intent.proposalHash, proposal.proposalHash)
        XCTAssertEqual(intent.confirmationChallenge, "challenge-\(proposal.id)")
        XCTAssertFalse(gate.canConfirm(currentProposal: proposal, at: now))
        XCTAssertNil(gate.consume(currentProposal: proposal, at: now), "confirmation must be single-use")

        XCTAssertTrue(gate.markSubmitting(intent, at: now))
        XCTAssertEqual(gate.phase, .submitting)
        XCTAssertFalse(gate.markSubmitting(intent, at: now), "submission transition must be single-use")
    }

    func testCopiedReadyGatesShareAtomicSingleUseLedger() throws {
        let proposal = PocketUITestFactory.proposal()
        let original = try readyGate(for: proposal)
        let firstCopy = original
        let secondCopy = original

        XCTAssertNotNil(firstCopy.consume(currentProposal: proposal, at: now))
        XCTAssertNil(secondCopy.consume(currentProposal: proposal, at: now))
        XCTAssertFalse(original.canConfirm(currentProposal: proposal, at: now))
    }

    func testConcurrentConfirmGesturesMintExactlyOneIntent() throws {
        let proposal = PocketUITestFactory.proposal()
        let gate = try readyGate(for: proposal)
        let counter = ThreadSafeIntentCounter()
        let currentDate = now

        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            if gate.consume(currentProposal: proposal, at: currentDate) != nil {
                counter.increment()
            }
        }

        XCTAssertEqual(counter.value, 1)
    }

    func testCopiedGatesShareOneAuthoritativeReadBackAttempt() {
        let proposal = PocketUITestFactory.proposal()
        let original = makeGate(proposal: proposal)
        let boxes = (0..<32).map { _ in ThreadSafeGateBox(gate: original) }
        let counter = ThreadSafeIntentCounter()
        let currentDate = now

        DispatchQueue.concurrentPerform(iterations: boxes.count) { index in
            if boxes[index].beginReadBack(for: proposal, at: currentDate) != nil {
                counter.increment()
            }
        }

        XCTAssertEqual(counter.value, 1, "copied gates must not start overlapping authoritative read-backs")
    }

    func testCopiedReadyGatesShareOneAtomicSubmissionTransition() throws {
        let proposal = PocketUITestFactory.proposal()
        var ready = try readyGate(for: proposal)
        let boxes = (0..<32).map { _ in ThreadSafeGateBox(gate: ready) }
        let intent = try XCTUnwrap(ready.consume(currentProposal: proposal, at: now))
        let counter = ThreadSafeIntentCounter()
        let currentDate = now

        DispatchQueue.concurrentPerform(iterations: boxes.count) { index in
            if boxes[index].markSubmitting(intent, at: currentDate) {
                counter.increment()
            }
        }

        XCTAssertEqual(counter.value, 1, "only one copied gate may begin governed submission")
    }

    func testReconstructedOrExpiredGateCannotBeginSubmission() throws {
        let proposal = PocketUITestFactory.proposal()
        let ledger = ProposalConfirmationLedger()
        let expiresAt = now.addingTimeInterval(10)
        var original = makeGate(proposal: proposal, ledger: ledger, validUntil: expiresAt)
        let attempt = try XCTUnwrap(original.beginReadBack(for: proposal, at: now))
        XCTAssertTrue(original.completeReadBack(attempt, for: proposal, at: now))
        let intent = try XCTUnwrap(original.consume(currentProposal: proposal, at: now))

        var reconstructed = makeGate(proposal: proposal, ledger: ledger, validUntil: expiresAt)
        XCTAssertFalse(reconstructed.markSubmitting(intent, at: now))
        XCTAssertFalse(original.markSubmitting(intent, at: expiresAt))
    }

    func testReconstructedGateCannotReplayConsumedProposal() throws {
        let proposal = PocketUITestFactory.proposal()
        let ledger = ProposalConfirmationLedger()
        let original = try readyGate(for: proposal, ledger: ledger)
        XCTAssertNotNil(original.consume(currentProposal: proposal, at: now))

        let reconstructed = makeGate(proposal: proposal, ledger: ledger)
        guard case .invalidated = reconstructed.phase else {
            return XCTFail("A reconstructed gate must preserve consumption")
        }
        XCTAssertNil(reconstructed.consume(currentProposal: proposal, at: now))
    }

    func testPersistedConsumptionSeedPreventsReplayAfterLedgerRecreation() {
        let proposal = PocketUITestFactory.proposal()
        let recreatedLedger = ProposalConfirmationLedger(consumedConfirmations: [
            ConsumedProposalConfirmation(
                proposalId: proposal.id,
                proposalHash: proposal.proposalHash
            )
        ])

        let reconstructed = makeGate(proposal: proposal, ledger: recreatedLedger)

        guard case .invalidated = reconstructed.phase else {
            return XCTFail("Persisted consumption must survive ledger recreation")
        }
        XCTAssertNil(reconstructed.consume(currentProposal: proposal, at: now))
    }

    func testInvalidatingOneCopyRevokesEveryCopy() throws {
        let proposal = PocketUITestFactory.proposal()
        let ready = try readyGate(for: proposal)
        var invalidatingCopy = ready
        invalidatingCopy.invalidate(reason: "checkpoint changed")

        XCTAssertNil(ready.consume(currentProposal: proposal, at: now))
    }

    func testReplacementRevokesOldProposalButAllowsFreshReplacementGate() throws {
        let original = PocketUITestFactory.proposal()
        let replacement = PocketUITestFactory.proposal(id: "proposal-2", message: "Fresh action")
        let ledger = ProposalConfirmationLedger()
        var oldGate = try readyGate(for: original, ledger: ledger)

        oldGate.synchronize(
            currentProposal: replacement,
            validation: validation(for: replacement),
            at: now
        )
        let freshGate = makeGate(proposal: replacement, ledger: ledger)

        guard case .invalidated = oldGate.phase else {
            return XCTFail("The old gate must stay invalidated")
        }
        XCTAssertEqual(freshGate.phase, .awaitingReadBack)
    }

    func testEveryProposalMutationInvalidatesCompletedReadBack() throws {
        let original = PocketUITestFactory.proposal()
        let variants = [
            PocketUITestFactory.proposal(id: "proposal-2"),
            PocketUITestFactory.proposal(kind: .opinionRequest),
            PocketUITestFactory.proposal(sessionId: "wrong-session"),
            PocketUITestFactory.proposal(sequence: 230181),
            PocketUITestFactory.proposal(message: "Different full message"),
            PocketUITestFactory.proposal(requiresConfirmation: false),
            PocketUITestFactory.proposal(createdAt: PocketUITestFactory.date.addingTimeInterval(1)),
            PocketUITestFactory.proposal(sourceQuestionId: "question-2"),
            PocketUITestFactory.proposal(proposalHash: "hash.changed")
        ]

        for variant in variants {
            var gate = try readyGate(for: original)
            gate.synchronize(
                currentProposal: variant,
                validation: validation(for: variant),
                at: now
            )
            XCTAssertFalse(gate.canConfirm(currentProposal: variant, at: now), "variant should invalidate: \(variant)")
            XCTAssertNil(gate.consume(currentProposal: variant, at: now))
            guard case .invalidated = gate.phase else {
                return XCTFail("Expected invalidated phase for variant: \(variant)")
            }
            XCTAssertNil(gate.beginReadBack(for: variant, at: now), "invalidated gate must not be reusable")
        }
    }

    func testChangedProposalDuringReadBackFailsClosed() throws {
        let original = PocketUITestFactory.proposal()
        let changed = PocketUITestFactory.proposal(message: "Changed during speech")
        var gate = makeGate(proposal: original)
        let attempt = try XCTUnwrap(gate.beginReadBack(for: original, at: now))

        XCTAssertFalse(gate.completeReadBack(attempt, for: changed, at: now))
        XCTAssertFalse(gate.canConfirm(currentProposal: changed, at: now))
        guard case .invalidated = gate.phase else {
            return XCTFail("Expected invalidated phase")
        }
    }

    func testReadBackAttemptRejectsOverlapAndStaleCompletion() throws {
        let proposal = PocketUITestFactory.proposal()
        var gate = makeGate(proposal: proposal)
        let first = try XCTUnwrap(gate.beginReadBack(for: proposal, at: now))
        XCTAssertNil(gate.beginReadBack(for: proposal, at: now), "overlapping playback must not start")

        gate.failReadBack(first, message: "Audio route changed")
        let second = try XCTUnwrap(gate.beginReadBack(for: proposal, at: now))
        XCTAssertFalse(gate.completeReadBack(first, for: proposal, at: now), "stale callback must not arm the gate")
        XCTAssertTrue(gate.completeReadBack(second, for: proposal, at: now))
    }

    func testFailedReadBackNeverEnablesConfirmationAndCanRetry() throws {
        let proposal = PocketUITestFactory.proposal()
        var gate = makeGate(proposal: proposal)
        let attempt = try XCTUnwrap(gate.beginReadBack(for: proposal, at: now))

        gate.failReadBack(attempt, message: "Audio route changed")
        XCTAssertFalse(gate.canConfirm(currentProposal: proposal, at: now))
        XCTAssertEqual(gate.readBack, .failed(message: "Audio route changed"))
        XCTAssertNotNil(gate.beginReadBack(for: proposal, at: now))
    }

    func testAuthorizationBindsExpectedTargetAndFreshness() {
        let proposal = PocketUITestFactory.proposal()
        let wrongSession = ProposalValidationState.authorize(
            proposal,
            context: context(
                for: proposal,
                expectedSessionId: "not-the-checkpoint-session"
            )
        )
        let wrongSequence = ProposalValidationState.authorize(
            proposal,
            context: context(for: proposal, expectedSequence: proposal.targetSequence + 1)
        )
        let expired = ProposalValidationState.authorize(
            proposal,
            context: context(for: proposal, validUntil: now)
        )
        let staleProposal = ProposalValidationState.authorize(
            proposal,
            context: context(
                for: proposal,
                oldestAllowedProposalDate: proposal.createdAt.addingTimeInterval(1)
            )
        )
        let notYetActive = ProposalValidationState.authorize(
            proposal,
            context: context(
                for: proposal,
                evaluatedAt: now.addingTimeInterval(60)
            )
        )
        let excessiveLifetime = ProposalValidationState.authorize(
            proposal,
            context: context(
                for: proposal,
                validUntil: now.addingTimeInterval(ProposalAuthorizationContext.maximumLifetime + 1)
            )
        )
        let missingChallenge = ProposalValidationState.authorize(
            proposal,
            context: context(for: proposal, confirmationChallenge: "")
        )
        let unboundedChallenge = ProposalValidationState.authorize(
            proposal,
            context: context(
                for: proposal,
                confirmationChallenge: String(
                    repeating: "x",
                    count: ProposalAuthorizationContext.maximumChallengeUTF8Length + 1
                )
            )
        )

        for validation in [
            wrongSession,
            wrongSequence,
            expired,
            staleProposal,
            notYetActive,
            excessiveLifetime,
            missingChallenge,
            unboundedChallenge
        ] {
            let gate = ProposalConfirmationGate(
                proposal: proposal,
                validation: validation,
                ledger: ProposalConfirmationLedger(),
                currentDate: now
            )
            guard case .invalidated = gate.phase else {
                return XCTFail("Unauthorized or stale target must fail closed")
            }
        }
    }

    func testAuthorizationExpiryAfterReadBackPreventsConfirmation() throws {
        let proposal = PocketUITestFactory.proposal()
        let expiresAt = now.addingTimeInterval(10)
        var gate = makeGate(proposal: proposal, validUntil: expiresAt)
        let attempt = try XCTUnwrap(gate.beginReadBack(for: proposal, at: now))
        XCTAssertTrue(gate.completeReadBack(attempt, for: proposal, at: now))

        XCTAssertNil(gate.consume(currentProposal: proposal, at: expiresAt))
    }

    func testFreshAuthorizationCannotReuseCompletedReadBack() throws {
        let proposal = PocketUITestFactory.proposal()
        var gate = try readyGate(for: proposal)
        let refreshedContext = ProposalAuthorizationContext(
            id: "refreshed-authorization",
            confirmationChallenge: "refreshed-challenge",
            expectedTargetSessionId: proposal.targetSessionId,
            expectedTargetSequence: proposal.targetSequence,
            oldestAllowedProposalDate: proposal.createdAt,
            evaluatedAt: now,
            validUntil: now.addingTimeInterval(240)
        )

        gate.synchronize(
            currentProposal: proposal,
            validation: .authorize(proposal, context: refreshedContext),
            at: now
        )

        guard case .invalidated = gate.phase else {
            return XCTFail("A replacement authorization must require a fresh gate and read-back")
        }
        XCTAssertNil(gate.consume(currentProposal: proposal, at: now))
    }

    func testChallengeReplacementCannotReuseCompletedReadBack() throws {
        let proposal = PocketUITestFactory.proposal()
        var gate = try readyGate(for: proposal)
        let replacement = context(for: proposal, confirmationChallenge: "replacement-challenge")

        gate.synchronize(
            currentProposal: proposal,
            validation: .authorize(proposal, context: replacement),
            at: now
        )

        guard case .invalidated = gate.phase else {
            return XCTFail("A replacement episode challenge must require a fresh gate and read-back")
        }
        XCTAssertNil(gate.consume(currentProposal: proposal, at: now))
    }

    func testOptionalProvenanceAndSubMillisecondDateChangesInvalidateReadBack() throws {
        let nilSource = PocketUITestFactory.proposal(sourceQuestionId: nil)
        let emptySource = PocketUITestFactory.proposal(sourceQuestionId: "")
        var provenanceGate = try readyGate(for: nilSource)
        let provenanceValidation = provenanceGate.validation
        provenanceGate.synchronize(
            currentProposal: emptySource,
            validation: provenanceValidation,
            at: now
        )
        guard case .invalidated = provenanceGate.phase else {
            return XCTFail("Optional provenance mutation must invalidate the UI gate")
        }

        let originalDate = PocketUITestFactory.proposal(createdAt: now)
        let subMillisecondDate = PocketUITestFactory.proposal(createdAt: now.addingTimeInterval(0.000_1))
        var dateGate = try readyGate(for: originalDate)
        let dateValidation = dateGate.validation
        dateGate.synchronize(
            currentProposal: subMillisecondDate,
            validation: dateValidation,
            at: now
        )
        guard case .invalidated = dateGate.phase else {
            return XCTFail("Sub-millisecond date mutation must invalidate the UI gate")
        }
    }

    func testRequiresConfirmationFalseIsNeverActionable() {
        let proposal = PocketUITestFactory.proposal(requiresConfirmation: false)
        var gate = makeGate(proposal: proposal)

        XCTAssertNil(gate.beginReadBack(for: proposal, at: now))
        XCTAssertNil(gate.consume(currentProposal: proposal, at: now))
        guard case .invalidated = gate.phase else {
            return XCTFail("Expected invalidated phase")
        }
    }

    func testInvalidDeterministicValidationFailsClosed() {
        let proposal = PocketUITestFactory.proposal()
        var gate = ProposalConfirmationGate(
            proposal: proposal,
            validation: .invalid(reason: "wrong session"),
            ledger: ProposalConfirmationLedger(),
            currentDate: now
        )

        XCTAssertNil(gate.beginReadBack(for: proposal, at: now))
        XCTAssertNil(gate.consume(currentProposal: proposal, at: now))
    }

    func testReadBackPayloadPreservesExactValuesAndMessageBytes() {
        let message = "@atlas **do not parse**\n  Keep leading spaces | “Unicode” e\u{301}"
        let proposal = PocketUITestFactory.proposal(
            kind: .opinionRequest,
            sessionId: "session|exact",
            sequence: 42,
            message: message
        )
        let payload = ProposalReadBackPayload(proposal: proposal)

        XCTAssertEqual(payload.kind, .opinionRequest)
        XCTAssertEqual(payload.targetSessionId, "session|exact")
        XCTAssertEqual(payload.targetSequence, 42)
        XCTAssertEqual(payload.fullMessageText, message)
        XCTAssertTrue(payload.spokenText.hasSuffix(message))
    }

    private var now: Date { PocketUITestFactory.date }

    private func context(
        for proposal: ActionProposal,
        confirmationChallenge: String? = nil,
        expectedSessionId: String? = nil,
        expectedSequence: Int? = nil,
        oldestAllowedProposalDate: Date? = nil,
        evaluatedAt: Date? = nil,
        validUntil: Date? = nil
    ) -> ProposalAuthorizationContext {
        let evaluationDate = evaluatedAt ?? now
        return ProposalAuthorizationContext(
            id: "authorization-\(proposal.id)",
            confirmationChallenge: confirmationChallenge ?? "challenge-\(proposal.id)",
            expectedTargetSessionId: expectedSessionId ?? proposal.targetSessionId,
            expectedTargetSequence: expectedSequence ?? proposal.targetSequence,
            oldestAllowedProposalDate: oldestAllowedProposalDate ?? proposal.createdAt,
            evaluatedAt: evaluationDate,
            validUntil: validUntil ?? evaluationDate.addingTimeInterval(300)
        )
    }

    private func validation(
        for proposal: ActionProposal,
        validUntil: Date? = nil
    ) -> ProposalValidationState {
        .authorize(proposal, context: context(for: proposal, validUntil: validUntil))
    }

    private func makeGate(
        proposal: ActionProposal,
        ledger: ProposalConfirmationLedger = ProposalConfirmationLedger(),
        validUntil: Date? = nil
    ) -> ProposalConfirmationGate {
        ProposalConfirmationGate(
            proposal: proposal,
            validation: validation(for: proposal, validUntil: validUntil),
            ledger: ledger,
            currentDate: now
        )
    }

    private func readyGate(
        for proposal: ActionProposal,
        ledger: ProposalConfirmationLedger = ProposalConfirmationLedger()
    ) throws -> ProposalConfirmationGate {
        var gate = makeGate(proposal: proposal, ledger: ledger)
        let attempt = try XCTUnwrap(gate.beginReadBack(for: proposal, at: now))
        XCTAssertTrue(gate.completeReadBack(attempt, for: proposal, at: now))
        return gate
    }
}

private final class ThreadSafeIntentCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private final class ThreadSafeGateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var gate: ProposalConfirmationGate

    init(gate: ProposalConfirmationGate) {
        self.gate = gate
    }

    func beginReadBack(for proposal: ActionProposal, at date: Date) -> ProposalReadBackAttempt? {
        lock.lock()
        defer { lock.unlock() }
        return gate.beginReadBack(for: proposal, at: date)
    }

    func markSubmitting(_ intent: ActionConfirmationIntent, at date: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return gate.markSubmitting(intent, at: date)
    }
}
#endif
