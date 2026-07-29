import Foundation
@testable import PocketVoice
import XCTest

final class VoiceRosterReadModelTests: XCTestCase {
    func testStagesPagesAndCommitsOnlyTheCompleteSnapshot() async throws {
        let identity = try makeIdentity()
        let projection = VoiceRosterProjection(identity: identity)
        let first = try VoiceRosterPage(
            identity: identity,
            snapshotId: snapshotId,
            pageIndex: 0,
            joinedCount: 2,
            participants: [try participant(index: 1)],
            nextCursor: "r1.first.signature",
            complete: false
        )
        let firstResult = try await projection.apply(first)
        let beforeCommit = await projection.currentSnapshot()
        XCTAssertNil(firstResult)
        XCTAssertNil(beforeCommit)

        let second = try VoiceRosterPage(
            identity: identity,
            snapshotId: snapshotId,
            pageIndex: 1,
            joinedCount: 2,
            participants: [try participant(index: 2)],
            nextCursor: nil,
            complete: true
        )
        let secondResult = try await projection.apply(second)
        let snapshot = try XCTUnwrap(secondResult)
        XCTAssertEqual(snapshot.joinedCount, 2)
        XCTAssertEqual(
            snapshot.participants.map(\.principalId),
            ["human-1", "human-2"]
        )
        let current = await projection.currentSnapshot()
        XCTAssertEqual(current, snapshot)
    }

    func testPageGapDiscardsPendingButPreservesLastCommittedSnapshot() async throws {
        let identity = try makeIdentity()
        let projection = VoiceRosterProjection(identity: identity)
        let committed = try VoiceRosterPage(
            identity: identity,
            snapshotId: snapshotId,
            pageIndex: 0,
            joinedCount: 1,
            participants: [try participant(index: 1)],
            nextCursor: nil,
            complete: true
        )
        let committedResult = try await projection.apply(committed)
        let baseline = try XCTUnwrap(committedResult)

        let nextSnapshotId =
            "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
        let first = try VoiceRosterPage(
            identity: identity,
            snapshotId: nextSnapshotId,
            pageIndex: 0,
            joinedCount: 2,
            participants: [try participant(index: 2)],
            nextCursor: "r1.next.signature",
            complete: false
        )
        let firstResult = try await projection.apply(first)
        XCTAssertNil(firstResult)
        let gap = try VoiceRosterPage(
            identity: identity,
            snapshotId: nextSnapshotId,
            pageIndex: 2,
            joinedCount: 2,
            participants: [try participant(index: 3)],
            nextCursor: nil,
            complete: true
        )
        await XCTAssertThrowsVoiceError(.invalidSnapshot) {
            try await projection.apply(gap)
        }
        let current = await projection.currentSnapshot()
        XCTAssertEqual(current, baseline)
    }

    func testDuplicateBindingAcrossPagesFailsClosed() async throws {
        let identity = try makeIdentity()
        let projection = VoiceRosterProjection(identity: identity)
        let repeated = try participant(index: 1)
        let firstResult = try await projection.apply(
            try VoiceRosterPage(
                identity: identity,
                snapshotId: snapshotId,
                pageIndex: 0,
                joinedCount: 2,
                participants: [repeated],
                nextCursor: "r1.next.signature",
                complete: false
            )
        )
        XCTAssertNil(firstResult)
        await XCTAssertThrowsVoiceError(.invalidSnapshot) {
            try await projection.apply(
                try VoiceRosterPage(
                    identity: identity,
                    snapshotId: snapshotId,
                    pageIndex: 1,
                    joinedCount: 2,
                    participants: [repeated],
                    nextCursor: nil,
                    complete: true
                )
            )
        }
        let current = await projection.currentSnapshot()
        XCTAssertNil(current)
    }

    func testDuplicateProviderParticipantAcrossPagesFailsClosed() async throws {
        let identity = try makeIdentity()
        let projection = VoiceRosterProjection(identity: identity)
        let firstResult = try await projection.apply(
            try VoiceRosterPage(
                identity: identity,
                snapshotId: snapshotId,
                pageIndex: 0,
                joinedCount: 2,
                participants: [try participant(index: 1)],
                nextCursor: "r1.next.signature",
                complete: false
            )
        )
        XCTAssertNil(firstResult)
        await XCTAssertThrowsVoiceError(.invalidSnapshot) {
            try await projection.apply(
                try VoiceRosterPage(
                    identity: identity,
                    snapshotId: snapshotId,
                    pageIndex: 1,
                    joinedCount: 2,
                    participants: [
                        try participant(
                            index: 2,
                            providerParticipantId: "provider-1"
                        )
                    ],
                    nextCursor: nil,
                    complete: true
                )
            )
        }
        let current = await projection.currentSnapshot()
        XCTAssertNil(current)
    }

    func testDuplicateProviderParticipantInsideOnePageFailsClosed() throws {
        let identity = try makeIdentity()
        XCTAssertThrowsError(
            try VoiceRosterPage(
                identity: identity,
                snapshotId: snapshotId,
                pageIndex: 0,
                joinedCount: 2,
                participants: [
                    try participant(index: 1),
                    try participant(
                        index: 2,
                        providerParticipantId: "provider-1"
                    )
                ],
                nextCursor: nil,
                complete: true
            )
        )
    }

    func testWrongEpochCannotReplaceTheProjection() async throws {
        let identity = try makeIdentity()
        let projection = VoiceRosterProjection(identity: identity)
        let other = try VoiceRoomIdentity(
            tenantId: identity.tenantId,
            sentiSessionId: identity.sentiSessionId,
            voiceRoomEpochId: "other-epoch"
        )
        let page = try VoiceRosterPage(
            identity: other,
            snapshotId: snapshotId,
            pageIndex: 0,
            joinedCount: 1,
            participants: [try participant(index: 1)],
            nextCursor: nil,
            complete: true
        )
        await XCTAssertThrowsVoiceError(.staleEpoch) {
            try await projection.apply(page)
        }
        let current = await projection.currentSnapshot()
        XCTAssertNil(current)
    }

    func testCompletePageCannotOverclaimItsJoinedCount() async throws {
        let identity = try makeIdentity()
        let projection = VoiceRosterProjection(identity: identity)
        let page = try VoiceRosterPage(
            identity: identity,
            snapshotId: snapshotId,
            pageIndex: 0,
            joinedCount: 2,
            participants: [try participant(index: 1)],
            nextCursor: nil,
            complete: true
        )
        await XCTAssertThrowsVoiceError(.invalidSnapshot) {
            try await projection.apply(page)
        }
    }

    func testDecodingRejectsUnknownSchemaAndProviderIdentityAsPrincipal() throws {
        let data = Data(
            """
            {
              "requestId": "request-roster-0001",
              "page": {
                "schemaVersion": "senti.voice_roster.page.v2",
                "tenantId": "tenant-demo",
                "sessionId": "session-demo",
                "roomEpoch": "epoch-demo",
                "snapshotId": "\(snapshotId)",
                "pageIndex": 0,
                "joinedCount": 1,
                "participants": [{
                  "principalId": "senti_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                  "providerParticipantId": "provider-1",
                  "providerCorrelationId": "senti_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                  "providerSessionId": "session-1",
                  "providerPeerId": "peer-1",
                  "kind": "human",
                  "role": "listener",
                  "displayName": "Person",
                  "joinedAt": "2026-07-29T12:00:00.000Z"
                }],
                "nextCursor": null,
                "complete": true
              }
            }
            """.utf8
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(VoiceRosterPageResponse.self, from: data)
        )
        XCTAssertThrowsError(
            try VoiceRosterParticipant(
                principalId:
                    "senti_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                providerParticipantId: "provider-1",
                providerCorrelationId:
                    "senti_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                providerSessionId: "session-1",
                providerPeerId: "peer-1",
                kind: .human,
                role: .listener,
                displayName: "Person",
                joinedAt: Date()
            )
        )
    }

    private let snapshotId =
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

    private func makeIdentity() throws -> VoiceRoomIdentity {
        try VoiceRoomIdentity(
            tenantId: "tenant-demo",
            sentiSessionId: "session-demo",
            voiceRoomEpochId: "epoch-demo"
        )
    }

    private func participant(
        index: Int,
        providerParticipantId: String? = nil
    ) throws -> VoiceRosterParticipant {
        try VoiceRosterParticipant(
            principalId: "human-\(index)",
            providerParticipantId: providerParticipantId ?? "provider-\(index)",
            providerCorrelationId:
                "senti_\(String(repeating: "\(index % 10)", count: 43))",
            providerSessionId: "provider-session-\(index)",
            providerPeerId: "peer-\(index)",
            kind: .human,
            role: .listener,
            displayName: "Person \(index)",
            joinedAt: Date(timeIntervalSince1970: TimeInterval(index))
        )
    }
}

private func XCTAssertThrowsVoiceError<T>(
    _ expected: VoiceTransportError,
    operation: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await operation()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch let error as VoiceTransportError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}
