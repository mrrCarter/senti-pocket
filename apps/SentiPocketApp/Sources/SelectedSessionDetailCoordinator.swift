import Combine
import Foundation
import PocketContracts
import PocketSyncClient
import PocketUI

enum SelectedSessionDetailLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(SessionLoadFailure)

    var isLoading: Bool {
        self == .loading
    }

    var failure: SessionLoadFailure? {
        guard case .failed(let failure) = self else { return nil }
        return failure
    }
}

/// Lossless identity for a visible read-only Activity destination.
///
/// Event navigation retains both the sequence and event id so a refreshed row cannot silently replace the
/// destination with a different event that happens to reuse the same sequence number.
enum SessionDetailDestination: Hashable, Identifiable {
    case event(sequenceId: Int64, eventId: String)
    case action(actionId: String)

    var id: String {
        switch self {
        case .event(let sequenceId, let eventId):
            return "event:\(sequenceId):\(eventId.utf8.count):\(eventId)"
        case .action(let actionId):
            return "action:\(actionId.utf8.count):\(actionId)"
        }
    }
}

/// Authentication-scoped owner for the selected session's read-only Activity and checkpoint projections.
///
/// Cancellation is only a resource optimization. Every completion is also fenced by the immutable request identity:
/// `(authenticationRevision, sessionId, requestRevision)`. A response from principal A therefore cannot publish into
/// principal B's UI even when both principals select the same session id and the transport ignores cancellation.
@MainActor
final class SelectedSessionDetailCoordinator: ObservableObject {
    @Published private(set) var selectedSessionId: String?
    @Published private(set) var activityState: SessionActivityPresentationState?
    @Published private(set) var checkpointState: SessionCheckpointListPresentationState?
    @Published private(set) var activityLoadState: SelectedSessionDetailLoadState = .idle
    @Published private(set) var checkpointLoadState: SelectedSessionDetailLoadState = .idle
    @Published private(set) var destination: SessionDetailDestination?

    private struct RequestToken: Equatable, Sendable {
        let authenticationRevision: UInt64
        let sessionId: String
        let requestRevision: UInt64
    }

    private struct ActivitySnapshot {
        let eventPage: SessionEventForwardPage
        let actionPage: SessionActionPage
        let loadedAt: Date
    }

    private struct CheckpointSnapshot {
        let page: SessionCheckpointListPage
        let loadedAt: Date
    }

    private enum Lane: Hashable {
        case activity
        case checkpoints
    }

    private let transport: any SessionTransport
    private let clock: @Sendable () -> Date
    private let onReauthenticationRequired: @MainActor () -> Void
    private let onSelectionRevoked: @MainActor (String) -> Void

    private var authenticationRevision: UInt64?
    private var requestRevision: UInt64 = 0
    private var activitySnapshot: ActivitySnapshot?
    private var checkpointSnapshot: CheckpointSnapshot?
    private var activityProvenance: SessionPresentationProvenance = .unavailable
    private var checkpointProvenance: SessionPresentationProvenance = .unavailable
    private var activityOperation: Task<Void, Never>?
    private var checkpointOperation: Task<Void, Never>?

    init(
        transport: any SessionTransport,
        clock: @escaping @Sendable () -> Date = { Date() },
        onReauthenticationRequired: @escaping @MainActor () -> Void = {},
        onSelectionRevoked: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.transport = transport
        self.clock = clock
        self.onReauthenticationRequired = onReauthenticationRequired
        self.onSelectionRevoked = onSelectionRevoked
    }

    deinit {
        activityOperation?.cancel()
        checkpointOperation?.cancel()
    }

    /// Changes the full authorization identity, not just the visible session id. A new authentication revision always
    /// destroys retained content before a request starts, including the same-session account-switch case.
    @discardableResult
    func setSelectedSession(
        _ sessionId: String?,
        authenticationRevision: UInt64
    ) -> Task<Void, Never>? {
        // A fail-closed lane clears its own identity before asking the outer allowlist to revoke the same selection.
        // Treat that reentrant nil as an acknowledgement so the access/integrity failure is not erased to `.idle`.
        if sessionId == nil, selectedSessionId == nil {
            return nil
        }
        guard selectedSessionId != sessionId
                || self.authenticationRevision != authenticationRevision else {
            return nil
        }

        cancelAndFence()
        clearSnapshots()
        self.authenticationRevision = authenticationRevision
        selectedSessionId = sessionId
        activityLoadState = .idle
        checkpointLoadState = .idle

        guard let sessionId, !sessionId.isEmpty else {
            selectedSessionId = nil
            return nil
        }
        return refresh()
    }

    func clearSelection() {
        cancelAndFence()
        clearSnapshots()
        selectedSessionId = nil
        authenticationRevision = nil
        activityLoadState = .idle
        checkpointLoadState = .idle
    }

    /// Direct synchronous revocation seam used when a protected sibling observes sign-out/401.
    /// It deliberately does not emit the callback because its caller already owns the authentication transition.
    func invalidateAuthentication() {
        cancelAndFence()
        clearSnapshots()
        selectedSessionId = nil
        authenticationRevision = nil
        activityLoadState = .failed(.reauthenticationRequired)
        checkpointLoadState = .failed(.reauthenticationRequired)
    }

    func send(_ intent: PocketProductIntent) {
        switch intent {
        case .refreshActivity(let sessionId):
            guard sessionId == selectedSessionId else { return }
            refreshActivity()
        case .refreshCheckpoints(let sessionId):
            guard sessionId == selectedSessionId else { return }
            refreshCheckpoints()
        case .openEvent(let sessionId, let sequenceId):
            guard sessionId == selectedSessionId,
                  let event = activityState?.events.first(where: {
                      $0.sessionId == sessionId && $0.sequenceId == sequenceId
                  }) else { return }
            destination = .event(sequenceId: sequenceId, eventId: event.id.eventId)
        case .openAction(let sessionId, let actionId):
            guard sessionId == selectedSessionId,
                  activityState?.actions.contains(where: {
                      $0.sessionId == sessionId && $0.id.actionId == actionId
                  }) == true else { return }
            destination = .action(actionId: actionId)
        case .openCheckpoint(let sessionId, let checkpointId):
            guard sessionId == selectedSessionId,
                  checkpointState?.rows.contains(where: {
                      $0.sessionId == sessionId && $0.checkpointId == checkpointId
                  }) == true else { return }
            // Membership-authorized checkpoints never fall through to the signed-bundle Pocket path.
        default:
            break
        }
    }

    func clearDestination() {
        destination = nil
    }

    func event(sequenceId: Int64, eventId: String) -> SessionEventRowPresentation? {
        activityState?.events.first {
            $0.sequenceId == sequenceId && $0.id.eventId == eventId
        }
    }

    func action(actionId: String) -> SessionActionRowPresentation? {
        activityState?.actions.first { $0.id.actionId == actionId }
    }

    @discardableResult
    func refresh() -> Task<Void, Never>? {
        guard let token = beginRequest(refreshing: [.activity, .checkpoints]) else { return nil }
        let activity = startActivityRequest(token)
        let checkpoints = startCheckpointRequest(token)
        return Task { @MainActor [weak self] in
            await withTaskCancellationHandler {
                await activity.value
                await checkpoints.value
            } onCancel: {
                activity.cancel()
                checkpoints.cancel()
                Task { @MainActor [weak self] in
                    self?.restoreAfterCallerCancellation(token)
                }
            }
        }
    }

    @discardableResult
    func refreshActivity() -> Task<Void, Never>? {
        guard let token = beginRequest(refreshing: [.activity]) else { return nil }
        return startActivityRequest(token)
    }

    @discardableResult
    func refreshCheckpoints() -> Task<Void, Never>? {
        guard let token = beginRequest(refreshing: [.checkpoints]) else { return nil }
        return startCheckpointRequest(token)
    }

    private func beginRequest(refreshing lanes: Set<Lane>) -> RequestToken? {
        guard let authenticationRevision, let selectedSessionId else { return nil }

        cancelAndFence()
        if !lanes.contains(.activity), activityLoadState == .loading {
            restoreRetainedState(for: .activity)
        }
        if !lanes.contains(.checkpoints), checkpointLoadState == .loading {
            restoreRetainedState(for: .checkpoints)
        }
        if lanes.contains(.activity) {
            activityLoadState = .loading
            activityState = activitySnapshot.map {
                renderActivity(
                    $0,
                    provenance: activityProvenance,
                    isRefreshing: true,
                    failure: nil
                )
            }
        }
        if lanes.contains(.checkpoints) {
            checkpointLoadState = .loading
            checkpointState = checkpointSnapshot.map {
                renderCheckpoints(
                    $0,
                    provenance: checkpointProvenance,
                    isRefreshing: true,
                    failure: nil
                )
            }
        }

        return RequestToken(
            authenticationRevision: authenticationRevision,
            sessionId: selectedSessionId,
            requestRevision: requestRevision
        )
    }

    private func startActivityRequest(_ token: RequestToken) -> Task<Void, Never> {
        let transport = transport
        let clock = clock
        let task = Task { @MainActor [weak self] in
            do {
                async let eventRequest = transport.listEvents(
                    sessionId: token.sessionId,
                    after: nil,
                    fromSequence: nil,
                    limit: 100
                )
                async let actionRequest = transport.listActions(
                    sessionId: token.sessionId,
                    targetSequenceId: nil,
                    targetActionId: nil,
                    limit: 200
                )
                let (eventPage, actionPage) = try await (eventRequest, actionRequest)
                let snapshot = ActivitySnapshot(
                    eventPage: eventPage,
                    actionPage: actionPage,
                    loadedAt: clock()
                )
                guard let self, self.canApply(token) else { return }
                self.applyActivity(snapshot, token: token)
            } catch {
                guard let self, self.canApply(token) else { return }
                self.apply(error, to: .activity, token: token)
            }
        }
        activityOperation = task
        return task
    }

    private func startCheckpointRequest(_ token: RequestToken) -> Task<Void, Never> {
        let transport = transport
        let clock = clock
        let task = Task { @MainActor [weak self] in
            do {
                let page = try await transport.listCheckpoints(sessionId: token.sessionId, limit: 100)
                let snapshot = CheckpointSnapshot(page: page, loadedAt: clock())
                guard let self, self.canApply(token) else { return }
                self.applyCheckpoints(snapshot, token: token)
            } catch {
                guard let self, self.canApply(token) else { return }
                self.apply(error, to: .checkpoints, token: token)
            }
        }
        checkpointOperation = task
        return task
    }

    private func applyActivity(_ snapshot: ActivitySnapshot, token: RequestToken) {
        let provenance = SessionPresentationProvenance.network(lastUpdated: snapshot.loadedAt)
        let projected = renderActivity(
            snapshot,
            provenance: provenance,
            isRefreshing: false,
            failure: nil
        )
        guard projected.failure != .invalidData else {
            failClosed(.invalidData, token: token)
            onSelectionRevoked(token.sessionId)
            return
        }

        activitySnapshot = snapshot
        activityProvenance = provenance
        activityState = projected
        reconcileDestination()
        activityLoadState = .loaded
        activityOperation = nil
    }

    private func applyCheckpoints(_ snapshot: CheckpointSnapshot, token: RequestToken) {
        let provenance = SessionPresentationProvenance.network(lastUpdated: snapshot.loadedAt)
        let projected = renderCheckpoints(
            snapshot,
            provenance: provenance,
            isRefreshing: false,
            failure: nil
        )
        guard projected.failure != .invalidData else {
            failClosed(.invalidData, token: token)
            onSelectionRevoked(token.sessionId)
            return
        }

        checkpointSnapshot = snapshot
        checkpointProvenance = provenance
        checkpointState = projected
        checkpointLoadState = .loaded
        checkpointOperation = nil
    }

    private func apply(_ error: Error, to lane: Lane, token: RequestToken) {
        let transportError: SessionTransportError?
        if error is CancellationError {
            transportError = .cancelled
        } else {
            transportError = error as? SessionTransportError
        }

        switch transportError {
        case .notLoggedIn, .reauthenticationRequired:
            failClosed(.reauthenticationRequired, token: token)
            onReauthenticationRequired()

        case .accessDenied:
            failClosed(.accessDenied, token: token)
            onSelectionRevoked(token.sessionId)

        case .invalidRequest, .invalidResponse, .invalidData:
            failClosed(.invalidData, token: token)
            onSelectionRevoked(token.sessionId)

        case .network:
            applyRecoverableFailure(
                lane: lane,
                noSnapshotFailure: .offlineNoCache,
                retainedSnapshotFailure: .network
            )

        case .notConfigured, .rateLimited, .service, nil:
            applyRecoverableFailure(
                lane: lane,
                noSnapshotFailure: .service,
                retainedSnapshotFailure: .service
            )

        case .cancelled:
            restoreRetainedState(for: lane)
        }
    }

    private func applyRecoverableFailure(
        lane: Lane,
        noSnapshotFailure: SessionLoadFailure,
        retainedSnapshotFailure: SessionLoadFailure
    ) {
        switch lane {
        case .activity:
            if let snapshot = activitySnapshot {
                activityProvenance = .cache(
                    cachedAt: snapshot.loadedAt,
                    authenticationExpired: false
                )
                activityState = renderActivity(
                    snapshot,
                    provenance: activityProvenance,
                    isRefreshing: false,
                    failure: retainedSnapshotFailure
                )
                activityLoadState = .failed(retainedSnapshotFailure)
            } else {
                activityProvenance = .unavailable
                activityState = nil
                activityLoadState = .failed(noSnapshotFailure)
            }
            reconcileDestination()
            activityOperation = nil

        case .checkpoints:
            if let snapshot = checkpointSnapshot {
                checkpointProvenance = .cache(
                    cachedAt: snapshot.loadedAt,
                    authenticationExpired: false
                )
                checkpointState = renderCheckpoints(
                    snapshot,
                    provenance: checkpointProvenance,
                    isRefreshing: false,
                    failure: retainedSnapshotFailure
                )
                checkpointLoadState = .failed(retainedSnapshotFailure)
            } else {
                checkpointProvenance = .unavailable
                checkpointState = nil
                checkpointLoadState = .failed(noSnapshotFailure)
            }
            checkpointOperation = nil
        }
    }

    private func restoreRetainedState(for lane: Lane) {
        switch lane {
        case .activity:
            if let snapshot = activitySnapshot {
                activityState = renderActivity(
                    snapshot,
                    provenance: activityProvenance,
                    isRefreshing: false,
                    failure: nil
                )
                activityLoadState = .loaded
            } else {
                activityState = nil
                activityLoadState = .idle
            }
            reconcileDestination()
            activityOperation = nil

        case .checkpoints:
            if let snapshot = checkpointSnapshot {
                checkpointState = renderCheckpoints(
                    snapshot,
                    provenance: checkpointProvenance,
                    isRefreshing: false,
                    failure: nil
                )
                checkpointLoadState = .loaded
            } else {
                checkpointState = nil
                checkpointLoadState = .idle
            }
            checkpointOperation = nil
        }
    }

    /// Any current-token authorization or integrity failure revokes both lanes before a callback is emitted.
    /// Incrementing the revision first makes a concurrent sibling failure stale, so reauthentication fires once.
    private func failClosed(_ failure: SessionLoadFailure, token: RequestToken) {
        guard canApply(token) else { return }
        cancelAndFence()
        clearSnapshots()
        selectedSessionId = nil
        authenticationRevision = nil
        activityLoadState = .failed(failure)
        checkpointLoadState = .failed(failure)
    }

    private func canApply(_ token: RequestToken) -> Bool {
        !Task.isCancelled
            && requestRevision == token.requestRevision
            && authenticationRevision == token.authenticationRevision
            && selectedSessionId == token.sessionId
    }

    private func restoreAfterCallerCancellation(_ token: RequestToken) {
        guard requestRevision == token.requestRevision,
              authenticationRevision == token.authenticationRevision,
              selectedSessionId == token.sessionId else { return }
        cancelAndFence()
        if activityLoadState == .loading {
            restoreRetainedState(for: .activity)
        }
        if checkpointLoadState == .loading {
            restoreRetainedState(for: .checkpoints)
        }
    }

    private func cancelAndFence() {
        activityOperation?.cancel()
        checkpointOperation?.cancel()
        activityOperation = nil
        checkpointOperation = nil
        requestRevision &+= 1
    }

    private func clearSnapshots() {
        activitySnapshot = nil
        checkpointSnapshot = nil
        activityProvenance = .unavailable
        checkpointProvenance = .unavailable
        activityState = nil
        checkpointState = nil
        destination = nil
    }

    private func reconcileDestination() {
        guard let destination else { return }
        switch destination {
        case .event(let sequenceId, let eventId):
            if event(sequenceId: sequenceId, eventId: eventId) == nil {
                self.destination = nil
            }
        case .action(let actionId):
            if action(actionId: actionId) == nil {
                self.destination = nil
            }
        }
    }

    private func renderActivity(
        _ snapshot: ActivitySnapshot,
        provenance: SessionPresentationProvenance,
        isRefreshing: Bool,
        failure: SessionLoadFailure?
    ) -> SessionActivityPresentationState {
        SessionActivityPresentationState(
            sessionId: selectedSessionId ?? "",
            eventPage: snapshot.eventPage,
            actionPage: snapshot.actionPage,
            provenance: provenance,
            isRefreshing: isRefreshing,
            failure: failure
        )
    }

    private func renderCheckpoints(
        _ snapshot: CheckpointSnapshot,
        provenance: SessionPresentationProvenance,
        isRefreshing: Bool,
        failure: SessionLoadFailure?
    ) -> SessionCheckpointListPresentationState {
        SessionCheckpointListPresentationState(
            sessionId: selectedSessionId ?? "",
            page: snapshot.page,
            provenance: provenance,
            isRefreshing: isRefreshing,
            failure: failure
        )
    }
}
