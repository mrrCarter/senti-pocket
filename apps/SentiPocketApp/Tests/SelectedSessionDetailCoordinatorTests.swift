import Foundation
import PocketContracts
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

private enum SelectedSessionDetailTestError: Error {
    case requestTimeout
}

private actor ControlledSessionDetailTransport: SessionTransport {
    private var eventContinuations: [CheckedContinuation<SessionEventForwardPage, Error>] = []
    private var actionContinuations: [CheckedContinuation<SessionActionPage, Error>] = []
    private var checkpointContinuations: [CheckedContinuation<SessionCheckpointListPage, Error>] = []
    private var eventSessions: [String] = []
    private var actionSessions: [String] = []
    private var checkpointSessions: [String] = []

    func listSessions(includeArchived: Bool, limit: Int, cursor: String?) async throws -> SessionListPage {
        throw SessionTransportError.invalidRequest
    }

    func listEvents(
        sessionId: String,
        after: String?,
        fromSequence: Int64?,
        limit: Int
    ) async throws -> SessionEventForwardPage {
        eventSessions.append(sessionId)
        return try await withCheckedThrowingContinuation { continuation in
            eventContinuations.append(continuation)
        }
    }

    func listEventsBefore(
        sessionId: String,
        beforeSequence: Int64?,
        limit: Int
    ) async throws -> SessionEventBeforePage {
        throw SessionTransportError.invalidRequest
    }

    func listActions(
        sessionId: String,
        targetSequenceId: Int64?,
        targetActionId: String?,
        limit: Int
    ) async throws -> SessionActionPage {
        actionSessions.append(sessionId)
        return try await withCheckedThrowingContinuation { continuation in
            actionContinuations.append(continuation)
        }
    }

    func listCheckpoints(sessionId: String, limit: Int) async throws -> SessionCheckpointListPage {
        checkpointSessions.append(sessionId)
        return try await withCheckedThrowingContinuation { continuation in
            checkpointContinuations.append(continuation)
        }
    }

    func requestCounts() -> (events: Int, actions: Int, checkpoints: Int) {
        (eventSessions.count, actionSessions.count, checkpointSessions.count)
    }

    func requestedSessions() -> (events: [String], actions: [String], checkpoints: [String]) {
        (eventSessions, actionSessions, checkpointSessions)
    }

    func resumeNextEvent(_ result: Result<SessionEventForwardPage, SessionTransportError>) {
        resume(eventContinuations.removeFirst(), with: result)
    }

    func resumeNextAction(_ result: Result<SessionActionPage, SessionTransportError>) {
        resume(actionContinuations.removeFirst(), with: result)
    }

    func resumeNextCheckpoint(_ result: Result<SessionCheckpointListPage, SessionTransportError>) {
        resume(checkpointContinuations.removeFirst(), with: result)
    }

    private func resume<Value>(
        _ continuation: CheckedContinuation<Value, Error>,
        with result: Result<Value, SessionTransportError>
    ) {
        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

@MainActor
final class SelectedSessionDetailCoordinatorTests: XCTestCase {
    func test_success_fetches_exact_session_and_publishes_both_network_lanes() async throws {
        let transport = ControlledSessionDetailTransport()
        let coordinator = SelectedSessionDetailCoordinator(
            transport: transport,
            clock: { Date(timeIntervalSince1970: 100) }
        )

        let operation = try XCTUnwrap(coordinator.setSelectedSession(
            "room-1",
            authenticationRevision: 7
        ))
        try await waitForRequests(transport, events: 1, actions: 1, checkpoints: 1)
        let requested = await transport.requestedSessions()
        XCTAssertEqual(requested.events, ["room-1"])
        XCTAssertEqual(requested.actions, ["room-1"])
        XCTAssertEqual(requested.checkpoints, ["room-1"])

        await transport.resumeNextEvent(.success(try eventPage(sessionId: "room-1", marker: "live")))
        await transport.resumeNextAction(.success(try actionPage(sessionId: "room-1", marker: "live")))
        await transport.resumeNextCheckpoint(.success(try checkpointPage(
            sessionId: "room-1",
            marker: "live"
        )))
        await operation.value

        XCTAssertEqual(coordinator.selectedSessionId, "room-1")
        XCTAssertEqual(coordinator.activityState?.events.map(\.id.eventId), ["event-live"])
        XCTAssertEqual(coordinator.activityState?.actions.map(\.id.actionId), ["action-live"])
        XCTAssertEqual(coordinator.checkpointState?.rows.map(\.checkpointId), ["checkpoint-live"])
        XCTAssertEqual(coordinator.activityLoadState, .loaded)
        XCTAssertEqual(coordinator.checkpointLoadState, .loaded)
        guard case .some(.network) = coordinator.activityState?.provenance else {
            return XCTFail("activity success must be labeled network")
        }
        guard case .some(.network) = coordinator.checkpointState?.provenance else {
            return XCTFail("checkpoint success must be labeled network")
        }
    }

    func test_activity_navigation_accepts_only_exact_visible_rows_and_clears_with_selection() async throws {
        let transport = ControlledSessionDetailTransport()
        let coordinator = SelectedSessionDetailCoordinator(transport: transport)

        let operation = try XCTUnwrap(coordinator.setSelectedSession(
            "room-1",
            authenticationRevision: 1
        ))
        try await waitForRequests(transport, events: 1, actions: 1, checkpoints: 1)
        await transport.resumeNextEvent(.success(try eventPage(sessionId: "room-1", marker: "visible")))
        await transport.resumeNextAction(.success(try actionPage(sessionId: "room-1", marker: "visible")))
        await transport.resumeNextCheckpoint(.success(try checkpointPage(
            sessionId: "room-1",
            marker: "visible"
        )))
        await operation.value

        coordinator.send(.openEvent(sessionId: "other-room", sequenceId: 1))
        coordinator.send(.openEvent(sessionId: "room-1", sequenceId: 999))
        coordinator.send(.openAction(sessionId: "room-1", actionId: "forged"))
        XCTAssertNil(coordinator.destination)

        coordinator.send(.openEvent(sessionId: "room-1", sequenceId: 1))
        XCTAssertEqual(
            coordinator.destination,
            .event(sequenceId: 1, eventId: "event-visible")
        )
        XCTAssertEqual(
            coordinator.event(sequenceId: 1, eventId: "event-visible")?.id.eventId,
            "event-visible"
        )
        XCTAssertNil(coordinator.event(sequenceId: 1, eventId: "event-forged"))

        coordinator.clearDestination()
        coordinator.send(.openAction(sessionId: "room-1", actionId: "action-visible"))
        XCTAssertEqual(coordinator.destination, .action(actionId: "action-visible"))
        XCTAssertEqual(coordinator.action(actionId: "action-visible")?.id.actionId, "action-visible")

        coordinator.clearSelection()
        XCTAssertNil(coordinator.destination)
    }

    func test_successful_activity_revision_clears_destination_when_exact_event_identity_changes() async throws {
        let transport = ControlledSessionDetailTransport()
        let coordinator = SelectedSessionDetailCoordinator(transport: transport)

        let initial = try XCTUnwrap(coordinator.setSelectedSession(
            "room-1",
            authenticationRevision: 1
        ))
        try await waitForRequests(transport, events: 1, actions: 1, checkpoints: 1)
        await transport.resumeNextEvent(.success(try eventPage(sessionId: "room-1", marker: "first")))
        await transport.resumeNextAction(.success(try actionPage(sessionId: "room-1", marker: "first")))
        await transport.resumeNextCheckpoint(.success(try checkpointPage(
            sessionId: "room-1",
            marker: "first"
        )))
        await initial.value

        coordinator.send(.openEvent(sessionId: "room-1", sequenceId: 1))
        XCTAssertEqual(coordinator.destination, .event(sequenceId: 1, eventId: "event-first"))

        let refresh = try XCTUnwrap(coordinator.refreshActivity())
        try await waitForRequests(transport, events: 2, actions: 2, checkpoints: 1)
        XCTAssertEqual(coordinator.destination, .event(sequenceId: 1, eventId: "event-first"))
        await transport.resumeNextEvent(.success(try eventPage(sessionId: "room-1", marker: "second")))
        await transport.resumeNextAction(.success(try actionPage(sessionId: "room-1", marker: "second")))
        await refresh.value

        XCTAssertNil(coordinator.destination)
        XCTAssertEqual(coordinator.activityState?.events.first?.id.eventId, "event-second")
    }

    func test_completion_after_selection_revocation_publishes_nothing() async throws {
        let transport = ControlledSessionDetailTransport()
        let reauthentication = DetailCallbackProbe()
        let coordinator = SelectedSessionDetailCoordinator(
            transport: transport,
            onReauthenticationRequired: { reauthentication.values.append("reauth") }
        )

        let operation = try XCTUnwrap(coordinator.setSelectedSession(
            "room-1",
            authenticationRevision: 1
        ))
        try await waitForRequests(transport, events: 1, actions: 1, checkpoints: 1)
        coordinator.clearSelection()

        await transport.resumeNextEvent(.success(try eventPage(sessionId: "room-1", marker: "late")))
        await transport.resumeNextAction(.success(try actionPage(sessionId: "room-1", marker: "late")))
        await transport.resumeNextCheckpoint(.success(try checkpointPage(
            sessionId: "room-1",
            marker: "late"
        )))
        await operation.value

        XCTAssertNil(coordinator.selectedSessionId)
        XCTAssertNil(coordinator.activityState)
        XCTAssertNil(coordinator.checkpointState)
        XCTAssertEqual(coordinator.activityLoadState, .idle)
        XCTAssertEqual(coordinator.checkpointLoadState, .idle)
        XCTAssertTrue(reauthentication.values.isEmpty)
    }

    func test_cancelling_returned_refresh_task_cancels_lanes_and_restores_idle() async throws {
        let transport = ControlledSessionDetailTransport()
        let coordinator = SelectedSessionDetailCoordinator(transport: transport)

        let operation = try XCTUnwrap(coordinator.setSelectedSession(
            "room-1",
            authenticationRevision: 1
        ))
        try await waitForRequests(transport, events: 1, actions: 1, checkpoints: 1)
        operation.cancel()
        try await waitForLoadStates(coordinator, activity: .idle, checkpoints: .idle)

        await transport.resumeNextEvent(.success(try eventPage(sessionId: "room-1", marker: "late")))
        await transport.resumeNextAction(.success(try actionPage(sessionId: "room-1", marker: "late")))
        await transport.resumeNextCheckpoint(.success(try checkpointPage(
            sessionId: "room-1",
            marker: "late"
        )))
        await operation.value

        XCTAssertEqual(coordinator.selectedSessionId, "room-1")
        XCTAssertNil(coordinator.activityState)
        XCTAssertNil(coordinator.checkpointState)
        XCTAssertEqual(coordinator.activityLoadState, .idle)
        XCTAssertEqual(coordinator.checkpointLoadState, .idle)
    }

    func test_current_401_clears_both_lanes_and_notifies_once() async throws {
        let transport = ControlledSessionDetailTransport()
        let reauthentication = DetailCallbackProbe()
        let coordinator = SelectedSessionDetailCoordinator(
            transport: transport,
            onReauthenticationRequired: { reauthentication.values.append("reauth") }
        )

        let operation = try XCTUnwrap(coordinator.setSelectedSession(
            "room-1",
            authenticationRevision: 1
        ))
        try await waitForRequests(transport, events: 1, actions: 1, checkpoints: 1)
        await transport.resumeNextEvent(.failure(.reauthenticationRequired))
        await transport.resumeNextAction(.success(try actionPage(sessionId: "room-1", marker: "late")))
        await transport.resumeNextCheckpoint(.failure(.reauthenticationRequired))
        await operation.value

        XCTAssertNil(coordinator.selectedSessionId)
        XCTAssertNil(coordinator.activityState)
        XCTAssertNil(coordinator.checkpointState)
        XCTAssertEqual(coordinator.activityLoadState, .failed(.reauthenticationRequired))
        XCTAssertEqual(coordinator.checkpointLoadState, .failed(.reauthenticationRequired))
        XCTAssertEqual(reauthentication.values, ["reauth"])
    }

    func test_current_403_revokes_selection_once_without_reauthentication() async throws {
        let transport = ControlledSessionDetailTransport()
        let reauthentication = DetailCallbackProbe()
        let revoked = DetailCallbackProbe()
        let coordinator = SelectedSessionDetailCoordinator(
            transport: transport,
            onReauthenticationRequired: { reauthentication.values.append("reauth") },
            onSelectionRevoked: { revoked.values.append($0) }
        )

        let operation = try XCTUnwrap(coordinator.setSelectedSession(
            "room-1",
            authenticationRevision: 1
        ))
        try await waitForRequests(transport, events: 1, actions: 1, checkpoints: 1)
        await transport.resumeNextEvent(.failure(.accessDenied))
        await transport.resumeNextAction(.success(try actionPage(sessionId: "room-1", marker: "late")))
        await transport.resumeNextCheckpoint(.failure(.accessDenied))
        await operation.value

        XCTAssertNil(coordinator.selectedSessionId)
        XCTAssertNil(coordinator.activityState)
        XCTAssertNil(coordinator.checkpointState)
        XCTAssertEqual(coordinator.activityLoadState, .failed(.accessDenied))
        XCTAssertEqual(coordinator.checkpointLoadState, .failed(.accessDenied))
        XCTAssertEqual(revoked.values, ["room-1"])
        XCTAssertTrue(reauthentication.values.isEmpty)
    }

    func test_cross_session_payload_revokes_all_protected_state() async throws {
        let transport = ControlledSessionDetailTransport()
        let revoked = DetailCallbackProbe()
        let coordinator = SelectedSessionDetailCoordinator(
            transport: transport,
            onSelectionRevoked: { revoked.values.append($0) }
        )

        let operation = try XCTUnwrap(coordinator.setSelectedSession(
            "room-1",
            authenticationRevision: 1
        ))
        try await waitForRequests(transport, events: 1, actions: 1, checkpoints: 1)
        await transport.resumeNextEvent(.success(try eventPage(sessionId: "room-2", marker: "forged")))
        await transport.resumeNextAction(.success(try actionPage(sessionId: "room-1", marker: "valid")))
        await transport.resumeNextCheckpoint(.success(try checkpointPage(
            sessionId: "room-1",
            marker: "valid"
        )))
        await operation.value

        XCTAssertNil(coordinator.selectedSessionId)
        XCTAssertNil(coordinator.activityState)
        XCTAssertNil(coordinator.checkpointState)
        XCTAssertEqual(coordinator.activityLoadState, .failed(.invalidData))
        XCTAssertEqual(coordinator.checkpointLoadState, .failed(.invalidData))
        XCTAssertEqual(revoked.values, ["room-1"])
    }

    func test_recoverable_refresh_failure_retains_exact_snapshot_as_cache() async throws {
        let transport = ControlledSessionDetailTransport()
        let coordinator = SelectedSessionDetailCoordinator(transport: transport)

        let initial = try XCTUnwrap(coordinator.setSelectedSession(
            "room-1",
            authenticationRevision: 1
        ))
        try await waitForRequests(transport, events: 1, actions: 1, checkpoints: 1)
        await transport.resumeNextEvent(.success(try eventPage(sessionId: "room-1", marker: "initial")))
        await transport.resumeNextAction(.success(try actionPage(sessionId: "room-1", marker: "initial")))
        await transport.resumeNextCheckpoint(.success(try checkpointPage(
            sessionId: "room-1",
            marker: "initial"
        )))
        await initial.value

        coordinator.send(.openEvent(sessionId: "room-1", sequenceId: 1))
        XCTAssertEqual(coordinator.destination, .event(sequenceId: 1, eventId: "event-initial"))

        let refresh = try XCTUnwrap(coordinator.refresh())
        try await waitForRequests(transport, events: 2, actions: 2, checkpoints: 2)
        await transport.resumeNextEvent(.failure(.network))
        await transport.resumeNextAction(.failure(.network))
        await transport.resumeNextCheckpoint(.failure(.service(statusCode: 503)))
        await refresh.value

        XCTAssertEqual(coordinator.activityState?.events.map(\.id.eventId), ["event-initial"])
        XCTAssertEqual(coordinator.checkpointState?.rows.map(\.checkpointId), ["checkpoint-initial"])
        XCTAssertEqual(coordinator.destination, .event(sequenceId: 1, eventId: "event-initial"))
        XCTAssertEqual(coordinator.activityState?.failure, .network)
        XCTAssertEqual(coordinator.checkpointState?.failure, .service)
        guard case .some(.cache) = coordinator.activityState?.provenance else {
            return XCTFail("retained activity must be relabeled cache")
        }
        guard case .some(.cache) = coordinator.checkpointState?.provenance else {
            return XCTFail("retained checkpoints must be relabeled cache")
        }
    }

    func test_initial_network_failure_has_no_cache_and_keeps_authorized_selection() async throws {
        let transport = ControlledSessionDetailTransport()
        let coordinator = SelectedSessionDetailCoordinator(transport: transport)

        let operation = try XCTUnwrap(coordinator.setSelectedSession(
            "room-1",
            authenticationRevision: 1
        ))
        try await waitForRequests(transport, events: 1, actions: 1, checkpoints: 1)
        await transport.resumeNextEvent(.failure(.network))
        await transport.resumeNextAction(.failure(.network))
        await transport.resumeNextCheckpoint(.failure(.network))
        await operation.value

        XCTAssertEqual(coordinator.selectedSessionId, "room-1")
        XCTAssertNil(coordinator.activityState)
        XCTAssertNil(coordinator.checkpointState)
        XCTAssertEqual(coordinator.activityLoadState, .failed(.offlineNoCache))
        XCTAssertEqual(coordinator.checkpointLoadState, .failed(.offlineNoCache))
    }

    func test_activity_only_refresh_restores_cancelled_checkpoint_lane() async throws {
        let transport = ControlledSessionDetailTransport()
        let coordinator = SelectedSessionDetailCoordinator(transport: transport)

        let initial = try XCTUnwrap(coordinator.setSelectedSession(
            "room-1",
            authenticationRevision: 1
        ))
        try await waitForRequests(transport, events: 1, actions: 1, checkpoints: 1)

        let activityRefresh = try XCTUnwrap(coordinator.refreshActivity())
        try await waitForRequests(transport, events: 2, actions: 2, checkpoints: 1)

        await transport.resumeNextEvent(.success(try eventPage(sessionId: "room-1", marker: "old")))
        await transport.resumeNextAction(.success(try actionPage(sessionId: "room-1", marker: "old")))
        await transport.resumeNextCheckpoint(.success(try checkpointPage(
            sessionId: "room-1",
            marker: "old"
        )))
        await initial.value

        XCTAssertNil(coordinator.activityState)
        XCTAssertNil(coordinator.checkpointState)
        XCTAssertEqual(coordinator.activityLoadState, .loading)
        XCTAssertEqual(coordinator.checkpointLoadState, .idle)

        await transport.resumeNextEvent(.success(try eventPage(sessionId: "room-1", marker: "fresh")))
        await transport.resumeNextAction(.success(try actionPage(sessionId: "room-1", marker: "fresh")))
        await activityRefresh.value

        XCTAssertEqual(coordinator.activityState?.events.map(\.id.eventId), ["event-fresh"])
        XCTAssertEqual(coordinator.activityLoadState, .loaded)
        XCTAssertNil(coordinator.checkpointState)
        XCTAssertEqual(coordinator.checkpointLoadState, .idle)
    }

    func test_same_session_new_authentication_revision_rejects_old_401_and_403() async throws {
        let transport = ControlledSessionDetailTransport()
        let reauthentication = DetailCallbackProbe()
        let revoked = DetailCallbackProbe()
        let coordinator = SelectedSessionDetailCoordinator(
            transport: transport,
            onReauthenticationRequired: { reauthentication.values.append("reauth") },
            onSelectionRevoked: { revoked.values.append($0) }
        )

        let principalA = try XCTUnwrap(coordinator.setSelectedSession(
            "room-1",
            authenticationRevision: 1
        ))
        try await waitForRequests(transport, events: 1, actions: 1, checkpoints: 1)

        let principalB = try XCTUnwrap(coordinator.setSelectedSession(
            "room-1",
            authenticationRevision: 2
        ))
        try await waitForRequests(transport, events: 2, actions: 2, checkpoints: 2)

        await transport.resumeNextEvent(.failure(.reauthenticationRequired))
        await transport.resumeNextAction(.success(try actionPage(sessionId: "room-1", marker: "principal-a")))
        await transport.resumeNextCheckpoint(.failure(.accessDenied))
        await principalA.value

        XCTAssertEqual(coordinator.selectedSessionId, "room-1")
        XCTAssertNil(coordinator.activityState)
        XCTAssertNil(coordinator.checkpointState)
        XCTAssertEqual(coordinator.activityLoadState, .loading)
        XCTAssertEqual(coordinator.checkpointLoadState, .loading)
        XCTAssertTrue(reauthentication.values.isEmpty)
        XCTAssertTrue(revoked.values.isEmpty)

        await transport.resumeNextEvent(.success(try eventPage(sessionId: "room-1", marker: "principal-b")))
        await transport.resumeNextAction(.success(try actionPage(sessionId: "room-1", marker: "principal-b")))
        await transport.resumeNextCheckpoint(.success(try checkpointPage(
            sessionId: "room-1",
            marker: "principal-b"
        )))
        await principalB.value

        XCTAssertEqual(coordinator.activityState?.events.map(\.id.eventId), ["event-principal-b"])
        XCTAssertEqual(coordinator.checkpointState?.rows.map(\.checkpointId), ["checkpoint-principal-b"])
    }

    private func waitForRequests(
        _ transport: ControlledSessionDetailTransport,
        events: Int,
        actions: Int,
        checkpoints: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<1_000 {
            let counts = await transport.requestCounts()
            if counts.events == events, counts.actions == actions, counts.checkpoints == checkpoints {
                return
            }
            await Task.yield()
        }
        let counts = await transport.requestCounts()
        XCTFail(
            "requests did not reach events=\(events), actions=\(actions), checkpoints=\(checkpoints); got \(counts)",
            file: file,
            line: line
        )
        throw SelectedSessionDetailTestError.requestTimeout
    }

    private func waitForLoadStates(
        _ coordinator: SelectedSessionDetailCoordinator,
        activity: SelectedSessionDetailLoadState,
        checkpoints: SelectedSessionDetailLoadState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<1_000 {
            if coordinator.activityLoadState == activity,
               coordinator.checkpointLoadState == checkpoints {
                return
            }
            await Task.yield()
        }
        XCTFail(
            "load states did not reach activity=\(activity), checkpoints=\(checkpoints)",
            file: file,
            line: line
        )
        throw SelectedSessionDetailTestError.requestTimeout
    }

    private func eventPage(sessionId: String, marker: String) throws -> SessionEventForwardPage {
        try decode(
            """
            {"events":[{"id":"event-\(marker)","event":"message","agent":{"displayName":"Agent"},
            "agentId":"agent-1","agentModel":"model","payload":{"text":"\(marker)"},"ts":"2026-07-31T00:00:00Z",
            "timestamp":"2026-07-31T00:00:00Z","cursor":"cursor-\(marker)","sequenceId":1,
            "sessionId":"\(sessionId)","source":null,"eventId":null,"idempotencyToken":null}]}
            """
        )
    }

    private func actionPage(sessionId: String, marker: String) throws -> SessionActionPage {
        try decode(
            """
            {"sessionId":"\(sessionId)","actions":[{"id":"action-\(marker)","sessionId":"\(sessionId)",
            "targetSequenceId":1,"targetCursor":null,"targetActionId":null,"actionType":"ack",
            "actorKind":"human","actorId":"actor-1","actorUserId":null,"actorRole":null,"note":"\(marker)",
            "metadata":{},"idempotencyKey":"idem-\(marker)","createdAt":"2026-07-31T00:00:00Z"}],
            "count":1,"projection":{}}
            """
        )
    }

    private func checkpointPage(sessionId: String, marker: String) throws -> SessionCheckpointListPage {
        try decode(
            """
            {"checkpoints":[{"checkpointId":"checkpoint-\(marker)","sessionId":"\(sessionId)",
            "kind":"manual","title":"\(marker)","summary":"summary","startSequence":1,"endSequence":1,
            "tokenRange":null,"createdBy":"agent-1","createdByAgentId":"agent-1","eventSequence":1,
            "cursor":"cursor-\(marker)","createdAt":"2026-07-31T00:00:00Z","summarySections":{},
            "grade":"A","gradeScore":100,"gradeVersion":"v1","gradeReasons":[]}],"count":1}
            """
        )
    }

    private func decode<Value: Decodable>(_ json: String) throws -> Value {
        try JSONDecoder().decode(Value.self, from: Data(json.utf8))
    }
}

@MainActor
private final class DetailCallbackProbe {
    var values: [String] = []
}
