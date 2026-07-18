import PocketVoice
import XCTest

final class EnergyVoiceActivityDetectorTests: XCTestCase {
    func testUsesAttackReleaseAndHysteresis() throws {
        let configuration = try VoiceActivityConfiguration(
            speechStartRMS: 0.02,
            speechEndRMS: 0.01,
            attackMilliseconds: 40,
            releaseMilliseconds: 80
        )
        var detector = EnergyVoiceActivityDetector(configuration: configuration)

        XCTAssertNil(try detector.process(samples: constant(0.03, count: 320), sampleRate: 16_000).transition)
        XCTAssertEqual(
            try detector.process(samples: constant(0.03, count: 320), sampleRate: 16_000).transition,
            .speechStarted
        )
        XCTAssertNil(try detector.process(samples: constant(0.015, count: 640), sampleRate: 16_000).transition)
        XCTAssertNil(try detector.process(samples: constant(0.005, count: 640), sampleRate: 16_000).transition)
        XCTAssertEqual(
            try detector.process(samples: constant(0.005, count: 640), sampleRate: 16_000).transition,
            .speechEnded
        )
    }

    func testRejectsNonFiniteAudio() throws {
        var detector = EnergyVoiceActivityDetector(configuration: try VoiceActivityConfiguration())
        XCTAssertThrowsError(try detector.process(samples: [.nan], sampleRate: 16_000))
    }

    func testRejectsImpossibleThresholdAndMidWindowSampleRateChange() throws {
        XCTAssertThrowsError(
            try VoiceActivityConfiguration(
                speechStartRMS: 1.1,
                speechEndRMS: 0.5,
                attackMilliseconds: 80,
                releaseMilliseconds: 280
            )
        )

        var detector = EnergyVoiceActivityDetector(configuration: try VoiceActivityConfiguration())
        _ = try detector.process(samples: constant(0.03, count: 320), sampleRate: 16_000)
        XCTAssertThrowsError(
            try detector.process(samples: constant(0.03, count: 320), sampleRate: 48_000)
        )
        XCTAssertEqual(detector.state, .silence)
    }

    private func constant(_ value: Float, count: Int) -> [Float] {
        [Float](repeating: value, count: count)
    }
}
