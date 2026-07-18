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
    private var attached = false
    private var pendingBuffers = 0
    private var scheduledFrames: Int64 = 0
    private var playbackGeneration: UInt64 = 0
    private var finishContinuation: CheckedContinuation<Void, Error>?
    private var finishTimeoutTask: Task<Void, Never>?

    init?(sampleRate: Double) {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }
        self.format = format
    }

    func prepare() throws {
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

        if !attached {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            attached = true
        }
        if !engine.isRunning {
            engine.prepare()
            do {
                try engine.start()
            } catch {
                throw VoiceError.audioSessionFailed(error.localizedDescription)
            }
        }
        if !player.isPlaying { player.play() }
    }

    func enqueue(_ data: Data) throws {
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

        pendingBuffers += 1
        scheduledFrames += Int64(frameCount)
        let generation = playbackGeneration
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { await self?.bufferCompleted(generation: generation) }
        }
    }

    func finish() async throws {
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
        try Task.checkCancellation()
        finishTimeoutTask?.cancel()
        finishTimeoutTask = nil
        playbackGeneration &+= 1
        player.stop()
        engine.stop()
        scheduledFrames = 0
    }

    func stop() {
        playbackGeneration &+= 1
        player.stop()
        engine.stop()
        pendingBuffers = 0
        scheduledFrames = 0
        finishTimeoutTask?.cancel()
        finishTimeoutTask = nil
        finishContinuation?.resume(throwing: VoiceError.cancelled)
        finishContinuation = nil
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
        finishContinuation?.resume(throwing: VoiceError.audioSessionFailed("PCM playback did not drain before its deadline"))
        finishContinuation = nil
    }
}
