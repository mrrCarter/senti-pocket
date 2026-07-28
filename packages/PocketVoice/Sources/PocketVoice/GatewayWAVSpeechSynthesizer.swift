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
/// so we buffer the whole response and hand it to `AVAudioPlayer`. This client is WAV-only — raw PCM belongs to
/// `GatewayStreamingSpeechSynthesizer`.
///
/// - Important: The synth ships **no** credential of its own. The gateway bearer is supplied by an injected
///   `bearerProvider`; its DEFAULT returns `nil`, so an un-wired synth authenticates with nothing, makes ZERO
///   network calls, and every briefing degrades to the on-device fallback (siri). The real session bearer is
///   wired at the app seam (DialHost) in a later round. A nil/empty bearer is rejected BEFORE any URLSession call.
///
/// Lifecycle mirrors `GatewayStreamingSpeechSynthesizer`: an owned in-flight `activeTask`, a monotone
/// `lifecycleGeneration` + `activeRequestID` (`claimLifecycle`/`isCurrent`/`clearLifecycleIfCurrent`), an
/// `isCurrent` re-check after every `await`, a `withTaskCancellationHandler` around the owned task, and a single
/// cross-backend cleanup barrier. The barrier releases the duplex audio-session lease EXACTLY ONCE and stops both
/// backends (WAV playback + siri fallback) IDEMPOTENTLY — backend stop is safe to call repeatedly, and a clean
/// success runs the barrier at BOTH preflight and settle, so playback/fallback stop can run more than once while
/// the lease is released only on the barrier that owns it. A stopped/superseded briefing can never play, never
/// re-speak via the fallback, and never overlap a newer briefing across backends.
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
    /// The cross-backend exclusion owner: stops WAV playback, stops the siri fallback, and releases the duplex
    /// lease. The LEASE release is exact-once (the barrier that captured the lease releases it); backend stop is
    /// idempotent. Every stop / supersede / settle awaits the SAME in-flight barrier, so no two backends and no
    /// two generations can produce audio at the same time.
    private struct CleanupBarrier: Sendable {
        let id: UUID
        let task: Task<VoiceError?, Never>
    }

    private let endpoint: URL
    private let bearerProvider: @Sendable () async -> String?
    private let fallback: any SpeechSynthesizer
    private let session: URLSession
    private let leases: DuplexAudioSessionLeaseManager
    // Injectable seams (production defaults below). Tests drive fetch / play / stop deterministically.
    private let fetch: @Sendable (_ text: String, _ bearer: String) async throws -> Data
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
        bearerProvider: @escaping @Sendable () async -> String? = { nil },
        fallback: any SpeechSynthesizer = AVSpeechSynthesizerAdapter(),
        session: URLSession? = nil
    ) {
        let resolvedSession = session ?? Self.makeSession()
        // AVAudioPlayer + its delegate must live on a thread with a running run loop, so build/drive it on the
        // main actor (mirrors the @MainActor driver pattern in AVSpeechSynthesizerAdapter).
        let playback = Task { @MainActor in WAVPlayback() }
        self.endpoint = endpoint
        self.bearerProvider = bearerProvider
        self.fallback = fallback
        self.session = resolvedSession
        self.leases = .shared
        self.fetch = { text, bearer in
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

    /// Test seam: inject the bearer provider, network fetch, WAV playback, playback-stop, and lease manager so the
    /// lifecycle can be driven deterministically without a live gateway or a real audio device. `bearerProvider`
    /// has NO default — every caller passes one explicitly, so the synth carries no bearer literal of its own.
    init(
        endpoint: URL,
        bearerProvider: @escaping @Sendable () async -> String?,
        fallback: any SpeechSynthesizer,
        session: URLSession = URLSession(configuration: .ephemeral),
        leases: DuplexAudioSessionLeaseManager = .shared,
        fetch: @escaping @Sendable (_ text: String, _ bearer: String) async throws -> Data,
        play: @escaping @Sendable (Data) async throws -> ContinuousClock.Instant,
        stopPlayback: @escaping @Sendable () async -> Void
    ) {
        self.endpoint = endpoint
        self.bearerProvider = bearerProvider
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
        // Await the cleanup barrier so WAV playback + siri fallback are stopped and the lease is released BEFORE
        // stop() returns. This teardown is prompt and bounded and does NOT depend on the fetch task.
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
            // Resolve + VALIDATE the gateway credential at the transport boundary. A nil / empty / whitespace-only
            // / control-char bearer is REJECTED (never trimmed) → ship NOTHING (zero network); the catch below
            // degrades to the on-device fallback, which returns ITS OWN metrics — never a fake Cartesia success.
            let rawBearer = await bearerProvider()
            try requireCurrent(requestID: request.id, generation: generation)
            let bearer = try Self.validatedBearer(rawBearer)
            let wav = try await fetch(request.text, bearer)
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
                // delegate start-callback), so `.avAudioPlayerPlaybackScheduled` names the mechanism exactly. This
                // is reported ONLY when a gateway WAV actually played; every degrade path returns the fallback's.
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
            // Genuine gateway/playback failure OR no-credential/pre-egress rejection → degrade to on-device siri,
            // returning the FALLBACK's metrics, but ONLY while this is still the current generation and the owned
            // task is not cancelled (a stale request must never speak).
            try Task.checkCancellation()
            guard isCurrent(requestID: request.id, generation: generation) else {
                throw VoiceError.cancelled
            }
            return try await fallback.speak(request)
        }
    }

    /// Post-completion settle: run the cleanup barrier (release the lease, stop both backends), clear the
    /// lifecycle if still current, and map cancellation / cleanup failures the same way GatewayStreaming does.
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
            // Terminal window: the barrier has already run (both backends stopped, lease released exactly once).
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

    // MARK: - Cross-backend cleanup barrier (idempotent backend stop, exact-once lease release)

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
                await stopPlayback() // stop any in-flight WAV playback (idempotent)
                await fallback.stop() // stop any in-flight siri fallback (idempotent cross-backend exclusion)
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

    // MARK: - Gateway fetch (ephemeral, no-redirect, https-pinned, pre-egress-validated, size-capped, WAV-only)

    /// Centralized transport-boundary credential validator. A valid bearer is a non-empty token with NO whitespace
    /// (space / tab / CR / LF / Unicode whitespace) and NO control characters. A malformed credential is REJECTED
    /// (never trimmed or normalized — the app supplies an unchanged valid token); this keeps an all-whitespace
    /// "credential" and CR/LF header-injection from ever reaching the wire.
    static func validatedBearer(_ bearer: String?) throws -> String {
        guard let bearer, !bearer.isEmpty else {
            throw VoiceError.insecureGateway
        }
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard bearer.unicodeScalars.allSatisfy({ !forbidden.contains($0) }) else {
            throw VoiceError.insecureGateway
        }
        return bearer
    }

    static func performFetch(
        text: String,
        endpoint: URL,
        bearer: String,
        session: URLSession,
        maxBytes: Int = maxWAVBytes
    ) async throws -> Data {
        // PRE-EGRESS (defense-in-depth): reject a malformed credential and a bad URL BEFORE any network call, so
        // the Authorization header is only ever built from a validated bearer.
        let bearer = try validatedBearer(bearer)
        let ttsURL = endpoint.appendingPathComponent("tts")
        try validateInitialRequestURL(ttsURL)
        var request = URLRequest(
            url: ttsURL,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 20
        )
        request.httpMethod = "POST"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/wav, application/octet-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(TTSRequestBody(text: text))

        let (bytes, response) = try await session.bytes(
            for: request,
            delegate: NoRedirectTaskDelegate.shared
        )
        try validateResponse(response, expectedURL: ttsURL, maxBytes: maxBytes)

        var data = Data()
        data.reserveCapacity(64 * 1_024)
        for try await byte in bytes {
            try Task.checkCancellation()
            data.append(byte)
            // Actual-size cap: enforced on the STREAMED body regardless of the advertised Content-Length, so a
            // gateway that under-advertises (or omits) its length cannot overflow the buffer.
            guard data.count <= maxBytes else {
                throw VoiceError.synthesisFailed("gateway WAV exceeded \(maxBytes) bytes")
            }
        }
        try precheckRIFFWAVEMagic(data)
        return data
    }

    /// PRE-EGRESS validation of the request URL, run BEFORE any network call so a bad endpoint never receives the
    /// Bearer. Policy: `https` only, a non-empty host, and NO userinfo, query, or fragment on the request URL.
    static func validateInitialRequestURL(_ url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.percentEncodedHost, !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw VoiceError.insecureGateway
        }
    }

    /// HTTP + transport validation: 200, real HTTP response, the FINAL response URL is the exact endpoint we
    /// posted to (see `isExactExpectedURL`), the response MIME is the WAV contract, and the advertised
    /// `Content-Length` is within the cap.
    static func validateResponse(_ response: URLResponse, expectedURL: URL, maxBytes: Int = maxWAVBytes) throws {
        guard let http = response as? HTTPURLResponse else {
            throw VoiceError.gatewayRejected(0)
        }
        guard http.statusCode == 200 else {
            throw VoiceError.gatewayRejected(http.statusCode)
        }
        guard let finalURL = http.url, isExactExpectedURL(finalURL, expectedURL: expectedURL) else {
            throw VoiceError.insecureGateway
        }
        try validateResponseMIME(http)
        if http.expectedContentLength != NSURLSessionTransferSizeUnknown,
           http.expectedContentLength > Int64(maxBytes) {
            throw VoiceError.synthesisFailed(
                "gateway advertised \(http.expectedContentLength) bytes; over the \(maxBytes)-byte cap"
            )
        }
    }

    /// The WAV contract accepts ONLY `audio/wav` or the documented `application/octet-stream` (a trailing
    /// `; charset=…`/parameter is ignored); an absent or any other media type is rejected.
    static func validateResponseMIME(_ http: HTTPURLResponse) throws {
        guard let rawContentType = http.value(forHTTPHeaderField: "Content-Type") else {
            throw VoiceError.synthesisFailed("gateway response is missing a Content-Type")
        }
        let mediaType = rawContentType
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard mediaType == "audio/wav" || mediaType == "application/octet-stream" else {
            throw VoiceError.synthesisFailed("gateway returned unexpected MIME '\(mediaType)'")
        }
    }

    /// Whether `finalURL` is the endpoint we posted to, compared COMPONENT-BY-COMPONENT (not a raw string/byte
    /// compare): scheme and host are matched case-insensitively; port, percent-encoded path, and percent-encoded
    /// query must be equal (both absent as expected); any userinfo or fragment, a missing host, or any host / port
    /// / path / query mutation is rejected. Rejects a redirect / host swap / credential injection.
    static func isExactExpectedURL(_ finalURL: URL, expectedURL: URL) -> Bool {
        guard let final = URLComponents(url: finalURL, resolvingAgainstBaseURL: false),
              let expected = URLComponents(url: expectedURL, resolvingAgainstBaseURL: false),
              let finalHost = final.percentEncodedHost, !finalHost.isEmpty,
              let expectedHost = expected.percentEncodedHost, !expectedHost.isEmpty else {
            return false
        }
        // Reject any credentials or fragment on the final URL.
        guard final.user == nil, final.password == nil, final.fragment == nil else { return false }
        guard final.scheme?.lowercased() == "https", expected.scheme?.lowercased() == "https" else { return false }
        return finalHost.lowercased() == expectedHost.lowercased()
            && final.port == expected.port
            && final.percentEncodedPath == expected.percentEncodedPath
            && final.percentEncodedQuery == expected.percentEncodedQuery
    }

    /// RIFF/WAVE MAGIC PRECHECK — a cheap sanity gate, NOT a full container validation: it confirms only the
    /// "RIFF"…"WAVE" magic and a minimum length. `AVAudioPlayer` in `WAVPlayback` is the real decoder and the
    /// authority on a valid, positive-duration payload; the RIFF chunk size and the `fmt `/`data` chunks are NOT
    /// parsed here.
    static func precheckRIFFWAVEMagic(_ data: Data) throws {
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

struct TTSRequestBody: Encodable {
    let text: String
}

/// Main-actor bridge around `AVAudioPlayer`: creates + plays the WAV on the main run loop (so the delegate
/// callbacks are delivered) and turns the `AVAudioPlayerDelegate` completion into an `async` result. The play
/// continuation is wrapped in `withTaskCancellationHandler`, and cancellation is IDENTITY-SCOPED to the exact
/// player it was created for — an older playback's late cancellation can never stop a newer player. A supersede
/// (or stop) actually STOPS the outgoing player, not merely finishes its continuation.
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

    /// How an identity-scoped cancellation is delivered to the main actor. Production hops via an unstructured
    /// Task (the natural delayed delivery); a test injects a scheduler that captures the pending cancellation so
    /// the delayed-onCancel race (an old cancel firing AFTER a new playback started) is deterministic.
    private let scheduleCancel: @Sendable (@escaping @Sendable @MainActor () -> Void) -> Void

    /// Upper bound on decoded playback so a tiny payload that decodes to a very long duration can never
    /// monopolize the call/lease. A pickup briefing is a handful of seconds; anything past this demo cap is
    /// rejected (and degrades to the on-device fallback).
    static let maxPlaybackSeconds: TimeInterval = 120

    init(
        scheduleCancel: @escaping @Sendable (@escaping @Sendable @MainActor () -> Void) -> Void = { work in
            Task { @MainActor in work() }
        }
    ) {
        self.scheduleCancel = scheduleCancel
        super.init()
    }

    /// Play `wav` to completion, returning the instant playback was scheduled. Suspends until the delegate reports
    /// finish / decode-error, `stop()` supersedes it, or the awaiting Task is cancelled.
    func play(_ wav: Data) async throws -> ContinuousClock.Instant {
        // Never start audio for an already-cancelled/stopped briefing.
        try Task.checkCancellation()
        // Supersede any in-flight playback: STOP its player and resume/clear it BEFORE constructing the next one.
        stop()

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

        let scheduleCancel = self.scheduleCancel // capture the @Sendable seam locally (avoid isolated self access)
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
            scheduleCancel { self.cancel(player: player) }
        }
    }

    /// Identity-scoped cancellation: stop playback only if `player` is STILL the active player. An older
    /// playback's cancellation that fires AFTER a newer playback has started is a no-op — latest-wins.
    func cancel(player: AVAudioPlayer) {
        guard let current = active, current.player === player else { return }
        stop()
    }

    /// Stop the active playback: STOP the player (audio actually ends) and resume/clear its continuation.
    func stop() {
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
        current.player.stop() // ensure the player is actually stopped when we clear it (supersede/stop included)
        current.continuation.resume(with: result)
    }
}
