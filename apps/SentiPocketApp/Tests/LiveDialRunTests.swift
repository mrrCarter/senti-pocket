import XCTest
import PocketCall
import PocketContracts
@testable import SentiPocketApp

/// Full LiveDialRun coverage (Pulse round-7 P2): the composition drives the orchestrator, cancel() makes it decline
/// without posting, and teardown() stops the voice + tears down an UNSUBMITTED writer. Stub voice/writer — no audio.
@MainActor
final class LiveDialRunTests: XCTestCase {

    final class InMemoryOutboxStorage: OutboxStorage {
        private var data: Data?
        func write(_ d: Data) -> Bool { data = d; return true }
        func read() -> Data? { data }
        func remove() { data = nil }
    }
    /// Fails every request with URLError.cancelled — simulates an interrupted in-flight POST.
    final class CancellingProtocol: URLProtocol {
        override class func canInit(with r: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
        override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.cancelled)) }
        override func stopLoading() {}
    }

    override func setUp() {
        super.setUp()
        OutboxStore.storage = InMemoryOutboxStorage(); OutboxStore.clear(); SessionTokenStore.delete()
    }
    override func tearDown() {
        OutboxStore.clear(); OutboxStore.storage = FileOutboxStorage(); SessionTokenStore.delete(); super.tearDown()
    }

    @MainActor
    final class StubVoice: StoppableDialVoice {
        private let lines: [String]; private var i = 0
        private(set) var stops = 0
        init(_ lines: [String] = []) { self.lines = lines }
        func speak(_ t: String) async {}
        func listen() async -> String { defer { i += 1 }; return i < lines.count ? lines[i] : "" }
        func answerFollowUp(_ q: String) async -> DialSpokenAnswer { DialSpokenAnswer(spokenText: "", grounded: true, evidenceIds: []) }
        func stop() async { stops += 1 }
    }

    @MainActor
    final class RecWriter: DialEpisodeWriter {
        private(set) var drafted: String?
        private(set) var confirmCalls = 0
        private(set) var cancelUnsubmittedCalls = 0
        let result: DialWriteResult
        init(result: DialWriteResult = .posted) { self.result = result }
        func draft(_ m: String) async { drafted = m }
        func cancel() async {}
        func cancelIfUnsubmitted() async { cancelUnsubmittedCalls += 1 }
        func confirmAndPost() async -> DialWriteResult { confirmCalls += 1; return result }
    }

    private func request() -> DialRequest {
        DialRequest(dialId: "d", message: "Ship it?", callerName: "Senti", priority: "high")
    }

    // run() drives the orchestrator: dictate + confirm → posts.
    func test_run_drives_the_orchestrator_to_posted() async {
        let voice = StubVoice(["my reply is do it", "confirm"])
        let writer = RecWriter(result: .posted)
        let run = LiveDialRun(voice: voice, writer: writer, request: request())
        let out = await run.run()
        XCTAssertEqual(out, .posted)
        XCTAssertEqual(writer.confirmCalls, 1)
        XCTAssertEqual(writer.drafted, "do it")
    }

    // cancel() BEFORE run() → declined, no confirm.
    func test_cancel_before_run_declines_without_confirm() async {
        let voice = StubVoice(["my reply is do it", "confirm"])
        let writer = RecWriter(result: .posted)
        let run = LiveDialRun(voice: voice, writer: writer, request: request())
        run.cancel()
        let out = await run.run()
        if case .declined = out {} else { XCTFail("cancel before run → declined") }
        XCTAssertEqual(writer.confirmCalls, 0)
    }

    // teardown() stops the voice AND tears down an unsubmitted writer draft.
    func test_teardown_stops_voice_and_tears_down_unsubmitted_writer() async {
        let voice = StubVoice()
        let writer = RecWriter()
        let run = LiveDialRun(voice: voice, writer: writer, request: request())
        await run.teardown()
        XCTAssertEqual(voice.stops, 1, "teardown stops the voice (synth+mic+recognition)")
        XCTAssertEqual(writer.cancelUnsubmittedCalls, 1, "teardown tears down an unsubmitted writer draft")
    }

    // cancel() mid-run → the orchestrator declines at its next checkpoint; nothing posted.
    func test_cancel_midrun_declines_without_post() async {
        @MainActor
        final class Gated: StoppableDialVoice {
            private var cont: CheckedContinuation<Void, Never>?
            private(set) var listenStarted = false
            func speak(_ t: String) async {}
            func listen() async -> String { listenStarted = true; await withCheckedContinuation { cont = $0 }; return "my reply is go" }
            func answerFollowUp(_ q: String) async -> DialSpokenAnswer { DialSpokenAnswer(spokenText: "", grounded: true, evidenceIds: []) }
            func stop() async { cont?.resume(); cont = nil }   // stop unblocks the gated listen
        }
        let voice = Gated()
        let writer = RecWriter()
        let run = LiveDialRun(voice: voice, writer: writer, request: request())
        let t = Task { await run.run() }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline { if voice.listenStarted { break }; await Task.yield() }
        XCTAssertTrue(voice.listenStarted, "listen must have started (blocked)")
        run.cancel()
        await run.teardown()   // stop() unblocks the gated listen; the cancelled run then declines before draft
        let out = await t.value
        if case .declined = out {} else { XCTFail("cancel mid-run → declined") }
        XCTAssertEqual(writer.confirmCalls, 0, "nothing posted after a mid-run cancel")
    }

    // POST-AUTHORIZE end-to-end through the REAL adapter (Pulse round-8 P2.2): a dictated + confirmed write drives the
    // real PhoneWriteAdapter/PhoneWriteViewModel; an interrupted (cancelled) in-flight POST → RECONCILING → the run
    // reports a RETAINED .pending and the durable outbox is retained (never declined/refused/lost).
    func test_authorized_write_through_real_adapter_reconciles_and_retains() async {
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [CancellingProtocol.self]
        let client = PocketWriteClient(apiBaseURL: URL(string: "https://safe.example")!,
                                       urlSession: URLSession(configuration: cfg), tokenProvider: { "tok" })
        let vm = PhoneWriteViewModel(sessionId: "6cf7e861", client: client)
        let run = LiveDialRun(voice: StubVoice(["my reply is rotate the token", "confirm"]),
                              writer: PhoneWriteAdapter(vm), request: request())

        let out = await run.run()
        if case .pending = out {} else { return XCTFail("an interrupted authorized write → retained .pending, never declined/refused") }
        XCTAssertNotNil(OutboxStore.load(), "the reconcilable proposal is retained in the durable outbox")
        guard case .reconciling = vm.state else { return XCTFail("the real VM entered the reconciling phase") }
    }

    // POST-AUTHORIZE offline through the REAL adapter: a network-failed POST → the real VM's .pending (retained), and
    // the run reports .pending — the confirmed intent stays durably queued.
    func test_authorized_write_through_real_adapter_offline_pends_and_retains() async {
        final class OfflineProtocol: URLProtocol {
            override class func canInit(with r: URLRequest) -> Bool { true }
            override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
            override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
            override func stopLoading() {}
        }
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [OfflineProtocol.self]
        let client = PocketWriteClient(apiBaseURL: URL(string: "https://safe.example")!,
                                       urlSession: URLSession(configuration: cfg), tokenProvider: { "tok" })
        let vm = PhoneWriteViewModel(sessionId: "6cf7e861", client: client)
        let run = LiveDialRun(voice: StubVoice(["my reply is rotate the token", "confirm"]),
                              writer: PhoneWriteAdapter(vm), request: request())

        let out = await run.run()
        if case .pending = out {} else { return XCTFail("offline authorized write → retained .pending") }
        XCTAssertNotNil(OutboxStore.load(), "the confirmed intent stays durably queued")
        guard case .pending = vm.state else { return XCTFail("the real VM is offline-pending") }
    }
}
