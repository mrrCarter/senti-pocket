import Foundation
import XCTest
import PocketContracts
@testable import PocketSyncClient

private actor MockSessionTransport: SessionTransport {
    private var pages: [SessionListPage]
    private var cursors: [String?] = []

    init(pages: [SessionListPage]) {
        self.pages = pages
    }

    func listSessions(includeArchived: Bool, limit: Int, cursor: String?) async throws -> SessionListPage {
        cursors.append(cursor)
        guard !pages.isEmpty else { throw SessionTransportError.service(statusCode: 599) }
        return pages.removeFirst()
    }

    func requestedCursors() -> [String?] {
        cursors
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

private actor ControlledSessionTransport: SessionTransport {
    private var continuation: CheckedContinuation<SessionListPage, Error>?
    private var requestStarted: CheckedContinuation<Void, Never>?

    func waitUntilRequestStarts() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { requestStarted = $0 }
    }

    func listSessions(includeArchived: Bool, limit: Int, cursor: String?) async throws -> SessionListPage {
        try await withCheckedThrowingContinuation {
            continuation = $0
            requestStarted?.resume()
            requestStarted = nil
        }
    }

    func resume(with page: SessionListPage) {
        continuation?.resume(returning: page)
        continuation = nil
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

final class SessionRepositoryTests: XCTestCase {
    func test_refresh_and_load_more_preserve_order_and_advance_cursor() async throws {
        let first = try page(ids: ["room_3", "room_2"], nextCursor: "cursor-2", hasMore: true)
        let second = try page(ids: ["room_1"], nextCursor: nil, hasMore: false)
        let repository = SessionRepository(
            transport: MockSessionTransport(pages: [first, second]),
            pageSize: 2,
            clock: { Date(timeIntervalSince1970: 100) }
        )

        let refreshed = try await repository.refreshSessions()
        XCTAssertEqual(refreshed.sessions.map(\.sessionId), ["room_3", "room_2"])
        XCTAssertEqual(refreshed.nextCursor, "cursor-2")
        XCTAssertTrue(refreshed.hasMore)

        let complete = try await repository.loadMoreSessions()
        XCTAssertEqual(complete.sessions.map(\.sessionId), ["room_3", "room_2", "room_1"])
        XCTAssertNil(complete.nextCursor)
        XCTAssertFalse(complete.hasMore)
        XCTAssertEqual(complete.loadedAt, Date(timeIntervalSince1970: 100))
    }

    func test_duplicate_identity_across_pages_fails_without_corrupting_snapshot() async throws {
        let first = try page(ids: ["room_2"], nextCursor: "cursor-1", hasMore: true)
        let duplicate = try page(ids: ["room_2"], nextCursor: nil, hasMore: false)
        let repository = SessionRepository(transport: MockSessionTransport(pages: [first, duplicate]))

        _ = try await repository.refreshSessions()
        await expectInvalidData { try await repository.loadMoreSessions() }

        let retained = await repository.currentSnapshot()
        XCTAssertEqual(retained?.sessions.map(\.sessionId), ["room_2"])
        XCTAssertEqual(retained?.nextCursor, "cursor-1")
    }

    func test_cursor_loop_fails_without_appending_page() async throws {
        let first = try page(ids: ["room_2"], nextCursor: "cursor-loop", hasMore: true)
        let loop = try page(ids: ["room_1"], nextCursor: "cursor-loop", hasMore: true)
        let repository = SessionRepository(transport: MockSessionTransport(pages: [first, loop]))

        _ = try await repository.refreshSessions()
        await expectInvalidData { try await repository.loadMoreSessions() }

        let retained = await repository.currentSnapshot()
        XCTAssertEqual(retained?.sessions.map(\.sessionId), ["room_2"])
    }

    func test_unicode_canonical_but_byte_distinct_cursors_advance_independently() async throws {
        let composed = "cursor-caf\u{00E9}"
        let decomposed = "cursor-cafe\u{0301}"
        XCTAssertEqual(composed, decomposed, "precondition: Swift String equality is Unicode-canonical")
        XCTAssertFalse(OpaqueUTF8Identity.matches(composed, decomposed))

        let transport = MockSessionTransport(pages: [
            try page(ids: ["room_3"], nextCursor: composed, hasMore: true),
            try page(ids: ["room_2"], nextCursor: decomposed, hasMore: true),
            try page(ids: ["room_1"], nextCursor: nil, hasMore: false),
        ])
        let repository = SessionRepository(transport: transport)

        _ = try await repository.refreshSessions()
        let advanced = try await repository.loadMoreSessions()
        XCTAssertTrue(OpaqueUTF8Identity.matches(advanced.nextCursor, decomposed))
        XCTAssertFalse(OpaqueUTF8Identity.matches(advanced.nextCursor, composed))

        let complete = try await repository.loadMoreSessions()
        XCTAssertEqual(complete.sessions.map(\.sessionId), ["room_3", "room_2", "room_1"])
        XCTAssertNil(complete.nextCursor)
        XCTAssertFalse(complete.hasMore)

        let requested = await transport.requestedCursors()
        XCTAssertEqual(requested.count, 3)
        XCTAssertNil(requested[0])
        XCTAssertTrue(OpaqueUTF8Identity.matches(requested[1], composed))
        XCTAssertTrue(OpaqueUTF8Identity.matches(requested[2], decomposed))
    }

    func test_invalid_server_count_or_archive_mode_cannot_replace_valid_snapshot() async throws {
        let valid = try page(ids: ["room_2"], nextCursor: nil, hasMore: false)
        let invalidCount = try page(
            ids: ["room_1"],
            nextCursor: nil,
            hasMore: false,
            countOverride: 9
        )
        let repository = SessionRepository(transport: MockSessionTransport(pages: [valid, invalidCount]))

        _ = try await repository.refreshSessions()
        await expectInvalidData { try await repository.refreshSessions() }

        let retained = await repository.currentSnapshot()
        XCTAssertEqual(retained?.sessions.map(\.sessionId), ["room_2"])
    }

    func test_ambiguous_whitespace_cursor_cannot_replace_valid_snapshot() async throws {
        let valid = try page(ids: ["room_2"], nextCursor: nil, hasMore: false)
        let invalidCursor = try page(ids: ["room_1"], nextCursor: " cursor-1 ", hasMore: true)
        let repository = SessionRepository(transport: MockSessionTransport(pages: [valid, invalidCursor]))

        _ = try await repository.refreshSessions()
        await expectInvalidData { try await repository.refreshSessions() }

        let retained = await repository.currentSnapshot()
        XCTAssertEqual(retained?.sessions.map(\.sessionId), ["room_2"])
    }

    func test_empty_page_cannot_advance_an_unbounded_cursor_chain() async throws {
        let first = try page(ids: ["room_2"], nextCursor: "cursor-1", hasMore: true)
        let emptyMore = try page(ids: [], nextCursor: "cursor-2", hasMore: true)
        let repository = SessionRepository(transport: MockSessionTransport(pages: [first, emptyMore]))

        _ = try await repository.refreshSessions()
        await expectInvalidData { try await repository.loadMoreSessions() }

        let retained = await repository.currentSnapshot()
        XCTAssertEqual(retained?.sessions.map(\.sessionId), ["room_2"])
        XCTAssertEqual(retained?.nextCursor, "cursor-1")
    }

    func test_dot_segment_session_id_cannot_replace_valid_snapshot() async throws {
        let valid = try page(ids: ["room_2"], nextCursor: nil, hasMore: false)
        let dotSegment = try page(ids: [".."], nextCursor: nil, hasMore: false)
        let repository = SessionRepository(transport: MockSessionTransport(pages: [valid, dotSegment]))

        _ = try await repository.refreshSessions()
        await expectInvalidData { try await repository.refreshSessions() }

        let retained = await repository.currentSnapshot()
        XCTAssertEqual(retained?.sessions.map(\.sessionId), ["room_2"])
    }

    func test_accumulation_cap_fails_closed() async throws {
        let first = try page(ids: ["room_3", "room_2"], nextCursor: "cursor-2", hasMore: true)
        let second = try page(ids: ["room_1"], nextCursor: nil, hasMore: false)
        let repository = SessionRepository(
            transport: MockSessionTransport(pages: [first, second]),
            maximumAccumulatedSessions: 2
        )

        _ = try await repository.refreshSessions()
        await expectInvalidData { try await repository.loadMoreSessions() }
        let retained = await repository.currentSnapshot()
        XCTAssertEqual(retained?.count, 2)
    }

    func test_reset_drops_authorized_state() async throws {
        let repository = SessionRepository(
            transport: MockSessionTransport(pages: [
                try page(ids: ["room_1"], nextCursor: nil, hasMore: false)
            ])
        )
        _ = try await repository.refreshSessions()

        await repository.reset()

        let cleared = await repository.currentSnapshot()
        XCTAssertNil(cleared)
    }

    func test_reset_fences_an_inflight_refresh_from_repopulating_signed_out_state() async throws {
        let transport = ControlledSessionTransport()
        let repository = SessionRepository(transport: transport)
        let refresh = Task { try await repository.refreshSessions() }
        await transport.waitUntilRequestStarts()

        await repository.reset()
        let response = try page(ids: ["room_1"], nextCursor: nil, hasMore: false)
        await transport.resume(with: response)

        do {
            _ = try await refresh.value
            XCTFail("a pre-reset refresh must not repopulate authorized state")
        } catch let error as SessionTransportError {
            XCTAssertEqual(error, .cancelled)
        }
        let cleared = await repository.currentSnapshot()
        XCTAssertNil(cleared)
    }

    private func page(
        ids: [String],
        nextCursor: String?,
        hasMore: Bool,
        includeArchived: Bool = false,
        countOverride: Int? = nil
    ) throws -> SessionListPage {
        let sessions = ids.map { id in
            """
            {"sessionId":"\(id)","status":"active","archiveStatus":"active","visibility":"private",
            "membershipRole":"owner","title":"\(id)","summaryText":null,"summaryGeneratedAt":null,
            "summaryModel":null,"agentCount":1,"eventCount":1,"totalCostUsd":0,"createdAt":null,
            "lastActivityAt":null,"expiresAt":null,"killedAt":null,"templateName":null,
            "codebasePath":null,"s3ArchivePath":null}
            """
        }.joined(separator: ",")
        let cursorJSON = nextCursor.map { "\"\($0)\"" } ?? "null"
        let json = """
        {"sessions":[\(sessions)],"count":\(countOverride ?? ids.count),
        "include_archived":\(includeArchived),"next_cursor":\(cursorJSON),"has_more":\(hasMore)}
        """
        return try JSONDecoder().decode(SessionListPage.self, from: Data(json.utf8))
    }

    private func expectInvalidData<T>(
        _ operation: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("expected invalidData", file: file, line: line)
        } catch let error as SessionTransportError {
            XCTAssertEqual(error, .invalidData, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }
}
