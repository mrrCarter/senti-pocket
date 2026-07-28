import XCTest
import PocketCall
import PocketContracts
@testable import SentiPocketApp

/// Full LiveDialRun coverage (Pulse round-7 P2): the composition drives the orchestrator, cancel() makes it decline
/// without posting, and teardown() stops the voice + tears down an UNSUBMITTED writer. Stub voice/writer — no audio.
@MainActor
final class LiveDialRunTests: XCTestCase {

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
}
