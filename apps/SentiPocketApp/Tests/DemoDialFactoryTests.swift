import XCTest
import PocketCall
import PocketContracts
@testable import SentiPocketApp

/// DemoDialFactory (spec A, P0-3): the foreground-reachability seed is minted ONLY behind the SAME trust gate the live
/// path uses (VerifiedBundle.verify), and it pairs the dialId/UUID with a `.renderable` ring whose core.id == dialId —
/// so the coordinator keys pending by the same id and the answer resolves the same ring (never an orphan decline).
final class DemoDialFactoryTests: XCTestCase {

    // A VERIFIED bundle mints a seed whose ids pair up and whose renderable ring carries the AUTHED headline/session.
    func test_make_from_verified_bundle_pairs_ids_and_renders() throws {
        let bundle = try XCTUnwrap(FixtureLoader.canonicalBundle(), "canonical fixture must load")
        XCTAssertNotNil(VerifiedBundle.verify(bundle), "precondition: the canonical fixture verifies")

        let uuid = UUID()
        let seed = try XCTUnwrap(DemoDialFactory.make(from: bundle, dialId: "demo-abc", callUUID: uuid))
        XCTAssertEqual(seed.dialId, "demo-abc")
        XCTAssertEqual(seed.callUUID, uuid)                       // ONE shared dialId/UUID pair
        XCTAssertEqual(seed.message, bundle.summary.headline)     // AUTHED, verified content — never fabricated
        guard case .renderable(let ring) = seed.state else { return XCTFail("state must be .renderable") }
        XCTAssertEqual(ring.core.id, "demo-abc")                  // ring id == dialId → coordinator keys pending by it
        XCTAssertEqual(ring.core.sessionId, bundle.sessionId)
        XCTAssertEqual(ring.message, bundle.summary.headline)
        XCTAssertTrue(ring.options.isEmpty)                        // not a pickOption ring
    }

    // A bundle that does NOT verify (tampered signed content) → nil → NO ring. Never bypasses the verify check.
    func test_make_from_unverified_bundle_returns_nil() throws {
        let base = try XCTUnwrap(FixtureLoader.canonicalBundle())
        // Tamper a SIGNED field (mirrors CanonicalFixtureTests): still semantically valid, but the signature no longer
        // covers these bytes → VerifiedBundle.verify fails.
        let tampered = PocketBundle(
            contractsVersion: base.contractsVersion, checkpointId: base.checkpointId, sessionId: base.sessionId,
            sequenceStart: base.sequenceStart, sequenceEnd: base.sequenceEnd + 1, summary: base.summary,
            evidence: base.evidence, createdAt: base.createdAt, signature: base.signature, signingKeyId: base.signingKeyId)
        XCTAssertNil(VerifiedBundle.verify(tampered), "precondition: the tampered bundle must NOT verify")
        XCTAssertNil(DemoDialFactory.make(from: tampered, dialId: "d", callUUID: UUID()),
                     "an unverified bundle must yield NO seed (fail-closed)")
    }

    // The canonical convenience mints fresh, distinct ids and a renderable ring (the fixture verifies).
    func test_makeFromCanonical_seeds_a_renderable_with_fresh_ids() {
        guard let a = DemoDialFactory.makeFromCanonical(), let b = DemoDialFactory.makeFromCanonical() else {
            return XCTFail("canonical fixture verifies → makeFromCanonical must seed")
        }
        if case .renderable = a.state {} else { XCTFail("must be .renderable") }
        XCTAssertTrue(a.dialId.hasPrefix("demo-"))
        XCTAssertNotEqual(a.dialId, b.dialId)     // fresh id each call
        XCTAssertNotEqual(a.callUUID, b.callUUID)
    }
}
