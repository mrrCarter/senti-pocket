import XCTest
import PocketContracts   // external-consumer: exercises the PUBLIC Atlas nonvisual types.

/// Tests for Atlas's nonvisual session types (V4 §85): lossless timestamp (raw never discarded) and the lossless,
/// trust-explicit checkpoint wrapper. No presentation is asserted here — there is none to assert.
final class SessionAtlasTypesTests: XCTestCase {

    private func checkpoint(title: String = "AUTH-1C", grade: String = "A-", gradeScore: Int = 91,
                            createdAt: String = "2026-07-18T10:40:00Z") throws -> SessionCheckpointDTO {
        let json = """
        {"checkpointId":"cp_1","sessionId":"s1","kind":"auto","title":"\(title)","summary":"canary cleared",
        "startSequence":230100,"endSequence":230180,"tokenRange":{"start":0,"end":100},
        "createdBy":"system","createdByAgentId":"","eventSequence":230180,"cursor":"c","createdAt":"\(createdAt)",
        "summarySections":{"headline":"h"},"grade":"\(grade)","gradeScore":\(gradeScore),
        "gradeVersion":"checkpoint_grade_v1","gradeReasons":[{"code":"coverage","message":"broad","points":3}]}
        """
        return try JSONDecoder().decode(SessionCheckpointDTO.self, from: Data(json.utf8))
    }

    // MARK: ParsedSessionTimestamp — lossless

    func testTimestampPreservesRawAndParsesBothForms() {
        let plain = ParsedSessionTimestamp("2026-07-18T10:36:34Z")
        XCTAssertEqual(plain.raw, "2026-07-18T10:36:34Z")     // raw is authoritative + exact
        XCTAssertNotNil(plain.date)                            // plain Z parsed

        let fractional = ParsedSessionTimestamp("2026-07-18T10:35:00.123456+00:00")
        XCTAssertEqual(fractional.raw, "2026-07-18T10:35:00.123456+00:00")  // byte-exact preserved
        XCTAssertNotNil(fractional.date)                       // fractional + offset parsed
    }

    func testTimestampKeepsRawEvenWhenUnparseable() {
        // The lossless guarantee: an unrecognized/future format still round-trips the exact wire bytes.
        let odd = ParsedSessionTimestamp("2026-W29-6T10:35Z")  // not a form we parse
        XCTAssertEqual(odd.raw, "2026-W29-6T10:35Z")           // NOT discarded
        XCTAssertNil(odd.date)                                 // best-effort parse missed — raw still authoritative
    }

    func testTimestampOptionalInit() {
        XCTAssertNil(ParsedSessionTimestamp(nil as String?))
        XCTAssertEqual(ParsedSessionTimestamp("2026-07-18T10:00:00Z" as String?)?.raw, "2026-07-18T10:00:00Z")
    }

    // MARK: MembershipAuthorizedCheckpoint — lossless + trust boundary

    func testCheckpointWrapperIsLossless() throws {
        let dto = try checkpoint()
        let wrapped = MembershipAuthorizedCheckpoint(dto)

        XCTAssertEqual(wrapped.id, "cp_1")
        // Every DTO field remains reachable through .checkpoint — nothing dropped (vs the prior lossful projection).
        XCTAssertEqual(wrapped.checkpoint.title, "AUTH-1C")
        XCTAssertEqual(wrapped.checkpoint.summary, "canary cleared")
        XCTAssertEqual(wrapped.checkpoint.grade, "A-")
        XCTAssertEqual(wrapped.checkpoint.gradeScore, 91)
        XCTAssertEqual(wrapped.checkpoint.kind, "auto")
        XCTAssertEqual(wrapped.checkpoint.startSequence, 230100)
        XCTAssertEqual(wrapped.checkpoint.gradeReasons.arrayValue?.first?["code"]?.stringValue, "coverage")

        // createdAt is raw-preserved (nonvisual; Pulse formats for display).
        XCTAssertEqual(wrapped.createdAt.raw, "2026-07-18T10:40:00Z")
        XCTAssertNotNil(wrapped.createdAt.date)
    }

    // TRUST BOUNDARY (compile-level): MembershipAuthorizedCheckpoint exposes NO verified/verification member and no
    // hardcoded-false bool — the guarantee is that it is a DIFFERENT TYPE from VerifiedBundle (PocketCall), with no
    // API here that yields verification. Checkpoint content therefore can only render NEUTRAL, never GREEN. There is
    // nothing to assert at runtime; the absence of a verified affordance is enforced by the type itself.
    func testCheckpointWrapperEquatableIdentity() throws {
        let a = MembershipAuthorizedCheckpoint(try checkpoint(title: "X"))
        let b = MembershipAuthorizedCheckpoint(try checkpoint(title: "Y"))
        XCTAssertNotEqual(a, b)                                // distinct content
        XCTAssertEqual(a, MembershipAuthorizedCheckpoint(try checkpoint(title: "X")))
    }

    // MARK: Completeness — timestamp byte-exactness across forms + FULL field losslessness

    func testTimestampByteExactAcrossForms() {
        // Every form the wire may emit round-trips its raw bytes exactly, whether or not `date` parses.
        for raw in ["2026-07-18T10:36:34Z",
                    "2026-07-18T10:36:34.123456+00:00",
                    "2026-07-18T10:36:34+05:30",
                    "2026-07-18T10:36:34.5-08:00",
                    "2026-W29-6T10:35Z"] {          // unparseable → still byte-exact raw
            XCTAssertEqual(ParsedSessionTimestamp(raw).raw, raw)
        }
        XCTAssertNotNil(ParsedSessionTimestamp("2026-07-18T10:36:34+05:30").date)   // non-UTC offset parses
    }

    /// Complete losslessness: EVERY SessionCheckpointDTO field is reachable through the wrapper — the wrapper drops
    /// nothing (this is the guarantee the prior lossful CheckpointContent broke).
    func testCheckpointPreservesEveryField() throws {
        let dto = try checkpoint(createdAt: "2026-07-18T10:40:00.250Z")
        let c = MembershipAuthorizedCheckpoint(dto).checkpoint
        XCTAssertEqual(c.checkpointId, "cp_1")
        XCTAssertEqual(c.sessionId, "s1")
        XCTAssertEqual(c.kind, "auto")
        XCTAssertEqual(c.title, "AUTH-1C")
        XCTAssertEqual(c.summary, "canary cleared")
        XCTAssertEqual(c.startSequence, 230100)
        XCTAssertEqual(c.endSequence, 230180)
        XCTAssertEqual(c.tokenRange?["start"]?.intValue, 0)
        XCTAssertEqual(c.tokenRange?["end"]?.intValue, 100)
        XCTAssertEqual(c.createdBy, "system")
        XCTAssertEqual(c.createdByAgentId, "")               // real empty-string emit preserved
        XCTAssertEqual(c.eventSequence, 230180)
        XCTAssertEqual(c.cursor, "c")
        XCTAssertEqual(c.createdAt, "2026-07-18T10:40:00.250Z")
        XCTAssertEqual(c.summarySections["headline"]?.stringValue, "h")
        XCTAssertEqual(c.grade, "A-")
        XCTAssertEqual(c.gradeScore, 91)
        XCTAssertEqual(c.gradeVersion, "checkpoint_grade_v1")
        XCTAssertEqual(c.gradeReasons.arrayValue?.first?["points"]?.intValue, 3)
        // and the wrapper's createdAt projection is raw-exact + parses the fractional form
        let wrapped = MembershipAuthorizedCheckpoint(dto)
        XCTAssertEqual(wrapped.createdAt.raw, "2026-07-18T10:40:00.250Z")
        XCTAssertNotNil(wrapped.createdAt.date)
    }
}
