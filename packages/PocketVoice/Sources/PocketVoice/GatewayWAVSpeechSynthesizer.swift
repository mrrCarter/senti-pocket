import AVFoundation
import Foundation

/// GatewayWAVSpeechSynthesizer — the DIAL-pickup briefing voice. It fetches a COMPLETE WAV from the live demo
/// gateway's `POST /tts` (pocket-TTS / Cartesia) and plays it on the loudspeaker, degrading to the injected
/// on-device `fallback` (AVSpeech / siri) whenever the gateway is unreachable so the caller ALWAYS hears the
/// briefing.
///
/// This is deliberately NOT `GatewayStreamingSpeechSynthesizer`: that one speaks a streaming raw-PCM protocol
/// (`Accept: audio/pcm`, and requires the `X-Senti-Audio-Format: pcm_s16le_24000` response header) which our demo
/// gateway does not implement. Our gateway returns a single `HTTP 200` RIFF/WAV body (`application/octet-stream`),
/// so we buffer the whole response and hand it to `AVAudioPlayer`.
///
/// - Important: This transport is **demo-only** — not the durable production speech-client contract. It defaults
///   to the login-free demo bearer (`pocket-demo`) and a whole-WAV body; the canonical production gateway
///   authenticates with the logged-in **session** bearer and its composition defaults to raw **PCM** streamed
///   through `GatewayStreamingSpeechSynthesizer`. The `bearer` and `expectedFormat` are injectable (see `init`)
///   precisely so those demo assumptions are explicit rather than hard-coded as universal.
///
/// Lifecycle mirrors `GatewayStreamingSpeechSynthesizer`: an owned in-flight `activeTask`, a monotone
/// `lifecycleGeneration` + `activeRequestID` (`claimLifecycle`/`isCurrent`/`clearLifecycleIfCurrent`), an
/// `isCurrent` re-check after every `await`, a `withTaskCancellationHandler` around the owned task, and a single
/// exact-once cleanup barrier that STOPS both backends (WAV playback + siri fallback) and releases the duplex
/// audio-session lease before it settles — so a stopped/superseded briefing can never play, never re-speak via
/// the fallback, and never overlap a newer briefing across backends.
///
/// stop()/supersede are PROMPT and BOUNDED: they invalidate the generation, run the audio/lease teardown via the
/// cleanup barrier, and move the cancelled owned task into a `draining` registry that keeps it owned/observable
/// until it terminates — WITHOUT awaiting it. A cancellation-uncooperative fetch therefore can never make
/// stop()/supersede hang; the generation guard guarantees any late-resolving fetch produces no audio, no
/// fallback, and no lease.
///
/// Audio routing reuses the SAME `DuplexAudioSessionLeaseManager` that `AVSpeechSynthesizerAdapter` uses, so the
/// WAV plays through the `.playAndRecord` / `.defaultToSpeaker` duplex session (audible on the loudspeaker, mic
/// still live for barge-in) and the session is deactivated once the shared lease count returns to zero.
public actor GatewayWAVSpeechSynthesizer: SpeechSynthesizer {
    /// The single cross-backend exclusion owner: stops WAV playback, stops the siri fallback, and releases the
    /// duplex lease exactly once. Every stop / supersede / settle awaits the SAME barrier, so no two backends and
    /// no two generations can produce audio at the same time.
    private struct CleanupBarrier: Sendable {
        let id: UUID
        let task: Task<VoiceError?, Never>
    }

    private let endpoint: URL
    private let bearer: String
    private let expectedFormat: GatewayResponseFormat
    private let fallback: any SpeechSynthesizer
    private let session: URLSession
    private let leases: DuplexAudioSessionLeaseManager
    // Injectable seams (production defaults below). Tests drive fetch / play / stop deterministically.
    private let fetch: @Sendable (String) async throws -> Data
    private let play: @Sendable (Data) async throws -> ContinuousClock.Instant
    private let stopPlayback: @Sendable () async -> Void

    private var activeRequestID: UUID?
    private var activeTask: Task<SpeechPlaybackMetrics, Error>?
    private var lifecycleGeneration: UInt64 = 0
    private var activeLease: DuplexAudioSessionLease?
    private var cleanupBarrier: CleanupBarrier?
    private var cleanupFailures = GatewayAudioSessionCleanupFailures()
    /// Cancelled-but-not-yet-terminated owned tasks. stop()/supersede move a cancelled task here (keyed by a
    /// drain id) instead of awaiting it, so teardown stays prompt/bounded while the task stays owned/observable;
    /// each entry removes itself when its task finally resolves.
    private var draining: [UUID: Task<Void, Never>] = [:]

    /// Cap on both the advertised `Content-Length` and the actual received body — a WAV briefing is a few hundred
    /// KB; anything past 10 MiB is rejected (and degrades to the on-device fallback).
    static let maxWAVBytes = 10 * 1_024 * 1_024

    public init(
        endpoint: URL,
        bearer: String = "pocket-demo",
        expectedFormat: GatewayResponseFormat = .wav,
        fallback: any SpeechSynthesizer = AVSpeechSynthesizerAdapter(),
        session: URLSession? = nil
    ) {
        let resolvedSession = session ?? Self.makeSession()
        // AVAudioPlayer + its delegate must live on a thread with a running run loop, so build/drive it on the
        // main actor (mirrors the @MainActor driver pattern in AVSpeechSynthesizerAdapter).
        let playback = Task { @MainActor in WAVPlayback() }
        self.endpoint = endpoint
        self.bearer = bearer
        self.expectedFormat = expectedFormat
        self.fallback = fallback
        self.session = resolvedSession
        self.leases = .shared
        self.fetch = { text in
            try await Self.performFetch(
                text: text,
                endpoint: endpoint,
                bearer: bearer,
                format: expectedFormat,
                session: resolvedSession
            )
        }
        self.play = { wav in try await playback.value.play(wav) }
        self.stopPlayback = { await playback.value.stop() }
    }

    /// Test seam: inject the network fetch, the WAV playback, the playback-stop, and the lease manager so the
    /// lifecycle can be driven deterministically without a live gateway or a real audio device.
    init(
        endpoint: URL,
        bearer: String = "pocket-demo",
        expectedFormat: GatewayResponseFormat = .wav,
        fallback: any SpeechSynthesizer,
        session: URLSession = URLSession(configuration: .ephemeral),
        leases: DuplexAudioSessionLeaseManager = .shared,
        fetch: @escaping @Sendable (String) async throws -> Data,
        play: @escaping @Sendable (Data) async throws -> ContinuousClock.Instant,
        stopPlayback: @escaping @Sendable () async -> Void
    ) {
        self.endpoint = endpoint
        self.bearer = bearer
        self.expectedFormat = expectedFormat
        self.fallback = fallback
        self.session = session
        self.leases = leases
        self.fetch = fetch
        self.play = play
        self.stopPlayback = stopPlayback
    }

    // MARK: - SpeechSynthesizer

    public func speak(_ request: SpeechSynthesisRequest) async throws -> SpeechPlaybackMetrics {
        try cleanupFailures.requireNoPendingError()

        let generation = claimLifecycle(requestID: request.id)
        supersedeActiveTask() // cancel + retain-for-drain the previous owned task (never awaited)
        let preflightCleanup = await awaitCleanupBarrier()
        do {
            try requireCurrent(requestID: request.id, generation: generation)
            try cleanupFailures.requireNoPendingError()
            if let preflightCleanup { throw preflightCleanup }
        } catch {
            clearLifecycleIfCurrent(requestID: request.id, generation: generation)
            if error is CancellationError { throw VoiceError.cancelled }
            throw error
        }

        let task = Task { try await performSpeak(request, generation: generation) }
        activeTask = task

        do {
            let metrics = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            return try await settle(.success(metrics), request: request, generation: generation)
        } catch {
            return try await settle(.failure(error), request: request, generation: generation)
        }
    }

    public func stop() async {
        _ = claimLifecycle(requestID: nil)
        activeRequestID = nil
        supersedeActiveTask() // cancel + retain-for-drain; NEVER block stop() on a (possibly uncooperative) fetch
        // Await the exact-once barrier so WAV playback + siri fallback are stopped and the lease is released
        // BEFORE stop() returns. This teardown is prompt and bounded and does NOT depend on the fetch task.
        _ = await awaitCleanupBarrier()
    }

    public func pendingAudioSessionError() -> VoiceError? {
        cleanupFailures.pendingError
    }

    func currentRequestID() -> UUID? {
        activeRequestID
    }

    /// Test hook: number of cancelled owned tasks still draining (owned/observable but not yet terminated).
    func drainingTaskCount() -> Int {
        draining.count
    }

    // MARK: - Owned-task drain registry (cancel promptly, retain until terminated, never await in stop/supersede)

    /// Cancel the in-flight owned task and MOVE it into the `draining` registry so it stays owned/observable until
    /// it terminates — WITHOUT awaiting it here. This keeps stop()/supersede prompt and bounded even when the
    /// in-flight fetch is cancellation-uncooperative; the generation guard guarantees the late task is silent.
    private func supersedeActiveTask() {
        guard let owned = activeTask else { return }
        activeTask = nil
        owned.cancel()
        retainForDrain(owned)
    }

    private func retainForDrain(_ task: Task<SpeechPlaybackMetrics, Error>) {
        let drainID = UUID()
        draining[drainID] = Task { [weak self] in
            _ = try? await task.value // wait for the cancelled owned task to ACTUALLY terminate
            await self?.finishDraining(drainID) // then drop the handle → registry empties (observable termination)
        }
    }

    private func finishDraining(_ id: UUID) {
        draining[id] = nil
    }

    // MARK: - Owned in-flight briefing (fetch -> play, degrading to the current-request-only fallback)

    private func performSpeak(
        _ request: SpeechSynthesisRequest,
        generation: UInt64
    ) async throws -> SpeechPlaybackMetrics {
        let started = ContinuousClock.now
        do {
            try requireCurrent(requestID: request.id, generation: generation)
            let wav = try await fetch(request.text)
            // After the fetch await: a stop()/supersede that changed the generation means we must NEVER play,
            // never acquire a lease, and never degrade to the fallback (latest-wins, generation-guarded).
            try requireCurrent(requestID: request.id, generation: generation)
            // requireCurrent -> acquire -> record are suspension-free, so a superseder either loses the generation
            // check here (no lease taken) or observes `activeLease` set and releases it through the barrier.
            let lease = try leases.acquire()
            activeLease = lease
            let firstAudioAt = try await play(wav)
            try requireCurrent(requestID: request.id, generation: generation)
            return SpeechPlaybackMetrics(
                // Telemetry: dedicated, accurate cases for this backend. This is Cartesia-via-full-WAV-AVAudioPlayer,
                // and `firstAudioAt` is captured synchronously when `AVAudioPlayer.play()` is scheduled (there is no
                // delegate start-callback), so `.avAudioPlayerPlaybackScheduled` names the mechanism exactly.
                backend: .cartesiaGateway,
                firstAudioMeasurement: .avAudioPlayerPlaybackScheduled,
                firstAudioMilliseconds: started.duration(to: firstAudioAt).voiceMilliseconds,
                totalMilliseconds: started.duration(to: .now).voiceMilliseconds,
                characterCount: request.text.count,
                residentMemoryBytes: VoiceRuntimeSnapshot.residentMemoryBytes,
                thermalState: VoiceRuntimeSnapshot.thermalLevel
            )
        } catch {
            // A deliberate stop() / teardown / supersede must stay silent — never re-speak the briefing.
            if error is CancellationError { throw VoiceError.cancelled }
            if let voiceError = error as? VoiceError, voiceError == .cancelled { throw voiceError }
            if let urlError = error as? URLError, urlError.code == .cancelled { throw VoiceError.cancelled }
            // Genuine gateway/playback failure → degrade to on-device siri, but ONLY while this is still the
            // current generation and the owned task is not cancelled (a stale request must never speak).
            try Task.checkCancellation()
            guard isCurrent(requestID: request.id, generation: generation) else {
                throw VoiceError.cancelled
            }
            return try await fallback.speak(request)
        }
    }

    /// Post-completion settle: run the exact-once cleanup barrier (release the lease, stop both backends), clear
    /// the lifecycle if still current, and map cancellation / cleanup failures the same way GatewayStreaming does.
    private func settle(
        _ result: Result<SpeechPlaybackMetrics, Error>,
        request: SpeechSynthesisRequest,
        generation: UInt64
    ) async throws -> SpeechPlaybackMetrics {
        switch result {
        case .success(let metrics):
            guard isCurrent(requestID: request.id, generation: generation) else {
                throw VoiceError.cancelled
            }
            let cleanupError = await awaitCleanupBarrier()
            // Terminal window: the barrier has already run exactly once (both backends stopped, lease released).
            // From here we only DECIDE the result — never a second cleanup. A supersede/stop (no longer current)
            // OR a parent-task cancellation that landed DURING settle must be reported as cancelled, not success.
            guard isCurrent(requestID: request.id, generation: generation) else {
                throw VoiceError.cancelled
            }
            activeRequestID = nil
            activeTask = nil
            if let cleanupError {
                cleanupFailures.consume(cleanupError)
                throw cleanupError
            }
            if Task.isCancelled {
                throw VoiceError.cancelled
            }
            return metrics
        case .failure(let error):
            let wasCurrent = isCurrent(requestID: request.id, generation: generation)
            var cleanupError: VoiceError?
            if wasCurrent {
                cleanupError = await awaitCleanupBarrier()
                if isCurrent(requestID: request.id, generation: generation) {
                    activeRequestID = nil
                    activeTask = nil
                    if let cleanupError { cleanupFailures.consume(cleanupError) }
                }
            }
            if let cleanupError {
                throw Self.errorByAddingCleanupFailure(error, cleanupError: cleanupError)
            }
            if Self.shouldReportCancellation(
                error,
                wasCurrent: wasCurrent,
                parentTaskCancelled: Task.isCancelled
            ) {
                throw VoiceError.cancelled
            }
            throw error
        }
    }

    // MARK: - Lifecycle generation

    private func claimLifecycle(requestID: UUID?) -> UInt64 {
        lifecycleGeneration &+= 1
        activeRequestID = requestID
        return lifecycleGeneration
    }

    private func isCurrent(requestID: UUID, generation: UInt64) -> Bool {
        lifecycleGeneration == generation && activeRequestID == requestID
    }

    private func clearLifecycleIfCurrent(requestID: UUID, generation: UInt64) {
        guard isCurrent(requestID: requestID, generation: generation) else { return }
        activeRequestID = nil
        activeTask = nil
    }

    private func requireCurrent(requestID: UUID, generation: UInt64) throws {
        try Task.checkCancellation()
        guard isCurrent(requestID: requestID, generation: generation) else {
            throw VoiceError.cancelled
        }
    }

    // MARK: - Exact-once cross-backend cleanup barrier

    private func awaitCleanupBarrier() async -> VoiceError? {
        let barrier: CleanupBarrier
        if let activeBarrier = cleanupBarrier {
            barrier = activeBarrier
        } else {
            let id = UUID()
            let stopPlayback = self.stopPlayback
            let fallback = self.fallback
            let leases = self.leases
            let lease = activeLease
            activeLease = nil // hand lease ownership to the barrier → released exactly once
            let task = Task<VoiceError?, Never> { [weak self] in
                await stopPlayback() // stop any in-flight WAV playback
                await fallback.stop() // stop any in-flight siri fallback (single cross-backend exclusion owner)
                var cleanupError: VoiceError?
                if let lease { cleanupError = leases.release(lease).error }
                await self?.completeCleanupBarrier(id: id, error: cleanupError)
                return cleanupError
            }
            barrier = CleanupBarrier(id: id, task: task)
            cleanupBarrier = barrier
        }
        return await barrier.task.value
    }

    private func completeCleanupBarrier(id: UUID, error: VoiceError?) {
        cleanupFailures.record(error)
        guard cleanupBarrier?.id == id else { return }
        cleanupBarrier = nil
    }

    static func shouldReportCancellation(
        _ error: Error,
        wasCurrent: Bool,
        parentTaskCancelled: Bool
    ) -> Bool {
        if let voiceError = error as? VoiceError, case .audioSessionFailed = voiceError {
            return false
        }
        return !wasCurrent
            || parentTaskCancelled
            || error is CancellationError
            || error as? VoiceError == .cancelled
    }

    static func errorByAddingCleanupFailure(_ error: Error, cleanupError: VoiceError) -> VoiceError {
        .audioSessionFailed("\(error.localizedDescription); \(cleanupError.localizedDescription)")
    }

    // MARK: - Gateway fetch (ephemeral, no-redirect, https-pinned, size-capped, RIFF/WAVE-validated)

    static func performFetch(
        text: String,
        endpoint: URL,
        bearer: String,
        format: GatewayResponseFormat = .wav,
        session: URLSession
    ) async throws -> Data {
        let ttsURL = endpoint.appendingPathComponent("tts")
        guard ttsURL.scheme?.lowercased() == "https" else {
            throw VoiceError.insecureGateway
        }
        var request = URLRequest(
            url: ttsURL,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 20
        )
        request.httpMethod = "POST"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(format.acceptHeader, forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(TTSRequestBody(text: text))

        let (bytes, response) = try await session.bytes(
            for: request,
            delegate: NoRedirectTaskDelegate.shared
        )
        try validateResponse(response, expectedURL: ttsURL)

        var data = Data()
        data.reserveCapacity(64 * 1_024)
        for try await byte in bytes {
            try Task.checkCancellation()
            data.append(byte)
            guard data.count <= maxWAVBytes else {
                throw VoiceError.synthesisFailed("gateway WAV exceeded \(maxWAVBytes) bytes")
            }
        }
        try validateBody(data, format: format)
        return data
    }

    /// HTTP + transport validation: 200, real HTTP response, the FINAL response URL is byte-for-byte the exact
    /// https endpoint we posted to (rejects a redirect / host swap / port / query / path mutation / injected
    /// userinfo), and the advertised `Content-Length` is within the cap.
    static func validateResponse(_ response: URLResponse, expectedURL: URL) throws {
        guard let http = response as? HTTPURLResponse else {
            throw VoiceError.gatewayRejected(0)
        }
        guard http.statusCode == 200 else {
            throw VoiceError.gatewayRejected(http.statusCode)
        }
        guard let finalURL = http.url, isExactExpectedURL(finalURL, expectedURL: expectedURL) else {
            throw VoiceError.insecureGateway
        }
        if http.expectedContentLength != NSURLSessionTransferSizeUnknown,
           http.expectedContentLength > Int64(maxWAVBytes) {
            throw VoiceError.synthesisFailed(
                "gateway advertised \(http.expectedContentLength) bytes; over the \(maxWAVBytes)-byte cap"
            )
        }
    }

    /// The FINAL response URL must be the endpoint we posted to, compared exactly: `https`, exact host, exact port
    /// (both absent = the scheme default), exact path, exact query (both absent as expected), and NO userinfo. Any
    /// redirect, host swap, port/query/path mutation, or injected credentials is rejected.
    static func isExactExpectedURL(_ finalURL: URL, expectedURL: URL) -> Bool {
        guard let final = URLComponents(url: finalURL, resolvingAgainstBaseURL: false),
              let expected = URLComponents(url: expectedURL, resolvingAgainstBaseURL: false),
              let finalHost = final.host, !finalHost.isEmpty,
              let expectedHost = expected.host, !expectedHost.isEmpty else {
            return false
        }
        // Reject any credentials embedded in the final URL.
        guard final.user == nil, final.password == nil else { return false }
        guard final.scheme?.lowercased() == "https", expected.scheme?.lowercased() == "https" else { return false }
        return finalHost.lowercased() == expectedHost.lowercased()
            && final.port == expected.port
            && final.path == expected.path
            && final.query == expected.query
    }

    /// Payload validation for the expected response format. WAV (the demo default) must be a real RIFF/WAVE
    /// container (positive audio duration is asserted in `WAVPlayback` where `AVAudioPlayer` decodes it).
    static func validateBody(_ data: Data, format: GatewayResponseFormat) throws {
        switch format {
        case .wav:
            try validateWAVContainer(data)
        case .rawPCM:
            // Parity with the production streaming expectation. This demo WAV client cannot PLAY a bare PCM
            // stream (AVAudioPlayer needs a container), so a caller selecting `.rawPCM` will fetch these bytes and
            // then degrade to the on-device fallback — real PCM playback is `GatewayStreamingSpeechSynthesizer`'s.
            guard !data.isEmpty, data.count.isMultiple(of: 2) else {
                throw VoiceError.synthesisFailed("gateway returned \(data.count) bytes; expected 16-bit PCM")
            }
        }
    }

    /// Payload validation: a real RIFF/WAVE container (positive audio duration is asserted in `WAVPlayback` where
    /// `AVAudioPlayer` decodes it).
    static func validateWAVContainer(_ data: Data) throws {
        // A canonical WAV header is 44 bytes: "RIFF" <uint32 size> "WAVE" ...; below that there is no audio.
        guard data.count > 44 else {
            throw VoiceError.synthesisFailed("gateway returned \(data.count) bytes; expected a WAV payload")
        }
        let header = Array(data.prefix(12)) // cheap 12-byte, slice-index-safe copy of the container magic
        guard header.count == 12,
              header[0] == 0x52, header[1] == 0x49, header[2] == 0x46, header[3] == 0x46, // "RIFF"
              header[8] == 0x57, header[9] == 0x41, header[10] == 0x56, header[11] == 0x45 // "WAVE"
        else {
            throw VoiceError.synthesisFailed("gateway payload is not a RIFF/WAVE container")
        }
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }
}

/// The response body shape this DEMO client expects from the gateway's `POST /tts`.
///
/// - Important: `.wav` (the demo default) is the only shape this `AVAudioPlayer`-backed client can play. `.rawPCM`
///   exists so a call site can DECLARE the canonical production expectation (the production speech path streams
///   raw PCM via `GatewayStreamingSpeechSynthesizer`); this demo client fetches PCM but cannot play it and
///   degrades to the on-device fallback. It selects the outgoing `Accept` header and the payload validation.
public enum GatewayResponseFormat: String, Sendable, Equatable {
    /// A complete RIFF/WAVE body returned as `application/octet-stream` (the login-free demo gateway shape).
    case wav
    /// Raw little-endian 16-bit PCM (the production streaming shape) — advertised for parity, not playable here.
    case rawPCM

    var acceptHeader: String {
        switch self {
        case .wav: return "audio/wav, application/octet-stream"
        case .rawPCM: return "audio/pcm"
        }
    }
}

struct TTSRequestBody: Encodable {
    let text: String
}

/// Main-actor bridge around `AVAudioPlayer`: creates + plays the WAV on the main run loop (so the delegate
/// callbacks are delivered) and turns the `AVAudioPlayerDelegate` completion into an `async` result. The play
/// continuation is wrapped in `withTaskCancellationHandler`, and cancellation is IDENTITY-SCOPED to the exact
/// player it was created for — an older playback's late cancellation can never stop a newer player.
///
/// `internal` (not `private`) only so the deterministic cross-generation cancellation regression test can drive
/// it directly; it is not part of the package's public surface.
@MainActor
final class WAVPlayback: NSObject, AVAudioPlayerDelegate {
    private struct Active {
        let player: AVAudioPlayer
        let firstAudioAt: ContinuousClock.Instant
        let continuation: CheckedContinuation<ContinuousClock.Instant, Error>
    }

    private var active: Active?

    /// Upper bound on decoded playback so a tiny payload that decodes to a very long duration can never
    /// monopolize the call/lease. A pickup briefing is a handful of seconds; anything past this demo cap is
    /// rejected (and degrades to the on-device fallback).
    static let maxPlaybackSeconds: TimeInterval = 120

    /// Play `wav` to completion, returning the instant playback was scheduled. Suspends until the delegate reports
    /// finish / decode-error, `stop()` supersedes it, or the awaiting Task is cancelled.
    func play(_ wav: Data) async throws -> ContinuousClock.Instant {
        // Never start audio for an already-cancelled/stopped briefing.
        try Task.checkCancellation()
        // Supersede any in-flight playback deterministically before starting the next one.
        finish(.failure(VoiceError.cancelled))

        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(data: wav)
        } catch {
            throw VoiceError.synthesisFailed("WAV decode failed: \(error.localizedDescription)")
        }
        guard player.duration > 0 else {
            throw VoiceError.synthesisFailed("WAV decoded to a zero-duration payload")
        }
        guard player.duration <= Self.maxPlaybackSeconds else {
            throw VoiceError.synthesisFailed(
                "WAV decoded to \(player.duration)s; over the \(Self.maxPlaybackSeconds)s demo cap"
            )
        }
        player.delegate = self

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard player.play() else {
                    player.delegate = nil
                    continuation.resume(
                        throwing: VoiceError.synthesisFailed("AVAudioPlayer could not start WAV playback")
                    )
                    return
                }
                active = Active(player: player, firstAudioAt: .now, continuation: continuation)
            }
        } onCancel: {
            // Identity-scoped: stop ONLY this invocation's player, and only if it is still the active one.
            Task { @MainActor in self.cancel(player: player) }
        }
    }

    /// Identity-scoped cancellation: stop playback only if `player` is STILL the active player. An older
    /// playback's cancellation that fires AFTER a newer playback has started is a no-op — latest-wins.
    func cancel(player: AVAudioPlayer) {
        guard let current = active, current.player === player else { return }
        stop()
    }

    func stop() {
        active?.player.stop()
        finish(.failure(VoiceError.cancelled))
    }

    /// Test hook: the currently active `AVAudioPlayer`, if any (used to observe cross-generation identity).
    func currentActivePlayer() -> AVAudioPlayer? {
        active?.player
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        MainActor.assumeIsolated {
            guard let current = active, current.player === player else { return }
            finish(flag
                ? .success(current.firstAudioAt)
                : .failure(VoiceError.synthesisFailed("AVAudioPlayer finished unsuccessfully")))
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        MainActor.assumeIsolated {
            guard let current = active, current.player === player else { return }
            finish(.failure(VoiceError.synthesisFailed(
                "WAV decode error: \(error?.localizedDescription ?? "unknown")")))
        }
    }

    private func finish(_ result: Result<ContinuousClock.Instant, Error>) {
        guard let current = active else { return }
        active = nil
        current.player.delegate = nil
        current.continuation.resume(with: result)
    }
}
