import Foundation
import XCTest
import PocketContracts
@testable import PocketUI

final class SessionPresentationTests: XCTestCase {
    func testRepositorySnapshotInitializerDoesNotManufactureWireProvenance() throws {
        let page = try decode(SessionListPage.self, """
        {"sessions":[{"sessionId":"room-1","status":"active","archiveStatus":"active",
        "visibility":"private","membershipRole":"owner","title":"Room","summaryText":null,
        "summaryGeneratedAt":null,"summaryModel":null,"agentCount":1,"eventCount":1,
        "totalCostUsd":0,"createdAt":null,"lastActivityAt":null,"expiresAt":null,
        "killedAt":null,"templateName":null,"codebasePath":null,"s3ArchivePath":null}],
        "count":1,"include_archived":false,"next_cursor":null,"has_more":false}
        """)
        let state = SessionListPresentationState(
            sessions: page.sessions,
            includesArchived: false,
            hasMore: false,
            provenance: .network(lastUpdated: Date(timeIntervalSince1970: 9))
        )

        XCTAssertEqual(state.rows.map(\.sessionId), ["room-1"])
        XCTAssertEqual(state.resultCount, 1)
        XCTAssertNil(state.failure)
    }

    func testRepositorySnapshotInitializerRejectsCountDrift() throws {
        let page = try decode(SessionListPage.self, """
        {"sessions":[],"count":0,"include_archived":false,"next_cursor":null,"has_more":false}
        """)
        let state = SessionListPresentationState(
            sessions: page.sessions,
            resultCount: 1,
            includesArchived: false,
            hasMore: false,
            provenance: .network(lastUpdated: Date())
        )

        XCTAssertTrue(state.rows.isEmpty)
        XCTAssertEqual(state.resultCount, 0)
        XCTAssertEqual(state.failure, .invalidData)
    }

    private let decoder = JSONDecoder()

    func testSessionRowsPreserveIdentityAndUsePresentationFallbacks() throws {
        let page = try decode(SessionListPage.self, """
        {"sessions":[{"sessionId":"room-1","status":"active","archiveStatus":"active",
        "visibility":"private","membershipRole":"owner","title":"   ","summaryText":"  Current work  ",
        "summaryGeneratedAt":null,"summaryModel":null,"agentCount":2,"eventCount":41,"totalCostUsd":1.25,
        "createdAt":"2026-07-18T10:00:00Z","lastActivityAt":"2026-07-18T10:36:34Z","expiresAt":null,
        "killedAt":null,"templateName":null,"codebasePath":null,"s3ArchivePath":null}],"count":1,
        "include_archived":false,"next_cursor":null,"has_more":false}
        """)

        let state = SessionListPresentationState(
            page: page,
            provenance: .network(lastUpdated: Date(timeIntervalSince1970: 1))
        )

        XCTAssertEqual(state.rows.count, 1)
        XCTAssertEqual(state.rows[0].sessionId, "room-1")
        XCTAssertEqual(state.rows[0].id.rawValue, "room-1")
        XCTAssertEqual(state.rows[0].title, "Untitled session")
        XCTAssertEqual(state.rows[0].summary, "Current work")
        XCTAssertEqual(state.rows[0].statusLabel, "Active")
        XCTAssertEqual(state.rows[0].lastActivity?.raw, "2026-07-18T10:36:34Z")
    }

    func testActivityKeepsEventsAndActionsSeparateAndLosslesslyTargetsThem() throws {
        let events = try decode(SessionEventForwardPage.self, """
        {"events":[{"id":"ev-1","event":"session_message","agent":{"displayName":"Relay"},
        "agentId":"claude-pocket-relay","agentModel":"claude","payload":{"text":"hello"},
        "ts":"2026-07-18T10:35:00Z","timestamp":"2026-07-18T10:35:00Z","cursor":"c1",
        "sequenceId":230141,"sessionId":"room-1","source":"relay"}]}
        """)
        let actions = try decode(SessionActionPage.self, """
        {"sessionId":"room-1","count":1,"projection":{},"actions":[{"id":"act-1",
        "sessionId":"room-1","targetSequenceId":230141,"targetCursor":null,"targetActionId":null,
        "actionType":"ack","actorKind":"human","actorId":"carter","actorUserId":null,"actorRole":"owner",
        "note":"reviewed","metadata":{},"idempotencyKey":"idem-1","createdAt":"2026-07-18T10:36:00Z"}]}
        """)

        let state = SessionActivityPresentationState(
            sessionId: "room-1",
            eventPage: events,
            actionPage: actions,
            provenance: .cache(cachedAt: Date(timeIntervalSince1970: 2), authenticationExpired: false)
        )

        XCTAssertNil(state.failure)
        XCTAssertEqual(state.events.map(\.sequenceId), [230141])
        XCTAssertEqual(state.events.first?.author, "Relay")
        XCTAssertEqual(state.events.first?.text, "hello")
        XCTAssertEqual(state.actions.first?.id.actionId, "act-1")
        XCTAssertEqual(state.actions.first?.targetSequenceId, 230141)
        XCTAssertEqual(state.actions.first?.targetLabel, "Target #230141")
        XCTAssertEqual(state.actions.first?.actionType, "ack")
    }

    func testSessionLevelActionDoesNotManufactureEventZeroTarget() throws {
        let events = try decode(SessionEventForwardPage.self, #"{"events":[]}"#)
        let actions = try decode(SessionActionPage.self, """
        {"sessionId":"room-1","count":1,"projection":{},"actions":[{"id":"act-session",
        "sessionId":"room-1","targetSequenceId":0,"targetCursor":null,"targetActionId":null,
        "actionType":"working_on","actorKind":"agent","actorId":"relay","actorUserId":null,
        "actorRole":null,"note":null,"metadata":{},"idempotencyKey":"idem-session",
        "createdAt":"2026-07-18T10:36:00Z"}]}
        """)

        let state = SessionActivityPresentationState(
            sessionId: "room-1",
            eventPage: events,
            actionPage: actions,
            provenance: .network(lastUpdated: Date())
        )

        XCTAssertEqual(state.actions.first?.targetSequenceId, 0)
        XCTAssertEqual(state.actions.first?.targetLabel, "Session-level")
    }

    func testCrossSessionActivityFailsClosedWithoutLeakingRows() throws {
        let events = try decode(SessionEventForwardPage.self, """
        {"events":[{"id":"ev-1","event":"session_message","agent":{},"agentId":"relay",
        "agentModel":"","payload":{"text":"private"},"ts":"2026-07-18T10:35:00Z",
        "timestamp":"2026-07-18T10:35:00Z","cursor":"c1","sequenceId":7,
        "sessionId":"different-room","source":null}]}
        """)
        let actions = try decode(SessionActionPage.self, """
        {"sessionId":"room-1","count":0,"projection":{},"actions":[]}
        """)

        let state = SessionActivityPresentationState(
            sessionId: "room-1",
            eventPage: events,
            actionPage: actions,
            provenance: .network(lastUpdated: Date())
        )

        XCTAssertEqual(state.failure, .invalidData)
        XCTAssertTrue(state.events.isEmpty)
        XCTAssertTrue(state.actions.isEmpty)
    }

    func testDuplicateEventSequenceFailsClosedBeforeIntentRouting() throws {
        let events = try decode(SessionEventForwardPage.self, """
        {"events":[{"id":"ev-1","event":"session_message","agent":{},"agentId":"relay",
        "agentModel":"","payload":{"text":"first"},"ts":"2026-07-18T10:35:00Z",
        "timestamp":"2026-07-18T10:35:00Z","cursor":"c1","sequenceId":7,
        "sessionId":"room-1","source":null},{"id":"ev-2","event":"session_message","agent":{},
        "agentId":"relay","agentModel":"","payload":{"text":"ambiguous"},
        "ts":"2026-07-18T10:36:00Z","timestamp":"2026-07-18T10:36:00Z","cursor":"c2",
        "sequenceId":7,"sessionId":"room-1","source":null}]}
        """)
        let actions = try decode(SessionActionPage.self, """
        {"sessionId":"room-1","count":0,"projection":{},"actions":[]}
        """)

        let state = SessionActivityPresentationState(
            sessionId: "room-1",
            eventPage: events,
            actionPage: actions,
            provenance: .network(lastUpdated: Date())
        )

        XCTAssertEqual(state.failure, .invalidData)
        XCTAssertTrue(state.events.isEmpty)
        XCTAssertTrue(state.actions.isEmpty)
    }

    func testDuplicateSessionIdentityFailsClosedBeforeSwiftUIDiffing() throws {
        let session = """
        {"sessionId":"room-1","status":"active","archiveStatus":"active","visibility":"private",
        "membershipRole":"owner","title":"Room","summaryText":null,"summaryGeneratedAt":null,
        "summaryModel":null,"agentCount":1,"eventCount":1,"totalCostUsd":0,"createdAt":null,
        "lastActivityAt":null,"expiresAt":null,"killedAt":null,"templateName":null,"codebasePath":null,
        "s3ArchivePath":null}
        """
        let page = try decode(SessionListPage.self, """
        {"sessions":[\(session),\(session)],"count":2,"include_archived":false,
        "next_cursor":null,"has_more":false}
        """)

        let state = SessionListPresentationState(
            page: page,
            provenance: .network(lastUpdated: Date())
        )

        XCTAssertTrue(state.rows.isEmpty)
        XCTAssertEqual(state.failure, .invalidData)
    }

    func testCanonicalButByteDistinctSessionRowsRemainDistinctSwiftUIIdentities() throws {
        let composed = "room-caf\u{00E9}"
        let decomposed = "room-cafe\u{0301}"
        XCTAssertEqual(composed, decomposed, "precondition: ordinary String identity would collide")
        func session(_ id: String) -> String {
            """
            {"sessionId":"\(id)","status":"active","archiveStatus":"active","visibility":"private",
            "membershipRole":"owner","title":"Room","summaryText":null,"summaryGeneratedAt":null,
            "summaryModel":null,"agentCount":1,"eventCount":1,"totalCostUsd":0,"createdAt":null,
            "lastActivityAt":null,"expiresAt":null,"killedAt":null,"templateName":null,"codebasePath":null,
            "s3ArchivePath":null}
            """
        }
        let page = try decode(SessionListPage.self, """
        {"sessions":[\(session(composed)),\(session(decomposed))],"count":2,
        "include_archived":false,"next_cursor":null,"has_more":false}
        """)

        let state = SessionListPresentationState(
            page: page,
            provenance: .network(lastUpdated: Date())
        )

        XCTAssertNil(state.failure)
        XCTAssertEqual(state.rows.count, 2)
        XCTAssertNotEqual(state.rows[0].id, state.rows[1].id)
        XCTAssertFalse(state.rows[0].sessionId.utf8.elementsEqual(state.rows[1].sessionId.utf8))
    }

    func testCanonicalButByteDistinctActivitySessionFailsClosed() throws {
        let composed = "room-caf\u{00E9}"
        let decomposed = "room-cafe\u{0301}"
        let events = try decode(SessionEventForwardPage.self, """
        {"events":[{"id":"ev-1","event":"session_message","agent":{},"agentId":"relay",
        "agentModel":"","payload":{"text":"private"},"ts":"2026-07-18T10:35:00Z",
        "timestamp":"2026-07-18T10:35:00Z","cursor":"c1","sequenceId":7,
        "sessionId":"\(decomposed)","source":null}]}
        """)
        let actions = try decode(SessionActionPage.self, """
        {"sessionId":"\(composed)","count":0,"projection":{},"actions":[]}
        """)

        let state = SessionActivityPresentationState(
            sessionId: composed,
            eventPage: events,
            actionPage: actions,
            provenance: .network(lastUpdated: Date())
        )

        XCTAssertEqual(state.failure, .invalidData)
        XCTAssertTrue(state.events.isEmpty)
    }

    func testCanonicalButByteDistinctActionSessionFailsClosed() throws {
        let composed = "room-caf\u{00E9}"
        let decomposed = "room-cafe\u{0301}"
        let events = try decode(SessionEventForwardPage.self, #"{"events":[]}"#)
        let envelopeVariant = try decode(SessionActionPage.self, """
        {"sessionId":"\(decomposed)","count":0,"projection":{},"actions":[]}
        """)
        let rowVariant = try decode(SessionActionPage.self, """
        {"sessionId":"\(composed)","count":1,"projection":{},"actions":[{"id":"act-1",
        "sessionId":"\(decomposed)","targetSequenceId":0,"targetCursor":null,"targetActionId":null,
        "actionType":"working_on","actorKind":"agent","actorId":"relay","actorUserId":null,
        "actorRole":null,"note":null,"metadata":{},"idempotencyKey":"idem-1",
        "createdAt":"2026-07-18T10:36:00Z"}]}
        """)

        for actions in [envelopeVariant, rowVariant] {
            let state = SessionActivityPresentationState(
                sessionId: composed,
                eventPage: events,
                actionPage: actions,
                provenance: .network(lastUpdated: Date())
            )
            XCTAssertEqual(state.failure, .invalidData)
            XCTAssertTrue(state.actions.isEmpty)
        }
    }

    func testCanonicalButByteDistinctEventIDsDoNotCollapse() throws {
        let composed = "event-caf\u{00E9}"
        let decomposed = "event-cafe\u{0301}"
        let events = try decode(SessionEventForwardPage.self, """
        {"events":[{"id":"\(composed)","event":"session_message","agent":{},"agentId":"relay",
        "agentModel":"","payload":{},"ts":"2026-07-18T10:35:00Z","timestamp":"2026-07-18T10:35:00Z",
        "cursor":"c1","sequenceId":7,"sessionId":"room-1","source":null},
        {"id":"\(decomposed)","event":"session_message","agent":{},"agentId":"relay",
        "agentModel":"","payload":{},"ts":"2026-07-18T10:36:00Z","timestamp":"2026-07-18T10:36:00Z",
        "cursor":"c2","sequenceId":8,"sessionId":"room-1","source":null}]}
        """)
        let actions = try decode(SessionActionPage.self, #"{"sessionId":"room-1","count":0,"projection":{},"actions":[]}"#)
        let state = SessionActivityPresentationState(
            sessionId: "room-1",
            eventPage: events,
            actionPage: actions,
            provenance: .network(lastUpdated: Date())
        )

        XCTAssertNil(state.failure)
        XCTAssertEqual(state.events.count, 2)
        XCTAssertNotEqual(state.events[0].id, state.events[1].id)
    }

    func testAuthorizationFailureSuppressesOtherwiseValidProtectedRows() throws {
        let page = try decode(SessionListPage.self, """
        {"sessions":[{"sessionId":"room-1","status":"active","archiveStatus":"active",
        "visibility":"private","membershipRole":"owner","title":"Private room","summaryText":"hidden",
        "summaryGeneratedAt":null,"summaryModel":null,"agentCount":1,"eventCount":1,"totalCostUsd":0,
        "createdAt":null,"lastActivityAt":null,"expiresAt":null,"killedAt":null,"templateName":null,
        "codebasePath":null,"s3ArchivePath":null}],"count":1,"include_archived":false,
        "next_cursor":null,"has_more":false}
        """)

        for failure in [
            SessionLoadFailure.reauthenticationRequired,
            .accessDenied,
            .offlineNoCache,
            .invalidData
        ] {
            let state = SessionListPresentationState(
                page: page,
                provenance: .cache(cachedAt: Date(), authenticationExpired: true),
                failure: failure
            )
            XCTAssertTrue(state.rows.isEmpty, "\(failure) must suppress protected rows")
            XCTAssertEqual(state.resultCount, 0)
            XCTAssertFalse(state.hasMore)
        }

        let unavailable = SessionListPresentationState(
            page: page,
            provenance: .unavailable
        )
        XCTAssertTrue(unavailable.rows.isEmpty)
        XCTAssertEqual(unavailable.resultCount, 0)
        XCTAssertFalse(unavailable.hasMore)
    }

    func testAuthPresentationContainsOnlyClosedNonSecretPhases() {
        let phases: [PocketSignInPhase] = [
            .signedOut,
            .authorizing,
            .signedIn,
            .reauthenticationRequired,
            .signingOut,
            .unavailable(.configuration)
        ]

        XCTAssertEqual(phases.count, 6)
        XCTAssertTrue(PocketSignInUnavailableReason.configuration.userMessage.contains("not registered"))
        XCTAssertFalse(PocketSignInUnavailableReason.secureStorage.userMessage.localizedCaseInsensitiveContains("token"))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try decoder.decode(type, from: Data(json.utf8))
    }
}
