import Foundation
import PocketContracts
import PocketVoice
import XCTest

final class VoiceTypesTests: XCTestCase {
    func testAudioBoundariesRejectNonFiniteAndOutOfRangeSamples() {
        XCTAssertThrowsError(try MicrophoneFrame(samples: [.nan], sampleRate: 16_000))
        XCTAssertThrowsError(try MicrophoneFrame(samples: [1.01], sampleRate: 16_000))
        XCTAssertThrowsError(try TranscriptionRequest(samples: [Float](repeating: 0, count: 1_599)))
        XCTAssertThrowsError(
            try TranscriptionRequest(
                samples: [Float](repeating: 0, count: TranscriptionRequest.maximumSampleCount + 1)
            )
        )
    }

    func testSpeechRequestTrimsAndConstrainsProviderTone() throws {
        let request = try SpeechSynthesisRequest(text: "  checkpoint ready  ", tone: .calm)

        XCTAssertEqual(request.text, "checkpoint ready")
        XCTAssertEqual(request.tone, .calm)
        XCTAssertThrowsError(try JSONDecoder().decode(BriefingTone.self, from: Data(#""provider-controlled""#.utf8)))
    }

    func testGatewayConfigurationRequiresExactHTTPSAllowlistAndBoundedVoice() throws {
        let endpoint = try XCTUnwrap(URL(string: "https://speech.example.com/v1/tts"))

        XCTAssertNoThrow(
            try SpeechGatewayConfiguration(
                endpoint: endpoint,
                allowedHosts: ["SPEECH.EXAMPLE.COM"],
                voiceId: "voice_01"
            )
        )
        XCTAssertThrowsError(
            try SpeechGatewayConfiguration(
                endpoint: try XCTUnwrap(URL(string: "http://speech.example.com/v1/tts")),
                allowedHosts: ["speech.example.com"],
                voiceId: "voice_01"
            )
        )
        XCTAssertThrowsError(
            try SpeechGatewayConfiguration(
                endpoint: endpoint,
                allowedHosts: ["other.example.com"],
                voiceId: "voice_01"
            )
        )
        XCTAssertThrowsError(
            try SpeechGatewayConfiguration(
                endpoint: endpoint,
                allowedHosts: ["speech.example.com"],
                voiceId: "../provider-key"
            )
        )
    }
}
