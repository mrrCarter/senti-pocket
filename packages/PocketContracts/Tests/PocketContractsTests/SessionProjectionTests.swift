import XCTest
import PocketContracts   // external-consumer: projects PUBLIC wire DTOs into view-ready values.

/// Tests for Atlas's thin typed projection over Relay's SessionWire DTOs. DTOs are built by DECODING real-shaped
/// JSON (their memberwise init is internal), matching how they actually arrive on the wire.
final class SessionProjectionTests: XCTestCase {

    // Build a SessionSummary with all required keys; title/summaryText/lastActivityAt overridable.
    private func summary(title: String?, summaryText: String?, lastActivityAt: String?,
                         agentCount: Int = 3, eventCount: Int = 42, role: String = "owner",
                         sessionId: String = "sess_abcdef123456") throws -> SessionSummary {
        func q(_ s: String?) -> String { s.map { "\"\($0)\"" } ?? "null" }
        let json = """
        {"sessionId":"\(sessionId)","status":"active","archiveStatus":"active","visibility":"private",
        "membershipRole":"\(role)","title":\(q(title)),"summaryText":\(q(summaryText)),
        "summaryGeneratedAt":null,"summaryModel":null,"agentCount":\(agentCount),"eventCount":\(eventCount),
        "totalCostUsd":1.23,"createdAt":null,"lastActivityAt":\(q(lastActivityAt)),
        "expiresAt":null,"killedAt":null,"templateName":null,"codebasePath":null,"s3ArchivePath":null}
        """
        return try JSONDecoder().decode(SessionSummary.self, from: Data(json.utf8))
    }

    private func checkpoint(title: String = "AUTH-1C", summary: String = "canary cleared", grade: String = "A-",
                            gradeScore: Int = 91, createdAt: String = "2026-07-18T10:40:00Z") throws -> SessionCheckpointDTO {
        let json = """
        {"checkpointId":"cp_1","sessionId":"s1","kind":"auto","title":"\(title)","summary":"\(summary)",
        "startSequence":230100,"endSequence":230180,"tokenRange":{"start":0,"end":100},
        "createdBy":"system","createdByAgentId":"","eventSequence":230180,"cursor":"c","createdAt":"\(createdAt)",
        "summarySections":{"headline":"h"},"grade":"\(grade)","gradeScore":\(gradeScore),
        "gradeVersion":"checkpoint_grade_v1","gradeReasons":[{"code":"coverage","message":"broad","points":3}]}
        """
        return try JSONDecoder().decode(SessionCheckpointDTO.self, from: Data(json.utf8))
    }

    // MARK: SessionRow

    func testSessionRowUsesTitleWhenPresent() throws {
        let row = SessionRow(try summary(title: "senti pocket", summaryText: "building the app",
                                         lastActivityAt: "2026-07-18T10:36:34Z"))
        XCTAssertEqual(row.displayTitle, "senti pocket")
        XCTAssertEqual(row.subtitle, "building the app")
        XCTAssertNotNil(row.lastActivity)          // plain-Z parsed
        XCTAssertEqual(row.agentCount, 3)
        XCTAssertEqual(row.eventCount, 42)
        XCTAssertEqual(row.membershipRole, "owner")
    }

    func testSessionRowFallsBackToSummaryTextThenShortId() throws {
        let r1 = SessionRow(try summary(title: nil, summaryText: "a summary line", lastActivityAt: nil))
        XCTAssertEqual(r1.displayTitle, "a summary line")    // title nil -> summaryText
        XCTAssertNil(r1.lastActivity)                        // nil timestamp -> nil, no throw

        let r2 = SessionRow(try summary(title: nil, summaryText: nil, lastActivityAt: nil,
                                        sessionId: "abcdef1234567890"))
        XCTAssertEqual(r2.displayTitle, "Session abcdef12")  // both nil -> "Session <first 8 of id>"
    }

    func testSessionRowFractionalTimestampParses() throws {
        let row = SessionRow(try summary(title: "t", summaryText: nil,
                                         lastActivityAt: "2026-07-18T10:35:00.123456+00:00"))
        XCTAssertNotNil(row.lastActivity)          // fractional + offset parsed by the projection
    }

    // MARK: CheckpointContent — the trust boundary

    func testCheckpointContentIsNeverVerified() throws {
        let c = CheckpointContent(try checkpoint())
        XCTAssertFalse(c.isCryptographicallyVerified)   // ALWAYS false — the type-level trust boundary
        XCTAssertEqual(c.title, "AUTH-1C")
        XCTAssertEqual(c.summary, "canary cleared")
        XCTAssertEqual(c.grade, "A-")
        XCTAssertEqual(c.gradeScore, 91)
        XCTAssertNotNil(c.created)
    }

    // MARK: SessionDate

    func testSessionDateParsesBothFormsAndRejectsBad() {
        XCTAssertNotNil(SessionDate.parse("2026-07-18T10:35:00Z"))
        XCTAssertNotNil(SessionDate.parse("2026-07-18T10:35:00.123456+00:00"))
        XCTAssertNil(SessionDate.parse(nil))
        XCTAssertNil(SessionDate.parse(""))
        XCTAssertNil(SessionDate.parse("not-a-date"))
    }
}
