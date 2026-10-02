import XCTest
import PocketCall
import PocketContracts
@testable import SentiPocketApp

/// Read-only-by-construction (Pulse issue 2b): a foreground DEMO episode is composed with ReadOnlyDialWriter, so a
/// demo "confirm" — even with a REAL SessionTokenStore token present — produces ZERO governed write (no POST, no outbox).
@MainActor
final class ReadOnlyDialWriterTests: XCTestCase {

    final class InMemoryOutboxStorage: OutboxStorage {
        private var data: Data?
        func write(_ d: Data) -> Bool { data = d; return true }
        func read() -> Data? { data }
        func remove() { data = nil }
    }
    override func setUp() {
        super.setUp()
        OutboxStore.storage = InMemoryOutboxStorage(); OutboxStore.clear(); SessionTokenStore.delete()
    }
    override func tearDown() {
        OutboxStore.clear(); OutboxStore.storage = FileOutboxStorage(); SessionTokenStore.delete(); super.tearDown()
    }

    /// A scripted voice that dictates a reply-marker then "confirm" — driving the orchestrator all the way to confirm.
    final class ScriptVoice: DialVoice, @unchecked Sendable {
        private let lines: [String]; private var i = 0
        init(_ lines: [String]) { self.lines = lines }
        func speak(_ t: String) async {}
        func listen() async -> String { defer { i += 1 }; return i < lines.count ? lines[i] : "" }
        func answerFollowUp(_ q: String) async -> DialSpokenAnswer { DialSpokenAnswer(spokenText: "", grounded: true, evidenceIds: []) }
    }

    // Even with a real token AND a full dictate→confirm, a read-only demo writes nothing.
    func test_read_only_demo_confirm_writes_nothing_even_with_a_token() async {
        try? SessionTokenStore.save("demo-token")   // a real token present — the demo must STILL not write
        let writer = ReadOnlyDialWriter()
        let orch = DialOrchestrator(voice: ScriptVoice(["my reply is post the update", "confirm"]), writer: writer)
        let out = await orch.run(DialRequest(dialId: "demo-1", message: "Ship it?", callerName: "Senti", priority: "high"))

        if case .declined = out {} else { XCTFail("a read-only demo confirm must decline (nothing written)") }
        XCTAssertEqual(writer.confirmAttempts, 1, "the flow reached confirm — and it still wrote nothing")
        XCTAssertNil(OutboxStore.load(), "ZERO outbox — read-only-by-construction, regardless of the token")
    }

    func test_read_only_writer_confirmAndPost_refuses() async {
        let writer = ReadOnlyDialWriter()
        await writer.draft("anything")
        await writer.cancelIfUnsubmitted()
        let r = await writer.confirmAndPost()
        if case .refused = r {} else { XCTFail("ReadOnlyDialWriter.confirmAndPost must refuse (never post)") }
        XCTAssertNil(OutboxStore.load())
    }
}
