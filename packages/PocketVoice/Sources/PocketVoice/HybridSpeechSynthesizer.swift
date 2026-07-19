import Foundation
import Network

public protocol ConnectivityProviding: Sendable {
    func isOnline() async -> Bool
}

public actor HybridSpeechSynthesizer: SpeechSynthesizer {
    private struct ActiveInvocation: Equatable {
        let requestID: UUID
        let generation: UInt64
    }

    private let premium: any SpeechSynthesizer
    private let offline: any SpeechSynthesizer
    private let connectivity: any ConnectivityProviding
    private var lifecycleGeneration: UInt64 = 0
    private var activeInvocation: ActiveInvocation?
    private var stopTail: Task<Void, Never>?
    private var stopTailID: UUID?

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
        lifecycleGeneration += 1
        let invocation = ActiveInvocation(
            requestID: request.id,
            generation: lifecycleGeneration
        )
        activeInvocation = invocation
        defer { clearIfCurrent(invocation) }

        await quiesceBackends()
        try ensureActive(invocation)

        guard await connectivity.isOnline() else {
            try ensureActive(invocation)
            return try await finishOffline(request, invocation: invocation)
        }

        do {
            let metrics = try await premium.speak(request)
            try ensureActive(invocation)
            return metrics
        } catch VoiceError.cancelled {
            throw VoiceError.cancelled
        } catch is CancellationError {
            throw VoiceError.cancelled
        } catch {
            try ensureActive(invocation)
            return try await finishOffline(request, invocation: invocation)
        }
    }

    public func stop() async {
        lifecycleGeneration += 1
        activeInvocation = nil
        await quiesceBackends()
    }

    private func finishOffline(
        _ request: SpeechSynthesisRequest,
        invocation: ActiveInvocation
    ) async throws -> SpeechPlaybackMetrics {
        do {
            let metrics = try await offline.speak(request)
            try ensureActive(invocation)
            return metrics
        } catch {
            let wasCurrent = activeInvocation == invocation
            if !wasCurrent || error is CancellationError || error as? VoiceError == .cancelled {
                throw VoiceError.cancelled
            }
            throw error
        }
    }

    private func ensureActive(_ invocation: ActiveInvocation) throws {
        guard activeInvocation == invocation, !Task.isCancelled else {
            throw VoiceError.cancelled
        }
    }

    private func clearIfCurrent(_ invocation: ActiveInvocation) {
        if activeInvocation == invocation { activeInvocation = nil }
    }

    func hasActiveRequest(_ requestID: UUID) -> Bool {
        activeInvocation?.requestID == requestID
    }

    /// Serialize stop operations across actor reentrancy. A newer request cannot start playback until every stop
    /// queued by an older request has completed, so stale cleanup can never stop the newer generation.
    private func quiesceBackends() async {
        let previous = stopTail
        let premium = self.premium
        let offline = self.offline
        let tailID = UUID()
        let tail = Task {
            if let previous { await previous.value }
            async let premiumStop: Void = premium.stop()
            async let offlineStop: Void = offline.stop()
            _ = await (premiumStop, offlineStop)
        }
        stopTail = tail
        stopTailID = tailID
        await tail.value
        if stopTailID == tailID {
            stopTail = nil
            stopTailID = nil
        }
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
