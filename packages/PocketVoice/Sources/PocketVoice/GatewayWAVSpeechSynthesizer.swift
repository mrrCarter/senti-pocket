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
/// Lifecycle mirrors `GatewayStreamingSpeechSynthesizer`: an owned in-flight `activeTask`, a monotone
/// `lifecycleGeneration` + `activeRequestID` (`claimLifecycle`/`isCurrent`/`clearLifecycleIfCurrent`), an
/// `isCurrent` re-check after every `await`, a `withTaskCancellationHandler` around the owned task, and a single
/// exact-once cleanup barrier that STOPS both backends (WAV playback + siri fallback) and releases the duplex
/// audio-session lease before it settles — so a stopped/superseded briefing can never play, never re-speak via
/// the fallback, and never overlap a newer briefing across backends.
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

    /// Cap on both the advertised `Content-Length` and the actual received body — a WAV briefing is a few hundred
    /// KB; anything past 10 MiB is rejected (and degrades to the on-device fallback).
    static let maxWAVBytes = 10 * 1_024 * 1_024

    public init(
        endpoint: URL,
        bearer: String = "pocket-demo",
        fallback: any SpeechSynthesizer = AVSpeechSynthesizerAdapter(),
        session: URLSession? = nil
    ) {
        let resolvedSession = session ?? Self.makeSession()
        // AVAudioPlayer + its delegate must live on a thread with a running run loop, so build/drive it on the
        // main actor (mirrors the @MainActor driver pattern in AVSpeechSynthesizerAdapter).
        let playback = Task { @MainActor in WAVPlayback() }
        self.endpoint = endpoint
        self.bearer = bearer
        self.fallback = fallback
        self.session = resolvedSession
        self.leases = .shared
        self.fetch = { text in
            try await Self.performFetch(
                text: text,
                endpoint: endpoint,
                bearer: bearer,
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
        fallback: any SpeechSynthesizer,
        session: URLSession = URLSession(configuration: .ephemeral),
        leases: DuplexAudioSessionLeaseManager = .shared,
        fetch: @escaping @Sendable (String) async throws -> Data,
        play: @escaping @Sendable (Data) async throws -> ContinuousClock.Instant,
        stopPlayback: @escaping @Sendable () async -> Void
    ) {
        self.endpoint = endpoint
        self.bearer = bearer
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
        activeTask?.cancel()
        activeTask = nil
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
        activeTask?.cancel()
        activeTask = nil
        // Await the exact-once barrier so WAV playback + siri fallback are stopped and the lease is released
        // BEFORE stop() returns.
        _ = await awaitCleanupBarrier()
    }

    public func pendingAudioSessionError() -> VoiceError? {
        cleanupFailures.pendingError
    }

    func currentRequestID() -> UUID? {
        activeRequestID
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
            // After the fetch await: a stop()/supersede that changed the generation means we must NEVER play.
            try requireCurrent(requestID: request.id, generation: generation)
            // requireCurrent -> acquire -> record are suspension-free, so a superseder either loses the generation
            // check here (no lease taken) or observes `activeLease` set and releases it through the barrier.
            let lease = try leases.acquire()
            activeLease = lease
            let firstAudioAt = try await play(wav)
            try requireCurrent(requestID: request.id, generation: generation)
            return SpeechPlaybackMetrics(
                // Telemetry: the closest ACCURATE existing cases in VoiceTypes (no invented cases). This backend is
                // Cartesia-via-full-WAV-AVAudioPlayer; VoiceTypes ships only `.avSpeechOffline` (on-device, wrong)
                // and `.elevenLabsGateway` (network gateway premium) -> the gateway case is correct in CATEGORY,
                // its vendor label is a known misnomer. `firstAudioAt` is captured synchronously when
                // `AVAudioPlayer.play()` is scheduled (no delegate callback), so `.pcmFirstBufferScheduled` (a
                // "scheduled at play" proxy) fits the mechanism where `.avSpeechDidStartCallback` (a delegate
                // callback we do not use) does not. The exact fix is dedicated enum cases in VoiceTypes.swift,
                // which is out of this change's scope.
                backend: .elevenLabsGateway,
                firstAudioMeasurement: .pcmFirstBufferScheduled,
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
            guard isCurrent(requestID: request.id, generation: generation) else {
                throw VoiceError.cancelled
            }
            activeRequestID = nil
            activeTask = nil
            if let cleanupError {
                cleanupFailures.consume(cleanupError)
                throw cleanupError
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
        try validateWAVContainer(data)
        return data
    }

    /// HTTP + transport validation: 200, real HTTP response, the FINAL response URL is the exact https host+path we
    /// posted to (rejects a redirect/host swap), and the advertised `Content-Length` is within the cap.
    static func validateResponse(_ response: URLResponse, expectedURL: URL) throws {
        guard let http = response as? HTTPURLResponse else {
            throw VoiceError.gatewayRejected(0)
        }
        guard http.statusCode == 200 else {
            throw VoiceError.gatewayRejected(http.statusCode)
        }
        guard let finalURL = http.url,
              finalURL.scheme?.lowercased() == "https",
              finalURL.host?.lowercased() == expectedURL.host?.lowercased(),
              finalURL.path == expectedURL.path else {
            throw VoiceError.insecureGateway
        }
        if http.expectedContentLength != NSURLSessionTransferSizeUnknown,
           http.expectedContentLength > Int64(maxWAVBytes) {
            throw VoiceError.synthesisFailed(
                "gateway advertised \(http.expectedContentLength) bytes; over the \(maxWAVBytes)-byte cap"
            )
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

private struct TTSRequestBody: Encodable {
    let text: String
}

/// Main-actor bridge around `AVAudioPlayer`: creates + plays the WAV on the main run loop (so the delegate
/// callbacks are delivered) and turns the `AVAudioPlayerDelegate` completion into an `async` result. The play
/// continuation is wrapped in `withTaskCancellationHandler`, so parent-Task cancellation stops the audio.
@MainActor
private final class WAVPlayback: NSObject, AVAudioPlayerDelegate {
    private struct Active {
        let player: AVAudioPlayer
        let firstAudioAt: ContinuousClock.Instant
        let continuation: CheckedContinuation<ContinuousClock.Instant, Error>
    }

    private var active: Active?

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
            Task { @MainActor in self.stop() }
        }
    }

    func stop() {
        active?.player.stop()
        finish(.failure(VoiceError.cancelled))
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
