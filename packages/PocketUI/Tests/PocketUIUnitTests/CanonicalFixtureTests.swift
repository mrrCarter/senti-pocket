import Foundation
import XCTest
import PocketContracts
import PocketCall
@testable import PocketUI

final class CanonicalFixtureTests: XCTestCase {
    func testCanonicalAtlasFixtureDecodesWithoutDuplication() throws {
        let data = try Data(contentsOf: canonicalFixtureURL)
        let appData = try Data(contentsOf: appCanonicalFixtureURL)
        XCTAssertEqual(appData, data, "app and package fixture copies must remain byte-identical")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bundle = try decoder.decode(PocketBundle.self, from: appData)

        XCTAssertEqual(PocketContracts.version, "0.1.8", "PocketUI must explicitly review every contract version bump")
        XCTAssertEqual(bundle.contractsVersion, "0.1.8")
        XCTAssertEqual(bundle.checkpointId, "cp_954233b7_000012")
        XCTAssertEqual(bundle.sequenceStart, 230100)
        XCTAssertEqual(bundle.sequenceEnd, 230180)
        XCTAssertEqual(bundle.summary.perAgent.flatMap(\.claims).count, 4)
        XCTAssertEqual(bundle.evidence.map(\.id), ["ev_1", "ev_2"])
        XCTAssertEqual(bundle.signingKeyId, "pocket-demo-app-fixture")
        XCTAssertTrue(bundle.semanticIssues().isEmpty)

        #if canImport(CryptoKit)
        XCTAssertNotNil(VerifiedBundle.verify(bundle), "the bundled demo fixture must pass the production trust boundary")

        let tampered = PocketBundle(
            contractsVersion: bundle.contractsVersion,
            checkpointId: bundle.checkpointId,
            sessionId: bundle.sessionId,
            sequenceStart: bundle.sequenceStart,
            sequenceEnd: bundle.sequenceEnd + 1,
            summary: bundle.summary,
            evidence: bundle.evidence,
            createdAt: bundle.createdAt,
            signature: bundle.signature,
            signingKeyId: bundle.signingKeyId
        )
        XCTAssertTrue(tampered.semanticIssues().isEmpty, "tamper probe must remain semantically valid")
        XCTAssertNil(VerifiedBundle.verify(tampered), "changing signed content must invalidate the fixture")
        #endif
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
        repositoryRootURL
            .appendingPathComponent("packages/PocketContracts/Fixtures/canonical_checkpoint.json")
            .standardizedFileURL
    }

    private var appCanonicalFixtureURL: URL {
        repositoryRootURL
            .appendingPathComponent("apps/SentiPocketApp/Resources/canonical_checkpoint.json")
            .standardizedFileURL
    }

    private var repositoryRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PocketUIUnitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // PocketUI
            .deletingLastPathComponent() // packages
            .deletingLastPathComponent() // repository root
            .standardizedFileURL
    }
}
