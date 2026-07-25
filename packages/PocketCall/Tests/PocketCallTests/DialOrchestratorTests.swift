import XCTest
@testable import PocketCall

final class DialOrchestratorTests: XCTestCase {
    /// Scripted voice: speak() is recorded; listen() returns queued transcripts in order (then "").
    final class MockVoice: DialVoice, @unchecked Sendable {
        private let transcripts: [String]
        private var i = 0
        private(set) var spoken: [String] = []
        init(_ transcripts: [String]) { self.transcripts = transcripts }
        func speak(_ text: String) async { spoken.append(text) }
        func listen() async -> String { defer { i += 1 }; return i < transcripts.count ? transcripts[i] : "" }
    }
    /// Records the governed-write calls so a test can assert confirmAndPost is reached ONLY on a real confirm.
    final class MockWriter: DialWriter, @unchecked Sendable {
        private let result: DialWriteResult
        private(set) var drafted: String?
        private(set) var confirmCalls = 0
        private(set) var cancelCalls = 0
        init(result: DialWriteResult = .posted) { self.result = result }
        func draft(_ message: String) async { drafted = message }
        func confirmAndPost() async -> DialWriteResult { confirmCalls += 1; return result }
        func cancel() async { cancelCalls += 1 }
    }

    @MainActor private func run(_ transcripts: [String], _ writer: MockWriter, retries: Int = 2) async -> DialOutcome {
        let v = MockVoice(transcripts)
        return await DialOrchestrator(voice: v, writer: writer, maxConfirmRetries: retries).run(
            DialRequest(dialId: "dial_x", message: "The token looks compromised.", callerName: "Senti", priority: "high"))
    }

    func testHappyPath_dictateThenConfirm_posts() async {
        let w = MockWriter(result: .posted)
        let out = await run(["rotate the token and hold the deploy", "confirm"], w)
        XCTAssertEqual(out, .posted)
        XCTAssertEqual(w.drafted, "rotate the token and hold the deploy") // authorized EXACTLY what was dictated
        XCTAssertEqual(w.confirmCalls, 1)
        XCTAssertEqual(w.cancelCalls, 0)
    }

    // CRITICAL: an explicit decline NEVER authorizes the write.
    func testDecline_neverPosts() async {
        let w = MockWriter()
        let out = await run(["post the update", "cancel"], w)
        XCTAssertEqual(out, .declined("explicit decline"))
        XCTAssertEqual(w.confirmCalls, 0)
        XCTAssertEqual(w.cancelCalls, 1)
    }

    func testUnclearThenConfirm_posts() async {
        let w = MockWriter(result: .posted)
        let out = await run(["post the update", "umm yeah go", "confirm"], w) // ambient "go" is NOT a confirm → re-ask
        XCTAssertEqual(out, .posted)
        XCTAssertEqual(w.confirmCalls, 1)
    }

    // CRITICAL: unclear confirms, exhausted, NEVER authorize the write.
    func testUnclearExhausted_neverPosts() async {
        let w = MockWriter()
        let out = await run(["post the update", "umm", "err", "hmm"], w, retries: 2) // reply + 3 unclear turns
        if case .declined = out {} else { return XCTFail("unclear-exhausted must decline") }
        XCTAssertEqual(w.confirmCalls, 0)
        XCTAssertEqual(w.cancelCalls, 1)
    }

    // CRITICAL: no dictated reply → nothing drafted or posted (never a default/ambient reply).
    func testNoReply_neverDraftsOrPosts() async {
        let w = MockWriter()
        let out = await run([""], w)
        XCTAssertEqual(out, .declined("no dictated reply"))
        XCTAssertNil(w.drafted)
        XCTAssertEqual(w.confirmCalls, 0)
    }

    func testOfflinePending_confirmedButQueuedNeverSent() async {
        let w = MockWriter(result: .pending("offline"))
        let out = await run(["post it", "confirm"], w)
        XCTAssertEqual(out, .pending("offline"))
    }

    func testRefusedWrite_declinesNeverSent() async {
        let w = MockWriter(result: .refused("signature not verified"))
        let out = await run(["post it", "confirm"], w)
        if case .declined = out {} else { return XCTFail("a refused write must decline, never sent") }
    }
}
