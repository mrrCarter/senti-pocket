import XCTest
@testable import SentiPocketApp
import PocketContracts

/// Locks the durable-outbox crash-safety of the governed write (Atlas #22). A Carter-confirmed write must be
/// persisted BEFORE the send, so a crash / app-kill during the `.sending` window can't silently drop it — the exact
/// "in-memory only → lost on kill" gap OutboxStore exists to close, previously left open for the in-flight window
/// (OutboxStore.save fired only in the offline catches). Pairs with the gateway's (principal, proposal.id)
/// crash-recovery (relay-verified handlers.mjs L266/270/283): the SAME persisted proposal id is resent on restore, so
/// a restart-retry dedups server-side (idempotent replay / 409 reconcile) — never a double-post.
///
/// These do NOT re-assert the consent/honesty invariants (unchanged by this fix): never-auto-confirm, render-gate
/// (.sent only on a pin-verified signature), offline→pending. Only the persist TIMING moved.
@MainActor
final class PhoneWriteOutboxDurabilityTests: XCTestCase {

    override func setUp() { super.setUp(); OutboxStore.clear() }
    override func tearDown() { OutboxStore.clear(); super.tearDown() }

    /// A client pointed at an unroutable host — the send Task never lands (no token in test → execute() fails fast),
    /// which is all these tests need: they assert the SYNCHRONOUS persist, not the network outcome.
    private func makeClient() -> PocketWriteClient {
        PocketWriteClient(apiBaseURL: URL(string: "https://unit.invalid")!)
    }

    /// THE FIX: confirm() persists the intent synchronously (top of post(), before `state = .sending` and before the
    /// network Task can run — MainActor serialization guarantees the Task has NOT run before this synchronous read).
    /// So an app-kill in the `.sending` window finds the confirmed write in the durable outbox. Before the fix nothing
    /// was persisted until an offline error, leaving the in-flight window unprotected.
    func test_confirm_persists_the_intent_before_the_send() async {
        let vm = PhoneWriteViewModel(sessionId: "6cf7e861", client: makeClient())

        vm.draft("Merge now")
        XCTAssertNil(OutboxStore.load(), "draft() alone must not persist — nothing is confirmed yet")

        vm.confirm()
        let persisted = OutboxStore.load()
        XCTAssertNotNil(persisted, "confirm() must persist BEFORE the send — else a kill in .sending loses the write")
        XCTAssertEqual(persisted?.proposal.renderedPreview, "Merge now")
        XCTAssertEqual(persisted?.confirmation.proposalId, persisted?.proposal.id,
                       "the persisted confirmation must bind the persisted proposal's id")

        // Drain the in-flight send Task so it can't leak into another test; the synchronous assertions above already
        // captured the in-flight-window persistence (the Task holds `self` weakly and no-ops once vm deallocates).
        for _ in 0..<5 { await Task.yield() }
    }

    /// The RESTORE half of the guarantee: a persisted intent reloads as `.pending` on init with the SAME proposal id,
    /// so a restart-retry hits the gateway's (principal, proposal.id) crash-recovery instead of authoring a duplicate.
    /// Fully hermetic — init() does no network.
    func test_persisted_intent_restores_as_pending_with_the_same_proposal_id() {
        let proposal = PocketWriteClient.makeHumanMessageProposal(sessionId: "6cf7e861", message: "Wait for forge")
        let confirmation = GovernedWriteConfirmation(
            proposalId: proposal.id,
            confirmedProposalHash: proposal.proposalHash,
            confirmedAt: Date(timeIntervalSince1970: 1_784_000_000))
        OutboxStore.save(PersistedWriteIntent(proposal: proposal, confirmation: confirmation))

        let vm = PhoneWriteViewModel(sessionId: "6cf7e861", client: makeClient())
        guard case .pending(let message) = vm.state else {
            return XCTFail("a restored confirmed intent must surface as .pending")
        }
        XCTAssertTrue(message.contains("6cf7e861"), "pending UI must name the exact target session")
        XCTAssertEqual(OutboxStore.load()?.proposal.id, proposal.id,
                       "restore must preserve the proposal id — it is the key the gateway crash-recovery dedups on")
    }

    /// Hostile cross-session regression: selecting B must never make a persisted A intent retryable, overwritable,
    /// or clearable. This closes the global-outbox confused-deputy path found by independent review.
    func test_foreign_session_intent_is_blocked_and_preserved() {
        let proposal = PocketWriteClient.makeHumanMessageProposal(
            sessionId: "session-A",
            message: "Only session A may retry this",
            at: Date(timeIntervalSince1970: 1_784_000_000)
        )
        let confirmation = GovernedWriteConfirmation(
            proposalId: proposal.id,
            confirmedProposalHash: proposal.proposalHash,
            confirmedAt: Date(timeIntervalSince1970: 1_784_000_000)
        )
        let persisted = PersistedWriteIntent(proposal: proposal, confirmation: confirmation)
        OutboxStore.save(persisted)

        let sessionB = PhoneWriteViewModel(sessionId: "session-B", client: makeClient())
        XCTAssertEqual(sessionB.state, .blockedByPendingSession("session-A"))

        sessionB.retryPending()
        sessionB.draft("Attempt to overwrite A")
        sessionB.cancel()

        XCTAssertEqual(sessionB.state, .blockedByPendingSession("session-A"))
        XCTAssertEqual(OutboxStore.load(), persisted, "session B must not mutate session A's confirmed outbox")
    }

    func test_confirm_compare_and_set_cannot_overwrite_an_intent_claimed_after_view_model_init() {
        let sessionB = PhoneWriteViewModel(sessionId: "session-B", client: makeClient())
        let proposalA = PocketWriteClient.makeHumanMessageProposal(
            sessionId: "session-A",
            message: "A claimed the slot after B was composed",
            at: Date(timeIntervalSince1970: 1_784_000_000)
        )
        let confirmationA = GovernedWriteConfirmation(
            proposalId: proposalA.id,
            confirmedProposalHash: proposalA.proposalHash,
            confirmedAt: Date(timeIntervalSince1970: 1_784_000_001)
        )
        let intentA = PersistedWriteIntent(proposal: proposalA, confirmation: confirmationA)
        XCTAssertEqual(OutboxStore.claim(intentA), .claimed)

        sessionB.draft("B must not overwrite A")
        sessionB.confirm()

        XCTAssertEqual(sessionB.state, .blockedByPendingSession("session-A"))
        XCTAssertEqual(OutboxStore.load(), intentA)
    }

    func test_late_compare_and_clear_for_A_does_not_delete_B() {
        let proposalA = PocketWriteClient.makeHumanMessageProposal(
            sessionId: "session-A",
            message: "A",
            at: Date(timeIntervalSince1970: 1_784_000_000)
        )
        let intentA = PersistedWriteIntent(
            proposal: proposalA,
            confirmation: GovernedWriteConfirmation(
                proposalId: proposalA.id,
                confirmedProposalHash: proposalA.proposalHash,
                confirmedAt: Date(timeIntervalSince1970: 1_784_000_001)
            )
        )
        let proposalB = PocketWriteClient.makeHumanMessageProposal(
            sessionId: "session-B",
            message: "B",
            at: Date(timeIntervalSince1970: 1_784_000_002)
        )
        let intentB = PersistedWriteIntent(
            proposal: proposalB,
            confirmation: GovernedWriteConfirmation(
                proposalId: proposalB.id,
                confirmedProposalHash: proposalB.proposalHash,
                confirmedAt: Date(timeIntervalSince1970: 1_784_000_003)
            )
        )
        OutboxStore.save(intentB)

        OutboxStore.clear(matching: intentA)

        XCTAssertEqual(OutboxStore.load(), intentB)
    }

    func test_submillisecond_live_intent_owns_its_millisecond_roundtrip() {
        let proposal = PocketWriteClient.makeHumanMessageProposal(
            sessionId: "session-A",
            message: "Canonical durable identity",
            at: Date(timeIntervalSince1970: 1_784_000_000.000456)
        )
        let intent = PersistedWriteIntent(
            proposal: proposal,
            confirmation: GovernedWriteConfirmation(
                proposalId: proposal.id,
                confirmedProposalHash: proposal.proposalHash,
                confirmedAt: Date(timeIntervalSince1970: 1_784_000_001.000789)
            )
        )
        OutboxStore.save(intent)

        XCTAssertNotEqual(OutboxStore.load(), intent,
                          "precondition: disk normalization intentionally drops sub-millisecond Date precision")
        XCTAssertEqual(OutboxStore.claim(intent), .claimed,
                       "canonical durable equality must recognize the live intent as the existing owner")

        OutboxStore.clear(matching: intent)

        XCTAssertNil(OutboxStore.load(), "the live intent must be able to clear its own normalized durable slot")
    }

    func test_tampered_persisted_confirmation_is_never_restored() {
        let proposal = PocketWriteClient.makeHumanMessageProposal(
            sessionId: "session-A",
            message: "Original content"
        )
        let mismatched = GovernedWriteConfirmation(
            proposalId: "different-proposal",
            confirmedProposalHash: proposal.proposalHash,
            confirmedAt: Date(timeIntervalSince1970: 1_784_000_000)
        )
        OutboxStore.save(PersistedWriteIntent(proposal: proposal, confirmation: mismatched))

        let vm = PhoneWriteViewModel(sessionId: "session-A", client: makeClient())

        guard case .refused(let message) = vm.state else {
            return XCTFail("a tampered outbox must fail closed")
        }
        XCTAssertTrue(message.contains("integrity"))
        XCTAssertNil(OutboxStore.load(), "a structurally invalid local intent must never remain retryable")
    }

    /// Regression for the moved persist: a cancelled decision must still leave NOTHING queued. cancel() after the
    /// confirm-time persist must clear the durable outbox.
    func test_cancel_after_confirm_clears_the_durable_outbox() async {
        let vm = PhoneWriteViewModel(sessionId: "6cf7e861", client: makeClient())
        vm.draft("Split the PR")
        vm.confirm()
        XCTAssertNotNil(OutboxStore.load(), "precondition: confirm() persisted the intent")

        vm.cancel()
        XCTAssertNil(OutboxStore.load(), "cancel() must clear the durable outbox — a cancelled decision queues nothing")

        for _ in 0..<5 { await Task.yield() }
    }
}
