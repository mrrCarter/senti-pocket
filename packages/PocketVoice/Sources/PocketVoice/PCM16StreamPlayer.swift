import AVFoundation
import Foundation

final class NoRedirectTaskDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = NoRedirectTaskDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

actor PCM16StreamPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private let audioSessionLeases: DuplexAudioSessionLeaseManager
    private var audioSessionLease: DuplexAudioSessionLease?
    private var attached = false
    private var pendingBuffers = 0
    private var scheduledFrames: Int64 = 0
    private var playbackGeneration: UInt64 = 0
    private var finishContinuation: CheckedContinuation<Void, Error>?
    private var finishTimeoutTask: Task<Void, Never>?

    init?(
        sampleRate: Double,
        audioSessionLeases: DuplexAudioSessionLeaseManager = .shared
    ) {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }
        self.format = format
        self.audioSessionLeases = audioSessionLeases
    }

    func prepare() throws {
        try Task.checkCancellation()
        if audioSessionLease == nil {
            let lease = try audioSessionLeases.acquire()
            do {
                try Task.checkCancellation()
            } catch {
                let cleanupError = audioSessionLeases.release(lease).error
                if let cleanupError {
                    throw Self.audioSessionFailure(
                        "playback preparation cancelled",
                        cleanupError: cleanupError
                    )
                }
                throw error
            }
            audioSessionLease = lease
        }

        if !attached {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            attached = true
        }
        if !engine.isRunning {
            engine.prepare()
            try checkCancellationAndStop()
            do {
                try engine.start()
            } catch {
                let cleanupError = releaseAudioSession()
                throw Self.audioSessionFailure(
                    error.localizedDescription,
                    cleanupError: cleanupError
                )
            }
        }
        try checkCancellationAndStop()
        if !player.isPlaying { player.play() }
    }

    func enqueue(_ data: Data) throws {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count.isMultiple(of: 2) else {
            throw VoiceError.malformedPCMStream
        }
        let frameCount = data.count / 2
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ), let channel = buffer.floatChannelData?.pointee else {
            throw VoiceError.malformedPCMStream
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for index in 0..<frameCount {
                let low = UInt16(bytes[index * 2])
                let high = UInt16(bytes[index * 2 + 1]) << 8
                let sample = Int16(bitPattern: low | high)
                channel[index] = Float(sample) / 32_768
            }
        }

        try Task.checkCancellation()
        pendingBuffers += 1
        scheduledFrames += Int64(frameCount)
        let generation = playbackGeneration
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { await self?.bufferCompleted(generation: generation) }
        }
    }

    func finish() async throws {
        try checkCancellationAndStop()
        if pendingBuffers > 0 {
            let playbackSeconds = Double(scheduledFrames) / format.sampleRate
            let timeoutSeconds = min(max(playbackSeconds + 10, 15), 600)
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    finishContinuation = continuation
                    finishTimeoutTask = Task { [weak self] in
                        do {
                            try await Task.sleep(for: .seconds(timeoutSeconds))
                        } catch {
                            return
                        }
                        await self?.playbackTimedOut()
                    }
                }
            } onCancel: {
                Task { await self.stop() }
            }
        }
        try checkCancellationAndStop()
        finishTimeoutTask?.cancel()
        finishTimeoutTask = nil
        playbackGeneration &+= 1
        player.stop()
        engine.stop()
        scheduledFrames = 0
        if let cleanupError = releaseAudioSession() {
            throw cleanupError
        }
    }

    @discardableResult
    func stop() -> VoiceError? {
        playbackGeneration &+= 1
        player.stop()
        engine.stop()
        pendingBuffers = 0
        scheduledFrames = 0
        finishTimeoutTask?.cancel()
        finishTimeoutTask = nil
        let cleanupError = releaseAudioSession()
        if let cleanupError {
            finishContinuation?.resume(
                throwing: Self.audioSessionFailure(
                    "playback cancelled",
                    cleanupError: cleanupError
                )
            )
        } else {
            finishContinuation?.resume(throwing: VoiceError.cancelled)
        }
        finishContinuation = nil
        return cleanupError
    }

    private func bufferCompleted(generation: UInt64) {
        guard generation == playbackGeneration else { return }
        pendingBuffers = max(0, pendingBuffers - 1)
        if pendingBuffers == 0 {
            finishTimeoutTask?.cancel()
            finishTimeoutTask = nil
            finishContinuation?.resume()
            finishContinuation = nil
        }
    }

    private func playbackTimedOut() {
        playbackGeneration &+= 1
        player.stop()
        engine.stop()
        pendingBuffers = 0
        scheduledFrames = 0
        finishTimeoutTask = nil
        let cleanupError = releaseAudioSession()
        finishContinuation?.resume(
            throwing: Self.audioSessionFailure(
                "PCM playback did not drain before its deadline",
                cleanupError: cleanupError
            )
        )
        finishContinuation = nil
    }

    private func releaseAudioSession() -> VoiceError? {
        guard let audioSessionLease else { return nil }
        self.audioSessionLease = nil
        return audioSessionLeases.release(audioSessionLease).error
    }

    private func checkCancellationAndStop() throws {
        do {
            try Task.checkCancellation()
        } catch {
            let cleanupError = stop()
            if let cleanupError {
                throw Self.audioSessionFailure("playback cancelled", cleanupError: cleanupError)
            }
            throw error
        }
    }

    private static func audioSessionFailure(
        _ reason: String,
        cleanupError: VoiceError?
    ) -> VoiceError {
        guard let cleanupError else { return .audioSessionFailed(reason) }
        return .audioSessionFailed("\(reason); \(cleanupError.localizedDescription)")
    }
}
