import XCTest
import PocketContracts
@testable import PocketUI

final class EvidenceResolutionTests: XCTestCase {
    func testResolvesInRequestedOrderAndReportsMissingIds() {
        let first = PocketUITestFactory.evidence(id: "ev_1")
        let second = PocketUITestFactory.evidence(id: "ev_2")

        let resolution = EvidenceResolution.resolve(
            ids: ["ev_2", "missing", "ev_1", "ev_2"],
            in: [first, second]
        )

        XCTAssertEqual(resolution.resolved.map(\.id), ["ev_2", "ev_1"])
        XCTAssertEqual(resolution.missingIds, ["missing"])
    }

    func testEmptyCitationsRemainExplicitlyEmpty() {
        let resolution = EvidenceResolution.resolve(ids: [], in: [PocketUITestFactory.evidence()])
        XCTAssertTrue(resolution.resolved.isEmpty)
        XCTAssertTrue(resolution.missingIds.isEmpty)
    }

    func testReusableIndexPreservesFirstDuplicateAndSupportsMultipleCitationGroups() {
        let first = PocketUITestFactory.evidence(id: "ev_1")
        let duplicate = EvidenceRef(
            id: first.id,
            sessionId: first.sessionId,
            sequence: first.sequence,
            agentId: first.agentId,
            snippet: "duplicate must not replace the first reference",
            ts: first.ts
        )
        let second = PocketUITestFactory.evidence(id: "ev_2")
        let index = EvidenceIndex(evidence: [first, duplicate, second])

        XCTAssertEqual(index.resolve(ids: ["ev_2"]).resolved, [second])
        XCTAssertEqual(index.resolve(ids: ["ev_1"]).resolved, [first])
    }

    func testCanonicalButByteDistinctEvidenceIdsResolveOnlyTheirExactReference() {
        let composed = "ev-caf\u{00E9}"
        let decomposed = "ev-cafe\u{0301}"
        XCTAssertEqual(composed, decomposed, "precondition: ordinary String lookup would collide")
        let first = PocketUITestFactory.evidence(id: composed)
        let second = EvidenceRef(
            id: decomposed,
            sessionId: first.sessionId,
            sequence: first.sequence + 1,
            agentId: first.agentId,
            snippet: "byte-distinct reference",
            ts: first.ts
        )
        let index = EvidenceIndex(evidence: [first, second])

        let resolution = index.resolve(ids: [decomposed, composed, decomposed])

        XCTAssertEqual(resolution.resolved.count, 2)
        XCTAssertTrue(resolution.resolved[0].id.utf8.elementsEqual(decomposed.utf8))
        XCTAssertEqual(resolution.resolved[0].snippet, second.snippet)
        XCTAssertTrue(resolution.resolved[1].id.utf8.elementsEqual(composed.utf8))
        XCTAssertEqual(resolution.resolved[1].snippet, first.snippet)
        XCTAssertTrue(resolution.missingIds.isEmpty)

        let exactMiss = EvidenceResolution.resolve(ids: [decomposed], in: [first])
        XCTAssertTrue(exactMiss.resolved.isEmpty)
        XCTAssertEqual(exactMiss.missingIds.count, 1)
        XCTAssertTrue(exactMiss.missingIds[0].utf8.elementsEqual(decomposed.utf8))
    }
}
