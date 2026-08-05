import Combine
import Foundation
import PocketCall
import PocketSyncClient

/// The exact membership-authorized row selected by the user, bound to the authentication epoch that exposed it.
/// Production composition emits this only after `SelectedSessionDetailCoordinator` revalidates the visible row;
/// the type is routing identity, not an authorization capability, and the gateway independently rechecks membership.
struct ExactCheckpointTarget: Equatable, Sendable {
    let authenticationRevision: UInt64
    let sessionId: String
    let checkpointId: String
}

enum CheckpointPocketFailure: Equatable, Sendable {
    case notConfigured
    case reauthenticationRequired
    case accessDenied
    case network
    case rateLimited
    case service
    case invalidData

    var title: String {
        switch self {
        case .notConfigured: return "Checkpoint service not configured"
        case .reauthenticationRequired: return "Sign in again"
        case .accessDenied: return "Access denied"
        case .network: return "Connection unavailable"
        case .rateLimited: return "Checkpoint temporarily unavailable"
        case .service: return "Checkpoint service unavailable"
        case .invalidData: return "Checkpoint could not be verified"
        }
    }

    var detail: String {
        switch self {
        case .notConfigured:
            return "This build does not have a trusted Senti checkpoint gateway."
        case .reauthenticationRequired:
            return "Your Senti authorization is no longer valid. Sign in again before loading protected content."
        case .accessDenied:
            return "This account is not authorized to open that checkpoint. No checkpoint content is shown."
        case .network:
            return "Check your connection and try again. No cached checkpoint is substituted."
        case .rateLimited:
            return "Senti is receiving too many checkpoint requests. Wait a moment and try again."
        case .service:
            return "Senti could not load this checkpoint right now. No cached checkpoint is substituted."
        case .invalidData:
            return "Senti returned checkpoint data that this app could not safely verify. No content is shown."
        }
    }

    var allowsRetry: Bool {
        switch self {
        case .network, .rateLimited, .service:
            return true
        case .notConfigured, .reauthenticationRequired, .accessDenied, .invalidData:
            return false
        }
    }
}

enum CheckpointPocketPhase: Equatable, Sendable {
    case idle
    case loading(ExactCheckpointTarget)
    case ready(ExactCheckpointTarget, VerifiedBundle)
    case failed(ExactCheckpointTarget, CheckpointPocketFailure)

    var isActive: Bool {
        if case .idle = self { return false }
        return true
    }
}

/// Authentication-scoped owner for one read-only, signed checkpoint presentation.
///
/// The transport returns only `VerifiedBundle`, and every suspended completion is additionally fenced by the
/// authentication epoch, selected session, exact checkpoint identity, and a request revision. No previous bundle is
/// retained across a retry or failure, so the UI cannot silently substitute stale protected content.
@MainActor
final class CheckpointPocketCoordinator: ObservableObject {
    @Published private(set) var phase: CheckpointPocketPhase = .idle

    private struct RequestToken: Equatable, Sendable {
        let target: ExactCheckpointTarget
        let requestRevision: UInt64
    }

    private let transport: any CheckpointTransport
    private let onReauthenticationRequired: @MainActor () -> Void
    private let onSelectionRevoked: @MainActor (String) -> Void

    private var selectedSessionId: String?
    private var authenticationRevision: UInt64?
    private var requestRevision: UInt64 = 0
    private var operation: Task<Void, Never>?

    init(
        transport: any CheckpointTransport,
        onReauthenticationRequired: @escaping @MainActor () -> Void = {},
        onSelectionRevoked: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.transport = transport
        self.onReauthenticationRequired = onReauthenticationRequired
        self.onSelectionRevoked = onSelectionRevoked
    }

    deinit {
        operation?.cancel()
    }

    var isActive: Bool { phase.isActive }

    func setSelectedSession(
        _ sessionId: String?,
        authenticationRevision: UInt64
    ) {
        guard self.authenticationRevision != authenticationRevision
                || !Self.byteExactOptional(selectedSessionId, sessionId) else {
            return
        }
        cancelAndFence()
        phase = .idle
        self.authenticationRevision = authenticationRevision
        selectedSessionId = sessionId
    }

    func clearSelection() {
        cancelAndFence()
        phase = .idle
        selectedSessionId = nil
        authenticationRevision = nil
    }

    /// Synchronous protected-content revocation used before the outer sign-in gate changes principals.
    func invalidateAuthentication() {
        clearSelection()
    }

    @discardableResult
    func open(_ target: ExactCheckpointTarget) -> Task<Void, Never>? {
        guard authenticationRevision == target.authenticationRevision,
              Self.byteExactOptional(selectedSessionId, target.sessionId) else {
            return nil
        }

        cancelAndFence()
        phase = .loading(target)
        let token = RequestToken(target: target, requestRevision: requestRevision)
        let transport = transport
        let task = Task { @MainActor [weak self] in
            do {
                let verified = try await transport.fetchExactCheckpoint(
                    sessionId: target.sessionId,
                    checkpointId: target.checkpointId
                )
                guard let self, self.requestMatches(token) else { return }
                guard !Task.isCancelled else {
                    self.phase = .idle
                    self.operation = nil
                    return
                }
                let bundle = verified.bundle
                guard Self.byteExact(bundle.sessionId, target.sessionId),
                      Self.byteExact(bundle.checkpointId, target.checkpointId) else {
                    self.phase = .failed(target, .invalidData)
                    self.operation = nil
                    return
                }
                self.phase = .ready(target, verified)
                self.operation = nil
            } catch {
                guard let self, self.requestMatches(token) else { return }
                guard !Task.isCancelled else {
                    self.phase = .idle
                    self.operation = nil
                    return
                }
                self.apply(error, target: target)
            }
        }
        operation = task
        return task
    }

    @discardableResult
    func retry() -> Task<Void, Never>? {
        guard case .failed(let target, let failure) = phase,
              failure.allowsRetry else { return nil }
        return open(target)
    }

    func clear() {
        cancelAndFence()
        phase = .idle
    }

    private func apply(_ error: Error, target: ExactCheckpointTarget) {
        let transportError: CheckpointTransportError?
        if error is CancellationError {
            transportError = .cancelled
        } else {
            transportError = error as? CheckpointTransportError
        }

        switch transportError {
        case .notLoggedIn, .reauthenticationRequired:
            phase = .failed(target, .reauthenticationRequired)
            operation = nil
            onReauthenticationRequired()

        case .accessDenied:
            phase = .failed(target, .accessDenied)
            operation = nil
            onSelectionRevoked(target.sessionId)

        case .notConfigured:
            phase = .failed(target, .notConfigured)
            operation = nil

        case .network:
            phase = .failed(target, .network)
            operation = nil

        case .rateLimited:
            phase = .failed(target, .rateLimited)
            operation = nil

        case .service, nil:
            phase = .failed(target, .service)
            operation = nil

        case .invalidRequest, .invalidResponse, .invalidData:
            phase = .failed(target, .invalidData)
            operation = nil

        case .cancelled:
            phase = .idle
            operation = nil
        }
    }

    private func requestMatches(_ token: RequestToken) -> Bool {
        requestRevision == token.requestRevision
            && authenticationRevision == token.target.authenticationRevision
            && Self.byteExactOptional(selectedSessionId, token.target.sessionId)
    }

    private func cancelAndFence() {
        operation?.cancel()
        operation = nil
        requestRevision &+= 1
    }

    private static func byteExact(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    private static func byteExactOptional(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none): return true
        case (.some(let lhs), .some(let rhs)): return byteExact(lhs, rhs)
        default: return false
        }
    }
}
