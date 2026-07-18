import PocketVoice
import XCTest

final class SpeechBenchmarkHarnessTests: XCTestCase {
    func testWordErrorRateIsDeterministic() {
        XCTAssertEqual(
            SpeechBenchmarkHarness.wordErrorRate(
                reference: "stop the current briefing",
                hypothesis: "stop current briefing"
            ),
            0.25,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            SpeechBenchmarkHarness.wordErrorRate(reference: "Ship it", hypothesis: "ship it"),
            0
        )
    }
}
