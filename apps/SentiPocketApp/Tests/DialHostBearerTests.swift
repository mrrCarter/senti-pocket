#if canImport(CallKit) && canImport(PushKit)
import XCTest
import PocketVoice
@testable import SentiPocketApp

/// Pocket-TTS bearer + gateway config (Pulse #1, #5): DialHost returns the Info.plist bearer UNCHANGED (no trim), the
/// gateway URL is FAIL-CLOSED (no hardcoded host default), and the bearer is paired with a synth endpoint ONLY when the
/// config is a valid HTTPS host — so a config failure yields Siri (zero wire, the bearer never egresses to a wrong host).
@MainActor
final class DialHostBearerTests: XCTestCase {

    /// A no-op fallback so a synth reject/degrade path touches no audio device.
    struct NoOpSynth: SpeechSynthesizer {
        func speak(_ r: SpeechSynthesisRequest) async throws -> SpeechPlaybackMetrics {
            SpeechPlaybackMetrics(backend: .avSpeechOffline, firstAudioMeasurement: .avSpeechDidStartCallback,
                                  firstAudioMilliseconds: 0, totalMilliseconds: 0, characterCount: r.text.count,
                                  residentMemoryBytes: nil, thermalState: .nominal)
        }
        func stop() async {}
    }
    /// Counts gateway requests.
    final class CountingProtocol: URLProtocol {
        static var count = 0
        static func reset() { count = 0 }
        override class func canInit(with r: URLRequest) -> Bool { count += 1; return false }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
        override func startLoading() {}
        override func stopLoading() {}
    }
    /// Records where a request actually went (host + Authorization), then fails so the synth degrades to the fallback.
    final class HostRecordingProtocol: URLProtocol {
        static var host: String?
        static var authorization: String?
        static var count = 0
        static func reset() { host = nil; authorization = nil; count = 0 }
        override class func canInit(with r: URLRequest) -> Bool { true }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
        override func startLoading() {
            Self.host = request.url?.host
            Self.authorization = request.value(forHTTPHeaderField: "Authorization")
            Self.count += 1
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
        override func stopLoading() {}
    }

    // MARK: - Bearer resolution (unchanged, no normalization)

    func test_resolveBearer_returns_the_configured_value_unchanged() {
        XCTAssertEqual(DialHost.resolveBearer(" token "), " token ")
        XCTAssertEqual(DialHost.resolveBearer("tok\r\nen"), "tok\r\nen")
        XCTAssertEqual(DialHost.resolveBearer("\u{00A0}token"), "\u{00A0}token")   // NBSP (Zs)
        XCTAssertEqual(DialHost.resolveBearer("tok\u{200B}en"), "tok\u{200B}en")   // ZWSP (Cf)
        XCTAssertEqual(DialHost.resolveBearer(""), "")
        XCTAssertNil(DialHost.resolveBearer(nil))
    }

    // A raw malformed bearer is rejected by the approved synth → it degrades to the fallback and makes ZERO gateway
    // network. (P2: explicit speak — assert the fallback backend so this can't pass vacuously on an early throw.)
    func test_raw_malformed_bearer_yields_zero_gateway_network() async throws {
        let malformed = [" token ", "tok\r\nen", "\u{00A0}token", "tok\u{200B}en", "tok\u{0007}en"]
        for raw in malformed {
            CountingProtocol.reset()
            let cfg = URLSessionConfiguration.ephemeral
            cfg.protocolClasses = [CountingProtocol.self]
            let synth = GatewayWAVSpeechSynthesizer(
                endpoint: URL(string: "https://gw.invalid")!,
                bearerProvider: { DialHost.resolveBearer(raw) },
                fallback: NoOpSynth(),
                session: URLSession(configuration: cfg))
            let metrics = try await synth.speak(try SpeechSynthesisRequest(text: "hi", tone: .neutral))
            XCTAssertEqual(metrics.backend, .avSpeechOffline, "malformed bearer must degrade to the on-device fallback")
            XCTAssertEqual(CountingProtocol.count, 0,
                           "raw malformed bearer must be rejected → zero gateway network for \(raw.debugDescription)")
        }
    }

    // MARK: - Fail-closed gateway URL + endpoint↔bearer coupling (Pulse #1)

    func test_gatewayURL_resolver_is_fail_closed() {
        XCTAssertNil(DialHost.gatewayURL(from: nil))
        XCTAssertNil(DialHost.gatewayURL(from: ""))
        XCTAssertNil(DialHost.gatewayURL(from: "   "))
        XCTAssertNil(DialHost.gatewayURL(from: "http://insecure.example"))   // non-https
        XCTAssertNil(DialHost.gatewayURL(from: "ftp://x.example"))           // non-https
        XCTAssertNil(DialHost.gatewayURL(from: "not a url with spaces"))     // unparseable / no host
        XCTAssertNil(DialHost.gatewayURL(from: "https://"))                  // no host
        XCTAssertEqual(DialHost.gatewayURL(from: "  https://safe.example  ")?.host, "safe.example")  // trimmed → valid
    }

    // Missing / blank / invalid / non-https config → makeTTSSynth returns Siri (NOT a gateway synth): the bearer is
    // never wired to any network synth, so ZERO requests are possible. A valid HTTPS config → a gateway synth.
    func test_makeTTSSynth_pairs_bearer_only_with_a_valid_https_endpoint() {
        let bearer: @Sendable () async -> String? = { "valid-bearer" }
        let bads: [String?] = [nil, "", "  ", "http://insecure.example", "not a url", "https://"]
        for bad in bads {
            let synth = DialHost.makeTTSSynth(gatewayURL: DialHost.gatewayURL(from: bad), bearerProvider: bearer)
            XCTAssertFalse(synth is GatewayWAVSpeechSynthesizer,
                           "bad config \(String(describing: bad)) → Siri; the bearer is never wired to a network synth (zero requests)")
        }
        let good = DialHost.makeTTSSynth(gatewayURL: DialHost.gatewayURL(from: "https://safe.example"), bearerProvider: bearer)
        XCTAssertTrue(good is GatewayWAVSpeechSynthesizer, "a valid HTTPS config pairs the bearer with a gateway synth")
    }

    // A valid HTTPS config + a valid bearer → the request goes to EXACTLY that host, carrying the bearer.
    func test_valid_config_sends_the_bearer_to_exactly_that_host() async throws {
        HostRecordingProtocol.reset()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [HostRecordingProtocol.self]
        let endpoint = try XCTUnwrap(DialHost.gatewayURL(from: "https://safe.example"))
        let synth = GatewayWAVSpeechSynthesizer(
            endpoint: endpoint, bearerProvider: { "valid-bearer" }, fallback: NoOpSynth(),
            session: URLSession(configuration: cfg))
        _ = try await synth.speak(try SpeechSynthesisRequest(text: "hi", tone: .neutral))

        XCTAssertEqual(HostRecordingProtocol.count, 1, "a valid config makes exactly one gateway request")
        XCTAssertEqual(HostRecordingProtocol.host, "safe.example", "the bearer request goes to EXACTLY the configured host")
        XCTAssertEqual(HostRecordingProtocol.authorization, "Bearer valid-bearer", "the bearer travels only to that host")
    }
}
#endif
