import Foundation
import PocketCall
import PocketContracts
import PocketReasoning
import PocketVoice

/// A microphone source `LiveDialVoice` drives. `MicrophoneCapture` conforms retroactively (its `start()`/`stop()`
/// signatures already match), and tests inject a canned-frame stub — so the capture→transcribe loop is
/// unit-testable without real hardware.
public protocol DialMicrophone: Sendable {
    func start() async throws -> AsyncThrowingStream<MicrophoneFrame, Error>
    func stop() async
}

extension MicrophoneCapture: DialMicrophone {}

/// LiveDialVoice — the AUDIO half of the DIALS voice loop (Forge lane). Conforms to `PocketCall.DialVoice`:
/// `speak` via on-device TTS (AVSpeech), `listen` via on-device Whisper STT (mic → VAD-bounded capture →
/// 16 kHz resample → whisper.cpp).
///
/// Lane split (agreed w/ Atlas): Forge owns the AUDIO I/O; the follow-up ANSWER comes from an injected
/// `DialReasoner` (Atlas). DELIBERATELY, `listen()` does NOT auto-classify utterances as follow-up questions:
/// this is the consent-critical governed-write path, and mis-reading a question-phrased dictated reply
/// (e.g. "should we ship it?") as a question would break the voice-GO === tap-GO invariant. `listen()` is
/// therefore deterministic (audio → transcript); the reasoner is exposed via `answerFollowUp(_:)` for the
/// orchestrator's conversing phase (placement TBD w/ Atlas). Both `speak`/`listen` are non-throwing per the
/// protocol, so every audio error degrades silently (`speak` → no-op, `listen` → "").
@MainActor
public final class LiveDialVoice: DialVoice {
    private let synthesizer: any SpeechSynthesizer
    private let recognizer: any SpeechRecognizer
    private let microphone: any DialMicrophone
    private let reasoner: any DialReasoner
    private let requestPermission: @Sendable () async -> Bool
    private let modelURL: URL?
    private let sessionId: String
    private let checkpointId: String?
    private let tone: BriefingTone
    private let maxListenSeconds: Double
    private let vad: VoiceActivityConfiguration

    private var modelPrepared = false
    /// Latched by `stop()` (Forge app-seam teardown). Once stopped, every in-flight speak/listen/answerFollowUp bails
    /// at its next await instead of starting/continuing speech or capture — so a delayed reasoner/model/permission/mic/
    /// transcribe await that resolves AFTER teardown can never restart the voice. Terminal for this per-episode instance.
    private var stopped = false

    /// True when this voice must produce no further audio/capture — an explicit stop() OR task cancellation. Checked
    /// after EACH await in the pipeline (the recheck the app-seam gate requires).
    private var isDown: Bool { stopped || Task.isCancelled }

    public init(
        reasoner: any DialReasoner,
        sessionId: String,
        checkpointId: String? = nil,
        modelURL: URL?,
        synthesizer: any SpeechSynthesizer = AVSpeechSynthesizerAdapter(),
        recognizer: any SpeechRecognizer = WhisperCPPRecognizer(),
        microphone: any DialMicrophone = MicrophoneCapture(),
        requestPermission: @escaping @Sendable () async -> Bool = { await MicrophoneCapture.requestPermission() },
        tone: BriefingTone = .neutral,
        maxListenSeconds: Double = 20,
        vad: VoiceActivityConfiguration = LiveDialVoice.defaultVAD
    ) {
        self.reasoner = reasoner
        self.sessionId = sessionId
        self.checkpointId = checkpointId
        self.modelURL = modelURL
        self.synthesizer = synthesizer
        self.recognizer = recognizer
        self.microphone = microphone
        self.requestPermission = requestPermission
        self.tone = tone
        self.maxListenSeconds = min(max(maxListenSeconds, 1), 30)
        self.vad = vad
    }

    /// The literal defaults (0.025/0.015/80/280 ms) satisfy every guard, so this force-try can never fire.
    public static let defaultVAD: VoiceActivityConfiguration = {
        // swiftlint:disable:next force_try
        try! VoiceActivityConfiguration()
    }()

    // MARK: - teardown seam (Forge app-seam, spec B)

    /// Explicit async teardown: stop the synthesizer (its reviewed `stop()`) AND the microphone/recognition, and latch
    /// `stopped` so any in-flight speak/listen/answerFollowUp bails at its next await rather than restarting speech or
    /// capture after teardown. Idempotent. The DialHost episode controller is the single teardown owner that calls this.
    public func stop() async {
        stopped = true
        await synthesizer.stop()
        await microphone.stop()
    }

    // MARK: - DialVoice

    public func speak(_ text: String) async {
        if isDown { return }
        guard let request = try? SpeechSynthesisRequest(text: text, tone: tone) else { return }
        if isDown { return }   // recheck immediately BEFORE the synth await — never start speech after a stop()
        _ = try? await synthesizer.speak(request)
    }

    public func listen() async -> String {
        if isDown { return "" }
        guard await ensureModel() else { return "" }
        if isDown { return "" }                                   // after the (async) model prepare
        guard await requestPermission() else { return "" }
        if isDown { return "" }                                   // after the (async) permission prompt
        guard let request = await captureUtterance() else { return "" }
        if isDown { return "" }                                   // after capture
        guard let result = try? await recognizer.transcribe(request) else { return "" }
        if isDown { return "" }                                   // after transcribe — a late transcript is discarded
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Answer a spoken follow-up via the injected reasoner, then speak it aloud. Exposed for the orchestrator's
    /// conversing phase — grounded-or-honest (`ProviderDialReasoner` never invents). NOT auto-invoked by `listen()`.
    @discardableResult
    public func answerFollowUp(_ question: String) async -> DialSpokenAnswer {
        let answer = await reasoner.answerFollowUp(question, sessionId: sessionId, checkpointId: checkpointId)
        if isDown { return answer }   // after the (async) reasoner — do NOT speak a late answer after a stop()
        await speak(answer.spokenText)
        return answer
    }

    // MARK: - capture pipeline

    private func ensureModel() async -> Bool {
        if modelPrepared { return true }
        guard let modelURL else { return false }
        do {
            _ = try await recognizer.prepareModel(at: modelURL)
            modelPrepared = true
            return true
        } catch {
            return false
        }
    }

    /// Drive the mic, accumulating frames until the VAD reports end-of-utterance (after speech began), the
    /// accumulator's cap trips, or the stream ends. Returns a 16 kHz transcription request, or nil if nothing
    /// usable was captured.
    private func captureUtterance() async -> TranscriptionRequest? {
        if isDown { return nil }   // do not begin capture after a stop()
        guard var accumulator = try? CapturedAudioAccumulator(maximumSeconds: maxListenSeconds) else { return nil }
        var detector = EnergyVoiceActivityDetector(configuration: vad)
        var speechStarted = false

        guard let stream = try? await microphone.start() else { return nil }
        if isDown { await microphone.stop(); return nil }   // stopped while the mic was starting → don't consume frames

        do {
            for try await frame in stream {
                try accumulator.append(frame)
                let update = try detector.process(samples: frame.samples, sampleRate: frame.sampleRate)
                if update.transition == .speechStarted { speechStarted = true }
                if speechStarted, update.transition == .speechEnded { break }
            }
        } catch {
            // Buffer overflow / cap trip / conversion error — stop and transcribe whatever we captured.
        }
        await microphone.stop()

        return try? accumulator.transcriptionRequest()
    }
}
