import Foundation
import XCTest
import PocketContracts
@testable import PocketUI

final class SessionCheckpointPresentationTests: XCTestCase {
    private let decoder = JSONDecoder()

    func testRoomCheckpointPresentationIsNeutralAndPreservesTargetIdentity() throws {
        let state = SessionCheckpointListPresentationState(
            sessionId: "room-1",
            page: try page(),
            provenance: .network(lastUpdated: Date(timeIntervalSince1970: 1))
        )

        XCTAssertNil(state.failure)
        XCTAssertEqual(state.resultCount, 1)
        XCTAssertEqual(state.rows.first?.id.sessionId, "room-1")
        XCTAssertEqual(state.rows.first?.id.checkpointId, "cp-1")
        XCTAssertEqual(state.rows.first?.title, "Sunday checkpoint")
        XCTAssertEqual(state.rows.first?.sequenceLabel, "Events #10–#20")
        XCTAssertEqual(
            state.rows.first?.trustNotice,
            "Available through your room membership. Not a signed Pocket briefing."
        )
    }

    func testCrossSessionCheckpointFailsClosed() throws {
        let state = SessionCheckpointListPresentationState(
            sessionId: "different-room",
            page: try page(),
            provenance: .network(lastUpdated: Date())
        )

        XCTAssertEqual(state.failure, .invalidData)
        XCTAssertTrue(state.rows.isEmpty)
        XCTAssertEqual(state.resultCount, 0)
    }

    func testDuplicateCheckpointIdentityFailsClosed() throws {
        let checkpoint = checkpointJSON()
        let state = SessionCheckpointListPresentationState(
            sessionId: "room-1",
            page: try decode(SessionCheckpointListPage.self, """
            {"checkpoints":[\(checkpoint),\(checkpoint)],"count":2}
            """),
            provenance: .cache(cachedAt: Date(), authenticationExpired: false)
        )

        XCTAssertEqual(state.failure, .invalidData)
        XCTAssertTrue(state.rows.isEmpty)
        XCTAssertEqual(state.resultCount, 0)
    }

    func testInvalidSequenceOrCountFailsClosed() throws {
        let inverted = checkpointJSON(startSequence: 30, endSequence: 20)
        let invalidSequenceState = SessionCheckpointListPresentationState(
            sessionId: "room-1",
            page: try decode(SessionCheckpointListPage.self, """
            {"checkpoints":[\(inverted)],"count":1}
            """),
            provenance: .network(lastUpdated: Date())
        )
        XCTAssertEqual(invalidSequenceState.failure, .invalidData)
        XCTAssertTrue(invalidSequenceState.rows.isEmpty)

        let invalidCountState = SessionCheckpointListPresentationState(
            sessionId: "room-1",
            page: try decode(SessionCheckpointListPage.self, """
            {"checkpoints":[\(checkpointJSON())],"count":2}
            """),
            provenance: .network(lastUpdated: Date())
        )
        XCTAssertEqual(invalidCountState.failure, .invalidData)
        XCTAssertEqual(invalidCountState.resultCount, 0)
    }

    func testAuthorizationFailuresAndUnavailableSourceSuppressCheckpointContent() throws {
        let page = try page()
        for failure in [
            SessionLoadFailure.reauthenticationRequired,
            .accessDenied,
            .offlineNoCache,
            .invalidData
        ] {
            let state = SessionCheckpointListPresentationState(
                sessionId: "room-1",
                page: page,
                provenance: .cache(cachedAt: Date(), authenticationExpired: true),
                failure: failure
            )
            XCTAssertTrue(state.rows.isEmpty, "\(failure) must suppress membership-authorized content")
            XCTAssertEqual(state.resultCount, 0)
        }

        let unavailable = SessionCheckpointListPresentationState(
            sessionId: "room-1",
            page: page,
            provenance: .unavailable
        )
        XCTAssertTrue(unavailable.rows.isEmpty)
        XCTAssertEqual(unavailable.resultCount, 0)
    }

    private func page() throws -> SessionCheckpointListPage {
        try decode(SessionCheckpointListPage.self, """
        {"checkpoints":[\(checkpointJSON())],"count":1}
        """)
    }

    private func checkpointJSON(startSequence: Int64 = 10, endSequence: Int64 = 20) -> String {
        """
        {"checkpointId":"cp-1","sessionId":"room-1","kind":"manual_checkpoint",
        "title":"Sunday checkpoint","summary":"Bounded room summary","startSequence":\(startSequence),
        "endSequence":\(endSequence),"tokenRange":null,"createdBy":"carter",
        "createdByAgentId":"human-mrrcarter","eventSequence":21,"cursor":"c21",
        "createdAt":"2026-07-18T10:40:00Z","summarySections":{},"grade":"A-",
        "gradeScore":91,"gradeVersion":"v1","gradeReasons":[]}
        """
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try decoder.decode(type, from: Data(json.utf8))
    }
}
