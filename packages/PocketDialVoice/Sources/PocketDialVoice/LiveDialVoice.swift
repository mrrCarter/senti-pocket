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

    /// Bridge CallKit's ownership callbacks into PocketVoice's shared lease manager. While this flag is active,
    /// synthesizer/player/microphone releases never call `AVAudioSession.setActive(false)` behind CallKit's back.
    public static func prepareCallKitAudioSession() throws {
        try CallKitAudioSessionOwnership.prepareForAnswer()
    }

    public static func callKitDidActivateAudioSession() {
        CallKitAudioSessionOwnership.didActivate()
    }

    public static func callKitDidDeactivateAudioSession() {
        CallKitAudioSessionOwnership.didDeactivate()
    }

    // MARK: - DialVoice

    public func speak(_ text: String) async {
        guard !Task.isCancelled else { return }
        guard let request = try? SpeechSynthesisRequest(text: text, tone: tone) else { return }
        _ = try? await synthesizer.speak(request)
    }

    public func listen() async -> String {
        guard !Task.isCancelled else { return "" }
        guard await ensureModel() else { return "" }
        guard !Task.isCancelled else { return "" }
        guard await requestPermission() else { return "" }
        guard !Task.isCancelled else { return "" }
        guard let request = await captureUtterance() else { return "" }
        guard !Task.isCancelled else { return "" }
        guard let result = try? await recognizer.transcribe(request) else { return "" }
        guard !Task.isCancelled else { return "" }
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Answer a spoken follow-up via the injected reasoner, then speak it aloud. Exposed for the orchestrator's
    /// conversing phase — grounded-or-honest (`ProviderDialReasoner` never invents). NOT auto-invoked by `listen()`.
    @discardableResult
    public func answerFollowUp(_ question: String) async -> DialSpokenAnswer {
        let answer = await reasoner.answerFollowUp(question, sessionId: sessionId, checkpointId: checkpointId)
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
        guard var accumulator = try? CapturedAudioAccumulator(maximumSeconds: maxListenSeconds) else { return nil }
        var detector = EnergyVoiceActivityDetector(configuration: vad)
        var speechStarted = false

        guard let stream = try? await microphone.start() else { return nil }

        do {
            for try await frame in stream {
                if Task.isCancelled { break }
                try accumulator.append(frame)
                let update = try detector.process(samples: frame.samples, sampleRate: frame.sampleRate)
                if update.transition == .speechStarted { speechStarted = true }
                if speechStarted, update.transition == .speechEnded { break }
            }
        } catch {
            // Buffer overflow / cap trip / conversion error — stop and transcribe whatever we captured.
        }
        await microphone.stop()

        guard !Task.isCancelled else { return nil }
        return try? accumulator.transcriptionRequest()
    }
}
