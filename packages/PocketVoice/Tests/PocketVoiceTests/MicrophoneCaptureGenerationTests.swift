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

    func testFrameSinkPreservesCallbackOrderWithoutPerFrameTasks() async throws {
        let pair = AsyncThrowingStream<MicrophoneFrame, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(4)
        )
        let sink = CaptureFrameSink()
        let captureID = UUID()
        sink.begin(captureID: captureID, continuation: pair.continuation)

        XCTAssertEqual(sink.yield(try frame(0.1), captureID: captureID), .accepted)
        XCTAssertEqual(sink.yield(try frame(0.2), captureID: captureID), .accepted)
        XCTAssertEqual(sink.yield(try frame(0.3), captureID: captureID), .accepted)
        sink.finish(captureID: captureID)

        var iterator = pair.stream.makeAsyncIterator()
        XCTAssertEqual(try await iterator.next()?.samples, [0.1])
        XCTAssertEqual(try await iterator.next()?.samples, [0.2])
        XCTAssertEqual(try await iterator.next()?.samples, [0.3])
        XCTAssertNil(try await iterator.next())
    }

    func testFrameSinkFailsLoudlyWhenItsBoundedBufferOverflows() async throws {
        let pair = AsyncThrowingStream<MicrophoneFrame, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(MicrophoneCapture.frameBufferCapacity)
        )
        let sink = CaptureFrameSink()
        let captureID = UUID()
        sink.begin(captureID: captureID, continuation: pair.continuation)

        for index in 0..<MicrophoneCapture.frameBufferCapacity {
            XCTAssertEqual(sink.yield(try frame(Float(index)), captureID: captureID), .accepted)
        }
        XCTAssertEqual(
            sink.yield(try frame(Float(MicrophoneCapture.frameBufferCapacity)), captureID: captureID),
            .overflow
        )
        XCTAssertEqual(sink.yield(try frame(99), captureID: captureID), .stale)

        var iterator = pair.stream.makeAsyncIterator()
        var deliveredFrameCount = 0
        do {
            while try await iterator.next() != nil {
                deliveredFrameCount += 1
            }
            XCTFail("overflow must terminate the stream with an explicit error")
        } catch {
            XCTAssertEqual(deliveredFrameCount, MicrophoneCapture.frameBufferCapacity)
            XCTAssertEqual(
                error as? VoiceError,
                .audioSessionFailed("microphone frame buffer overflow")
            )
        }
    }

    private func frame(_ sample: Float) throws -> MicrophoneFrame {
        try MicrophoneFrame(
            samples: [sample],
            sampleRate: 16_000,
            capturedAt: Date(timeIntervalSince1970: Double(sample))
        )
    }
}
