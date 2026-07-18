import Foundation
import XCTest
import PocketContracts
@testable import PocketUI

final class CanonicalFixtureTests: XCTestCase {
    func testCanonicalAtlasFixtureDecodesWithoutDuplication() throws {
        let data = try Data(contentsOf: canonicalFixtureURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let bundle = try decoder.decode(PocketBundle.self, from: data)

        XCTAssertEqual(PocketContracts.version, "0.1.8", "PocketUI must explicitly review every contract version bump")
        XCTAssertEqual(bundle.contractsVersion, "0.1.8")
        XCTAssertEqual(bundle.checkpointId, "cp_954233b7_000012")
        XCTAssertEqual(bundle.sequenceStart, 230100)
        XCTAssertEqual(bundle.sequenceEnd, 230180)
        XCTAssertEqual(bundle.summary.perAgent.flatMap(\.claims).count, 4)
        XCTAssertEqual(bundle.evidence.map(\.id), ["ev_1", "ev_2"])
        XCTAssertTrue(bundle.signature.hasPrefix("FIXTURE_UNSIGNED"), "fixture must never be presented as verified")
    }

    func testCheckpointContextPreservesExactBundleTarget() throws {
        let data = try Data(contentsOf: canonicalFixtureURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bundle = try decoder.decode(PocketBundle.self, from: data)

        let context = CheckpointContext(bundle: bundle)

        XCTAssertEqual(context.checkpointId, bundle.checkpointId)
        XCTAssertEqual(context.sessionId, bundle.sessionId)
        XCTAssertEqual(context.sequenceStart, bundle.sequenceStart)
        XCTAssertEqual(context.sequenceEnd, bundle.sequenceEnd)
    }

    func testAtlasTypedUIScenariosPreserveSafetyInvariants() {
        XCTAssertEqual(PocketFixtures.briefingPlan.checkpointId, "cp_954233b7_000012")
        XCTAssertEqual(PocketFixtures.questionAnswer.citations, ["ev_1"])
        XCTAssertTrue(PocketFixtures.questionAnswer.answeredOffline)
        XCTAssertTrue(PocketFixtures.pendingReceipt.isStructurallyValid())
        XCTAssertFalse(PocketFixtures.pendingReceipt.status == .posted)
        XCTAssertTrue(PocketFixtures.postedReceipt.isStructurallyValid())

        #if canImport(CryptoKit)
        let pending = ReceiptPresentation.evaluate(
            receipt: PocketFixtures.pendingReceipt,
            proposal: PocketFixtures.actionProposal,
            trustStore: ReceiptTrustStore()
        )
        XCTAssertFalse(pending.isPosted)

        let placeholderPosted = ReceiptPresentation.evaluate(
            receipt: PocketFixtures.postedReceipt,
            proposal: PocketFixtures.actionProposal,
            trustStore: ReceiptTrustStore()
        )
        XCTAssertFalse(placeholderPosted.isPosted, "placeholder fixture signature must never render verified")
        #endif
    }

    private var canonicalFixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PocketUIUnitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // PocketUI
            .deletingLastPathComponent() // packages
            .appendingPathComponent("PocketContracts/Fixtures/canonical_checkpoint.json")
            .standardizedFileURL
    }
}
