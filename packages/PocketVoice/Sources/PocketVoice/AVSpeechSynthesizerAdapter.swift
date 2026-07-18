import AVFoundation
import Foundation
import PocketContracts

public actor AVSpeechSynthesizerAdapter: SpeechSynthesizer {
    private let driverTask: Task<AVSpeechDriver, Never>
    private var activeRequestID: UUID?

    public init() {
        driverTask = Task { @MainActor in AVSpeechDriver() }
    }

    public func speak(_ request: SpeechSynthesisRequest) async throws -> SpeechPlaybackMetrics {
        let driver = await driverTask.value
        if activeRequestID != nil {
            await driver.stop()
        }
        activeRequestID = request.id

        do {
            let timing = try await withTaskCancellationHandler {
                try await driver.speak(request)
            } onCancel: {
                Task { await self.cancel(requestID: request.id) }
            }
            try Task.checkCancellation()
            guard activeRequestID == request.id else { throw VoiceError.cancelled }
            activeRequestID = nil
            return SpeechPlaybackMetrics(
                backend: .avSpeechOffline,
                firstAudioMeasurement: .avSpeechDidStartCallback,
                firstAudioMilliseconds: timing.firstAudioMilliseconds,
                totalMilliseconds: timing.totalMilliseconds,
                characterCount: request.text.count,
                residentMemoryBytes: VoiceRuntimeSnapshot.residentMemoryBytes,
                thermalState: VoiceRuntimeSnapshot.thermalLevel
            )
        } catch {
            if activeRequestID == request.id { activeRequestID = nil }
            if error is CancellationError || Task.isCancelled {
                throw VoiceError.cancelled
            }
            throw error
        }
    }

    public func stop() async {
        activeRequestID = nil
        await driverTask.value.stop()
    }

    private func cancel(requestID: UUID) async {
        guard activeRequestID == requestID else { return }
        activeRequestID = nil
        await driverTask.value.stop()
    }
}

private struct AVSpeechTiming: Sendable {
    let firstAudioMilliseconds: Double
    let totalMilliseconds: Double
}

@MainActor
private final class AVSpeechDriver: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private struct ActiveSpeech {
        let requestID: UUID
        let utterance: AVSpeechUtterance
        let started: ContinuousClock.Instant
        let continuation: CheckedContinuation<AVSpeechTiming, Error>
        var firstAudioAt: ContinuousClock.Instant?
    }

    private let synthesizer = AVSpeechSynthesizer()
    private var active: ActiveSpeech?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ request: SpeechSynthesisRequest) async throws -> AVSpeechTiming {
        guard active == nil else {
            throw VoiceError.synthesisFailed("AVSpeechSynthesizer is busy")
        }

        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.defaultToSpeaker, .allowBluetooth]
            )
            try session.setActive(true)
        } catch {
            throw VoiceError.audioSessionFailed(error.localizedDescription)
        }
        #endif

        let utterance = AVSpeechUtterance(string: request.text)
        utterance.voice = AVSpeechSynthesisVoice(language: request.localeIdentifier)
        let settings = Self.settings(for: request.tone)
        utterance.rate = settings.rate
        utterance.pitchMultiplier = settings.pitch
        utterance.volume = 1

        return try await withCheckedThrowingContinuation { continuation in
            active = ActiveSpeech(
                requestID: request.id,
                utterance: utterance,
                started: .now,
                continuation: continuation,
                firstAudioAt: nil
            )
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        guard active != nil else { return }
        _ = synthesizer.stopSpeaking(at: .immediate)
        finish(.failure(VoiceError.cancelled))
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        guard active?.utterance === utterance else { return }
        if active?.firstAudioAt == nil { active?.firstAudioAt = .now }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard let active, active.utterance === utterance else { return }
        let firstAudioAt = active.firstAudioAt ?? ContinuousClock.now
        finish(
            .success(
                AVSpeechTiming(
                    firstAudioMilliseconds: active.started.duration(to: firstAudioAt).voiceMilliseconds,
                    totalMilliseconds: active.started.duration(to: .now).voiceMilliseconds
                )
            )
        )
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard active?.utterance === utterance else { return }
        finish(.failure(VoiceError.cancelled))
    }

    private func finish(_ result: Result<AVSpeechTiming, Error>) {
        guard let active else { return }
        self.active = nil
        active.continuation.resume(with: result)
    }

    private static func settings(for tone: BriefingTone) -> (rate: Float, pitch: Float) {
        switch tone {
        case .neutral: return (0.50, 1.00)
        case .urgent: return (0.56, 1.02)
        case .calm: return (0.46, 0.96)
        case .celebratory: return (0.51, 1.06)
        }
    }
}
