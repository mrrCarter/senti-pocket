import Foundation
import LiteRTLM
import PocketContracts

public actor LiteRTLMInferenceEngine: LocalInferenceEngine {
    private let modelIdentifier: String
    private let backend: InferenceBackend
    private let cacheDirectory: URL
    private let maximumTokens: Int
    private let promptBuilder: GroundedPromptBuilder
    private let answerDecoder: GroundedAnswerDecoder

    private var runtimeModelSnapshot: RuntimeModelSnapshot?
    private var engine: Engine?
    private var preparationID: UUID?
    private var benchmarkID: UUID?
    private var pendingAnswerID: UUID?
    private var activeRun: ActiveRun?
    private var stopReasons: [UUID: InferenceError] = [:]

    public init(
        modelIdentifier: String,
        backend: InferenceBackend = .gpu,
        cacheDirectory: URL,
        maximumTokens: Int = 8_192,
        promptBuilder: GroundedPromptBuilder = GroundedPromptBuilder(),
        answerDecoder: GroundedAnswerDecoder = GroundedAnswerDecoder()
    ) {
        self.modelIdentifier = modelIdentifier
        self.backend = backend
        self.cacheDirectory = cacheDirectory
        self.maximumTokens = maximumTokens
        self.promptBuilder = promptBuilder
        self.answerDecoder = answerDecoder
    }

    public func prepareModel(_ artifact: VerifiedModelArtifact) async throws -> ModelPreparationMetrics {
        guard preparationID == nil else {
            throw InferenceError.invalidRequest("model preparation is already in progress")
        }
        guard benchmarkID == nil else {
            throw InferenceError.invalidRequest("model preparation cannot overlap a benchmark")
        }
        let verifiedModelURL = artifact.url
        guard verifiedModelURL.isFileURL,
              verifiedModelURL.pathExtension == "litertlm",
              artifact.descriptor.identifier == modelIdentifier,
              verifiedModelURL.lastPathComponent == artifact.descriptor.fileName,
              FileManager.default.fileExists(atPath: verifiedModelURL.path) else {
            throw InferenceError.invalidRequest("verified model artifact does not match this engine")
        }
        guard !modelIdentifier.isEmpty, modelIdentifier.count <= 128 else {
            throw InferenceError.invalidRequest("modelIdentifier must contain 1...128 characters")
        }
        guard (2_048...32_768).contains(maximumTokens) else {
            throw InferenceError.invalidRequest("maximumTokens must be within 2048...32768")
        }
        guard cacheDirectory.isFileURL else {
            throw InferenceError.invalidRequest("cacheDirectory must be a local file URL")
        }

        supersedeActiveRun()
        supersedePendingAnswer()
        let currentPreparationID = UUID()
        preparationID = currentPreparationID
        defer {
            if preparationID == currentPreparationID { preparationID = nil }
        }

        let started = ContinuousClock.now
        try artifact.revalidate()
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let cacheValues = try cacheDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard cacheValues.isDirectory == true, cacheValues.isSymbolicLink != true else {
            throw InferenceError.invalidRequest("cacheDirectory must be a regular directory")
        }
        let runtimeSnapshot = try artifact.makeRuntimeSnapshot(in: cacheDirectory)
        let config = try EngineConfig(
            modelPath: runtimeSnapshot.url.path,
            backend: liteRTBackend,
            maxNumTokens: maximumTokens,
            cacheDir: cacheDirectory.path
        )
        let newEngine = Engine(engineConfig: config)
        try await newEngine.initialize()
        _ = try await newEngine.createConversation(with: conversationConfiguration())
        try Task.checkCancellation()
        try artifact.revalidate()

        guard preparationID == currentPreparationID else {
            throw InferenceError.superseded
        }

        engine = newEngine
        runtimeModelSnapshot = runtimeSnapshot

        return ModelPreparationMetrics(
            modelIdentifier: modelIdentifier,
            backend: backend,
            loadMilliseconds: started.duration(to: .now).pocketMilliseconds,
            residentMemoryBytes: DeviceRuntimeSnapshot.residentMemoryBytes,
            thermalState: DeviceRuntimeSnapshot.thermalLevel
        )
    }

    public func answer(_ request: GroundedInferenceRequest) async throws -> GroundedInferenceResult {
        guard preparationID == nil, let engine else { throw InferenceError.modelNotPrepared }
        guard benchmarkID == nil else {
            throw InferenceError.invalidRequest("inference cannot overlap a benchmark")
        }

        let prompt = try promptBuilder.build(for: request)
        guard prompt.text.utf8.count <= maximumTokens - 1_024 else {
            throw InferenceError.invalidRequest("prompt exceeds the model context budget")
        }
        let configuration = try conversationConfiguration()
        supersedeActiveRun()
        supersedePendingAnswer()
        let currentAnswerID = UUID()
        pendingAnswerID = currentAnswerID
        let conversation: Conversation
        do {
            conversation = try await engine.createConversation(with: configuration)
        } catch {
            if pendingAnswerID == currentAnswerID { pendingAnswerID = nil }
            if let stopReason = stopReasons.removeValue(forKey: currentAnswerID) {
                throw stopReason
            }
            if error is CancellationError || Task.isCancelled {
                throw InferenceError.cancelled
            }
            throw error
        }
        if Task.isCancelled {
            if pendingAnswerID == currentAnswerID { pendingAnswerID = nil }
            try? conversation.cancel()
            throw InferenceError.cancelled
        }
        if let stopReason = stopReasons.removeValue(forKey: currentAnswerID) {
            try? conversation.cancel()
            throw stopReason
        }
        guard pendingAnswerID == currentAnswerID else {
            try? conversation.cancel()
            throw InferenceError.superseded
        }
        pendingAnswerID = nil
        let generation = currentAnswerID
        activeRun = ActiveRun(id: generation, conversation: conversation)
        let started = ContinuousClock.now
        var firstTokenAt: ContinuousClock.Instant?
        var output = ""

        do {
            try await withTaskCancellationHandler {
                for try await chunk in conversation.sendMessageStream(Message(prompt.text)) {
                    try Task.checkCancellation()
                    if let stopReason = stopReasons[generation] { throw stopReason }
                    guard activeRun?.id == generation else { throw InferenceError.superseded }
                    if firstTokenAt == nil { firstTokenAt = .now }
                    output.append(chunk.toString)
                    guard output.utf8.count <= 16_384 else {
                        try conversation.cancel()
                        throw InferenceError.malformedModelOutput
                    }
                }
                try Task.checkCancellation()
                if let stopReason = stopReasons[generation] { throw stopReason }
                guard activeRun?.id == generation else { throw InferenceError.superseded }
            } onCancel: {
                Task { await self.cancel(generation: generation) }
            }
        } catch {
            let stopReason = finishRun(generation)
            if let stopReason { throw stopReason }
            if error is CancellationError || Task.isCancelled {
                try? conversation.cancel()
                throw InferenceError.cancelled
            }
            throw error
        }

        if let stopReason = finishRun(generation) { throw stopReason }
        guard let firstTokenAt else { throw InferenceError.malformedModelOutput }

        let data = Data(output.utf8)
        let questionAnswer = try answerDecoder.decode(
            data,
            checkpointId: request.checkpointId,
            question: request.question,
            allowedEvidenceIds: prompt.admittedEvidenceIds
        )
        guard !Task.isCancelled else { throw InferenceError.cancelled }
        let metrics = InferenceRunMetrics(
            timeToFirstTokenMilliseconds: started.duration(to: firstTokenAt).pocketMilliseconds,
            totalMilliseconds: started.duration(to: .now).pocketMilliseconds,
            outputCharacterCount: output.count,
            residentMemoryBytes: DeviceRuntimeSnapshot.residentMemoryBytes,
            thermalState: DeviceRuntimeSnapshot.thermalLevel
        )
        guard !Task.isCancelled else { throw InferenceError.cancelled }
        return GroundedInferenceResult(questionAnswer: questionAnswer, metrics: metrics)
    }

    public func cancel() async {
        if let pendingAnswerID {
            stopReasons[pendingAnswerID] = .cancelled
            self.pendingAnswerID = nil
        }
        guard let activeRun else { return }
        stopReasons[activeRun.id] = .cancelled
        self.activeRun = nil
        try? activeRun.conversation.cancel()
    }

    public func benchmark(prefillTokens: Int = 256, decodeTokens: Int = 128) async throws -> DeviceBenchmarkReport {
        guard let runtimeModelSnapshot else { throw InferenceError.modelNotPrepared }
        guard preparationID == nil, benchmarkID == nil, pendingAnswerID == nil, activeRun == nil else {
            throw InferenceError.invalidRequest("benchmark requires an idle engine")
        }
        guard (1...4_096).contains(prefillTokens), (1...1_024).contains(decodeTokens) else {
            throw InferenceError.invalidRequest("benchmark token counts are out of bounds")
        }

        let currentBenchmarkID = UUID()
        benchmarkID = currentBenchmarkID
        defer {
            if benchmarkID == currentBenchmarkID { benchmarkID = nil }
        }

        let info = try await LiteRTLMBenchmarkGate.shared.run(
            modelPath: runtimeModelSnapshot.url.path,
            backend: backend,
            prefillTokens: prefillTokens,
            decodeTokens: decodeTokens,
            cacheDir: cacheDirectory.path
        )
        try Task.checkCancellation()
        return DeviceBenchmarkReport(
            measuredAt: Date(),
            deviceModel: DeviceRuntimeSnapshot.deviceModel,
            operatingSystem: DeviceRuntimeSnapshot.operatingSystem,
            modelIdentifier: modelIdentifier,
            backend: backend,
            initializationSeconds: info.initializationSeconds,
            timeToFirstTokenSeconds: info.timeToFirstTokenSeconds,
            prefillTokenCount: info.prefillTokenCount,
            decodeTokenCount: info.decodeTokenCount,
            prefillTokensPerSecond: info.prefillTokensPerSecond,
            decodeTokensPerSecond: info.decodeTokensPerSecond,
            residentMemoryBytes: DeviceRuntimeSnapshot.residentMemoryBytes,
            thermalState: DeviceRuntimeSnapshot.thermalLevel
        )
    }

    private var liteRTBackend: Backend {
        switch backend {
        case .cpu: return .cpu()
        case .gpu: return .gpu
        }
    }

    private func conversationConfiguration() throws -> ConversationConfig {
        let sampler = try SamplerConfig(topK: 20, topP: 0.9, temperature: 0.1, seed: 0)
        return ConversationConfig(
            systemMessage: Message(
                "Answer from supplied checkpoint evidence only. Return strict JSON and never call tools.",
                role: .system
            ),
            tools: [],
            samplerConfig: sampler
        )
    }

    private func supersedeActiveRun() {
        guard let activeRun else { return }
        stopReasons[activeRun.id] = .superseded
        self.activeRun = nil
        try? activeRun.conversation.cancel()
    }

    private func supersedePendingAnswer() {
        guard let pendingAnswerID else { return }
        stopReasons[pendingAnswerID] = .superseded
        self.pendingAnswerID = nil
    }

    private func cancel(generation: UUID) {
        guard let activeRun, activeRun.id == generation else { return }
        stopReasons[generation] = .cancelled
        self.activeRun = nil
        try? activeRun.conversation.cancel()
    }

    private func finishRun(_ generation: UUID) -> InferenceError? {
        if activeRun?.id == generation { activeRun = nil }
        return stopReasons.removeValue(forKey: generation)
    }
}

private struct ActiveRun {
    let id: UUID
    let conversation: Conversation
}

private struct BenchmarkSnapshot: Sendable {
    let initializationSeconds: Double
    let timeToFirstTokenSeconds: Double
    let prefillTokenCount: Int
    let decodeTokenCount: Int
    let prefillTokensPerSecond: Double
    let decodeTokensPerSecond: Double
}

private actor LiteRTLMBenchmarkGate {
    static let shared = LiteRTLMBenchmarkGate()

    func run(
        modelPath: String,
        backend: InferenceBackend,
        prefillTokens: Int,
        decodeTokens: Int,
        cacheDir: String
    ) async throws -> BenchmarkSnapshot {
        let liteBackend: Backend
        switch backend {
        case .cpu: liteBackend = .cpu()
        case .gpu: liteBackend = .gpu
        }
        let info = try await LiteRTLM.benchmark(
            modelPath: modelPath,
            backend: liteBackend,
            prefillTokens: prefillTokens,
            decodeTokens: decodeTokens,
            cacheDir: cacheDir
        )
        return BenchmarkSnapshot(
            initializationSeconds: info.initTimeInSecond,
            timeToFirstTokenSeconds: info.timeToFirstTokenInSecond,
            prefillTokenCount: info.lastPrefillTokenCount,
            decodeTokenCount: info.lastDecodeTokenCount,
            prefillTokensPerSecond: info.lastPrefillTokensPerSecond,
            decodeTokensPerSecond: info.lastDecodeTokensPerSecond
        )
    }
}
