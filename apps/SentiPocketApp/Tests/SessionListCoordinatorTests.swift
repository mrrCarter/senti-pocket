import Foundation
import PocketContracts
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

private enum SessionListMockResponse: Sendable {
    case page(SessionListPage)
    case failure(SessionTransportError)
}

private actor SessionListMockTransport: SessionTransport {
    private var responses: [SessionListMockResponse]

    init(_ responses: [SessionListMockResponse]) {
        self.responses = responses
    }

    func listSessions(includeArchived: Bool, limit: Int, cursor: String?) async throws -> SessionListPage {
        guard !responses.isEmpty else { throw SessionTransportError.service(statusCode: 599) }
        switch responses.removeFirst() {
        case .page(let page): return page
        case .failure(let error): throw error
        }
    }

    func listEvents(
        sessionId: String,
        after: String?,
        fromSequence: Int64?,
        limit: Int
    ) async throws -> SessionEventForwardPage {
        throw SessionTransportError.invalidRequest
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
        throw SessionTransportError.invalidRequest
    }

    func listCheckpoints(sessionId: String, limit: Int) async throws -> SessionCheckpointListPage {
        throw SessionTransportError.invalidRequest
    }
}

@MainActor
final class SessionListCoordinatorTests: XCTestCase {
    func test_refresh_projects_network_rows_and_allows_only_a_visible_selection() async throws {
        let coordinator = makeCoordinator([
            .page(try page(ids: ["room-2", "room-1"], nextCursor: nil, hasMore: false))
        ])

        await coordinator.start()?.value
        coordinator.send(.selectSession(sessionId: "forged-room"))
        XCTAssertNil(coordinator.selectedSessionId)
        coordinator.send(.selectSession(sessionId: "room-1"))

        XCTAssertEqual(coordinator.state.rows.map(\.sessionId), ["room-2", "room-1"])
        XCTAssertEqual(coordinator.selectedSessionId, "room-1")
        XCTAssertNil(coordinator.state.failure)
        guard case .network = coordinator.state.provenance else {
            return XCTFail("a successful repository refresh must be labeled network")
        }
    }

    func test_load_more_uses_repository_snapshot_and_preserves_order() async throws {
        let coordinator = makeCoordinator([
            .page(try page(ids: ["room-2"], nextCursor: "cursor-1", hasMore: true)),
            .page(try page(ids: ["room-1"], nextCursor: nil, hasMore: false))
        ])

        await coordinator.start()?.value
        await coordinator.loadMoreSessions().value

        XCTAssertEqual(coordinator.state.rows.map(\.sessionId), ["room-2", "room-1"])
        XCTAssertFalse(coordinator.state.hasMore)
    }

    func test_network_failure_after_success_keeps_rows_but_labels_cache() async throws {
        let coordinator = makeCoordinator([
            .page(try page(ids: ["room-1"], nextCursor: nil, hasMore: false)),
            .failure(.network)
        ])

        await coordinator.start()?.value
        await coordinator.refreshSessions().value

        XCTAssertEqual(coordinator.state.rows.map(\.sessionId), ["room-1"])
        XCTAssertEqual(coordinator.state.failure, .network)
        guard case .cache(_, let authenticationExpired) = coordinator.state.provenance else {
            return XCTFail("stale rows after a network failure must be labeled cache")
        }
        XCTAssertFalse(authenticationExpired)
    }

    func test_initial_network_failure_has_no_cache_and_no_protected_rows() async {
        let coordinator = makeCoordinator([.failure(.network)])

        await coordinator.start()?.value

        XCTAssertTrue(coordinator.state.rows.isEmpty)
        XCTAssertEqual(coordinator.state.failure, .offlineNoCache)
        XCTAssertNil(coordinator.selectedSessionId)
        guard case .unavailable = coordinator.state.provenance else {
            return XCTFail("there is no cache until one authorized refresh succeeds")
        }
    }

    func test_refresh_revokes_selection_when_session_leaves_authorized_rows() async throws {
        let selection = SessionSelectionProbe()
        let coordinator = makeCoordinator([
            .page(try page(ids: ["room-1"], nextCursor: nil, hasMore: false)),
            .page(try page(ids: ["room-2"], nextCursor: nil, hasMore: false))
        ], onSelectionChanged: { selection.values.append($0) })

        await coordinator.start()?.value
        coordinator.send(.selectSession(sessionId: "room-1"))
        XCTAssertEqual(coordinator.selectedSessionId, "room-1")

        await coordinator.refreshSessions().value

        XCTAssertNil(coordinator.selectedSessionId)
        XCTAssertEqual(coordinator.state.rows.map(\.sessionId), ["room-2"])
        XCTAssertEqual(selection.values, ["room-1", nil],
                       "dial registration must be revoked when the authorized row disappears")
    }

    func test_canonical_variant_not_present_as_an_exact_row_cannot_be_selected() async throws {
        let composed = "room-caf\u{00E9}"
        let decomposed = "room-cafe\u{0301}"
        XCTAssertEqual(composed, decomposed, "precondition: ordinary String comparison is canonical")
        let coordinator = makeCoordinator([
            .page(try page(ids: [composed], nextCursor: nil, hasMore: false))
        ])

        await coordinator.start()?.value
        coordinator.send(.selectSession(sessionId: decomposed))

        XCTAssertNil(coordinator.selectedSessionId)
        XCTAssertEqual(coordinator.state.rows.count, 1)
        XCTAssertTrue(coordinator.state.rows[0].sessionId.utf8.elementsEqual(composed.utf8))
    }

    func test_refresh_replacing_selection_with_canonical_variant_revokes_exact_authority() async throws {
        let composed = "room-caf\u{00E9}"
        let decomposed = "room-cafe\u{0301}"
        let selection = SessionSelectionProbe()
        let coordinator = makeCoordinator([
            .page(try page(ids: [composed], nextCursor: nil, hasMore: false)),
            .page(try page(ids: [decomposed], nextCursor: nil, hasMore: false)),
        ], onSelectionChanged: { selection.values.append($0) })

        await coordinator.start()?.value
        coordinator.send(.selectSession(sessionId: composed))
        await coordinator.refreshSessions().value

        XCTAssertNil(coordinator.selectedSessionId)
        XCTAssertEqual(selection.values.count, 2)
        XCTAssertTrue(selection.values[0]?.utf8.elementsEqual(composed.utf8) == true)
        XCTAssertNil(selection.values[1])
        XCTAssertTrue(coordinator.state.rows[0].sessionId.utf8.elementsEqual(decomposed.utf8))
    }

    func test_service_failure_after_success_keeps_rows_but_revokes_live_provenance() async throws {
        let coordinator = makeCoordinator([
            .page(try page(ids: ["room-1"], nextCursor: nil, hasMore: false)),
            .failure(.service(statusCode: 503))
        ])

        await coordinator.start()?.value
        await coordinator.refreshSessions().value

        XCTAssertEqual(coordinator.state.rows.map(\.sessionId), ["room-1"])
        XCTAssertEqual(coordinator.state.failure, .service)
        guard case .cache = coordinator.state.provenance else {
            return XCTFail("a failed refresh must never leave stale rows labeled as live network data")
        }
    }

    func test_401_clears_rows_selection_and_notifies_authentication_gate() async throws {
        let probe = ReauthenticationProbe()
        let coordinator = makeCoordinator([
            .page(try page(ids: ["room-1"], nextCursor: nil, hasMore: false)),
            .failure(.reauthenticationRequired)
        ], onReauthenticationRequired: {
            probe.count += 1
        })

        await coordinator.start()?.value
        coordinator.send(.selectSession(sessionId: "room-1"))
        await coordinator.refreshSessions().value

        XCTAssertTrue(coordinator.state.rows.isEmpty)
        XCTAssertNil(coordinator.selectedSessionId)
        XCTAssertEqual(coordinator.state.failure, .reauthenticationRequired)
        XCTAssertEqual(probe.count, 1)
        guard case .unavailable = coordinator.state.provenance else {
            return XCTFail("protected rows must be unavailable after a 401")
        }
    }

    private func makeCoordinator(
        _ responses: [SessionListMockResponse],
        onReauthenticationRequired: @escaping @MainActor () -> Void = {},
        onSelectionChanged: @escaping @MainActor (String?) -> Void = { _ in }
    ) -> SessionListCoordinator {
        let repository = SessionRepository(
            transport: SessionListMockTransport(responses),
            clock: { Date(timeIntervalSince1970: 100) }
        )
        return SessionListCoordinator(
            repository: repository,
            onReauthenticationRequired: onReauthenticationRequired,
            onSelectionChanged: onSelectionChanged
        )
    }

    private func page(ids: [String], nextCursor: String?, hasMore: Bool) throws -> SessionListPage {
        let sessions = ids.map { id in
            """
            {"sessionId":"\(id)","status":"active","archiveStatus":"active","visibility":"private",
            "membershipRole":"owner","title":"\(id)","summaryText":null,"summaryGeneratedAt":null,
            "summaryModel":null,"agentCount":1,"eventCount":1,"totalCostUsd":0,"createdAt":null,
            "lastActivityAt":null,"expiresAt":null,"killedAt":null,"templateName":null,
            "codebasePath":null,"s3ArchivePath":null}
            """
        }.joined(separator: ",")
        let cursor = nextCursor.map { "\"\($0)\"" } ?? "null"
        let json = """
        {"sessions":[\(sessions)],"count":\(ids.count),"include_archived":false,
        "next_cursor":\(cursor),"has_more":\(hasMore)}
        """
        return try JSONDecoder().decode(SessionListPage.self, from: Data(json.utf8))
    }
}

@MainActor
private final class ReauthenticationProbe {
    var count = 0
}

@MainActor
private final class SessionSelectionProbe {
    var values: [String?] = []
}
