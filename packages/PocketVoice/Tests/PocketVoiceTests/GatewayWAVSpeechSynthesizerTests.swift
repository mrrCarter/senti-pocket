import Foundation
import XCTest
@testable import PocketVoice

final class GatewayWAVSpeechSynthesizerTests: XCTestCase {

    // MARK: - (a) stop-during-fetch → no audio, no fallback after the late fetch resolves

    func testStopDuringFetchNeverPlaysOrFallsBack() async throws {
        let fetch = ControlledFetch()
        let play = SpyPlay()
        let fallback = RecordingFallback()
        let system = CountingDuplexSystem()
        let synthesizer = GatewayWAVSpeechSynthesizer(
            endpoint: try endpoint(),
            fallback: fallback,
            leases: DuplexAudioSessionLeaseManager(system: system),
            fetch: { text in try await fetch.fetch(text) },
            play: { data in try await play.play(data) },
            stopPlayback: {}
        )
        let request = try SpeechSynthesisRequest(text: "briefing that is stopped mid-fetch")

        let speak = Task { try await synthesizer.speak(request) }
        try await fetch.waitForCallCount(1)
        await synthesizer.stop()
        await fetch.resumeNext(with: .success(Data(repeating: 0, count: 128)))

        await XCTAssertThrowsVoiceError(.cancelled) { _ = try await speak.value }
        let playCalls = await play.callCountNow()
        let fallbackSpeaks = await fallback.speakCountNow()
        XCTAssertEqual(playCalls, 0, "a stopped briefing must never play the late WAV")
        XCTAssertEqual(fallbackSpeaks, 0, "a stopped briefing must never re-speak via the fallback")
        XCTAssertEqual(system.activateCount, 0, "no lease is taken when the fetch is superseded before playback")
        XCTAssertEqual(system.deactivateCount, 0)
    }

    // MARK: - (b) cancel-during-playback → the WAV playback is cancelled/stopped

    func testCancelDuringPlaybackStopsAudio() async throws {
        let play = ControlledPlay()
        let stopPlayback = StopPlaybackSpy()
        let fallback = RecordingFallback()
        let system = CountingDuplexSystem()
        let synthesizer = GatewayWAVSpeechSynthesizer(
            endpoint: try endpoint(),
            fallback: fallback,
            leases: DuplexAudioSessionLeaseManager(system: system),
            fetch: { _ in Data(repeating: 0, count: 128) },
            play: { data in try await play.play(data) },
            stopPlayback: { await stopPlayback.stop() }
        )
        let request = try SpeechSynthesisRequest(text: "briefing cancelled during playback")

        let speak = Task { try await synthesizer.speak(request) }
        try await play.waitForStart()
        speak.cancel()

        await XCTAssertThrowsVoiceError(.cancelled) { _ = try await speak.value }
        let cancelledCount = await play.cancelledCountNow()
        let stopCalls = await stopPlayback.countNow()
        let fallbackSpeaks = await fallback.speakCountNow()
        XCTAssertEqual(cancelledCount, 1, "parent-Task cancellation must reach the playback continuation")
        XCTAssertGreaterThanOrEqual(stopCalls, 1, "the cleanup barrier must stop WAV playback")
        XCTAssertEqual(fallbackSpeaks, 0, "a cancelled briefing must not re-speak via the fallback")
    }

    // MARK: - (c) out-of-order latest-wins → a superseded (older) fetch never plays over the newer one

    func testSupersededOlderFetchNeverPlaysOverNewer() async throws {
        let fetch = ControlledFetch()
        let play = SpyPlay()
        let fallback = RecordingFallback()
        let synthesizer = GatewayWAVSpeechSynthesizer(
            endpoint: try endpoint(),
            fallback: fallback,
            leases: DuplexAudioSessionLeaseManager(system: CountingDuplexSystem()),
            fetch: { text in try await fetch.fetch(text) },
            play: { data in try await play.play(data) },
            stopPlayback: {}
        )
        let older = try SpeechSynthesisRequest(text: "older briefing")
        let newer = try SpeechSynthesisRequest(text: "newer briefing")

        let first = Task { try await synthesizer.speak(older) }
        try await fetch.waitForCallCount(1)
        let second = Task { try await synthesizer.speak(newer) }
        try await fetch.waitForCallCount(2)
        try await waitForCurrentRequest(newer.id, on: synthesizer)

        // Resume the OLDER fetch first: it must observe the generation change and refuse to play.
        await fetch.resumeNext(with: .success(Data(repeating: 1, count: 128)))
        await XCTAssertThrowsVoiceError(.cancelled) { _ = try await first.value }
        let playsAfterOlder = await play.callCountNow()
        XCTAssertEqual(playsAfterOlder, 0, "the superseded older briefing must never reach playback")

        // Resume the NEWER fetch: it is the sole request allowed to play.
        await fetch.resumeNext(with: .success(Data(repeating: 2, count: 128)))
        _ = try await second.value
        let finalPlays = await play.callCountNow()
        XCTAssertEqual(finalPlays, 1, "only the newest briefing plays")
    }

    // MARK: - (d) cross-backend exclusion → a stale siri fallback and a current WAV never overlap

    func testStaleFallbackAndCurrentWAVNeverOverlap() async throws {
        let exclusion = AudioExclusion()
        let fallback = BlockingFallback(exclusion: exclusion)
        let system = CountingDuplexSystem()
        // A single synthesizer (one cross-backend exclusion owner). Its `play` fails for the FIRST briefing so that
        // one degrades to the blocking siri fallback; the SECOND briefing plays on the WAV path.
        let shared = SharedPlay(exclusion: exclusion)
        let synth = GatewayWAVSpeechSynthesizer(
            endpoint: try endpoint(),
            fallback: fallback,
            leases: DuplexAudioSessionLeaseManager(system: system),
            fetch: { _ in Data(repeating: 0, count: 128) },
            play: { data in try await shared.play(data) },
            stopPlayback: {}
        )
        let older = try SpeechSynthesisRequest(text: "older briefing that falls back to siri")
        let newer = try SpeechSynthesisRequest(text: "newer briefing on the WAV path")

        let first = Task { try await synth.speak(older) }
        try await fallback.waitForSpeakCount(1) // the older briefing is now "speaking" via siri
        let second = Task { try await synth.speak(newer) } // supersedes → barrier must stop the stale siri first
        _ = try await second.value

        await XCTAssertThrowsVoiceError(.cancelled) { _ = try await first.value }
        let overlapped = await exclusion.overlapDetectedNow()
        let siriSpeaks = await fallback.speakCountNow()
        XCTAssertFalse(overlapped, "a stale siri utterance and the current WAV playback must never overlap")
        XCTAssertEqual(siriSpeaks, 1, "only the older briefing degraded to siri; the newer stayed on the WAV path")
    }

    // MARK: - (e) exact-once lease cleanup → success / throw+fallback / cancel each release the lease exactly once

    func testLeaseReleasedExactlyOnceAcrossSuccessThrowAndCancel() async throws {
        // Success: WAV plays cleanly.
        do {
            let system = CountingDuplexSystem()
            let synth = GatewayWAVSpeechSynthesizer(
                endpoint: try endpoint(),
                fallback: RecordingFallback(),
                leases: DuplexAudioSessionLeaseManager(system: system),
                fetch: { _ in Data(repeating: 0, count: 128) },
                play: { _ in ContinuousClock.now },
                stopPlayback: {}
            )
            _ = try await synth.speak(try SpeechSynthesisRequest(text: "clean success"))
            XCTAssertEqual(system.activateCount, 1, "success: one lease acquired")
            XCTAssertEqual(system.deactivateCount, 1, "success: lease released exactly once")
        }

        // Throw → fallback: the WAV playback fails, the request degrades to the fallback, and the WAV lease is still
        // released exactly once.
        do {
            let system = CountingDuplexSystem()
            let synth = GatewayWAVSpeechSynthesizer(
                endpoint: try endpoint(),
                fallback: RecordingFallback(),
                leases: DuplexAudioSessionLeaseManager(system: system),
                fetch: { _ in Data(repeating: 0, count: 128) },
                play: { _ in throw VoiceError.synthesisFailed("bad WAV") },
                stopPlayback: {}
            )
            _ = try await synth.speak(try SpeechSynthesisRequest(text: "degrades to fallback"))
            XCTAssertEqual(system.activateCount, 1, "throw: one WAV lease acquired")
            XCTAssertEqual(system.deactivateCount, 1, "throw: WAV lease released exactly once")
        }

        // Cancel during playback.
        do {
            let system = CountingDuplexSystem()
            let play = ControlledPlay()
            let synth = GatewayWAVSpeechSynthesizer(
                endpoint: try endpoint(),
                fallback: RecordingFallback(),
                leases: DuplexAudioSessionLeaseManager(system: system),
                fetch: { _ in Data(repeating: 0, count: 128) },
                play: { data in try await play.play(data) },
                stopPlayback: {}
            )
            let speak = Task { try await synth.speak(try SpeechSynthesisRequest(text: "cancelled")) }
            try await play.waitForStart()
            speak.cancel()
            await XCTAssertThrowsVoiceError(.cancelled) { _ = try await speak.value }
            XCTAssertEqual(system.activateCount, 1, "cancel: one lease acquired")
            XCTAssertEqual(system.deactivateCount, 1, "cancel: lease released exactly once")
        }
    }

    // MARK: - (f) end-call (explicit stop) during playback → audio stops AND the briefing is never re-spoken

    func testEndCallDuringPlaybackStopsAudioAndNeverReSpeaks() async throws {
        let play = ControlledPlay()
        let stopPlayback = StopPlaybackSpy()
        let fallback = RecordingFallback()
        let system = CountingDuplexSystem()
        let synthesizer = GatewayWAVSpeechSynthesizer(
            endpoint: try endpoint(),
            fallback: fallback,
            leases: DuplexAudioSessionLeaseManager(system: system),
            fetch: { _ in Data(repeating: 0, count: 128) },
            play: { data in try await play.play(data) },
            stopPlayback: { await stopPlayback.stop() }
        )
        let request = try SpeechSynthesisRequest(text: "briefing when the caller hangs up")

        let speak = Task { try await synthesizer.speak(request) }
        try await play.waitForStart()
        await synthesizer.stop() // the caller ends the call mid-briefing

        await XCTAssertThrowsVoiceError(.cancelled) { _ = try await speak.value }
        let cancelledCount = await play.cancelledCountNow()
        let stopCalls = await stopPlayback.countNow()
        let fallbackSpeaks = await fallback.speakCountNow()
        XCTAssertEqual(cancelledCount, 1, "an end-call must interrupt the in-flight WAV playback")
        XCTAssertGreaterThanOrEqual(stopCalls, 1, "stop() must run the WAV playback-stop before returning")
        XCTAssertEqual(fallbackSpeaks, 0, "an end-call must be silent — never re-speak the briefing (no write, no audio)")
        XCTAssertEqual(system.deactivateCount, 1, "the lease is released exactly once before stop() returns")
    }

    // MARK: - Fetch hardening (P1) + payload validation (unit-level, deterministic)

    func testValidateWAVContainerAcceptsRIFFWAVEAndRejectsOthers() throws {
        XCTAssertNoThrow(try GatewayWAVSpeechSynthesizer.validateWAVContainer(fixtureWAV(200)))
        // Too short (a bare 44-byte header carries no audio).
        XCTAssertThrowsError(try GatewayWAVSpeechSynthesizer.validateWAVContainer(Data(repeating: 0, count: 40)))
        // Right size, wrong magic.
        XCTAssertThrowsError(
            try GatewayWAVSpeechSynthesizer.validateWAVContainer(Data(repeating: 0x41, count: 200))
        )
    }

    func testValidateResponseRejectsBadStatusHostAndOversize() throws {
        let expected = try XCTUnwrap(URL(string: "https://gw.example.test/tts"))
        // Non-200.
        XCTAssertThrowsError(
            try GatewayWAVSpeechSynthesizer.validateResponse(
                httpResponse(url: expected, status: 502), expectedURL: expected
            )
        )
        // 200 but a different final host (redirect/host swap).
        let swapped = try XCTUnwrap(URL(string: "https://evil.example.test/tts"))
        XCTAssertThrowsError(
            try GatewayWAVSpeechSynthesizer.validateResponse(
                httpResponse(url: swapped, status: 200), expectedURL: expected
            )
        ) { XCTAssertEqual($0 as? VoiceError, .insecureGateway) }
        // 200, correct URL, but an oversize advertised Content-Length.
        let oversize = GatewayWAVSpeechSynthesizer.maxWAVBytes + 1
        XCTAssertThrowsError(
            try GatewayWAVSpeechSynthesizer.validateResponse(
                httpResponse(url: expected, status: 200, contentLength: oversize), expectedURL: expected
            )
        )
        // Happy path.
        XCTAssertNoThrow(
            try GatewayWAVSpeechSynthesizer.validateResponse(
                httpResponse(url: expected, status: 200, contentLength: 1_024), expectedURL: expected
            )
        )
    }

    func testPerformFetchRejectsNonHTTPSEndpoint() async throws {
        let httpEndpoint = try XCTUnwrap(URL(string: "http://gw.example.test"))
        await XCTAssertThrowsVoiceError(.insecureGateway) {
            _ = try await GatewayWAVSpeechSynthesizer.performFetch(
                text: "hello",
                endpoint: httpEndpoint,
                bearer: "pocket-demo",
                session: URLSession(configuration: .ephemeral)
            )
        }
    }

    func testPerformFetchReturnsValidatedWAVBody() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixedWAVURLProtocol.self]
        let body = try await GatewayWAVSpeechSynthesizer.performFetch(
            text: "hello",
            endpoint: try XCTUnwrap(URL(string: "https://gw.example.test")),
            bearer: "pocket-demo",
            session: URLSession(configuration: configuration)
        )
        XCTAssertEqual(body, FixedWAVURLProtocol.body)
    }

    // MARK: - Helpers

    private func endpoint() throws -> URL {
        try XCTUnwrap(URL(string: "https://gw.example.test"))
    }

    private func waitForCurrentRequest(
        _ requestID: UUID?,
        on synthesizer: GatewayWAVSpeechSynthesizer
    ) async throws {
        for _ in 0..<1_000_000 {
            if await synthesizer.currentRequestID() == requestID { return }
            await Task.yield()
        }
        throw HarnessError.didNotArrive
    }

    private func httpResponse(
        url: URL,
        status: Int,
        contentLength: Int? = nil
    ) -> HTTPURLResponse {
        var headers: [String: String] = [:]
        if let contentLength { headers["Content-Length"] = "\(contentLength)" }
        return HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }
}

// MARK: - Deterministic harness

private enum HarnessError: Error { case didNotArrive }

private func fixtureWAV(_ byteCount: Int) -> Data {
    var data = Data()
    data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
    data.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // chunk size (unused by validation)
    data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
    data.append(Data(repeating: 0, count: max(0, byteCount - data.count)))
    return data
}

private extension XCTestCase {
    func XCTAssertThrowsVoiceError(
        _ expected: VoiceError,
        _ body: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected) to be thrown", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? VoiceError, expected, file: file, line: line)
        }
    }
}

private actor ControlledFetch {
    private(set) var callCount = 0
    private var waiters: [CheckedContinuation<Data, Error>] = []

    func fetch(_ text: String) async throws -> Data {
        callCount += 1
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func callCountNow() -> Int { callCount }

    func waitForCallCount(_ expected: Int) async throws {
        for _ in 0..<1_000_000 {
            if callCount >= expected { return }
            await Task.yield()
        }
        throw HarnessError.didNotArrive
    }

    func resumeNext(with result: Result<Data, Error>) {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume(with: result)
    }
}

private actor SpyPlay {
    private(set) var callCount = 0

    func play(_ data: Data) async throws -> ContinuousClock.Instant {
        callCount += 1
        return ContinuousClock.now
    }

    func callCountNow() -> Int { callCount }
}

private actor ControlledPlay {
    private(set) var callCount = 0
    private(set) var cancelledCount = 0
    private var started = 0
    private var waiter: CheckedContinuation<ContinuousClock.Instant, Error>?

    func play(_ data: Data) async throws -> ContinuousClock.Instant {
        callCount += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter = continuation
                started += 1
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    private func cancel() {
        cancelledCount += 1
        waiter?.resume(throwing: VoiceError.cancelled)
        waiter = nil
    }

    func waitForStart() async throws {
        for _ in 0..<1_000_000 {
            if started > 0 { return }
            await Task.yield()
        }
        throw HarnessError.didNotArrive
    }

    func callCountNow() -> Int { callCount }
    func cancelledCountNow() -> Int { cancelledCount }
}

private actor SharedPlay {
    private let exclusion: AudioExclusion
    private var served = 0

    init(exclusion: AudioExclusion) {
        self.exclusion = exclusion
    }

    func play(_ data: Data) async throws -> ContinuousClock.Instant {
        served += 1
        if served == 1 {
            // First briefing: force the WAV path to fail so it degrades to the (blocking) siri fallback.
            throw VoiceError.synthesisFailed("forced WAV failure")
        }
        await exclusion.begin(.wav)
        await Task.yield()
        await exclusion.end(.wav)
        return ContinuousClock.now
    }
}

private actor StopPlaybackSpy {
    private(set) var count = 0
    func stop() async { count += 1 }
    func countNow() -> Int { count }
}

private actor AudioExclusion {
    enum Owner: Equatable { case siri, wav }
    private var active: Owner?
    private(set) var overlapDetected = false

    func begin(_ owner: Owner) {
        if active != nil, active != owner { overlapDetected = true }
        active = owner
    }

    func end(_ owner: Owner) {
        if active == owner { active = nil }
    }

    func overlapDetectedNow() -> Bool { overlapDetected }
}

private actor RecordingFallback: SpeechSynthesizer {
    private(set) var speakCount = 0
    private(set) var stopCount = 0

    func speak(_ request: SpeechSynthesisRequest) async throws -> SpeechPlaybackMetrics {
        speakCount += 1
        return Self.metrics(characterCount: request.text.count)
    }

    func stop() async { stopCount += 1 }

    func speakCountNow() -> Int { speakCount }
    func stopCountNow() -> Int { stopCount }

    static func metrics(characterCount: Int) -> SpeechPlaybackMetrics {
        SpeechPlaybackMetrics(
            backend: .avSpeechOffline,
            firstAudioMeasurement: .avSpeechDidStartCallback,
            firstAudioMilliseconds: 1,
            totalMilliseconds: 2,
            characterCount: characterCount,
            residentMemoryBytes: nil,
            thermalState: .nominal
        )
    }
}

private actor BlockingFallback: SpeechSynthesizer {
    private let exclusion: AudioExclusion
    private(set) var speakCount = 0
    private(set) var stopCount = 0
    private var waiter: CheckedContinuation<SpeechPlaybackMetrics, Error>?

    init(exclusion: AudioExclusion) {
        self.exclusion = exclusion
    }

    func speak(_ request: SpeechSynthesisRequest) async throws -> SpeechPlaybackMetrics {
        speakCount += 1
        await exclusion.begin(.siri)
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func stop() async {
        stopCount += 1
        await exclusion.end(.siri)
        waiter?.resume(throwing: VoiceError.cancelled)
        waiter = nil
    }

    func speakCountNow() -> Int { speakCount }

    func waitForSpeakCount(_ expected: Int) async throws {
        for _ in 0..<1_000_000 {
            if speakCount >= expected { return }
            await Task.yield()
        }
        throw HarnessError.didNotArrive
    }
}

private final class CountingDuplexSystem: DuplexAudioSessionSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var activations = 0
    private var deactivations = 0

    func activate() throws {
        lock.withLock { activations += 1 }
    }

    func deactivate() throws {
        lock.withLock { deactivations += 1 }
    }

    var activateCount: Int { lock.withLock { activations } }
    var deactivateCount: Int { lock.withLock { deactivations } }
}

private final class FixedWAVURLProtocol: URLProtocol, @unchecked Sendable {
    static let body = fixtureWAV(120)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Length": "\(Self.body.count)"]
              ) else {
            client?.urlProtocol(self, didFailWithError: VoiceError.gatewayRejected(0))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
