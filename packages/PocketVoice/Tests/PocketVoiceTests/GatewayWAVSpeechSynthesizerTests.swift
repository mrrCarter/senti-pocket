import AVFoundation
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

    // MARK: - (f) explicit stop() during playback → audio stops, lease released once, briefing never re-spoken
    //
    // Scope note (honesty): this proves ONLY the synthesizer-level contract of `stop()` — it interrupts the
    // in-flight WAV playback, runs the playback-stop, releases the lease exactly once, and never re-speaks via the
    // fallback. It does NOT drive CallKit or the phone writer, so it proves neither live call teardown nor
    // "no write on end-call". The real live-teardown / no-write assertion lands as a DialHost `onEnded` wiring
    // app-integration test (a separate change, not in this file).

    func testStopStopsAudioAndDoesNotReSpeak() async throws {
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
        let request = try SpeechSynthesisRequest(text: "briefing interrupted by stop()")

        let speak = Task { try await synthesizer.speak(request) }
        try await play.waitForStart()
        await synthesizer.stop() // explicit stop mid-briefing

        await XCTAssertThrowsVoiceError(.cancelled) { _ = try await speak.value }
        let cancelledCount = await play.cancelledCountNow()
        let stopCalls = await stopPlayback.countNow()
        let fallbackSpeaks = await fallback.speakCountNow()
        XCTAssertEqual(cancelledCount, 1, "stop() must interrupt the in-flight WAV playback")
        XCTAssertGreaterThanOrEqual(stopCalls, 1, "stop() must run the WAV playback-stop before returning")
        XCTAssertEqual(fallbackSpeaks, 0, "a stopped briefing must be silent — never re-speak via the fallback")
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

    // MARK: - (P0) identity-scoped cancellation → a stale OLD cancel never stops a newer player

    // Drives the real `WAVPlayback` (real `AVAudioPlayer`s): start playback A, supersede it with playback B, then
    // fire A's cancellation AFTER B has started. With identity-scoped cancel this is a no-op; the pre-fix
    // untracked `stop()` would have evicted/stopped B (the newer player).
    @MainActor
    func testStaleCancelDoesNotStopNewerPlayback() async throws {
        let playback = WAVPlayback()
        let wav = Self.pcmWAV(seconds: 30) // long enough not to finish during the test; under the 120s cap

        // Start playback A and capture its player.
        let aTask = Task { try await playback.play(wav) }
        let playerA = try await Self.waitForActivePlayer(on: playback, differentFrom: nil)

        // Start playback B: it supersedes A (A's continuation resumes cancelled) and becomes the active player.
        let bTask = Task { try await playback.play(wav) }
        let playerB = try await Self.waitForActivePlayer(on: playback, differentFrom: playerA)
        XCTAssertTrue(playerA !== playerB, "each play() must create a distinct AVAudioPlayer instance")

        // A was superseded → its awaiting task observes cancellation.
        await XCTAssertThrowsVoiceError(.cancelled) { _ = try await aTask.value }

        // The OLD playback's cancellation fires AFTER the NEW playback has started. Identity-scoped → no-op.
        playback.cancel(player: playerA)

        XCTAssertTrue(playback.currentActivePlayer() === playerB,
                      "a stale cancel of the older player must not evict the newer active player")
        XCTAssertTrue(playerB.isPlaying,
                      "the newer playback must keep playing after a stale cancel of the older player")

        // Cleanup: a real stop ends B; the orphaned (superseded, not stopped) A player is stopped directly.
        playerA.stop()
        playback.stop()
        await XCTAssertThrowsVoiceError(.cancelled) { _ = try await bTask.value }
        XCTAssertFalse(playerB.isPlaying, "stop() must end the active playback")
    }

    // MARK: - (P1) bounded decoded duration → a tiny payload that decodes very long is rejected before playback

    @MainActor
    func testPlaybackRejectsDurationOverDemoCap() async throws {
        let playback = WAVPlayback()
        let overlong = Self.pcmWAV(seconds: 121) // > the 120s demo cap, but ~1.9 MB (under the byte cap)
        do {
            _ = try await playback.play(overlong)
            XCTFail("an over-long WAV must be rejected before playback starts")
        } catch let error as VoiceError {
            guard case .synthesisFailed = error else {
                return XCTFail("expected .synthesisFailed for an over-long WAV, got \(error)")
            }
        }
        XCTAssertNil(playback.currentActivePlayer(), "a rejected over-long WAV must never become the active player")
    }

    // MARK: - (P1) settle cancellation → a parent-task cancel DURING settle is reported as cancelled, not success

    func testCancellationDuringSettleReportsCancelledNotSuccess() async throws {
        let stopGate = StopGate() // blocks the cleanup barrier's stopPlayback so we can cancel mid-settle
        let system = CountingDuplexSystem()
        let synth = GatewayWAVSpeechSynthesizer(
            endpoint: try endpoint(),
            fallback: RecordingFallback(),
            leases: DuplexAudioSessionLeaseManager(system: system),
            fetch: { _ in Data(repeating: 0, count: 128) },
            play: { _ in ContinuousClock.now }, // plays successfully & instantly → settle(.success)
            stopPlayback: { await stopGate.stop() } // barrier suspends here during settle
        )
        let speak = Task { try await synth.speak(try SpeechSynthesisRequest(text: "cancel during settle")) }

        // Wait until the SETTLE barrier is blocked in stopPlayback (the preflight barrier already passed).
        try await stopGate.waitForBlocking()
        speak.cancel()      // parent cancellation lands DURING settle, after a successful play
        await stopGate.open() // unblock the barrier → settle resumes and must decide the result

        await XCTAssertThrowsVoiceError(.cancelled) { _ = try await speak.value }
        XCTAssertEqual(system.deactivateCount, 1, "cleanup still runs exactly once even when cancelled during settle")
    }

    // MARK: - (P1) owned-task drain registry → cooperative cancel terminates & empties the registry

    func testStopDrainRegistryEmptiesWhenCancelledFetchTerminates() async throws {
        let fetch = CooperativeFetch() // honors cancellation → the owned task actually terminates
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
        let speak = Task { try await synthesizer.speak(try SpeechSynthesisRequest(text: "briefing")) }
        try await fetch.waitForCallCount(1)
        await synthesizer.stop() // cancels the cooperative fetch → owned task terminates

        await XCTAssertThrowsVoiceError(.cancelled) { _ = try await speak.value }
        // The cancelled owned task was retained for drain and, being cooperative, terminates → registry empties.
        try await waitForDrainingEmpty(on: synthesizer)
        let plays = await play.callCountNow()
        let fallbackSpeaks = await fallback.speakCountNow()
        XCTAssertEqual(plays, 0, "a stopped briefing never plays")
        XCTAssertEqual(fallbackSpeaks, 0, "a stopped briefing never re-speaks via the fallback")
        XCTAssertEqual(system.activateCount, 0, "no lease is taken when the fetch is stopped before playback")
    }

    // MARK: - (P1) drain registry → stop() returns promptly on a NON-cooperative fetch; late resolution is silent

    func testStopReturnsPromptlyThenLateNonCooperativeFetchStaysSilent() async throws {
        let fetch = ControlledFetch() // non-cooperative: only resolves on an explicit resumeNext
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
        let speak = Task { try await synthesizer.speak(try SpeechSynthesisRequest(text: "briefing")) }
        try await fetch.waitForCallCount(1)

        // stop() must NOT block on the cancellation-uncooperative fetch: it returns once the audio/lease teardown
        // is done. Run it in a Task and assert it completes within a bounded budget (no hang).
        let stopDone = BoolFlag()
        let stopTask = Task { await synthesizer.stop(); await stopDone.set() }
        var returnedPromptly = false
        for _ in 0..<2_000_000 {
            if await stopDone.isSet() { returnedPromptly = true; break }
            await Task.yield()
        }
        _ = await stopTask.value
        XCTAssertTrue(returnedPromptly, "stop() must return promptly and never block on a non-cooperative fetch")

        // The cancelled fetch is still suspended and OWNED (draining) — not dropped.
        let drainingCount = await synthesizer.drainingTaskCount()
        XCTAssertEqual(drainingCount, 1,
                       "the cancelled non-cooperative fetch stays owned/observable in the drain registry")

        // Release the fetch LATE: the generation guard keeps it silent — no play, no fallback, no lease.
        await fetch.resumeNext(with: .success(Data(repeating: 0, count: 128)))
        await XCTAssertThrowsVoiceError(.cancelled) { _ = try await speak.value }
        try await waitForDrainingEmpty(on: synthesizer) // it eventually terminates → registry empties
        let plays = await play.callCountNow()
        let fallbackSpeaks = await fallback.speakCountNow()
        XCTAssertEqual(plays, 0, "a late fetch after stop must never play")
        XCTAssertEqual(fallbackSpeaks, 0, "a late fetch after stop must never re-speak via fallback")
        XCTAssertEqual(system.activateCount, 0, "a late fetch after stop must never acquire a lease")
        XCTAssertEqual(system.deactivateCount, 0)
    }

    // MARK: - (P1) telemetry → real, accurate enum cases (raw value + Codable round-trip) and used by the metrics

    func testNewTelemetryEnumCasesRawValueAndCodableRoundTrip() throws {
        XCTAssertEqual(SpeechSynthesisBackend.cartesiaGateway.rawValue, "cartesiaGateway")
        XCTAssertEqual(FirstAudioMeasurement.avAudioPlayerPlaybackScheduled.rawValue, "avAudioPlayerPlaybackScheduled")

        let backend = try JSONDecoder().decode(
            SpeechSynthesisBackend.self,
            from: JSONEncoder().encode(SpeechSynthesisBackend.cartesiaGateway)
        )
        XCTAssertEqual(backend, .cartesiaGateway)

        let measurement = try JSONDecoder().decode(
            FirstAudioMeasurement.self,
            from: JSONEncoder().encode(FirstAudioMeasurement.avAudioPlayerPlaybackScheduled)
        )
        XCTAssertEqual(measurement, .avAudioPlayerPlaybackScheduled)
    }

    func testSuccessfulBriefingReportsCartesiaGatewayTelemetry() async throws {
        let synth = GatewayWAVSpeechSynthesizer(
            endpoint: try endpoint(),
            fallback: RecordingFallback(),
            leases: DuplexAudioSessionLeaseManager(system: CountingDuplexSystem()),
            fetch: { _ in Data(repeating: 0, count: 128) },
            play: { _ in ContinuousClock.now },
            stopPlayback: {}
        )
        let metrics = try await synth.speak(try SpeechSynthesisRequest(text: "briefing"))
        XCTAssertEqual(metrics.backend, .cartesiaGateway)
        XCTAssertEqual(metrics.firstAudioMeasurement, .avAudioPlayerPlaybackScheduled)
    }

    // MARK: - (P1) exact-URL validation → same-host port/query/path/userinfo mutations are rejected

    func testValidateResponseRejectsSameHostPortQueryPathAndUserinfoMutation() throws {
        let expected = try XCTUnwrap(URL(string: "https://gw.example.test/tts"))
        func reject(_ urlString: String) throws {
            let url = try XCTUnwrap(URL(string: urlString))
            XCTAssertThrowsError(
                try GatewayWAVSpeechSynthesizer.validateResponse(
                    httpResponse(url: url, status: 200), expectedURL: expected
                )
            ) { XCTAssertEqual($0 as? VoiceError, .insecureGateway, "should reject \(urlString)") }
        }
        try reject("https://gw.example.test:8443/tts")  // mutated port
        try reject("https://gw.example.test/tts?x=1")   // added query
        try reject("https://gw.example.test/tts/evil")  // mutated path
        // Injected userinfo is asserted at the comparison layer (HTTPURLResponse may normalize credentials away).
        XCTAssertFalse(
            GatewayWAVSpeechSynthesizer.isExactExpectedURL(
                try XCTUnwrap(URL(string: "https://user:pass@gw.example.test/tts")), expectedURL: expected
            ),
            "a final URL carrying userinfo must be rejected"
        )
        // Missing host is rejected.
        XCTAssertFalse(
            GatewayWAVSpeechSynthesizer.isExactExpectedURL(
                try XCTUnwrap(URL(string: "https:/tts")), expectedURL: expected
            ),
            "a final URL missing its host must be rejected"
        )
        // Control: the exact same-host, no-port, no-query, no-userinfo URL is accepted.
        XCTAssertTrue(GatewayWAVSpeechSynthesizer.isExactExpectedURL(expected, expectedURL: expected))
        XCTAssertNoThrow(
            try GatewayWAVSpeechSynthesizer.validateResponse(
                httpResponse(url: expected, status: 200, contentLength: 1_024), expectedURL: expected
            )
        )
    }

    // MARK: - (Honesty) demo-only transport → POST shape (URL/method/auth/body) + injectable bearer & WAV format

    func testDemoPOSTShapeAndDefaultWAVFormatHandling() async throws {
        CapturingURLProtocol.reset(responseBody: fixtureWAV(120))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CapturingURLProtocol.self]

        let body = try await GatewayWAVSpeechSynthesizer.performFetch(
            text: "hello world",
            endpoint: try XCTUnwrap(URL(string: "https://gw.example.test")),
            bearer: "live-session-token", // injected (non-default) bearer proves the seam
            format: .wav,
            session: URLSession(configuration: configuration)
        )

        let captured = try XCTUnwrap(CapturingURLProtocol.capturedNow())
        XCTAssertEqual(captured.url?.absoluteString, "https://gw.example.test/tts")
        XCTAssertEqual(captured.method, "POST")
        XCTAssertEqual(captured.authorization, "Bearer live-session-token")
        XCTAssertEqual(captured.accept, "audio/wav, application/octet-stream")
        let json = try JSONSerialization.jsonObject(with: try XCTUnwrap(captured.body)) as? [String: Any]
        XCTAssertEqual(json?["text"] as? String, "hello world", "the POST body must carry the briefing text")
        XCTAssertEqual(body, CapturingURLProtocol.responseBodyNow(), "the WAV body is validated and returned")
    }

    // MARK: - Helpers

    private func endpoint() throws -> URL {
        try XCTUnwrap(URL(string: "https://gw.example.test"))
    }

    private func waitForDrainingEmpty(
        on synthesizer: GatewayWAVSpeechSynthesizer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<1_000_000 {
            if await synthesizer.drainingTaskCount() == 0 { return }
            await Task.yield()
        }
        XCTFail("the drain registry never emptied", file: file, line: line)
        throw HarnessError.didNotArrive
    }

    @MainActor
    private static func waitForActivePlayer(
        on playback: WAVPlayback,
        differentFrom previous: AVAudioPlayer?
    ) async throws -> AVAudioPlayer {
        for _ in 0..<1_000_000 {
            if let player = playback.currentActivePlayer(), player !== previous {
                return player
            }
            await Task.yield()
        }
        throw HarnessError.didNotArrive
    }

    /// A valid silent 8 kHz / 16-bit mono PCM WAV of the requested duration (real container `AVAudioPlayer` decodes).
    static func pcmWAV(seconds: Double) -> Data {
        let sampleRate = 8_000, bitsPerSample = 16, channels = 1
        let frames = Int(Double(sampleRate) * seconds)
        let dataSize = frames * channels * bitsPerSample / 8
        var d = Data()
        func le32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); le32(UInt32(36 + dataSize)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); le32(16); le16(1); le16(UInt16(channels)); le32(UInt32(sampleRate))
        le32(UInt32(sampleRate * channels * bitsPerSample / 8))
        le16(UInt16(channels * bitsPerSample / 8)); le16(UInt16(bitsPerSample))
        d.append(contentsOf: Array("data".utf8)); le32(UInt32(dataSize)); d.append(Data(repeating: 0, count: dataSize))
        return d
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

// A cancellation-aware fetch fake: its suspended fetch RESUMES with a CancellationError when the owning task is
// cancelled, so a stopped/superseded owned task actually terminates (used for the drain-registry-empties test).
private actor CooperativeFetch {
    private(set) var callCount = 0
    private var waiters: [CheckedContinuation<Data, Error>] = []
    private var cancelled = false

    func fetch(_ text: String) async throws -> Data {
        callCount += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                store(continuation)
            }
        } onCancel: {
            Task { await self.cancelAll() }
        }
    }

    private func store(_ continuation: CheckedContinuation<Data, Error>) {
        if cancelled {
            continuation.resume(throwing: CancellationError())
            return
        }
        waiters.append(continuation)
    }

    private func cancelAll() {
        cancelled = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume(throwing: CancellationError()) }
    }

    func callCountNow() -> Int { callCount }

    func waitForCallCount(_ expected: Int) async throws {
        for _ in 0..<1_000_000 {
            if callCount >= expected { return }
            await Task.yield()
        }
        throw HarnessError.didNotArrive
    }
}

// Blocks the cleanup barrier's stopPlayback on its Nth invocation until `open()` is called, so a test can inject
// a parent-task cancellation while settle is suspended inside the barrier. speak() runs the barrier twice for a
// clean success — once at preflight, once at settle — so `blockAtCall: 2` lets preflight pass and blocks settle.
private actor StopGate {
    private let blockAtCall: Int
    private var opened = false
    private var callCount = 0
    private var blocking = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(blockAtCall: Int = 2) { self.blockAtCall = blockAtCall }

    func stop() async {
        callCount += 1
        guard callCount >= blockAtCall else { return }
        blocking = true
        if opened { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }

    func waitForBlocking() async throws {
        for _ in 0..<1_000_000 {
            if blocking { return }
            await Task.yield()
        }
        throw HarnessError.didNotArrive
    }
}

private actor BoolFlag {
    private var value = false
    func set() { value = true }
    func isSet() -> Bool { value }
}

// Captures the outgoing request (URL / method / Authorization / Accept / body) and returns a fixed WAV, so a
// test can assert the exact POST shape the demo transport puts on the wire.
private final class CapturingURLProtocol: URLProtocol, @unchecked Sendable {
    struct Captured: Sendable {
        let url: URL?
        let method: String?
        let authorization: String?
        let accept: String?
        let body: Data?
    }

    private static let lock = NSLock()
    private static var captured: Captured?
    private static var responseBody = Data()

    static func reset(responseBody: Data) {
        lock.withLock {
            captured = nil
            self.responseBody = responseBody
        }
    }

    static func capturedNow() -> Captured? { lock.withLock { captured } }
    static func responseBodyNow() -> Data { lock.withLock { responseBody } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.readBody(from: request)
        Self.lock.withLock {
            Self.captured = Captured(
                url: request.url,
                method: request.httpMethod,
                authorization: request.value(forHTTPHeaderField: "Authorization"),
                accept: request.value(forHTTPHeaderField: "Accept"),
                body: body
            )
        }
        let payload = Self.responseBodyNow()
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Length": "\(payload.count)"]
              ) else {
            client?.urlProtocol(self, didFailWithError: VoiceError.gatewayRejected(0))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4_096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
