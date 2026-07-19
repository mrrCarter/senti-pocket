import AVFoundation
import Foundation

public actor MicrophoneCapture {
    static let frameBufferCapacity = 8

    private var engine: AVAudioEngine?
    private let frameSink = CaptureFrameSink()
    private let audioSessionLeases = DuplexAudioSessionLeaseManager.shared
    private var audioSessionLease: DuplexAudioSessionLease?
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
        #endif

        let audioSessionLease = try audioSessionLeases.acquire()
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setPreferredIOBufferDuration(0.01)
        } catch {
            let cleanupError = audioSessionLeases.release(audioSessionLease).error
            throw Self.audioSessionFailure(error.localizedDescription, cleanupError: cleanupError)
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
            let reason = "no valid microphone input format"
            let cleanupError = audioSessionLeases.release(audioSessionLease).error
            throw Self.audioSessionFailure(reason, cleanupError: cleanupError)
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
        input.installTap(onBus: 0, bufferSize: 1_024, format: captureFormat) { [weak self] buffer, _ in
            guard let channel = buffer.floatChannelData?.pointee else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            guard let frame = try? MicrophoneFrame(samples: samples, sampleRate: captureSampleRate) else {
                return
            }
            switch frameSink.yield(frame, captureID: captureID) {
            case .overflow:
                Task {
                    await self?.failActiveCapture(
                        "microphone frame buffer overflow",
                        captureID: captureID
                    )
                }
            case .unknown:
                Task {
                    await self?.failActiveCapture(
                        "unknown microphone frame delivery state",
                        captureID: captureID
                    )
                }
            case .accepted, .stale, .terminated, .terminalPending:
                break
            }
        }
        tapInstalled = true

        do {
            engine.prepare()
            try engine.start()
            self.engine = engine
            self.audioSessionLease = audioSessionLease
            installAudioSessionObservers(captureID: captureID)
            return stream
        } catch {
            let cleanupError = audioSessionLeases.release(audioSessionLease).error
            let failure = Self.audioSessionFailure(
                error.localizedDescription,
                cleanupError: cleanupError
            )
            input.removeTap(onBus: 0)
            tapInstalled = false
            _ = generations.end(captureID)
            frameSink.finish(
                captureID: captureID,
                throwing: failure
            )
            throw failure
        }
    }

    public func stop() async {
        guard let captureID = generations.activeID else { return }
        await stop(captureID: captureID)
    }

    private func stop(captureID: UUID, failureReason: String? = nil) async {
        guard generations.end(captureID) else { return }
        removeAudioSessionObservers()
        if tapInstalled, let engine {
            engine.inputNode.removeTap(onBus: 0)
        }
        tapInstalled = false
        engine?.stop()
        engine = nil
        let effectiveFailureReason = frameSink.pendingTerminalReason(captureID: captureID)
            ?? failureReason
        var cleanupError: VoiceError?
        if let audioSessionLease {
            self.audioSessionLease = nil
            cleanupError = audioSessionLeases.release(audioSessionLease).error
        }
        let completionError = effectiveFailureReason.map {
            Self.audioSessionFailure($0, cleanupError: cleanupError)
        } ?? cleanupError
        frameSink.finish(captureID: captureID, throwing: completionError)
    }

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
        await stop(captureID: captureID, failureReason: reason)
    }

    private static func audioSessionFailure(
        _ reason: String,
        cleanupError: VoiceError?
    ) -> VoiceError {
        guard let cleanupError else { return .audioSessionFailed(reason) }
        return .audioSessionFailed("\(reason); \(cleanupError.localizedDescription)")
    }
}

enum CaptureFrameDelivery: Equatable {
    case accepted
    case stale
    case terminated
    case terminalPending
    case overflow
    case unknown
}

final class CaptureFrameSink: @unchecked Sendable {
    typealias Continuation = AsyncThrowingStream<MicrophoneFrame, Error>.Continuation

    private let lock = NSLock()
    private var activeCaptureID: UUID?
    private var terminalCaptureID: UUID?
    private var terminalReason: String?
    private var continuation: Continuation?

    func begin(captureID: UUID, continuation: Continuation) {
        lock.lock()
        activeCaptureID = captureID
        terminalCaptureID = nil
        terminalReason = nil
        self.continuation = continuation
        lock.unlock()
    }

    func yield(_ frame: MicrophoneFrame, captureID: UUID) -> CaptureFrameDelivery {
        lock.lock()
        guard activeCaptureID == captureID, let continuation else {
            lock.unlock()
            return .stale
        }
        guard terminalCaptureID != captureID else {
            lock.unlock()
            return .terminalPending
        }

        switch continuation.yield(frame) {
        case .enqueued(_):
            lock.unlock()
            return .accepted
        case .terminated:
            activeCaptureID = nil
            terminalCaptureID = nil
            terminalReason = nil
            self.continuation = nil
            lock.unlock()
            return .terminated
        case .dropped(_):
            terminalCaptureID = captureID
            terminalReason = "microphone frame buffer overflow"
            lock.unlock()
            return .overflow
        @unknown default:
            terminalCaptureID = captureID
            terminalReason = "unknown microphone frame delivery state"
            lock.unlock()
            return .unknown
        }
    }

    func pendingTerminalReason(captureID: UUID) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard activeCaptureID == captureID, terminalCaptureID == captureID else { return nil }
        return terminalReason
    }

    func finish(captureID: UUID, throwing error: Error? = nil) {
        lock.lock()
        guard activeCaptureID == captureID, let continuation else {
            lock.unlock()
            return
        }
        activeCaptureID = nil
        terminalCaptureID = nil
        terminalReason = nil
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
