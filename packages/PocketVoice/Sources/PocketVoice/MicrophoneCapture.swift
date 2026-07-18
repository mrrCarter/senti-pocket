import AVFoundation
import Foundation

public actor MicrophoneCapture {
    private var engine: AVAudioEngine?
    private var continuation: AsyncThrowingStream<MicrophoneFrame, Error>.Continuation?
    private var tapInstalled = false
    private var notificationTokens: [NSObjectProtocol] = []

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
            throw VoiceError.audioSessionFailed("no valid microphone input format")
        }

        let streamPair = AsyncThrowingStream<MicrophoneFrame, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        let stream = streamPair.stream
        continuation = streamPair.continuation
        streamPair.continuation.onTermination = { @Sendable _ in
            Task { await self.stop() }
        }

        input.installTap(onBus: 0, bufferSize: 1_024, format: captureFormat) { [weak self] buffer, _ in
            guard let channel = buffer.floatChannelData?.pointee else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            guard let frame = try? MicrophoneFrame(samples: samples, sampleRate: captureFormat.sampleRate) else {
                return
            }
            Task { await self?.yield(frame) }
        }
        tapInstalled = true

        do {
            engine.prepare()
            try engine.start()
            self.engine = engine
            installAudioSessionObservers()
            return stream
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            continuation?.finish(throwing: VoiceError.audioSessionFailed(error.localizedDescription))
            continuation = nil
            throw VoiceError.audioSessionFailed(error.localizedDescription)
        }
    }

    public func stop() async {
        removeAudioSessionObservers()
        if tapInstalled, let engine {
            engine.inputNode.removeTap(onBus: 0)
        }
        tapInstalled = false
        engine?.stop()
        engine = nil
        continuation?.finish()
        continuation = nil

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func yield(_ frame: MicrophoneFrame) {
        continuation?.yield(frame)
    }

    private func installAudioSessionObservers() {
        #if os(iOS)
        let center = NotificationCenter.default
        notificationTokens.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: nil
            ) { [weak self] notification in
                let rawValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                Task { await self?.handleInterruption(rawValue) }
            }
        )
        notificationTokens.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: AVAudioSession.sharedInstance(),
                queue: nil
            ) { [weak self] notification in
                let rawValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                Task { await self?.handleRouteChange(rawValue) }
            }
        )
        notificationTokens.append(
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: AVAudioSession.sharedInstance(),
                queue: nil
            ) { [weak self] _ in
                Task { await self?.failActiveCapture("audio media services reset") }
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

    private func handleInterruption(_ rawValue: UInt?) async {
        #if os(iOS)
        guard let rawValue,
              AVAudioSession.InterruptionType(rawValue: rawValue) == .began else { return }
        await failActiveCapture("audio session interrupted")
        #endif
    }

    private func handleRouteChange(_ rawValue: UInt?) async {
        #if os(iOS)
        guard let rawValue, let reason = AVAudioSession.RouteChangeReason(rawValue: rawValue) else { return }
        switch reason {
        case .oldDeviceUnavailable, .noSuitableRouteForCategory, .routeConfigurationChange:
            await failActiveCapture("audio route became unavailable")
        default:
            break
        }
        #endif
    }

    private func failActiveCapture(_ reason: String) async {
        continuation?.finish(throwing: VoiceError.audioSessionFailed(reason))
        continuation = nil
        await stop()
    }
}
