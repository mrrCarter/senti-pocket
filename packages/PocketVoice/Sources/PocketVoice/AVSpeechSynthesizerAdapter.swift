import AVFoundation
import Foundation
import PocketContracts

public actor AVSpeechSynthesizerAdapter: SpeechSynthesizer {
    private struct DriverStopBarrier: Sendable {
        let id: UUID
        let task: Task<Void, Never>
    }

    private let driverTask: Task<any AVSpeechDriving, Never>
    private var activeRequestID: UUID?
    private var stoppingGeneration: UInt64?
    private var lifecycleGeneration: UInt64 = 0
    private var stopBarrier: DriverStopBarrier?

    public init() {
        driverTask = Task { @MainActor in AVSpeechDriver() as any AVSpeechDriving }
    }

    init(driver: any AVSpeechDriving) {
        driverTask = Task { driver }
    }

    init(driverTask: Task<any AVSpeechDriving, Never>) {
        self.driverTask = driverTask
    }

    public func speak(_ request: SpeechSynthesisRequest) async throws -> SpeechPlaybackMetrics {
        let supersedesActiveSpeech = activeRequestID != nil
            || stoppingGeneration != nil
            || stopBarrier != nil
        let generation = claimLifecycle(requestID: request.id)
        let driver = await driverTask.value

        do {
            try Task.checkCancellation()
            guard isCurrent(requestID: request.id, generation: generation) else {
                throw VoiceError.cancelled
            }
            if supersedesActiveSpeech {
                let barrier = await awaitStopBarrier(driver: driver)
                try Task.checkCancellation()
                guard isCurrent(requestID: request.id, generation: generation) else {
                    throw VoiceError.cancelled
                }
                clearStopBarrier(barrier.id)
            }
            let timing = try await withTaskCancellationHandler {
                try await driver.speak(request)
            } onCancel: {
                Task {
                    await self.cancel(
                        requestID: request.id,
                        generation: generation,
                        driver: driver
                    )
                }
            }
            try Task.checkCancellation()
            guard isCurrent(requestID: request.id, generation: generation) else {
                throw VoiceError.cancelled
            }
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
            let wasCurrent = isCurrent(requestID: request.id, generation: generation)
            if wasCurrent {
                let barrier = await awaitStopBarrier(driver: driver)
                if isCurrent(requestID: request.id, generation: generation) {
                    clearStopBarrier(barrier.id)
                    activeRequestID = nil
                }
            }
            if Self.shouldReportCancellation(error, taskCancelled: Task.isCancelled) {
                throw VoiceError.cancelled
            }
            throw error
        }
    }

    public func stop() async {
        let generation = claimLifecycle(requestID: nil)
        let driver = await driverTask.value
        guard isCurrentStop(generation: generation) else { return }
        let barrier = await awaitStopBarrier(driver: driver)
        guard isCurrentStop(generation: generation) else { return }
        clearStopBarrier(barrier.id)
        stoppingGeneration = nil
    }

    func currentRequestID() -> UUID? {
        activeRequestID
    }

    func isStopping() -> Bool {
        stoppingGeneration != nil || stopBarrier != nil
    }

    private func cancel(
        requestID: UUID,
        generation: UInt64,
        driver: any AVSpeechDriving
    ) async {
        guard isCurrent(requestID: requestID, generation: generation) else { return }
        let barrier = await awaitStopBarrier(driver: driver)
        guard isCurrent(requestID: requestID, generation: generation) else { return }
        clearStopBarrier(barrier.id)
        activeRequestID = nil
    }

    private func claimLifecycle(requestID: UUID?) -> UInt64 {
        lifecycleGeneration &+= 1
        activeRequestID = requestID
        stoppingGeneration = requestID == nil ? lifecycleGeneration : nil
        return lifecycleGeneration
    }

    private func isCurrent(requestID: UUID, generation: UInt64) -> Bool {
        lifecycleGeneration == generation && activeRequestID == requestID
    }

    private func isCurrentStop(generation: UInt64) -> Bool {
        lifecycleGeneration == generation
            && activeRequestID == nil
            && stoppingGeneration == generation
    }

    private func beginStopBarrier(driver: any AVSpeechDriving) -> DriverStopBarrier {
        if let stopBarrier { return stopBarrier }
        let barrier = DriverStopBarrier(
            id: UUID(),
            task: Task { await driver.stop() }
        )
        stopBarrier = barrier
        return barrier
    }

    private func awaitStopBarrier(driver: any AVSpeechDriving) async -> DriverStopBarrier {
        let barrier = beginStopBarrier(driver: driver)
        await barrier.task.value
        return barrier
    }

    private func clearStopBarrier(_ id: UUID) {
        guard stopBarrier?.id == id else { return }
        stopBarrier = nil
    }

    static func shouldReportCancellation(_ error: Error, taskCancelled: Bool) -> Bool {
        if let voiceError = error as? VoiceError,
           case .audioSessionFailed = voiceError {
            return false
        }
        return taskCancelled
            || error is CancellationError
            || error as? VoiceError == .cancelled
    }

}

struct AVSpeechTiming: Sendable {
    let firstAudioMilliseconds: Double
    let totalMilliseconds: Double
}

protocol AVSpeechDriving: Sendable {
    func speak(_ request: SpeechSynthesisRequest) async throws -> AVSpeechTiming
    func stop() async
}

@MainActor
private final class AVSpeechDriver: NSObject, AVSpeechDriving, AVSpeechSynthesizerDelegate,
    @unchecked Sendable {
    private struct ActiveSpeech {
        let requestID: UUID
        let utterance: AVSpeechUtterance
        let started: ContinuousClock.Instant
        let audioSessionLease: DuplexAudioSessionLease
        let continuation: CheckedContinuation<AVSpeechTiming, Error>
        var firstAudioAt: ContinuousClock.Instant?
    }

    private let synthesizer = AVSpeechSynthesizer()
    private let audioSessionLeases = DuplexAudioSessionLeaseManager.shared
    private var active: ActiveSpeech?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ request: SpeechSynthesisRequest) async throws -> AVSpeechTiming {
        guard active == nil else {
            throw VoiceError.synthesisFailed("AVSpeechSynthesizer is busy")
        }

        try Task.checkCancellation()
        let audioSessionLease = try audioSessionLeases.acquire()
        do {
            try Task.checkCancellation()
        } catch {
            let cleanupError = audioSessionLeases.release(audioSessionLease).error
            if let cleanupError {
                throw VoiceError.audioSessionFailed(
                    "speech cancelled before playback; \(cleanupError.localizedDescription)"
                )
            }
            throw error
        }

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
                audioSessionLease: audioSessionLease,
                continuation: continuation,
                firstAudioAt: nil
            )
            synthesizer.speak(utterance)
        }
    }

    func stop() async {
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
        let cleanupError = audioSessionLeases.release(active.audioSessionLease).error
        switch (result, cleanupError) {
        case (.success(_), let cleanupError?):
            active.continuation.resume(throwing: cleanupError)
        case (.failure(let error), let cleanupError?):
            active.continuation.resume(
                throwing: VoiceError.audioSessionFailed(
                    "\(error.localizedDescription); \(cleanupError.localizedDescription)"
                )
            )
        default:
            active.continuation.resume(with: result)
        }
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
