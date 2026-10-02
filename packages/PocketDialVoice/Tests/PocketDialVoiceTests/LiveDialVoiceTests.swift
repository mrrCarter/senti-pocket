import XCTest
import PocketCall
import PocketContracts
import PocketReasoning
import PocketVoice
@testable import PocketDialVoice

// MARK: - Stubs

private struct StubError: Error {}

private final class SpokenLog: @unchecked Sendable {
    var texts: [String] = []
    var synthStops = 0
}

private struct StubSynth: SpeechSynthesizer {
    let log: SpokenLog
    let failing: Bool
    init(log: SpokenLog, failing: Bool = false) { self.log = log; self.failing = failing }
    func speak(_ request: SpeechSynthesisRequest) async throws -> SpeechPlaybackMetrics {
        log.texts.append(request.text)
        if failing { throw StubError() }
        return SpeechPlaybackMetrics(
            backend: .avSpeechOffline,
            firstAudioMeasurement: .avSpeechDidStartCallback,
            firstAudioMilliseconds: 1,
            totalMilliseconds: 1,
            characterCount: request.text.count,
            residentMemoryBytes: nil,
            thermalState: .nominal
        )
    }
    func stop() async { log.synthStops += 1 }
}

private final class StubRecognizer: SpeechRecognizer, @unchecked Sendable {
    let transcript: String
    let prepareFails: Bool
    let transcribeFails: Bool
    private(set) var cancelCount = 0
    init(transcript: String = "", prepareFails: Bool = false, transcribeFails: Bool = false) {
        self.transcript = transcript
        self.prepareFails = prepareFails
        self.transcribeFails = transcribeFails
    }
    func prepareModel(at modelURL: URL) async throws -> SpeechModelMetrics {
        if prepareFails { throw StubError() }
        return SpeechModelMetrics(modelIdentifier: "stub", loadMilliseconds: 1, residentMemoryBytes: nil, thermalState: .nominal)
    }
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        if transcribeFails { throw StubError() }
        return TranscriptionResult(
            text: transcript,
            metrics: TranscriptionMetrics(audioDurationSeconds: 1, transcriptionMilliseconds: 1, realTimeFactor: 1, residentMemoryBytes: nil, thermalState: .nominal)
        )
    }
    func cancel() async { cancelCount += 1 }
}

private final class StubMic: DialMicrophone, @unchecked Sendable {
    let frames: [MicrophoneFrame]
    private(set) var stopped = false
    private(set) var startedCount = 0
    init(frames: [MicrophoneFrame]) { self.frames = frames }
    func start() async throws -> AsyncThrowingStream<MicrophoneFrame, Error> {
        startedCount += 1
        let frames = self.frames
        return AsyncThrowingStream { continuation in
            for frame in frames { continuation.yield(frame) }
            continuation.finish()
        }
    }
    func stop() async { stopped = true }
}

private final class StubReasoner: DialReasoner, @unchecked Sendable {
    private(set) var calls: [(question: String, sessionId: String, checkpointId: String?)] = []
    let answer: DialSpokenAnswer
    init(answer: DialSpokenAnswer = DialSpokenAnswer(spokenText: "grounded reply", grounded: true, evidenceIds: ["ev_1"])) {
        self.answer = answer
    }
    func answerFollowUp(_ question: String, sessionId: String, checkpointId: String?) async -> DialSpokenAnswer {
        calls.append((question, sessionId, checkpointId))
        return answer
    }
}

/// Six 100 ms frames of speech-amplitude audio at 16 kHz — enough captured audio (>0.1 s) for a valid
/// transcription request; the stub stream then finishes, so capture() exits on stream-end (robust, not
/// dependent on precise VAD attack/release timing).
private func speechFrames() -> [MicrophoneFrame] {
    (0..<6).compactMap { _ in try? MicrophoneFrame(samples: Array(repeating: 0.2, count: 1600), sampleRate: 16_000) }
}

@MainActor
private func makeVoice(
    log: SpokenLog = SpokenLog(),
    synthFailing: Bool = false,
    recognizer: StubRecognizer = StubRecognizer(transcript: "post the reply"),
    mic: StubMic = StubMic(frames: speechFrames()),
    reasoner: StubReasoner = StubReasoner(),
    permission: Bool = true,
    modelURL: URL? = URL(fileURLWithPath: "/tmp/ggml-base.en.bin")
) -> LiveDialVoice {
    LiveDialVoice(
        reasoner: reasoner,
        sessionId: "sess_1",
        checkpointId: "cp_1",
        modelURL: modelURL,
        synthesizer: StubSynth(log: log, failing: synthFailing),
        recognizer: recognizer,
        microphone: mic,
        requestPermission: { permission }
    )
}

final class LiveDialVoiceTests: XCTestCase {

    // MARK: speak

    @MainActor
    func test_speak_forwards_text_to_synthesizer() async {
        let log = SpokenLog()
        let voice = makeVoice(log: log)
        await voice.speak("Decision needed.")
        XCTAssertEqual(log.texts, ["Decision needed."])
    }

    @MainActor
    func test_speak_swallows_synthesizer_error() async {
        let log = SpokenLog()
        let voice = makeVoice(log: log, synthFailing: true)
        await voice.speak("still recorded")   // must not throw / crash
        XCTAssertEqual(log.texts, ["still recorded"])
    }

    @MainActor
    func test_speak_skips_empty_text() async {
        let log = SpokenLog()
        let voice = makeVoice(log: log)
        await voice.speak("   ")   // SpeechSynthesisRequest rejects empty → guard returns, synth untouched
        XCTAssertTrue(log.texts.isEmpty)
    }

    // MARK: listen

    @MainActor
    func test_listen_returns_transcribed_text() async {
        let voice = makeVoice(recognizer: StubRecognizer(transcript: "post the reply"))
        let heard = await voice.listen()
        XCTAssertEqual(heard, "post the reply")
    }

    @MainActor
    func test_listen_empty_when_permission_denied() async {
        let voice = makeVoice(permission: false)
        let heard = await voice.listen()
        XCTAssertEqual(heard, "")
    }

    @MainActor
    func test_listen_empty_when_model_unavailable() async {
        let voice = makeVoice(modelURL: nil)
        let heard = await voice.listen()
        XCTAssertEqual(heard, "")
    }

    @MainActor
    func test_listen_empty_on_prepare_failure() async {
        let voice = makeVoice(recognizer: StubRecognizer(transcript: "x", prepareFails: true))
        let heard = await voice.listen()
        XCTAssertEqual(heard, "")
    }

    @MainActor
    func test_listen_empty_on_transcribe_failure() async {
        let voice = makeVoice(recognizer: StubRecognizer(transcript: "x", transcribeFails: true))
        let heard = await voice.listen()
        XCTAssertEqual(heard, "")
    }

    // MARK: the consent-critical invariant

    /// The load-bearing security property: `listen()` NEVER routes to the reasoner, even when the transcript
    /// reads like a question. In the governed-write path, an utterance the caller expects as a dictated reply
    /// (or a confirm/decline) must come back verbatim — the reasoner (which speaks a NEW answer) must not
    /// intercept it, or voice-GO could diverge from what the user actually authorized.
    @MainActor
    func test_listen_never_invokes_reasoner_even_for_a_question() async {
        let reasoner = StubReasoner()
        let log = SpokenLog()
        let voice = makeVoice(log: log, recognizer: StubRecognizer(transcript: "did the token rotate?"), reasoner: reasoner)
        let heard = await voice.listen()
        XCTAssertEqual(heard, "did the token rotate?")   // returned verbatim, not answered
        XCTAssertTrue(reasoner.calls.isEmpty, "listen() must not call the reasoner")
        XCTAssertTrue(log.texts.isEmpty, "listen() must not speak an answer")
    }

    // MARK: answerFollowUp (the EXPLICIT reasoner path)

    @MainActor
    func test_answerFollowUp_calls_reasoner_with_context_and_speaks_answer() async {
        let reasoner = StubReasoner(answer: DialSpokenAnswer(spokenText: "Yes — rotated at 14:02.", grounded: true, evidenceIds: ["ev_9"]))
        let log = SpokenLog()
        let voice = makeVoice(log: log, reasoner: reasoner)
        let answer = await voice.answerFollowUp("did the token rotate?")
        XCTAssertEqual(reasoner.calls.count, 1)
        XCTAssertEqual(reasoner.calls.first?.question, "did the token rotate?")
        XCTAssertEqual(reasoner.calls.first?.sessionId, "sess_1")
        XCTAssertEqual(reasoner.calls.first?.checkpointId, "cp_1")
        XCTAssertEqual(answer.spokenText, "Yes — rotated at 14:02.")
        XCTAssertEqual(log.texts, ["Yes — rotated at 14:02."])   // the grounded answer was spoken aloud
    }

    // MARK: - stop() teardown seam (spec B)

    @MainActor
    func test_stop_stops_synth_mic_and_recognizer() async {
        let log = SpokenLog()
        let mic = StubMic(frames: speechFrames())
        let recognizer = StubRecognizer(transcript: "x")
        let voice = makeVoice(log: log, recognizer: recognizer, mic: mic)
        await voice.stop()
        XCTAssertEqual(log.synthStops, 1, "stop() must stop the synthesizer")
        XCTAssertTrue(mic.stopped, "stop() must stop the microphone")
        XCTAssertEqual(recognizer.cancelCount, 1, "stop() must cancel the recognizer (no in-flight transcription survives)")
    }

    // No reasoner EGRESS after a stop(): answerFollowUp must not call the (networked) reasoner nor speak anything.
    @MainActor
    func test_answerFollowUp_after_stop_makes_no_reasoner_egress() async {
        let log = SpokenLog()
        let reasoner = StubReasoner()
        let voice = makeVoice(log: log, reasoner: reasoner)
        await voice.stop()
        _ = await voice.answerFollowUp("did it rotate?")
        XCTAssertTrue(reasoner.calls.isEmpty, "a stop() must prevent any reasoner egress")
        XCTAssertTrue(log.texts.isEmpty, "nothing is spoken after stop()")
    }

    @MainActor
    func test_speak_after_stop_is_noop() async {
        let log = SpokenLog()
        let voice = makeVoice(log: log)
        await voice.stop()
        await voice.speak("should not be spoken")
        XCTAssertTrue(log.texts.isEmpty, "a speak after stop() must not reach the synthesizer")
    }

    @MainActor
    func test_listen_after_stop_returns_empty_without_capturing() async {
        let mic = StubMic(frames: speechFrames())
        let voice = makeVoice(recognizer: StubRecognizer(transcript: "should not be used"), mic: mic)
        await voice.stop()
        let heard = await voice.listen()
        XCTAssertEqual(heard, "", "listen after stop() must return empty")
        XCTAssertEqual(mic.startedCount, 0, "listen after stop() must not begin capture")
    }

    /// A stop() that lands DURING the (async) permission await must prevent capture from ever beginning — the
    /// post-permission generation-recheck bails, so a delayed await cannot restart capture after teardown.
    @MainActor
    func test_stop_during_permission_await_prevents_capture() async {
        final class Box: @unchecked Sendable { var voice: LiveDialVoice? }
        let box = Box()
        let mic = StubMic(frames: speechFrames())
        let voice = LiveDialVoice(
            reasoner: StubReasoner(),
            sessionId: "sess_1",
            checkpointId: "cp_1",
            modelURL: URL(fileURLWithPath: "/tmp/ggml-base.en.bin"),
            synthesizer: StubSynth(log: SpokenLog()),
            recognizer: StubRecognizer(transcript: "should not be used"),
            microphone: mic,
            requestPermission: { await box.voice?.stop(); return true }   // stop() lands mid-listen (during permission)
        )
        box.voice = voice
        let heard = await voice.listen()
        XCTAssertEqual(heard, "", "the post-permission recheck must bail after a mid-flight stop()")
        XCTAssertEqual(mic.startedCount, 0, "capture must not begin after a stop() during the permission await")
    }
}
