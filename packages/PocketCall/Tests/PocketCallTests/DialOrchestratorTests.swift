import XCTest
import PocketContracts
@testable import PocketCall

final class DialOrchestratorTests: XCTestCase {
    /// Scripted voice: speak() is recorded; listen() returns queued transcripts in order (then ""). answerFollowUp
    /// records the question + speaks the (grounded) answer, mirroring LiveDialVoice — it NEVER posts.
    final class MockVoice: DialVoice, @unchecked Sendable {
        private let transcripts: [String]
        private var i = 0
        private(set) var spoken: [String] = []
        private(set) var answered: [String] = []
        private let followUpAnswer: DialSpokenAnswer
        init(_ transcripts: [String],
             followUp: DialSpokenAnswer = DialSpokenAnswer(spokenText: "Here's what I found.", grounded: true, evidenceIds: ["ev_1"])) {
            self.transcripts = transcripts
            self.followUpAnswer = followUp
        }
        func speak(_ text: String) async { spoken.append(text) }
        func listen() async -> String { defer { i += 1 }; return i < transcripts.count ? transcripts[i] : "" }
        func answerFollowUp(_ question: String) async -> DialSpokenAnswer {
            answered.append(question)
            await speak(followUpAnswer.spokenText)
            return followUpAnswer
        }
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

    private func req() -> DialRequest {
        DialRequest(dialId: "dial_x", message: "The token looks compromised.", callerName: "Senti", priority: "high")
    }

    @MainActor private func run(_ transcripts: [String], _ writer: MockWriter, retries: Int = 2) async -> DialOutcome {
        let v = MockVoice(transcripts)
        return await DialOrchestrator(voice: v, writer: writer, maxConfirmRetries: retries).run(req())
    }

    // MARK: - Dictate + confirm (reply now arrives via an explicit reply-marker in the conversing phase)

    func testHappyPath_dictateThenConfirm_posts() async {
        let w = MockWriter(result: .posted)
        let out = await run(["my reply is rotate the token and hold the deploy", "confirm"], w)
        XCTAssertEqual(out, .posted)
        XCTAssertEqual(w.drafted, "rotate the token and hold the deploy") // authorized EXACTLY what was dictated
        XCTAssertEqual(w.confirmCalls, 1)
        XCTAssertEqual(w.cancelCalls, 0)
    }

    // CRITICAL: an explicit decline NEVER authorizes the write.
    func testDecline_neverPosts() async {
        let w = MockWriter()
        let out = await run(["my reply is post the update", "cancel"], w)
        XCTAssertEqual(out, .declined("explicit decline"))
        XCTAssertEqual(w.confirmCalls, 0)
        XCTAssertEqual(w.cancelCalls, 1)
    }

    func testUnclearThenConfirm_posts() async {
        let w = MockWriter(result: .posted)
        let out = await run(["my reply is post the update", "umm yeah go", "confirm"], w) // ambient "go" is NOT a confirm → re-ask
        XCTAssertEqual(out, .posted)
        XCTAssertEqual(w.confirmCalls, 1)
    }

    // CRITICAL: unclear confirms, exhausted, NEVER authorize the write.
    func testUnclearExhausted_neverPosts() async {
        let w = MockWriter()
        let out = await run(["my reply is post the update", "umm", "err", "hmm"], w, retries: 2) // reply + 3 unclear turns
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
        let out = await run(["my reply is post it", "confirm"], w)
        XCTAssertEqual(out, .pending("offline"))
    }

    func testRefusedWrite_declinesNeverSent() async {
        let w = MockWriter(result: .refused("signature not verified"))
        let out = await run(["my reply is post it", "confirm"], w)
        if case .declined = out {} else { return XCTFail("a refused write must decline, never sent") }
    }

    // MARK: - Conversing phase (grounded Q&A; reply-marker is the ONLY exit to a write)

    @MainActor
    func testConversing_questionIsAnswered_thenMarkerReplyPosts() async {
        let w = MockWriter(result: .posted)
        let v = MockVoice(["did the token actually rotate?", "my reply is rotate it now and page me", "confirm"])
        let out = await DialOrchestrator(voice: v, writer: w).run(req())
        XCTAssertEqual(out, .posted)
        XCTAssertEqual(v.answered, ["did the token actually rotate?"])  // the question was answered aloud...
        XCTAssertEqual(w.drafted, "rotate it now and page me")          // ...and ONLY the marker'd reply was drafted
        XCTAssertEqual(w.confirmCalls, 1)
    }

    // CRITICAL consent invariant at the run() level: a reply-SOUNDING utterance with NO marker is ANSWERED, NEVER
    // posted — even repeated. Only an explicit marker reaches a write. This is the load-bearing conversing test.
    @MainActor
    func testConversing_replySoundingWithoutMarker_neverPosts() async {
        let w = MockWriter()
        let v = MockVoice(["ship it", "yes approve it", "just send it"]) // all sound like GO — none carries a marker
        let out = await DialOrchestrator(voice: v, writer: w).run(req())
        if case .declined = out {} else { return XCTFail("no marker must never post") }
        XCTAssertEqual(v.answered, ["ship it", "yes approve it", "just send it"]) // all answered as questions
        XCTAssertNil(w.drafted)
        XCTAssertEqual(w.confirmCalls, 0)
    }

    @MainActor
    func testConversing_questionThenSilence_neverPosts() async {
        let w = MockWriter()
        let v = MockVoice(["what's the blast radius?", ""]) // asks, then goes silent — never a marker
        let out = await DialOrchestrator(voice: v, writer: w).run(req())
        XCTAssertEqual(out, .declined("no dictated reply"))
        XCTAssertEqual(v.answered, ["what's the blast radius?"])
        XCTAssertNil(w.drafted)
        XCTAssertEqual(w.confirmCalls, 0)
    }

    @MainActor
    func testConversing_bareMarker_takesNextUtteranceVerbatim() async {
        let w = MockWriter(result: .posted)
        let v = MockVoice(["my reply is", "ship it to prod tonight", "confirm"]) // bare marker → next utterance verbatim
        let out = await DialOrchestrator(voice: v, writer: w).run(req())
        XCTAssertEqual(out, .posted)
        XCTAssertEqual(w.drafted, "ship it to prod tonight")
        XCTAssertEqual(v.answered, []) // a bare marker does NOT route the next utterance to the reasoner
    }
}
