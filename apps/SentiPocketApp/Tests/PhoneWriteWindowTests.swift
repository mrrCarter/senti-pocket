import XCTest
@testable import SentiPocketApp
import PocketContracts

/// The WRITE-WINDOW invariants (spec C): a dial hangup must never fake "nothing posted", never erase another
/// proposal, and never surface a torn-down write as a durable .pending.
///  • OutboxStore clears STRICTLY by proposal id + serializes a second owner (one global slot).
///  • cancelIfUnsubmitted() cancels ONLY a pre-submit draft; an authorized in-flight write is RETAINED.
///  • PocketWriteClient keeps URLError.cancelled DISTINCT from .network (a pre-cancelled write makes ZERO requests).
@MainActor
final class PhoneWriteWindowTests: XCTestCase {

    override func setUp() { super.setUp(); OutboxStore.clear() }
    override func tearDown() { OutboxStore.clear(); super.tearDown() }

    private func makeClient() -> PocketWriteClient {
        PocketWriteClient(apiBaseURL: URL(string: "https://unit.invalid")!)
    }
    private func intent(_ message: String) -> PersistedWriteIntent {
        let p = PocketWriteClient.makeHumanMessageProposal(sessionId: "6cf7e861", message: message)
        let c = GovernedWriteConfirmation(proposalId: p.id, confirmedProposalHash: p.proposalHash,
                                          confirmedAt: Date(timeIntervalSince1970: 1_784_000_000))
        return PersistedWriteIntent(proposal: p, confirmation: c)
    }

    // MARK: - OutboxStore single-slot discipline

    func test_clear_by_id_does_not_erase_a_foreign_proposal() {
        let a = intent("A")
        XCTAssertTrue(OutboxStore.save(a))
        OutboxStore.clear(proposalId: "some-other-id")
        XCTAssertEqual(OutboxStore.load()?.proposal.id, a.proposal.id, "clear by a foreign id must NOT erase A")
        OutboxStore.clear(proposalId: a.proposal.id)
        XCTAssertNil(OutboxStore.load(), "clear by A's own id removes A")
    }

    func test_save_serializes_a_second_owner() {
        let a = intent("A"), b = intent("B")
        XCTAssertNotEqual(a.proposal.id, b.proposal.id)
        XCTAssertTrue(OutboxStore.save(a))
        XCTAssertFalse(OutboxStore.save(b), "a DIFFERENT confirmed write must not clobber the slot")
        XCTAssertEqual(OutboxStore.load()?.proposal.id, a.proposal.id)
        XCTAssertTrue(OutboxStore.save(a), "re-saving the SAME proposal id is allowed (idempotent)")
    }

    // MARK: - Authorization-aware teardown

    // An AUTHORIZED in-flight write, torn down by a hangup, retains EXACTLY ONE reconcilable proposal (not erased).
    func test_cancelIfUnsubmitted_retains_an_authorized_in_flight_write() async {
        let vm = PhoneWriteViewModel(sessionId: "6cf7e861", client: makeClient())
        vm.draft("Rotate the token")
        vm.confirm()                                  // authorized → .sending, the confirmed intent is persisted
        let saved = OutboxStore.load()
        XCTAssertNotNil(saved, "precondition: confirm persisted the intent")

        vm.cancelIfUnsubmitted()                      // a hangup AFTER authorization must not erase the attempt
        XCTAssertEqual(OutboxStore.load()?.proposal.id, saved?.proposal.id,
                       "an authorized in-flight write is RETAINED (exactly one reconcilable proposal)")

        for _ in 0..<6 { await Task.yield() }         // drain the send Task (no token → refused; clears its OWN id)
    }

    // A PRE-SUBMIT draft torn down by a hangup is cancelled → composing, nothing queued.
    func test_cancelIfUnsubmitted_cancels_a_presubmit_draft() {
        let vm = PhoneWriteViewModel(sessionId: "6cf7e861", client: makeClient())
        vm.draft("Split the PR")                      // .confirming — nothing authorized/persisted
        XCTAssertNil(OutboxStore.load())
        vm.cancelIfUnsubmitted()
        guard case .composing = vm.state else { return XCTFail("a pre-submit draft must cancel → composing") }
        XCTAssertNil(OutboxStore.load())
    }

    // A dial hangup tearing down ITS OWN pre-submit draft must NEVER erase an UNRELATED earlier confirmed pending write.
    func test_presubmit_draft_cancel_does_not_erase_a_foreign_pending_write() {
        let a = intent("A — an earlier confirmed pending write")
        OutboxStore.save(a)                           // A owns the single durable slot

        let vm = PhoneWriteViewModel(sessionId: "6cf7e861", client: makeClient())   // init restores A as .pending
        vm.draft("B — the dial's fresh draft")        // arms a DIFFERENT proposal (nothing persisted for B)
        vm.cancelIfUnsubmitted()                       // hangup teardown of B's draft
        XCTAssertEqual(OutboxStore.load()?.proposal.id, a.proposal.id,
                       "a dial hangup must NEVER erase an unrelated earlier confirmed pending write")
    }

    // MARK: - PocketWriteClient cancellation mapping

    /// Counts every request the session tries to handle (canInit) — proves a pre-cancelled execute() issues ZERO.
    final class RequestCountingProtocol: URLProtocol {
        static var count = 0
        static func reset() { count = 0 }
        override class func canInit(with request: URLRequest) -> Bool { count += 1; return false }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {}
        override func stopLoading() {}
    }

    func test_pre_cancelled_execute_makes_zero_requests_and_stays_cancellation() async {
        RequestCountingProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RequestCountingProtocol.self]
        let session = URLSession(configuration: config)
        let client = PocketWriteClient(apiBaseURL: URL(string: "https://unit.invalid")!, urlSession: session)
        let p = PocketWriteClient.makeHumanMessageProposal(sessionId: "6cf7e861", message: "hi")
        let c = GovernedWriteConfirmation(proposalId: p.id, confirmedProposalHash: p.proposalHash, confirmedAt: Date())

        let task = Task { () -> Error? in
            while !Task.isCancelled { await Task.yield() }        // run execute() only AFTER cancellation lands
            do { _ = try await client.execute(proposal: p, confirmation: c); return nil }
            catch { return error }
        }
        task.cancel()
        let err = await task.value

        XCTAssertEqual(err as? PocketWriteError, .cancelled,
                       "a pre-cancelled write stays a cancellation — NOT .network (which the VM maps to a durable .pending)")
        XCTAssertEqual(RequestCountingProtocol.count, 0, "a pre-cancelled write issues ZERO URL requests")
    }
}
