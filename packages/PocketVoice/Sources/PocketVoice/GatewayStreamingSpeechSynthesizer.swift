import AVFoundation
import Foundation

public protocol SpeechGatewayAuthorizer: Sendable {
    func authorize(_ request: URLRequest) async throws -> URLRequest
}

public struct SpeechGatewayConfiguration: Sendable, Equatable {
    public let endpoint: URL
    public let allowedHosts: Set<String>
    public let voiceId: String

    public init(endpoint: URL, allowedHosts: Set<String>, voiceId: String) throws {
        let normalizedHosts = Set(allowedHosts.map { $0.lowercased() })
        let allowedVoiceId = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard endpoint.scheme?.lowercased() == "https",
              endpoint.user == nil,
              endpoint.password == nil,
              let host = endpoint.host?.lowercased(),
              normalizedHosts.contains(host),
              !normalizedHosts.isEmpty,
              (1...128).contains(voiceId.count),
              voiceId.unicodeScalars.allSatisfy(allowedVoiceId.contains) else {
            throw VoiceError.insecureGateway
        }
        self.endpoint = endpoint
        self.allowedHosts = normalizedHosts
        self.voiceId = voiceId
    }
}

public actor GatewayStreamingSpeechSynthesizer: SpeechSynthesizer {
    private let configuration: SpeechGatewayConfiguration
    private let authorizer: any SpeechGatewayAuthorizer
    private let session: URLSession
    private let player: PCM16StreamPlayer

    private var activeRequestID: UUID?
    private var activeTask: Task<SpeechPlaybackMetrics, Error>?

    public init(
        configuration: SpeechGatewayConfiguration,
        authorizer: any SpeechGatewayAuthorizer,
        session: URLSession? = nil
    ) throws {
        guard let player = PCM16StreamPlayer(sampleRate: 24_000) else {
            throw VoiceError.audioSessionFailed("could not create the 24 kHz PCM format")
        }
        self.configuration = configuration
        self.authorizer = authorizer
        self.session = session ?? Self.makeSession()
        self.player = player
    }

    public func speak(_ request: SpeechSynthesisRequest) async throws -> SpeechPlaybackMetrics {
        activeRequestID = request.id
        activeTask?.cancel()
        activeTask = nil
        await player.stop()
        guard activeRequestID == request.id else { throw VoiceError.cancelled }

        let task = Task { try await performSpeech(request) }
        activeTask = task

        do {
            let metrics = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            guard activeRequestID == request.id else { throw VoiceError.cancelled }
            activeRequestID = nil
            activeTask = nil
            return metrics
        } catch {
            let wasCurrent = activeRequestID == request.id
            if wasCurrent {
                activeRequestID = nil
                activeTask = nil
                await player.stop()
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

    public func stop() async {
        activeRequestID = nil
        activeTask?.cancel()
        activeTask = nil
        await player.stop()
    }

    private func performSpeech(_ request: SpeechSynthesisRequest) async throws -> SpeechPlaybackMetrics {
        let body = GatewaySpeechRequest(
            text: request.text,
            voiceId: configuration.voiceId,
            modelId: "eleven_flash_v2_5",
            outputFormat: "pcm_24000",
            tone: request.tone.rawValue
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encodedBody = try encoder.encode(body)

        var unsignedRequest = URLRequest(
            url: configuration.endpoint,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 30
        )
        unsignedRequest.httpMethod = "POST"
        unsignedRequest.httpBody = encodedBody
        unsignedRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        unsignedRequest.setValue("audio/pcm", forHTTPHeaderField: "Accept")

        let request = try await authorizer.authorize(unsignedRequest)
        try validateAuthorizedRequest(request, expectedBody: encodedBody)
        let started = ContinuousClock.now
        let (bytes, response) = try await session.bytes(
            for: request,
            delegate: NoRedirectTaskDelegate.shared
        )
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw VoiceError.gatewayRejected(0)
        }
        guard (200..<300).contains(http.statusCode),
              http.url == configuration.endpoint,
              http.value(forHTTPHeaderField: "X-Senti-Audio-Format") == "pcm_s16le_24000" else {
            throw VoiceError.gatewayRejected(http.statusCode)
        }
        if http.expectedContentLength != NSURLSessionTransferSizeUnknown,
           http.expectedContentLength > 24_000_000 {
            throw VoiceError.malformedPCMStream
        }

        try await player.prepare()
        var chunk = Data()
        chunk.reserveCapacity(1_920)
        var totalBytes = 0
        var firstBufferAt: ContinuousClock.Instant?

        for try await byte in bytes {
            try Task.checkCancellation()
            chunk.append(byte)
            totalBytes += 1
            guard totalBytes <= 24_000_000 else {
                throw VoiceError.malformedPCMStream
            }
            if chunk.count == 1_920 {
                try await player.enqueue(chunk)
                if firstBufferAt == nil { firstBufferAt = .now }
                chunk.removeAll(keepingCapacity: true)
            }
        }
        if !chunk.isEmpty {
            guard chunk.count.isMultiple(of: 2) else { throw VoiceError.malformedPCMStream }
            try await player.enqueue(chunk)
            if firstBufferAt == nil { firstBufferAt = .now }
        }
        guard totalBytes > 0, let firstBufferAt else { throw VoiceError.malformedPCMStream }
        try await player.finish()

        return SpeechPlaybackMetrics(
            backend: .elevenLabsGateway,
            firstAudioMeasurement: .pcmFirstBufferScheduled,
            firstAudioMilliseconds: started.duration(to: firstBufferAt).voiceMilliseconds,
            totalMilliseconds: started.duration(to: .now).voiceMilliseconds,
            characterCount: request.text.count,
            residentMemoryBytes: VoiceRuntimeSnapshot.residentMemoryBytes,
            thermalState: VoiceRuntimeSnapshot.thermalLevel
        )
    }

    private func validateAuthorizedRequest(_ request: URLRequest, expectedBody: Data) throws {
        guard request.url == configuration.endpoint,
              request.httpMethod == "POST",
              request.httpBody == expectedBody,
              request.url?.scheme?.lowercased() == "https",
              let host = request.url?.host?.lowercased(),
              configuration.allowedHosts.contains(host),
              request.value(forHTTPHeaderField: "xi-api-key") == nil else {
            throw VoiceError.insecureGateway
        }
    }

    static func shouldReportCancellation(
        _ error: Error,
        wasCurrent: Bool,
        parentTaskCancelled: Bool
    ) -> Bool {
        !wasCurrent
            || parentTaskCancelled
            || error is CancellationError
            || error as? VoiceError == .cancelled
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }
}

private struct GatewaySpeechRequest: Encodable {
    let text: String
    let voiceId: String
    let modelId: String
    let outputFormat: String
    let tone: String
}
