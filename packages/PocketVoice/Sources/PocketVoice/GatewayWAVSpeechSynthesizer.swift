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
/// Audio routing reuses the SAME `DuplexAudioSessionLeaseManager` that `AVSpeechSynthesizerAdapter` uses, so the
/// WAV plays through the `.playAndRecord` / `.defaultToSpeaker` duplex session (audible on the loudspeaker, mic
/// still live for barge-in) and the session is deactivated once the shared lease count returns to zero.
///
/// Self-contained fallback (NO dependency on `HybridSpeechSynthesizer` / `ConnectivityProviding`): any failure
/// — non-200, network error, empty/short body, decode/playback error — routes to `fallback.speak(request)`.
public actor GatewayWAVSpeechSynthesizer: SpeechSynthesizer {
    private let endpoint: URL
    private let bearer: String
    private let fallback: any SpeechSynthesizer
    private let session: URLSession
    private let playbackTask: Task<WAVPlayback, Never>

    public init(
        endpoint: URL,
        bearer: String = "pocket-demo",
        fallback: any SpeechSynthesizer = AVSpeechSynthesizerAdapter(),
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.bearer = bearer
        self.fallback = fallback
        self.session = session
        // AVAudioPlayer + its delegate must live on a thread with a running run loop, so build/drive it on the
        // main actor (mirrors the @MainActor driver pattern in AVSpeechSynthesizerAdapter).
        self.playbackTask = Task { @MainActor in WAVPlayback() }
    }

    // MARK: - SpeechSynthesizer

    public func speak(_ request: SpeechSynthesisRequest) async throws -> SpeechPlaybackMetrics {
        let started = ContinuousClock.now
        do {
            let wav = try await fetchWAV(text: request.text)
            let firstAudioAt = try await play(wav)
            return SpeechPlaybackMetrics(
                backend: .elevenLabsGateway,
                firstAudioMeasurement: .pcmFirstBufferScheduled,
                firstAudioMilliseconds: started.duration(to: firstAudioAt).voiceMilliseconds,
                totalMilliseconds: started.duration(to: .now).voiceMilliseconds,
                characterCount: request.text.count,
                residentMemoryBytes: VoiceRuntimeSnapshot.residentMemoryBytes,
                thermalState: VoiceRuntimeSnapshot.thermalLevel
            )
        } catch {
            // A deliberate stop() / teardown must stay silent — never re-speak the briefing via the fallback.
            if error is CancellationError { throw VoiceError.cancelled }
            if let voiceError = error as? VoiceError, voiceError == .cancelled { throw voiceError }
            if let urlError = error as? URLError, urlError.code == .cancelled { throw VoiceError.cancelled }
            // Any genuine gateway/playback failure → the caller still hears the briefing on-device (siri).
            return try await fallback.speak(request)
        }
    }

    public func stop() async {
        await playbackTask.value.stop()
        await fallback.stop()
    }

    // MARK: - Gateway fetch

    private func fetchWAV(text: String) async throws -> Data {
        var request = URLRequest(
            url: endpoint.appendingPathComponent("tts"),
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 20
        )
        request.httpMethod = "POST"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(TTSRequestBody(text: text))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw VoiceError.gatewayRejected(0)
        }
        guard http.statusCode == 200 else {
            throw VoiceError.gatewayRejected(http.statusCode)
        }
        // A RIFF/WAV header alone is 44 bytes; anything at-or-below that carries no audio.
        guard data.count > 44 else {
            throw VoiceError.synthesisFailed("gateway returned \(data.count) bytes; expected a WAV payload")
        }
        return data
    }

    // MARK: - Playback (acquire duplex lease → play to completion → release lease)

    private func play(_ wav: Data) async throws -> ContinuousClock.Instant {
        let lease = try DuplexAudioSessionLeaseManager.shared.acquire()
        do {
            let firstAudioAt = try await playbackTask.value.play(wav)
            _ = DuplexAudioSessionLeaseManager.shared.release(lease)
            return firstAudioAt
        } catch {
            _ = DuplexAudioSessionLeaseManager.shared.release(lease)
            throw error
        }
    }
}

private struct TTSRequestBody: Encodable {
    let text: String
}

/// Main-actor bridge around `AVAudioPlayer`: creates + plays the WAV on the main run loop (so the delegate
/// callbacks are delivered) and turns the `AVAudioPlayerDelegate` completion into an `async` result.
@MainActor
private final class WAVPlayback: NSObject, AVAudioPlayerDelegate {
    private struct Active {
        let player: AVAudioPlayer
        let firstAudioAt: ContinuousClock.Instant
        let continuation: CheckedContinuation<ContinuousClock.Instant, Error>
    }

    private var active: Active?

    /// Play `wav` to completion, returning the instant playback was scheduled. Suspends until the delegate reports
    /// finish / decode-error, or `stop()` supersedes it.
    func play(_ wav: Data) async throws -> ContinuousClock.Instant {
        // Supersede any in-flight playback deterministically before starting the next one.
        finish(.failure(VoiceError.cancelled))

        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(data: wav)
        } catch {
            throw VoiceError.synthesisFailed("WAV decode failed: \(error.localizedDescription)")
        }
        player.delegate = self

        return try await withCheckedThrowingContinuation { continuation in
            guard player.play() else {
                player.delegate = nil
                continuation.resume(
                    throwing: VoiceError.synthesisFailed("AVAudioPlayer could not start WAV playback")
                )
                return
            }
            active = Active(player: player, firstAudioAt: .now, continuation: continuation)
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
