import AVFoundation
import Foundation

public actor MicrophoneCapture {
    static let frameBufferCapacity = 8

    private var engine: AVAudioEngine?
    private let frameSink = CaptureFrameSink()
    private var tapInstalled = false
    private var notificationTokens: [NSObjectProtocol] = []
    private var generations = CaptureGenerationGate()

    public init() {}

    public static func requestPermission() async -> Bool {
        #if os(iOS)
        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        #else
        return true
        #endif
    }

    public func start() async throws -> AsyncThrowingStream<MicrophoneFrame, Error> {
        guard engine == nil else {
            throw VoiceError.audioSessionFailed("microphone capture is already active")
        }

        #if os(iOS)
        guard AVAudioSession.sharedInstance().recordPermission == .granted else {
            throw VoiceError.microphonePermissionDenied
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.defaultToSpeaker, .allowBluetooth]
            )
            try session.setPreferredIOBufferDuration(0.01)
            try session.setActive(true)
        } catch {
            throw VoiceError.audioSessionFailed(error.localizedDescription)
        }
        #endif

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hardwareFormat = input.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0,
              let captureFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: hardwareFormat.sampleRate,
                channels: 1,
                interleaved: false
              ) else {
            #if os(iOS)
            Self.deactivateAudioSession()
            #endif
            throw VoiceError.audioSessionFailed("no valid microphone input format")
        }

        let streamPair = AsyncThrowingStream<MicrophoneFrame, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(Self.frameBufferCapacity)
        )
        let captureID = generations.begin()
        let stream = streamPair.stream
        frameSink.begin(captureID: captureID, continuation: streamPair.continuation)
        streamPair.continuation.onTermination = { @Sendable _ in
            Task { await self.stop(captureID: captureID) }
        }

        let frameSink = self.frameSink
        let captureSampleRate = captureFormat.sampleRate
        input.installTap(onBus: 0, bufferSize: 1_024, format: captureFormat) { buffer, _ in
            guard let channel = buffer.floatChannelData?.pointee else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            guard let frame = try? MicrophoneFrame(samples: samples, sampleRate: captureSampleRate) else {
                return
            }
            // Overflow finishes the stream; onTermination owns actor-isolated engine teardown.
            _ = frameSink.yield(frame, captureID: captureID)
        }
        tapInstalled = true

        do {
            engine.prepare()
            try engine.start()
            self.engine = engine
            installAudioSessionObservers(captureID: captureID)
            return stream
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            _ = generations.end(captureID)
            frameSink.finish(
                captureID: captureID,
                throwing: VoiceError.audioSessionFailed(error.localizedDescription)
            )
            #if os(iOS)
            Self.deactivateAudioSession()
            #endif
            throw VoiceError.audioSessionFailed(error.localizedDescription)
        }
    }

    public func stop() async {
        guard let captureID = generations.activeID else { return }
        await stop(captureID: captureID)
    }

    private func stop(captureID: UUID) async {
        guard generations.end(captureID) else { return }
        removeAudioSessionObservers()
        if tapInstalled, let engine {
            engine.inputNode.removeTap(onBus: 0)
        }
        tapInstalled = false
        engine?.stop()
        engine = nil
        frameSink.finish(captureID: captureID)

        #if os(iOS)
        Self.deactivateAudioSession()
        #endif
    }

    #if os(iOS)
    private static func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    #endif

    private func installAudioSessionObservers(captureID: UUID) {
        #if os(iOS)
        let center = NotificationCenter.default
        notificationTokens.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: nil
            ) { [weak self] notification in
                let rawValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                Task { await self?.handleInterruption(rawValue, captureID: captureID) }
            }
        )
        notificationTokens.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: AVAudioSession.sharedInstance(),
                queue: nil
            ) { [weak self] notification in
                let rawValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                Task { await self?.handleRouteChange(rawValue, captureID: captureID) }
            }
        )
        notificationTokens.append(
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: AVAudioSession.sharedInstance(),
                queue: nil
            ) { [weak self] _ in
                Task { await self?.failActiveCapture("audio media services reset", captureID: captureID) }
            }
        )
        #endif
    }

    private func removeAudioSessionObservers() {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        notificationTokens.removeAll()
    }

    private func handleInterruption(_ rawValue: UInt?, captureID: UUID) async {
        #if os(iOS)
        guard let rawValue,
              AVAudioSession.InterruptionType(rawValue: rawValue) == .began else { return }
        await failActiveCapture("audio session interrupted", captureID: captureID)
        #endif
    }

    private func handleRouteChange(_ rawValue: UInt?, captureID: UUID) async {
        #if os(iOS)
        guard let rawValue, let reason = AVAudioSession.RouteChangeReason(rawValue: rawValue) else { return }
        switch reason {
        case .oldDeviceUnavailable, .noSuitableRouteForCategory, .routeConfigurationChange:
            await failActiveCapture("audio route became unavailable", captureID: captureID)
        default:
            break
        }
        #endif
    }

    private func failActiveCapture(_ reason: String, captureID: UUID) async {
        guard generations.accepts(captureID) else { return }
        frameSink.finish(captureID: captureID, throwing: VoiceError.audioSessionFailed(reason))
        await stop(captureID: captureID)
    }
}

enum CaptureFrameDelivery: Equatable {
    case accepted
    case stale
    case terminated
    case overflow
}

final class CaptureFrameSink: @unchecked Sendable {
    typealias Continuation = AsyncThrowingStream<MicrophoneFrame, Error>.Continuation

    private let lock = NSLock()
    private var activeCaptureID: UUID?
    private var continuation: Continuation?

    func begin(captureID: UUID, continuation: Continuation) {
        lock.lock()
        activeCaptureID = captureID
        self.continuation = continuation
        lock.unlock()
    }

    func yield(_ frame: MicrophoneFrame, captureID: UUID) -> CaptureFrameDelivery {
        lock.lock()
        guard activeCaptureID == captureID, let continuation else {
            lock.unlock()
            return .stale
        }

        switch continuation.yield(frame) {
        case .enqueued(_):
            lock.unlock()
            return .accepted
        case .terminated:
            activeCaptureID = nil
            self.continuation = nil
            lock.unlock()
            return .terminated
        case .dropped(_):
            activeCaptureID = nil
            self.continuation = nil
            lock.unlock()
            continuation.finish(
                throwing: VoiceError.audioSessionFailed("microphone frame buffer overflow")
            )
            return .overflow
        @unknown default:
            activeCaptureID = nil
            self.continuation = nil
            lock.unlock()
            continuation.finish(
                throwing: VoiceError.audioSessionFailed("unknown microphone frame delivery state")
            )
            return .terminated
        }
    }

    func finish(captureID: UUID, throwing error: Error? = nil) {
        lock.lock()
        guard activeCaptureID == captureID, let continuation else {
            lock.unlock()
            return
        }
        activeCaptureID = nil
        self.continuation = nil
        lock.unlock()

        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }
}

struct CaptureGenerationGate: Sendable {
    private(set) var activeID: UUID?

    mutating func begin() -> UUID {
        let id = UUID()
        activeID = id
        return id
    }

    func accepts(_ id: UUID) -> Bool {
        activeID == id
    }

    mutating func end(_ id: UUID) -> Bool {
        guard activeID == id else { return false }
        activeID = nil
        return true
    }
}
