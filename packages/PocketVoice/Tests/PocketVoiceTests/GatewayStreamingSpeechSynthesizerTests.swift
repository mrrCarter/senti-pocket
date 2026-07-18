import XCTest
@testable import PocketVoice

final class GatewayStreamingSpeechSynthesizerTests: XCTestCase {
    func testCurrentGatewayFailureIsNotReclassifiedAsCancellation() {
        let error = VoiceError.gatewayRejected(503)

        XCTAssertFalse(
            GatewayStreamingSpeechSynthesizer.shouldReportCancellation(
                error,
                wasCurrent: true,
                parentTaskCancelled: false
            )
        )
    }

    func testSupersededRequestIsReportedAsCancellation() {
        XCTAssertTrue(
            GatewayStreamingSpeechSynthesizer.shouldReportCancellation(
                VoiceError.gatewayRejected(503),
                wasCurrent: false,
                parentTaskCancelled: false
            )
        )
    }

    func testExplicitCancellationIsReportedAsCancellation() {
        XCTAssertTrue(
            GatewayStreamingSpeechSynthesizer.shouldReportCancellation(
                VoiceError.cancelled,
                wasCurrent: true,
                parentTaskCancelled: false
            )
        )
        XCTAssertTrue(
            GatewayStreamingSpeechSynthesizer.shouldReportCancellation(
                VoiceError.gatewayRejected(503),
                wasCurrent: true,
                parentTaskCancelled: true
            )
        )
    }
}
