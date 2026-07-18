import XCTest
@testable import PocketSyncClient

// Interface-compile smoke (Atlas runs on the Mac; no Swift toolchain on the relay box).
final class PocketSyncClientTests: XCTestCase {
    func testEnvelopeRoundTrips() throws {
        let env = PocketBundleEnvelope(
            bundleId: "pb_test", sessionId: "sid", startSequence: 1, endSequence: 2,
            participants: ["a", "b"], builtAt: Date(timeIntervalSince1970: 0),
            signature: BundleSignature(alg: "sha256-unsigned", value: "deadbeef"),
            payload: Data("{}".utf8))
        let data = try JSONEncoder().encode(env)
        let back = try JSONDecoder().decode(PocketBundleEnvelope.self, from: data)
        XCTAssertEqual(env, back)
    }
}
