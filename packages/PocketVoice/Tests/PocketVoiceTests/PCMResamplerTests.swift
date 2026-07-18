import PocketVoice
import XCTest

final class PCMResamplerTests: XCTestCase {
    func testResamples48kMonoTo16k() throws {
        let input = [Float](repeating: 0.25, count: 4_800)

        let output = try PCMResampler().resampleTo16kMono(input, sourceSampleRate: 48_000)

        XCTAssertGreaterThanOrEqual(output.count, 1_550)
        XCTAssertLessThanOrEqual(output.count, 1_650)
        XCTAssertTrue(output.allSatisfy(\.isFinite))
        XCTAssertEqual(output.reduce(0, +) / Float(output.count), 0.25, accuracy: 0.02)
    }

    func testAccumulatorBuildsBounded16kRequest() throws {
        var accumulator = try CapturedAudioAccumulator(maximumSeconds: 1)
        try accumulator.append(
            MicrophoneFrame(samples: [Float](repeating: 0.1, count: 8_000), sampleRate: 16_000)
        )
        try accumulator.append(
            MicrophoneFrame(samples: [Float](repeating: 0.1, count: 8_000), sampleRate: 16_000)
        )

        let request = try accumulator.transcriptionRequest()

        XCTAssertEqual(request.samples.count, 16_000)
        XCTAssertEqual(request.durationSeconds, 1, accuracy: 0.000_001)
    }

    func testAccumulatorRejectsDurationOverflowAndSampleRateChange() throws {
        var overflow = try CapturedAudioAccumulator(maximumSeconds: 1)
        try overflow.append(
            MicrophoneFrame(samples: [Float](repeating: 0, count: 16_000), sampleRate: 16_000)
        )
        XCTAssertThrowsError(
            try overflow.append(MicrophoneFrame(samples: [0], sampleRate: 16_000))
        )

        var routeChanged = try CapturedAudioAccumulator(maximumSeconds: 1)
        try routeChanged.append(
            MicrophoneFrame(samples: [Float](repeating: 0, count: 1_600), sampleRate: 16_000)
        )
        XCTAssertThrowsError(
            try routeChanged.append(
                MicrophoneFrame(samples: [Float](repeating: 0, count: 4_800), sampleRate: 48_000)
            )
        )
    }
}
