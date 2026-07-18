import XCTest
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
}
