#if DEBUG
import AVFoundation
import Foundation
import Speech

/// A deliberately small, fail-closed adapter around Apple's on-device speech recognizer.
/// It never permits server-backed recognition: unsupported devices surface an error instead.
@MainActor
final class OnDeviceSpeechRecognizer {
    enum RecognitionError: LocalizedError {
        case speechPermissionDenied
        case microphonePermissionDenied
        case recognizerUnavailable
        case onDeviceRecognitionUnavailable
        case invalidAudioFormat
        case noSpeechDetected
        case recognitionFailed(String)

        var errorDescription: String? {
            switch self {
            case .speechPermissionDenied:
                return "Speech Recognition permission is required for push-to-talk."
            case .microphonePermissionDenied:
                return "Microphone permission is required for push-to-talk."
            case .recognizerUnavailable:
                return "English speech recognition is unavailable right now."
            case .onDeviceRecognitionUnavailable:
                return "This device does not support offline speech recognition. No audio was sent to a server."
            case .invalidAudioFormat:
                return "The microphone did not provide a usable audio format."
            case .noSpeechDetected:
                return "No speech was recognized. Hold the microphone and try again."
            case .recognitionFailed(let detail):
                return "On-device speech recognition failed: \(detail)"
            }
        }
    }

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var bestTranscript = ""
    private var recognitionFailure: String?
    private var receivedFinalResult = false
    private var hasInputTap = false

    func start() async throws {
        cancel()

        guard await Self.requestSpeechAuthorization() == .authorized else {
            throw RecognitionError.speechPermissionDenied
        }
        try Task.checkCancellation()
        guard await Self.requestMicrophonePermission() else {
            throw RecognitionError.microphonePermissionDenied
        }
        try Task.checkCancellation()

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
            throw RecognitionError.recognizerUnavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw RecognitionError.onDeviceRecognitionUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.defaultToSpeaker, .duckOthers]
            )
            try session.setActive(true)

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw RecognitionError.invalidAudioFormat
            }

            bestTranscript = ""
            recognitionFailure = nil
            receivedFinalResult = false
            recognitionRequest = request
            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let transcript = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal ?? false
                let failure = error?.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let transcript, !transcript.isEmpty {
                        self.bestTranscript = transcript
                    }
                    self.receivedFinalResult = isFinal
                    if let failure { self.recognitionFailure = failure }
                }
            }

            input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
                request.append(buffer)
            }
            hasInputTap = true
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            cancel()
            throw error
        }
    }

    func stop() async throws -> String {
        guard let request = recognitionRequest else {
            throw RecognitionError.noSpeechDetected
        }

        stopCapturingAudio()
        request.endAudio()

        // Give the local recognizer a short bounded window to deliver its final result.
        for _ in 0..<15 where !receivedFinalResult {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let transcript = bestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let failure = recognitionFailure
        finishRecognition()

        if !transcript.isEmpty { return transcript }
        if let failure { throw RecognitionError.recognitionFailed(failure) }
        throw RecognitionError.noSpeechDetected
    }

    func cancel() {
        recognitionRequest?.endAudio()
        stopCapturingAudio()
        finishRecognition()
    }

    private func stopCapturingAudio() {
        if audioEngine.isRunning { audioEngine.stop() }
        if hasInputTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInputTap = false
        }
    }

    private func finishRecognition() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private static func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
#endif
