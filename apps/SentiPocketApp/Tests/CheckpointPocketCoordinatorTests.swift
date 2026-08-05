import Foundation
import PocketCall
import PocketContracts
import PocketSyncClient
import XCTest
@testable import SentiPocketApp

private enum CheckpointPocketTestError: Error {
    case requestTimeout
}

private actor ControlledCheckpointTransport: CheckpointTransport {
    struct Request: Equatable, Sendable {
        let sessionId: String
        let checkpointId: String
    }

    private var requests: [Request] = []
    private var continuations: [CheckedContinuation<VerifiedBundle, Error>] = []

    func fetchExactCheckpoint(
        sessionId: String,
        checkpointId: String
    ) async throws -> VerifiedBundle {
        requests.append(Request(sessionId: sessionId, checkpointId: checkpointId))
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func requestSnapshot() -> [Request] { requests }

    func resumeNext(_ result: Result<VerifiedBundle, CheckpointTransportError>) {
        let continuation = continuations.removeFirst()
        switch result {
        case .success(let verified):
            continuation.resume(returning: verified)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

@MainActor
final class CheckpointPocketCoordinatorTests: XCTestCase {
    func test_exact_success_publishes_only_verified_bundle() async throws {
        let verified = try loadVerifiedBundle()
        let target = makeTarget(verified, authenticationRevision: 7)
        let transport = ControlledCheckpointTransport()
        let coordinator = CheckpointPocketCoordinator(transport: transport)
        coordinator.setSelectedSession(target.sessionId, authenticationRevision: 7)

        let operation = try XCTUnwrap(coordinator.open(target))
        XCTAssertEqual(coordinator.phase, .loading(target))
        try await waitForRequests(transport, count: 1)
        let requests = await transport.requestSnapshot()
        XCTAssertEqual(
            requests,
            [.init(sessionId: target.sessionId, checkpointId: target.checkpointId)]
        )

        await transport.resumeNext(.success(verified))
        await operation.value
        XCTAssertEqual(coordinator.phase, .ready(target, verified))
    }

    func test_wrong_authentication_or_session_target_never_starts_transport() async throws {
        let verified = try loadVerifiedBundle()
        let transport = ControlledCheckpointTransport()
        let coordinator = CheckpointPocketCoordinator(transport: transport)
        coordinator.setSelectedSession(verified.bundle.sessionId, authenticationRevision: 2)

        XCTAssertNil(coordinator.open(makeTarget(verified, authenticationRevision: 1)))
        XCTAssertNil(coordinator.open(ExactCheckpointTarget(
            authenticationRevision: 2,
            sessionId: "another-session",
            checkpointId: verified.bundle.checkpointId
        )))
        XCTAssertEqual(coordinator.phase, .idle)
        let requests = await transport.requestSnapshot()
        XCTAssertTrue(requests.isEmpty)
    }

    func test_transport_identity_mismatch_fails_closed() async throws {
        let verified = try loadVerifiedBundle()
        let target = ExactCheckpointTarget(
            authenticationRevision: 1,
            sessionId: verified.bundle.sessionId,
            checkpointId: "different-checkpoint"
        )
        let transport = ControlledCheckpointTransport()
        let coordinator = CheckpointPocketCoordinator(transport: transport)
        coordinator.setSelectedSession(target.sessionId, authenticationRevision: 1)

        let operation = try XCTUnwrap(coordinator.open(target))
        try await waitForRequests(transport, count: 1)
        await transport.resumeNext(.success(verified))
        await operation.value

        XCTAssertEqual(coordinator.phase, .failed(target, .invalidData))
    }

    func test_second_request_wins_when_cancelled_first_transport_still_completes() async throws {
        let verified = try loadVerifiedBundle()
        let target = makeTarget(verified, authenticationRevision: 1)
        let transport = ControlledCheckpointTransport()
        let coordinator = CheckpointPocketCoordinator(transport: transport)
        coordinator.setSelectedSession(target.sessionId, authenticationRevision: 1)

        let first = try XCTUnwrap(coordinator.open(target))
        try await waitForRequests(transport, count: 1)
        let second = try XCTUnwrap(coordinator.open(target))
        try await waitForRequests(transport, count: 2)

        await transport.resumeNext(.success(verified))
        await first.value
        XCTAssertEqual(coordinator.phase, .loading(target))

        await transport.resumeNext(.success(verified))
        await second.value
        XCTAssertEqual(coordinator.phase, .ready(target, verified))
    }

    func test_selection_and_same_session_authentication_changes_drop_late_success() async throws {
        let verified = try loadVerifiedBundle()
        let firstTarget = makeTarget(verified, authenticationRevision: 1)
        let transport = ControlledCheckpointTransport()
        let coordinator = CheckpointPocketCoordinator(transport: transport)
        coordinator.setSelectedSession(firstTarget.sessionId, authenticationRevision: 1)

        let oldPrincipal = try XCTUnwrap(coordinator.open(firstTarget))
        try await waitForRequests(transport, count: 1)
        coordinator.setSelectedSession(firstTarget.sessionId, authenticationRevision: 2)
        await transport.resumeNext(.success(verified))
        await oldPrincipal.value
        XCTAssertEqual(coordinator.phase, .idle)

        let secondTarget = makeTarget(verified, authenticationRevision: 2)
        let oldSelection = try XCTUnwrap(coordinator.open(secondTarget))
        try await waitForRequests(transport, count: 2)
        coordinator.setSelectedSession("another-session", authenticationRevision: 2)
        await transport.resumeNext(.success(verified))
        await oldSelection.value
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func test_done_clears_content_and_drops_late_completion() async throws {
        let verified = try loadVerifiedBundle()
        let target = makeTarget(verified, authenticationRevision: 1)
        let transport = ControlledCheckpointTransport()
        let coordinator = CheckpointPocketCoordinator(transport: transport)
        coordinator.setSelectedSession(target.sessionId, authenticationRevision: 1)

        let operation = try XCTUnwrap(coordinator.open(target))
        try await waitForRequests(transport, count: 1)
        coordinator.clear()
        XCTAssertEqual(coordinator.phase, .idle)

        await transport.resumeNext(.success(verified))
        await operation.value
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func test_ready_content_revokes_synchronously_before_checkpoint_owner_mutates() async throws {
        let verified = try loadVerifiedBundle()
        let target = makeTarget(verified, authenticationRevision: 1)
        let transport = ControlledCheckpointTransport()
        var coordinator: CheckpointPocketCoordinator!
        var observedPhases: [CheckpointPocketPhase] = []
        coordinator = CheckpointPocketCoordinator(
            transport: transport,
            onProtectedContentRevoked: {
                observedPhases.append(coordinator.phase)
            }
        )
        coordinator.setSelectedSession(target.sessionId, authenticationRevision: 1)

        let operation = try XCTUnwrap(coordinator.open(target))
        try await waitForRequests(transport, count: 1)
        await transport.resumeNext(.success(verified))
        await operation.value
        XCTAssertEqual(coordinator.phase, .ready(target, verified))

        coordinator.clear()
        XCTAssertEqual(observedPhases, [.ready(target, verified)])
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func test_current_401_notifies_once_while_stale_401_cannot_revoke_new_login() async throws {
        let verified = try loadVerifiedBundle()
        let transport = ControlledCheckpointTransport()
        let callbacks = CheckpointCallbackProbe()
        let coordinator = CheckpointPocketCoordinator(
            transport: transport,
            onReauthenticationRequired: { callbacks.reauthenticationCount += 1 }
        )
        let firstTarget = makeTarget(verified, authenticationRevision: 1)
        coordinator.setSelectedSession(firstTarget.sessionId, authenticationRevision: 1)

        let current = try XCTUnwrap(coordinator.open(firstTarget))
        try await waitForRequests(transport, count: 1)
        await transport.resumeNext(.failure(.reauthenticationRequired))
        await current.value
        XCTAssertEqual(callbacks.reauthenticationCount, 1)
        XCTAssertEqual(coordinator.phase, .failed(firstTarget, .reauthenticationRequired))

        coordinator.setSelectedSession(firstTarget.sessionId, authenticationRevision: 2)
        let secondTarget = makeTarget(verified, authenticationRevision: 2)
        let stale = try XCTUnwrap(coordinator.open(secondTarget))
        try await waitForRequests(transport, count: 2)
        coordinator.setSelectedSession(firstTarget.sessionId, authenticationRevision: 3)
        await transport.resumeNext(.failure(.reauthenticationRequired))
        await stale.value
        XCTAssertEqual(callbacks.reauthenticationCount, 1)
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func test_403_revokes_exact_selection_and_recoverable_failure_retains_no_bundle() async throws {
        let verified = try loadVerifiedBundle()
        let target = makeTarget(verified, authenticationRevision: 1)
        let transport = ControlledCheckpointTransport()
        let callbacks = CheckpointCallbackProbe()
        let coordinator = CheckpointPocketCoordinator(
            transport: transport,
            onSelectionRevoked: { callbacks.revokedSessions.append($0) }
        )
        coordinator.setSelectedSession(target.sessionId, authenticationRevision: 1)

        let denied = try XCTUnwrap(coordinator.open(target))
        try await waitForRequests(transport, count: 1)
        await transport.resumeNext(.failure(.accessDenied))
        await denied.value
        XCTAssertEqual(callbacks.revokedSessions, [target.sessionId])
        XCTAssertEqual(coordinator.phase, .failed(target, .accessDenied))

        let live = try XCTUnwrap(coordinator.open(target))
        try await waitForRequests(transport, count: 2)
        await transport.resumeNext(.success(verified))
        await live.value
        XCTAssertEqual(coordinator.phase, .ready(target, verified))

        let offline = try XCTUnwrap(coordinator.open(target))
        XCTAssertEqual(coordinator.phase, .loading(target))
        try await waitForRequests(transport, count: 3)
        await transport.resumeNext(.failure(.network))
        await offline.value
        XCTAssertEqual(coordinator.phase, .failed(target, .network))

        let retry = try XCTUnwrap(coordinator.retry())
        try await waitForRequests(transport, count: 4)
        await transport.resumeNext(.success(verified))
        await retry.value
        XCTAssertEqual(coordinator.phase, .ready(target, verified))
    }

    private func waitForRequests(
        _ transport: ControlledCheckpointTransport,
        count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if await transport.requestSnapshot().count == count { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("checkpoint requests did not reach \(count)", file: file, line: line)
        throw CheckpointPocketTestError.requestTimeout
    }

    private func makeTarget(
        _ verified: VerifiedBundle,
        authenticationRevision: UInt64
    ) -> ExactCheckpointTarget {
        ExactCheckpointTarget(
            authenticationRevision: authenticationRevision,
            sessionId: verified.bundle.sessionId,
            checkpointId: verified.bundle.checkpointId
        )
    }

    private func loadVerifiedBundle() throws -> VerifiedBundle {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bundle = try decoder.decode(
            PocketBundle.self,
            from: Data(contentsOf: canonicalFixtureURL)
        )
        return try XCTUnwrap(VerifiedBundle.verify(bundle))
    }

    private var canonicalFixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // SentiPocketApp
            .deletingLastPathComponent() // apps
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("packages/PocketContracts/Fixtures/canonical_checkpoint.json")
            .standardizedFileURL
    }
}

@MainActor
private final class CheckpointCallbackProbe {
    var reauthenticationCount = 0
    var revokedSessions: [String] = []
}
