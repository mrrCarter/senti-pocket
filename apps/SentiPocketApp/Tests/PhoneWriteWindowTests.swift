import XCTest
@testable import SentiPocketApp
import PocketContracts
import PocketCall   // DialWriteResult (the adapter's result type, for the bounded-await helper)

/// The WRITE-WINDOW invariants (spec C + Pulse issue 4): a dial hangup must never fake "nothing posted", never erase
/// another proposal, and never surface a torn-down write as a durable .pending; and a write requires DURABLE ownership
/// before any network. Hermetic: OutboxStore's storage seam is swapped to an in-memory double per test.
@MainActor
final class PhoneWriteWindowTests: XCTestCase {

    /// In-memory OutboxStore storage — hermetic, no filesystem.
    final class InMemoryOutboxStorage: OutboxStorage {
        private var data: Data?
        func write(_ d: Data) -> Bool { data = d; return true }
        func read() -> Data? { data }
        func remove() { data = nil }
    }
    /// A storage whose persist ALWAYS fails — proves save() claims no ownership + the caller does not POST.
    final class FailingOutboxStorage: OutboxStorage {
        func write(_ d: Data) -> Bool { false }
        func read() -> Data? { nil }
        func remove() {}
    }
    /// In-memory storage that COUNTS write() calls — proves a nil-gateway confirm attempts NO durable write.
    final class SpyOutboxStorage: OutboxStorage {
        private var data: Data?
        private(set) var writeCount = 0
        func write(_ d: Data) -> Bool { writeCount += 1; data = d; return true }
        func read() -> Data? { data }
        func remove() { data = nil }
    }

    override func setUp() {
        super.setUp()
        OutboxStore.storage = InMemoryOutboxStorage()
        OutboxStore.clear()
        SessionTokenStore.delete()
    }
    override func tearDown() {
        OutboxStore.clear()
        OutboxStore.storage = FileOutboxStorage()   // restore the production default for other suites
        SessionTokenStore.delete()
        super.tearDown()
    }

    private func makeClient() -> PocketWriteClient {
        PocketWriteClient(apiBaseURL: URL(string: "https://unit.invalid")!)
    }
    private func intent(_ message: String) -> PersistedWriteIntent {
        let p = PocketWriteClient.makeHumanMessageProposal(sessionId: "6cf7e861", message: message)
        let c = GovernedWriteConfirmation(proposalId: p.id, confirmedProposalHash: p.proposalHash,
                                          confirmedAt: Date(timeIntervalSince1970: 1_784_000_000))
        return PersistedWriteIntent(proposal: p, confirmation: c)
    }
    /// Bounded spin with a WALL-CLOCK deadline (P2: never an unbounded yield-loop; fails fast if the condition stalls).
    private func spin(_ cond: @escaping () -> Bool, _ msg: String = "condition never held",
                      timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return }
            await Task.yield()
        }
        XCTFail("spin timed out after \(timeout)s: \(msg)", file: file, line: line)
    }

    final class Box<T>: @unchecked Sendable { var value: T? }
    /// BOUNDED await (Pulse round-8 P2.1): await a task's value with a hard timeout via an XCTestExpectation, so a true
    /// regression FAILS the test (unfulfilled expectation) instead of HANGING on `await task.value`. Returns nil on timeout.
    private func awaitBounded<T>(_ task: Task<T, Never>, timeout: TimeInterval = 5,
                                 _ msg: String = "task did not complete in time") async -> T? {
        let box = Box<T>()
        let exp = expectation(description: msg)
        let waiter = Task { box.value = await task.value; exp.fulfill() }
        defer { waiter.cancel() }   // P2: don't leave the waiter awaiting after we return (best-effort)
        await fulfillment(of: [exp], timeout: timeout)
        return box.value
    }

    /// Counts every request the session tries to handle (canInit) — proves ZERO POST.
    final class RequestCountingProtocol: URLProtocol {
        static var count = 0
        static func reset() { count = 0 }
        override class func canInit(with request: URLRequest) -> Bool { count += 1; return false }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {}
        override func stopLoading() {}
    }
    /// Fails every request with URLError.cancelled — simulates an interrupted in-flight POST.
    final class CancellingProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.cancelled)) }
        override func stopLoading() {}
    }
    /// BLOCKS an in-flight request until `release()`, then fails it cancelled — so a POST can be held mid-flight while a
    /// hangup cancels the adapter/orchestrator observer.
    final class BlockingProtocol: URLProtocol {
        static let lock = NSLock()
        private static var _started = false
        private static var _released = false
        static func reset() { lock.lock(); _started = false; _released = false; lock.unlock() }
        static var started: Bool { lock.lock(); defer { lock.unlock() }; return _started }
        static func release() { lock.lock(); _released = true; lock.unlock() }
        override class func canInit(with r: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
        override func startLoading() {
            Self.lock.lock(); Self._started = true; Self.lock.unlock()
            let deadline = Date().addingTimeInterval(30)   // P2: HARD deadline — never block a URLSession thread forever
            while Date() < deadline {
                Self.lock.lock(); let r = Self._released; Self.lock.unlock()
                if r { break }
                Thread.sleep(forTimeInterval: 0.005)
            }
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
        }
        override func stopLoading() { Self.release() }   // P2: if the session cancels the request, unblock startLoading
    }
    private func blockingClient() -> PocketWriteClient {
        BlockingProtocol.reset()
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [BlockingProtocol.self]
        return PocketWriteClient(apiBaseURL: URL(string: "https://unit.invalid")!,
                                 urlSession: URLSession(configuration: cfg), tokenProvider: { "demo-token" })
    }
    private func countingClient() -> (PocketWriteClient, () -> Int) {
        RequestCountingProtocol.reset()
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [RequestCountingProtocol.self]
        // Inject a token so ONLY the save/cancel gates (not notLoggedIn) can stop the POST — hermetic (no Keychain).
        let client = PocketWriteClient(apiBaseURL: URL(string: "https://unit.invalid")!,
                                       urlSession: URLSession(configuration: cfg), tokenProvider: { "demo-token" })
        return (client, { RequestCountingProtocol.count })
    }
    /// A client whose in-flight POST fails with URLError.cancelled (a token injected, no Keychain) — for the reconciling path.
    private func cancellingClient() -> PocketWriteClient {
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [CancellingProtocol.self]
        return PocketWriteClient(apiBaseURL: URL(string: "https://unit.invalid")!,
                                 urlSession: URLSession(configuration: cfg), tokenProvider: { "demo-token" })
    }

    // MARK: - OutboxStore single-slot discipline + durable ownership

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

    // A FAILED persist must claim no durable ownership (save == false).
    func test_save_returns_false_when_persistence_fails() {
        OutboxStore.storage = FailingOutboxStorage()
        XCTAssertFalse(OutboxStore.save(intent("A")), "a failed persist must NOT claim ownership")
        XCTAssertNil(OutboxStore.load())
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

    // MARK: - Durable ownership BEFORE any network (Pulse issue 4a/4b)

    // Submitting B while a DIFFERENT confirmed write A owns the outbox → honor save()==false → ZERO POST, A intact.
    func test_submit_while_a_foreign_write_owns_the_outbox_does_not_post_and_keeps_it() async {
        OutboxStore.save(intent("A owns the slot"))
        let aId = OutboxStore.load()!.proposal.id
        let (client, requests) = countingClient()     // token injected — so ONLY the durable-ownership gate can stop the POST

        let vm = PhoneWriteViewModel(sessionId: "6cf7e861", client: client)  // init restores A as .pending
        vm.draft("B — a different write")
        vm.confirm()                                  // post(B): save(B) == false (A owns) → refuse, NO POST
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(requests(), 0, "B must NOT POST while a foreign write owns the outbox")
        XCTAssertEqual(OutboxStore.load()?.proposal.id, aId, "A is intact (never clobbered)")
        if case .refused = vm.state {} else { XCTFail("B refused — couldn't secure the outbox") }
    }

    // NIL-GATEWAY WRITE HONESTY (Pulse round-8 P1): confirming a write with NO gateway configured must REFUSE
    // SYNCHRONOUSLY — no durable outbox, no token read, no request, no transient state, and NEVER a false
    // ".pending"/"offline queued" (a nil endpoint can't be repaired by a reconnect).
    func test_confirm_with_no_gateway_refuses_and_persists_nothing() async {
        RequestCountingProtocol.reset()
        var tokenReads = 0
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [RequestCountingProtocol.self]
        // apiBaseURL == nil (unconfigured), a valid FAKE token available, request/token spies.
        let client = PocketWriteClient(apiBaseURL: nil, urlSession: URLSession(configuration: cfg),
                                       tokenProvider: { tokenReads += 1; return "valid-fake-token" })
        let vm = PhoneWriteViewModel(sessionId: "6cf7e861", client: client)
        vm.draft("Rotate the token")     // .confirming
        vm.confirm()                     // SYNCHRONOUS refuse — no save, no token, no request, no async task

        guard case .refused = vm.state else { return XCTFail("no gateway → REFUSED, never .pending/offline-queued") }
        XCTAssertNil(OutboxStore.load(), "no durable intent was created")
        XCTAssertEqual(tokenReads, 0, "no token was read")
        XCTAssertEqual(RequestCountingProtocol.count, 0, "no request was made")

        for _ in 0..<6 { await Task.yield() }   // drain: prove no async task later persists/sends anything
        XCTAssertNil(OutboxStore.load(), "still no transient persisted state")
        if case .refused = vm.state {} else { XCTFail("stays refused (not a delayed .pending)") }
    }

    // Empty-outbox + nil-gateway confirm → storage.write is NEVER called (Pulse round-9: refuse before save).
    func test_empty_outbox_nil_gateway_confirm_writes_zero() {
        let spy = SpyOutboxStorage(); OutboxStore.storage = spy   // empty
        let vm = PhoneWriteViewModel(sessionId: "6cf7e861", client: PocketWriteClient(apiBaseURL: nil))
        vm.draft("Rotate the token"); vm.confirm()   // nil gateway → refuse BEFORE any save
        guard case .refused = vm.state else { return XCTFail("nil-gateway confirm → refused") }
        XCTAssertEqual(spy.writeCount, 0, "no durable write was attempted for a nil-gateway confirm")
        XCTAssertNil(OutboxStore.load())
    }

    // MARK: - Restored authorized intent honesty (Pulse round-9 P1)

    // seed A → NIL-client init → RETAINED-UNAVAILABLE (NOT a false connectivity .pending); A intact; 0 token/request.
    func test_restored_intent_with_nil_gateway_is_unavailable_not_pending() {
        OutboxStore.save(intent("A — an earlier authorized write"))
        let aId = OutboxStore.load()!.proposal.id
        RequestCountingProtocol.reset(); var tokenReads = 0
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [RequestCountingProtocol.self]
        let nilClient = PocketWriteClient(apiBaseURL: nil, urlSession: URLSession(configuration: cfg),
                                          tokenProvider: { tokenReads += 1; return "valid-fake-token" })
        let vm = PhoneWriteViewModel(sessionId: "6cf7e861", client: nilClient)

        guard case .unavailable = vm.state else { return XCTFail("nil-gateway restore → .unavailable, never connectivity .pending") }
        XCTAssertEqual(OutboxStore.load()?.proposal.id, aId, "A is intact (retained)")
        XCTAssertEqual(tokenReads, 0, "no token read on restore")
        XCTAssertEqual(RequestCountingProtocol.count, 0, "no request on restore")
    }

    // From .unavailable: retry is a no-op and hangup/cancel PRESERVE it — never orphan/delete/wire. A stays intact.
    func test_unavailable_retry_and_hangup_preserve_and_never_wire() async {
        OutboxStore.save(intent("A"))
        let aId = OutboxStore.load()!.proposal.id
        RequestCountingProtocol.reset(); var tokenReads = 0
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [RequestCountingProtocol.self]
        let nilClient = PocketWriteClient(apiBaseURL: nil, urlSession: URLSession(configuration: cfg),
                                          tokenProvider: { tokenReads += 1; return "tok" })
        let vm = PhoneWriteViewModel(sessionId: "6cf7e861", client: nilClient)
        guard case .unavailable = vm.state else { return XCTFail("precondition: .unavailable") }

        vm.retryPending()            // no-op (retryPending guards .pending) — never wires a nil endpoint
        vm.cancelIfUnsubmitted()     // hangup — PRESERVE
        vm.cancel()                  // explicit cancel — PRESERVE (never orphan/delete)
        for _ in 0..<6 { await Task.yield() }

        guard case .unavailable = vm.state else { return XCTFail("stays .unavailable — retry/hangup/cancel preserve it") }
        XCTAssertEqual(OutboxStore.load()?.proposal.id, aId, "A intact — never orphaned/deleted")
        XCTAssertEqual(tokenReads, 0, "never read a token")
        XCTAssertEqual(RequestCountingProtocol.count, 0, "never wired a request")
    }

    // A second nil launch stays honest (.unavailable), and a CONFIGURED launch restores A as retryable .pending.
    func test_second_nil_launch_unavailable_then_configured_launch_pending() {
        OutboxStore.save(intent("A"))
        _ = PhoneWriteViewModel(sessionId: "6cf7e861", client: PocketWriteClient(apiBaseURL: nil))   // 1st nil launch
        let vm2 = PhoneWriteViewModel(sessionId: "6cf7e861", client: PocketWriteClient(apiBaseURL: nil))   // 2nd nil launch
        guard case .unavailable = vm2.state else { return XCTFail("a second nil launch stays honest .unavailable") }
        XCTAssertNotNil(OutboxStore.load(), "A still retained across nil launches")

        let vmCfg = PhoneWriteViewModel(sessionId: "6cf7e861", client: PocketWriteClient(apiBaseURL: URL(string: "https://safe.example")!))
        guard case .pending = vmCfg.state else { return XCTFail("a configured launch restores A as retryable .pending") }
        XCTAssertNotNil(OutboxStore.load(), "A still retained for the configured retry")
    }

    // A FAILED persist (no durable ownership) → the write does NOT POST.
    func test_failed_persistence_does_not_post() async {
        OutboxStore.storage = FailingOutboxStorage()
        let (client, requests) = countingClient()     // token injected — the save-gate is the only thing stopping the POST

        let vm = PhoneWriteViewModel(sessionId: "6cf7e861", client: client)
        vm.draft("Rotate the token")
        vm.confirm()                                  // post(): save() == false (persist failed) → NO POST
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(requests(), 0, "a failed persist must not POST (no durable ownership)")
        if case .refused = vm.state {} else { XCTFail("failed persist → refused, not sent") }
    }

    // MARK: - Reconciling phase (Pulse issue 4c)

    // A cancelled AUTHORIZED POST enters the explicit RECONCILING phase: the durable intent is RETAINED, it is NOT a
    // false "not posted", and a later cancel()/cancelIfUnsubmitted() cannot erase it.
    func test_cancelled_authorized_post_reconciles_retained_and_not_erasable() async {
        let vm = PhoneWriteViewModel(sessionId: "6cf7e861", client: cancellingClient())   // token injected; POST fails cancelled
        vm.draft("Rotate the token")
        vm.confirm()                                  // authorized → .sending, durable outbox
        vm.cancelIfUnsubmitted()                      // hang up while the POST is in flight → retain (no-op on .sending)
        XCTAssertNotNil(OutboxStore.load(), "authorized in-flight write retained on hangup")

        // the POST resolves as URLError.cancelled → PhoneWriteError.cancelled → RECONCILING (not .refused/"not posted")
        await spin({ if case .reconciling = vm.state { return true }; return false }, "never reconciled")
        XCTAssertNotNil(OutboxStore.load(), "the reconciling attempt is RETAINED (reconcilable)")

        vm.cancel(); vm.cancelIfUnsubmitted()         // a later cancel must NOT erase a reconciling authorized write
        guard case .reconciling = vm.state else { return XCTFail("still reconciling after a cancel") }
        XCTAssertNotNil(OutboxStore.load(), "a later cancel must not erase a reconciling authorized write")
    }

    // CANCEL-AFTER-AUTHORIZE with a BLOCKING request (Pulse round-6 #3): the POST is held in-flight while a hangup
    // cancels the adapter/orchestrator observer. The result MUST be a RETAINED .pending — NEVER .refused/not-posted —
    // and the durable outbox is retained. Releasing the request then resolves the terminal outcome (reconciling).
    func test_cancel_after_authorize_with_blocking_post_is_retained_never_refused() async {
        defer { BlockingProtocol.release() }   // P2: UNCONDITIONAL — even if an assertion fails early, unblock the URLSession thread
        let vm = PhoneWriteViewModel(sessionId: "6cf7e861", client: blockingClient())
        let adapter = PhoneWriteAdapter(vm)
        await adapter.draft("Rotate the token")
        let confirmTask = Task { await adapter.confirmAndPost() }
        defer { confirmTask.cancel() }   // P2: ensure the observer task is cancelled on any exit

        await spin({ BlockingProtocol.started }, "the POST never went in-flight")   // authorized + POST blocked
        XCTAssertNotNil(OutboxStore.load(), "authorized in-flight write is retained")

        confirmTask.cancel()                                     // hang up: cancel the adapter/orchestrator observer
        guard let result = await awaitBounded(confirmTask, timeout: 5, "confirmAndPost after cancel") else {
            return XCTFail("confirmAndPost did not return within 5s (a regression would hang here)")
        }
        if case .pending = result {} else { XCTFail("cancel-after-authorize must be a RETAINED .pending, never .refused") }
        XCTAssertNotNil(OutboxStore.load(), "the durable outbox is still retained after the cancel")

        BlockingProtocol.release()                              // release the POST → resolves cancelled → reconciling
        await spin({ if case .reconciling = vm.state { return true }; return false }, "never reached a terminal outcome")
        XCTAssertNotNil(OutboxStore.load(), "the reconcilable proposal is retained through the terminal outcome")
    }

    // The adapter maps .reconciling to a RETAINED (.pending) result — never a false .refused/"not posted".
    func test_adapter_maps_reconciling_to_pending_not_refused() async {
        let vm = PhoneWriteViewModel(sessionId: "6cf7e861", client: cancellingClient())   // token injected; POST fails cancelled
        let adapter = PhoneWriteAdapter(vm)
        await adapter.draft("Rotate the token")
        let result = await adapter.confirmAndPost()   // confirm → POST → cancelled → reconciling → adapter maps → pending
        if case .pending = result {} else { XCTFail("a reconciling write must map to .pending (retained), not .refused") }
        XCTAssertNotNil(OutboxStore.load(), "the reconcilable proposal is retained")
    }

    // PRE-CONFIRM cancel (Pulse round-7 #2): an armed adapter invoked from an ALREADY-canceled Task must NOT persist or
    // POST — it cancels the unsubmitted draft and refuses. Zero outbox, zero request.
    func test_confirmAndPost_from_an_already_canceled_task_writes_nothing() async {
        let (client, requests) = countingClient()
        let vm = PhoneWriteViewModel(sessionId: "6cf7e861", client: client)
        let adapter = PhoneWriteAdapter(vm)
        await adapter.draft("Rotate the token")          // armed → .confirming
        XCTAssertNil(OutboxStore.load())

        let task = Task {
            while !Task.isCancelled { await Task.yield() }   // enter confirmAndPost only AFTER cancellation lands
            return await adapter.confirmAndPost()
        }
        task.cancel()
        let result = await task.value

        if case .refused = result {} else { XCTFail("an already-canceled confirm must refuse, never authorize") }
        XCTAssertNil(OutboxStore.load(), "ZERO outbox — never persisted")
        XCTAssertEqual(requests(), 0, "ZERO request — never POSTed")
        guard case .composing = vm.state else { return XCTFail("the unsubmitted draft is canceled → composing") }
    }

    // Cancel a draft BEFORE confirm, then call the adapter: no armed draft → refuse, ZERO outbox + ZERO request.
    func test_confirmAndPost_after_a_presubmit_cancel_writes_nothing() async {
        let (client, requests) = countingClient()
        let vm = PhoneWriteViewModel(sessionId: "6cf7e861", client: client)
        let adapter = PhoneWriteAdapter(vm)
        await adapter.draft("Rotate the token")       // armed → .confirming
        vm.cancelIfUnsubmitted()                       // HANG UP before confirm → draft cancelled → .composing
        let result = await adapter.confirmAndPost()    // no armed draft → refuse, writes nothing
        if case .refused = result {} else { XCTFail("a cancelled draft must not confirm/post") }
        XCTAssertNil(OutboxStore.load(), "zero outbox")
        XCTAssertEqual(requests(), 0, "zero request")
    }

    // MARK: - PocketWriteClient cancellation mapping

    func test_pre_cancelled_execute_makes_zero_requests_and_stays_cancellation() async {
        let (client, requests) = countingClient()
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
        XCTAssertEqual(requests(), 0, "a pre-cancelled write issues ZERO URL requests")
    }
}
