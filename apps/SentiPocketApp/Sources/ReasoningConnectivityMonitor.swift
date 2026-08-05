import Foundation
import Network
import PocketUI

/// The small path-state surface reasoning needs. Keeping `NWPath` behind this protocol lets the app prove routing,
/// cancellation, and monitor ownership without fabricating framework objects in tests.
enum ReasoningPathStatus: Sendable {
    case satisfied
    case requiresConnection
    case unsatisfied
    case unknown
}

protocol ReasoningPathStatusMonitoring: AnyObject, Sendable {
    var statusUpdateHandler: (@Sendable (ReasoningPathStatus) -> Void)? { get set }
    func start()
    func cancel()
}

/// Produces one connectivity stream per observation. A stream owns one fresh `NWPathMonitor`; terminating that
/// stream clears its callback and cancels that exact monitor, so inactive/disappeared phone views retain no network
/// observer. The one-element newest-value buffer prevents path churn from building an unbounded routing backlog.
struct ReasoningConnectivityUpdates: Sendable {
    private let makeMonitor: @Sendable () -> any ReasoningPathStatusMonitoring

    init() {
        makeMonitor = { NWReasoningPathStatusMonitor() }
    }

    init(makeMonitor: @escaping @Sendable () -> any ReasoningPathStatusMonitoring) {
        self.makeMonitor = makeMonitor
    }

    func stream() -> AsyncStream<PocketConnectivity> {
        let monitor = makeMonitor()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.yield(.reconnecting)
            monitor.statusUpdateHandler = { status in
                continuation.yield(Self.connectivity(for: status))
            }
            continuation.onTermination = { @Sendable _ in
                monitor.statusUpdateHandler = nil
                monitor.cancel()
            }
            monitor.start()
        }
    }

    private static func connectivity(for status: ReasoningPathStatus) -> PocketConnectivity {
        switch status {
        case .satisfied:
            return .online
        case .requiresConnection:
            return .reconnecting
        case .unsatisfied, .unknown:
            return .offline(cachedAt: nil)
        }
    }
}

private final class NWReasoningPathStatusMonitor: ReasoningPathStatusMonitoring, @unchecked Sendable {
    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.plexaura.sentipocket.reasoning-connectivity")
    private let lock = NSLock()
    private var storedHandler: (@Sendable (ReasoningPathStatus) -> Void)?

    var statusUpdateHandler: (@Sendable (ReasoningPathStatus) -> Void)? {
        get { lock.withLock { storedHandler } }
        set { lock.withLock { storedHandler = newValue } }
    }

    init(monitor: NWPathMonitor = NWPathMonitor()) {
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            self?.emit(Self.status(for: path.status))
        }
    }

    func start() {
        monitor.start(queue: queue)
    }

    func cancel() {
        statusUpdateHandler = nil
        monitor.pathUpdateHandler = nil
        monitor.cancel()
    }

    private func emit(_ status: ReasoningPathStatus) {
        let handler = lock.withLock { storedHandler }
        handler?(status)
    }

    private static func status(for status: NWPath.Status) -> ReasoningPathStatus {
        switch status {
        case .satisfied:
            return .satisfied
        case .requiresConnection:
            return .requiresConnection
        case .unsatisfied:
            return .unsatisfied
        @unknown default:
            return .unknown
        }
    }
}
