import Foundation
import Network

public protocol ConnectivityProviding: Sendable {
    func isOnline() async -> Bool
}

public actor HybridSpeechSynthesizer: SpeechSynthesizer {
    private let premium: any SpeechSynthesizer
    private let offline: any SpeechSynthesizer
    private let connectivity: any ConnectivityProviding
    private var activeRequestID: UUID?

    public init(
        premium: any SpeechSynthesizer,
        offline: any SpeechSynthesizer,
        connectivity: any ConnectivityProviding
    ) {
        self.premium = premium
        self.offline = offline
        self.connectivity = connectivity
    }

    public func speak(_ request: SpeechSynthesisRequest) async throws -> SpeechPlaybackMetrics {
        activeRequestID = request.id
        async let premiumStop: Void = premium.stop()
        async let offlineStop: Void = offline.stop()
        _ = await (premiumStop, offlineStop)
        try ensureActive(request.id)

        guard await connectivity.isOnline() else {
            try ensureActive(request.id)
            return try await finishOffline(request)
        }

        do {
            let metrics = try await premium.speak(request)
            try ensureActive(request.id)
            activeRequestID = nil
            return metrics
        } catch VoiceError.cancelled {
            clearIfCurrent(request.id)
            throw VoiceError.cancelled
        } catch is CancellationError {
            clearIfCurrent(request.id)
            throw VoiceError.cancelled
        } catch {
            try ensureActive(request.id)
            return try await finishOffline(request)
        }
    }

    public func stop() async {
        activeRequestID = nil
        async let premiumStop: Void = premium.stop()
        async let offlineStop: Void = offline.stop()
        _ = await (premiumStop, offlineStop)
    }

    private func finishOffline(_ request: SpeechSynthesisRequest) async throws -> SpeechPlaybackMetrics {
        do {
            let metrics = try await offline.speak(request)
            try ensureActive(request.id)
            activeRequestID = nil
            return metrics
        } catch {
            let wasCurrent = activeRequestID == request.id
            clearIfCurrent(request.id)
            if !wasCurrent || error is CancellationError || error as? VoiceError == .cancelled {
                throw VoiceError.cancelled
            }
            throw error
        }
    }

    private func ensureActive(_ requestID: UUID) throws {
        guard activeRequestID == requestID, !Task.isCancelled else {
            throw VoiceError.cancelled
        }
    }

    private func clearIfCurrent(_ requestID: UUID) {
        if activeRequestID == requestID { activeRequestID = nil }
    }
}

public final class NetworkPathConnectivity: ConnectivityProviding, @unchecked Sendable {
    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var online = false

    public init(requiredInterfaceType: NWInterface.InterfaceType? = nil) {
        if let requiredInterfaceType {
            monitor = NWPathMonitor(requiredInterfaceType: requiredInterfaceType)
        } else {
            monitor = NWPathMonitor()
        }
        queue = DispatchQueue(label: "com.sentinelayer.pocket.voice.network-path")
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.withLock { self.online = path.status == .satisfied }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    public func isOnline() async -> Bool {
        lock.withLock { online }
    }
}

public struct FixedConnectivity: ConnectivityProviding {
    private let online: Bool

    public init(online: Bool) {
        self.online = online
    }

    public func isOnline() async -> Bool { online }
}
