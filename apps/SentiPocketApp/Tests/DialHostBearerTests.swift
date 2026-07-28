#if canImport(CallKit) && canImport(PushKit)
import XCTest
import PocketVoice
@testable import SentiPocketApp

/// Pocket-TTS bearer (Pulse issue 1): DialHost returns the Info.plist value UNCHANGED (no trim/normalize), and a
/// malformed bearer is REJECTED by the APPROVED synth → ZERO gateway network (degrades to Siri). Trimming here would
/// smuggle a padded / CRLF-wrapped / Unicode-space token past the synth's reject-unchanged contract.
@MainActor
final class DialHostBearerTests: XCTestCase {

    // The resolver never normalizes: padded / CRLF / Unicode-space values come back byte-identical; absent → nil.
    func test_resolveBearer_returns_the_configured_value_unchanged() {
        XCTAssertEqual(DialHost.resolveBearer(" token "), " token ")
        XCTAssertEqual(DialHost.resolveBearer("tok\r\nen"), "tok\r\nen")
        XCTAssertEqual(DialHost.resolveBearer("\u{00A0}token"), "\u{00A0}token")   // NBSP (Zs)
        XCTAssertEqual(DialHost.resolveBearer("tok\u{200B}en"), "tok\u{200B}en")   // ZWSP (Cf)
        XCTAssertEqual(DialHost.resolveBearer(""), "")                             // empty is returned as-is (synth rejects it)
        XCTAssertNil(DialHost.resolveBearer(nil))
    }

    /// Counts gateway requests. A malformed RAW bearer must yield ZERO (the synth rejects it, degrading to the fallback).
    final class CountingProtocol: URLProtocol {
        static var count = 0
        static func reset() { count = 0 }
        override class func canInit(with r: URLRequest) -> Bool { count += 1; return false }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
        override func startLoading() {}
        override func stopLoading() {}
    }
    /// A no-op fallback so the reject path touches no audio device.
    struct NoOpSynth: SpeechSynthesizer {
        func speak(_ r: SpeechSynthesisRequest) async throws -> SpeechPlaybackMetrics {
            SpeechPlaybackMetrics(backend: .avSpeechOffline, firstAudioMeasurement: .avSpeechDidStartCallback,
                                  firstAudioMilliseconds: 0, totalMilliseconds: 0, characterCount: r.text.count,
                                  residentMemoryBytes: nil, thermalState: .nominal)
        }
        func stop() async {}
    }

    // ASCII-padded, CRLF-wrapped, Unicode Zs/Cf, and control-char values → the RAW provider output is rejected by the
    // approved synth → ZERO gateway network. (If DialHost trimmed, " token " would become a valid "token" and egress.)
    func test_raw_malformed_bearer_yields_zero_gateway_network() async {
        let malformed = [" token ", "tok\r\nen", "\u{00A0}token", "tok\u{200B}en", "tok\u{0007}en"]
        for raw in malformed {
            CountingProtocol.reset()
            let cfg = URLSessionConfiguration.ephemeral
            cfg.protocolClasses = [CountingProtocol.self]
            let synth = GatewayWAVSpeechSynthesizer(
                endpoint: URL(string: "https://gw.invalid")!,
                bearerProvider: { DialHost.resolveBearer(raw) },   // RAW passthrough (non-empty → unchanged)
                fallback: NoOpSynth(),
                session: URLSession(configuration: cfg))
            if let request = try? SpeechSynthesisRequest(text: "hi", tone: .neutral) {
                _ = try? await synth.speak(request)
            }
            XCTAssertEqual(CountingProtocol.count, 0,
                           "raw malformed bearer must be rejected by the synth → zero gateway network for \(raw.debugDescription)")
        }
    }
}
#endif
