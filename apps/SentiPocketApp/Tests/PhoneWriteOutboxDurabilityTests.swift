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
        guard case .pending = vm.state else { return XCTFail("a restored confirmed intent must surface as .pending") }
        XCTAssertEqual(OutboxStore.load()?.proposal.id, proposal.id,
                       "restore must preserve the proposal id — it is the key the gateway crash-recovery dedups on")
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
