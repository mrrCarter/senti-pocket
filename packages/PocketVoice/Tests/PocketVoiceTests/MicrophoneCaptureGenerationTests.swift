@testable import PocketVoice
import XCTest

final class MicrophoneCaptureGenerationTests: XCTestCase {
    func testStaleCallbacksCannotAffectNewCaptureGeneration() {
        var gate = CaptureGenerationGate()
        let first = gate.begin()
        XCTAssertTrue(gate.accepts(first))

        let second = gate.begin()
        XCTAssertFalse(gate.accepts(first))
        XCTAssertTrue(gate.accepts(second))
        XCTAssertFalse(gate.end(first))
        XCTAssertTrue(gate.accepts(second))
        XCTAssertTrue(gate.end(second))
        XCTAssertNil(gate.activeID)
    }
}
