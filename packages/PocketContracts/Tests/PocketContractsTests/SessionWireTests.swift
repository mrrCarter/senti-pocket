import XCTest
@testable import PocketContracts

/// Decode KAVs for the Relay-owned Senti sessions wire DTOs — pinned to the exact camelCase/snake-envelope
/// shapes the deployed API emits (serializers identical at deployed 3ca7640 and origin/main 91a2c3fa —
/// main is +1 non-serializer commit ahead; the SHAs are serializer-identical, not equal). Proves lossless decode + that malformed
/// wire FAILS rather than silently minting ambiguous domain state.
final class SessionWireTests: XCTestCase {

    private func decoder() -> JSONDecoder { JSONDecoder() }
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try decoder().decode(type, from: Data(json.utf8))
    }

    // MARK: - Session list (route wrapper: sessions,count,include_archived,next_cursor,has_more)

    func testSessionListPageDecodesLossless() throws {
        let json = """
        {"sessions":[{"sessionId":"954233b7","status":"active","archiveStatus":"active",
        "visibility":"private","membershipRole":"owner","title":"AUTH-1C","summaryText":"canary cleared",
        "summaryGeneratedAt":"2026-07-18T10:36:34Z","summaryModel":"claude","agentCount":2,"eventCount":41,
        "totalCostUsd":1.2345,"createdAt":"2026-07-18T10:00:00Z","lastActivityAt":"2026-07-18T10:36:34Z",
        "expiresAt":null,"killedAt":null,"templateName":null,"codebasePath":null,"s3ArchivePath":null}],
        "count":1,"include_archived":false,"next_cursor":"opaque123","has_more":true}
        """
        let page = try decode(SessionListPage.self, json)
        XCTAssertEqual(page.count, 1)
        XCTAssertFalse(page.includeArchived)
        XCTAssertEqual(page.nextCursor, "opaque123")
        XCTAssertTrue(page.hasMore)
        let s = page.sessions[0]
        XCTAssertEqual(s.sessionId, "954233b7")
        XCTAssertEqual(s.status, "active")
        XCTAssertEqual(s.totalCostUsd, Decimal(string: "1.2345"))
        XCTAssertNil(s.killedAt)                                   // explicit null preserved as nil
    }

    /// A required route-guaranteed key missing MUST throw (surfaces server drift, no ambiguous state).
    func testSessionListMissingRequiredKeyThrows() {
        let json = #"{"sessions":[],"include_archived":false,"next_cursor":null,"has_more":false}"# // no count
        XCTAssertThrowsError(try decode(SessionListPage.self, json))
    }

    // MARK: - Events (forward {events}; nested agent presentation + flat agentId/agentModel + row id)

    func testEventForwardPagePreservesIdAndAgentPresentationKeys() throws {
        let json = """
        {"events":[{"id":"ev_1","event":"session_message",
        "agent":{"id":"claude-pocket-relay","model":"claude","role":"assistant","displayName":"Relay",
        "provider":"anthropic","clientKind":"cli","futureKey":"kept"},
        "agentId":"claude-pocket-relay","agentModel":"claude","payload":{"text":"hi","seq":90071992547409},
        "ts":"2026-07-18T10:35:00Z","timestamp":"2026-07-18T10:35:00Z","cursor":"c1","sequenceId":230141,
        "sessionId":"954233b7","source":"relay"}]}
        """
        let page = try decode(SessionEventForwardPage.self, json)
        let e = page.events[0]
        XCTAssertEqual(e.id, "ev_1")                              // row id present (was omitted before)
        XCTAssertEqual(e.agentId, "claude-pocket-relay")          // flat kept
        // nested agent presentation keys preserved losslessly (incl an unknown future key)
        XCTAssertEqual(e.agent["displayName"]?.stringValue, "Relay")
        XCTAssertEqual(e.agent["provider"]?.stringValue, "anthropic")
        XCTAssertEqual(e.agent["clientKind"]?.stringValue, "cli")
        XCTAssertEqual(e.agent["futureKey"]?.stringValue, "kept")
        XCTAssertEqual(e.payload["seq"]?.intValue, 90_071_992_547_409) // large Int64 preserved
        XCTAssertEqual(e.sequenceId, 230_141)
    }

    func testEventBeforePageEnvelope() throws {
        let json = """
        {"events":[],"count":0,"next_before_sequence":230100,"has_more":true,"partial":false}
        """
        let page = try decode(SessionEventBeforePage.self, json)
        XCTAssertEqual(page.nextBeforeSequence, 230_100)          // sequence anchor, not a cursor
        XCTAssertTrue(page.hasMore)
        XCTAssertFalse(page.partial)
    }

    // MARK: - Actions (envelope {sessionId,actions,count,projection}; separate feed)

    func testActionPageEnvelopeAndProjectionPreserved() throws {
        let json = """
        {"sessionId":"954233b7","count":1,"projection":{"view":"default","v":2},
        "actions":[{"id":"act_1","sessionId":"954233b7","targetSequenceId":0,"targetCursor":null,
        "targetActionId":null,"actionType":"working_on","actorKind":"agent","actorId":"relay",
        "actorUserId":null,"actorRole":null,"note":null,"metadata":{},"idempotencyKey":"idem-1",
        "createdAt":"2026-07-18T10:35:00Z"}]}
        """
        let page = try decode(SessionActionPage.self, json)
        XCTAssertEqual(page.projection["view"]?.stringValue, "default") // projection lossless
        let a = page.actions[0]
        XCTAssertEqual(a.targetSequenceId, 0)                     // default 0, non-null
        XCTAssertEqual(a.metadata, .object([:]))                  // empty metadata object, non-null
        XCTAssertNil(a.note)
    }

    // MARK: - Checkpoints (full content DTO; grade family incl reasons {code,message,points})

    func testCheckpointDTOGradeFamily() throws {
        let json = """
        {"checkpoints":[{"checkpointId":"cp_954233b7_000012","sessionId":"954233b7","kind":"auto",
        "title":"AUTH-1C","summary":"canary cleared","startSequence":230100,"endSequence":230180,
        "createdBy":"system","createdByAgentId":"","tokenRange":{"start":0,"end":100},"eventSequence":230180,
        "cursor":"cp1","createdAt":"2026-07-18T10:40:00Z","summarySections":{"headline":"h"},"grade":"A-",
        "gradeScore":91,"gradeVersion":"checkpoint_grade_v1",
        "gradeReasons":[{"code":"coverage","message":"broad","points":3}]}],"count":1}
        """
        let page = try decode(SessionCheckpointListPage.self, json)
        let c = page.checkpoints[0]
        XCTAssertEqual(c.gradeScore, 91)
        XCTAssertEqual(c.gradeVersion, "checkpoint_grade_v1")
        XCTAssertEqual(c.gradeReasons.arrayValue?.first?["code"]?.stringValue, "coverage")
        XCTAssertEqual(c.gradeReasons.arrayValue?.first?["points"]?.intValue, 3)
        XCTAssertEqual(c.title, "AUTH-1C")                        // membership-authorized content retained
    }

    /// The grade family is serializer-guaranteed non-null; a checkpoint missing it MUST fail decode (fail-closed).
    func testCheckpointMissingGradeThrows() {
        let json = """
        {"checkpoints":[{"checkpointId":"cp_1","sessionId":"s1","kind":"auto","title":"t","summary":"s",
        "createdBy":"system","createdByAgentId":"","eventSequence":10,"cursor":"c","createdAt":"2026-07-18T10:40:00Z",
        "summarySections":{}}],"count":1}
        """
        XCTAssertThrowsError(try decode(SessionCheckpointListPage.self, json))
    }

    /// event.source key is always emitted but DB-nullable — an explicit null decodes to nil, never a throw.
    func testEventNullSourceDecodesToNil() throws {
        let json = """
        {"events":[{"id":"ev_2","event":"session_action","agent":{},"agentId":"warden","agentModel":"",
        "payload":{},"ts":"2026-07-18T10:36:34Z","timestamp":"2026-07-18T10:36:34Z","cursor":"c2",
        "sequenceId":230160,"sessionId":"954233b7","source":null}]}
        """
        let e = try decode(SessionEventForwardPage.self, json).events[0]
        XCTAssertNil(e.source)
        XCTAssertEqual(e.agent, .object([:]))     // empty agent object still lossless, not nil
    }

    /// Timestamps are raw ISO String -> byte-for-byte preserved across fractional/+00:00/Z forms (tolerant
    /// parse is the projection's job). An unknown event kind survives raw (projection maps open enums).
    func testRawTimestampAndUnknownEventKindPreserved() throws {
        let json = """
        {"events":[{"id":"ev_3","event":"future_unknown_kind_v9","agent":{},"agentId":"a","agentModel":"",
        "payload":{},"ts":"2026-07-18T10:35:00.123456+00:00","timestamp":"2026-07-18T10:35:00Z",
        "cursor":"c3","sequenceId":230161,"sessionId":"954233b7","source":"relay"}]}
        """
        let e = try decode(SessionEventForwardPage.self, json).events[0]
        XCTAssertEqual(e.event, "future_unknown_kind_v9")            // unknown kind survives raw
        XCTAssertEqual(e.ts, "2026-07-18T10:35:00.123456+00:00")     // fractional + offset byte-exact
        XCTAssertEqual(e.timestamp, "2026-07-18T10:35:00Z")          // Z form byte-exact
    }

    // MARK: - JSONValue numeric exactness + round-trip

    func testJSONValueIntExactNoRounding() throws {
        XCTAssertEqual((try decode(JSONValue.self, "7")).intValue, 7)
        XCTAssertNil((try decode(JSONValue.self, "7.5")).intValue)   // 7.5 must NOT coerce to 8
        XCTAssertEqual((try decode(JSONValue.self, "9223372036854775807")).intValue, Int64.max)
    }

    func testJSONValueRoundTrip() throws {
        let v = try decode(JSONValue.self, #"{"a":[1,2.5,"x",null,true],"n":9007199254740993}"#)
        let re = try decode(JSONValue.self, String(data: try JSONEncoder().encode(v), encoding: .utf8)!)
        XCTAssertEqual(v, re)
        XCTAssertEqual(v["n"]?.intValue, 9_007_199_254_740_993)      // survives without Double degradation
    }
}
