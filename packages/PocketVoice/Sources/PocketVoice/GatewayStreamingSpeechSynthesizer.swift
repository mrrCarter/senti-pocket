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

struct GatewayAudioSessionCleanupFailures: Sendable {
    private(set) var pendingError: VoiceError?

    mutating func record(_ error: VoiceError?) {
        guard pendingError == nil, let error else { return }
        pendingError = error
    }

    mutating func take() -> VoiceError? {
        defer { pendingError = nil }
        return pendingError
    }

    mutating func requireNoPendingError() throws {
        if let pendingError = take() {
            throw pendingError
        }
    }

    mutating func consume(_ error: VoiceError) {
        guard pendingError == error else { return }
        pendingError = nil
    }
}

public actor GatewayStreamingSpeechSynthesizer: SpeechSynthesizer {
    private struct CleanupBarrier: Sendable {
        let id: UUID
        let task: Task<VoiceError?, Never>
    }

    private let configuration: SpeechGatewayConfiguration
    private let authorizer: any SpeechGatewayAuthorizer
    private let session: URLSession
    private let preparePlayer: @Sendable () async throws -> Void
    private let enqueuePlayer: @Sendable (Data) async throws -> Void
    private let finishPlayer: @Sendable () async throws -> Void
    private let stopPlayer: @Sendable () async -> VoiceError?
    private let cleanupWaitObserver: (@Sendable (UUID) async -> Void)?

    private var activeRequestID: UUID?
    private var activeTask: Task<SpeechPlaybackMetrics, Error>?
    private var cleanupFailures = GatewayAudioSessionCleanupFailures()
    private var cleanupBarrier: CleanupBarrier?
    private var lifecycleGeneration: UInt64 = 0

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
        self.preparePlayer = { try await player.prepare() }
        self.enqueuePlayer = { data in try await player.enqueue(data) }
        self.finishPlayer = { try await player.finish() }
        self.stopPlayer = { await player.stop() }
        self.cleanupWaitObserver = nil
    }

    init(
        configuration: SpeechGatewayConfiguration,
        authorizer: any SpeechGatewayAuthorizer,
        session: URLSession,
        player: PCM16StreamPlayer,
        preparePlayer: (@Sendable () async throws -> Void)? = nil,
        enqueuePlayer: (@Sendable (Data) async throws -> Void)? = nil,
        finishPlayer: (@Sendable () async throws -> Void)? = nil,
        stopPlayer: @escaping @Sendable () async -> VoiceError?,
        cleanupWaitObserver: (@Sendable (UUID) async -> Void)? = nil
    ) {
        self.configuration = configuration
        self.authorizer = authorizer
        self.session = session
        self.preparePlayer = preparePlayer ?? { try await player.prepare() }
        self.enqueuePlayer = enqueuePlayer ?? { data in try await player.enqueue(data) }
        self.finishPlayer = finishPlayer ?? { try await player.finish() }
        self.stopPlayer = stopPlayer
        self.cleanupWaitObserver = cleanupWaitObserver
    }

    public func speak(_ request: SpeechSynthesisRequest) async throws -> SpeechPlaybackMetrics {
        try cleanupFailures.requireNoPendingError()

        let generation = claimLifecycle(requestID: request.id)
        activeTask?.cancel()
        activeTask = nil
        let cleanupError = await awaitCleanupBarrier()
        if let cleanupWaitObserver { await cleanupWaitObserver(request.id) }
        do {
            try Task.checkCancellation()
            guard isCurrent(requestID: request.id, generation: generation) else {
                throw VoiceError.cancelled
            }
            try cleanupFailures.requireNoPendingError()
            if let cleanupError { throw cleanupError }
        } catch {
            clearLifecycleIfCurrent(requestID: request.id, generation: generation)
            if error is CancellationError { throw VoiceError.cancelled }
            throw error
        }

        let task = Task {
            try await performSpeech(request, generation: generation)
        }
        activeTask = task

        do {
            let metrics = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            guard isCurrent(requestID: request.id, generation: generation) else {
                throw VoiceError.cancelled
            }
            activeRequestID = nil
            activeTask = nil
            return metrics
        } catch {
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

    public func stop() async {
        _ = claimLifecycle(requestID: nil)
        activeRequestID = nil
        activeTask?.cancel()
        activeTask = nil
        _ = await awaitCleanupBarrier()
    }

    public func pendingAudioSessionError() -> VoiceError? {
        cleanupFailures.pendingError
    }

    func currentRequestID() -> UUID? {
        activeRequestID
    }

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

    private func awaitCleanupBarrier() async -> VoiceError? {
        let barrier: CleanupBarrier
        if let activeBarrier = cleanupBarrier {
            barrier = activeBarrier
        } else {
            let id = UUID()
            let stopPlayer = self.stopPlayer
            let task = Task { [weak self] in
                let error = await stopPlayer()
                await self?.completeCleanupBarrier(id: id, error: error)
                return error
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

    private func performSpeech(
        _ request: SpeechSynthesisRequest,
        generation: UInt64
    ) async throws -> SpeechPlaybackMetrics {
        try requireCurrent(requestID: request.id, generation: generation)
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

        let authorizedRequest = try await authorizer.authorize(unsignedRequest)
        try requireCurrent(requestID: request.id, generation: generation)
        try validateAuthorizedRequest(authorizedRequest, expectedBody: encodedBody)
        let started = ContinuousClock.now
        let (bytes, response) = try await session.bytes(
            for: authorizedRequest,
            delegate: NoRedirectTaskDelegate.shared
        )
        try requireCurrent(requestID: request.id, generation: generation)
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

        try await preparePlayer()
        try requireCurrent(requestID: request.id, generation: generation)
        var chunk = Data()
        chunk.reserveCapacity(1_920)
        var totalBytes = 0
        var firstBufferAt: ContinuousClock.Instant?

        for try await byte in bytes {
            try requireCurrent(requestID: request.id, generation: generation)
            chunk.append(byte)
            totalBytes += 1
            guard totalBytes <= 24_000_000 else {
                throw VoiceError.malformedPCMStream
            }
            if chunk.count == 1_920 {
                try await enqueuePlayer(chunk)
                try requireCurrent(requestID: request.id, generation: generation)
                if firstBufferAt == nil { firstBufferAt = .now }
                chunk.removeAll(keepingCapacity: true)
            }
        }
        if !chunk.isEmpty {
            guard chunk.count.isMultiple(of: 2) else { throw VoiceError.malformedPCMStream }
            try await enqueuePlayer(chunk)
            try requireCurrent(requestID: request.id, generation: generation)
            if firstBufferAt == nil { firstBufferAt = .now }
        }
        guard totalBytes > 0, let firstBufferAt else { throw VoiceError.malformedPCMStream }
        try await finishPlayer()
        try requireCurrent(requestID: request.id, generation: generation)

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
        if let voiceError = error as? VoiceError,
           case .audioSessionFailed = voiceError {
            return false
        }
        return !wasCurrent
            || parentTaskCancelled
            || error is CancellationError
            || error as? VoiceError == .cancelled
    }

    static func errorByAddingCleanupFailure(
        _ error: Error,
        cleanupError: VoiceError
    ) -> VoiceError {
        .audioSessionFailed(
            "\(error.localizedDescription); \(cleanupError.localizedDescription)"
        )
    }

    static func requireCleanStop(_ cleanupError: VoiceError?) throws {
        if let cleanupError {
            throw cleanupError
        }
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
