import Foundation
import PocketCall
import PocketContracts

public protocol LocalInferenceEngine: Sendable {
    func prepareModel(_ artifact: VerifiedModelArtifact) async throws -> ModelPreparationMetrics
    func answer(_ request: GroundedInferenceRequest) async throws -> GroundedInferenceResult
    func cancel() async
    func benchmark(prefillTokens: Int, decodeTokens: Int) async throws -> DeviceBenchmarkReport
}

public struct GroundedInferenceRequest: Sendable {
    public static let maximumEvidenceCount = 32

    public let checkpointId: String
    public let sessionId: String
    public let sequenceStart: Int
    public let sequenceEnd: Int
    public let question: String
    public let evidence: [EvidenceRef]

    public init(verifiedBundle: VerifiedBundle, question: String, evidence: [EvidenceRef]? = nil) throws {
        try self.init(bundle: verifiedBundle.bundle, question: question, evidence: evidence)
    }

    init(bundle: PocketBundle, question: String, evidence: [EvidenceRef]? = nil) throws {
        let selectedEvidence = evidence ?? Self.defaultEvidenceSelection(from: bundle.evidence)
        guard selectedEvidence.allSatisfy(bundle.evidence.contains) else {
            throw InferenceError.invalidRequest("evidence must be an exact subset of the supplied bundle")
        }
        try self.init(
            checkpointId: bundle.checkpointId,
            sessionId: bundle.sessionId,
            sequenceStart: bundle.sequenceStart,
            sequenceEnd: bundle.sequenceEnd,
            question: question,
            evidence: selectedEvidence
        )
    }

    init(
        checkpointId: String,
        sessionId: String,
        sequenceStart: Int,
        sequenceEnd: Int,
        question: String,
        evidence: [EvidenceRef]
    ) throws {
        let trimmedCheckpointId = checkpointId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCheckpointId.isEmpty, trimmedCheckpointId.utf8.count <= 256 else {
            throw InferenceError.invalidRequest("checkpointId must contain 1...256 UTF-8 bytes")
        }
        guard !trimmedSessionId.isEmpty, trimmedSessionId.utf8.count <= 256 else {
            throw InferenceError.invalidRequest("sessionId must contain 1...256 UTF-8 bytes")
        }
        guard sequenceStart > 0, sequenceEnd >= sequenceStart else {
            throw InferenceError.invalidRequest("checkpoint sequence range is invalid")
        }
        guard !trimmedQuestion.isEmpty, trimmedQuestion.utf8.count <= 2_000 else {
            throw InferenceError.invalidRequest("question must contain 1...2000 UTF-8 bytes")
        }
        guard !evidence.isEmpty, evidence.count <= Self.maximumEvidenceCount else {
            throw InferenceError.invalidRequest("evidence must contain 1...\(Self.maximumEvidenceCount) entries")
        }

        var evidenceIds = Set<String>()
        for item in evidence {
            guard !item.id.isEmpty,
                  item.id.utf8.count <= 128,
                  !item.agentId.isEmpty,
                  item.agentId.utf8.count <= 128,
                  item.sessionId == trimmedSessionId,
                  item.sequence > 0,
                  (sequenceStart...sequenceEnd).contains(item.sequence),
                  !item.snippet.isEmpty,
                  item.snippet.utf8.count <= 8_000 else {
                throw InferenceError.invalidRequest("evidence entries must be bounded and belong to the checkpoint session and sequence range")
            }
            guard evidenceIds.insert(item.id).inserted else {
                throw InferenceError.invalidRequest("evidence IDs must be unique")
            }
        }

        self.checkpointId = trimmedCheckpointId
        self.sessionId = trimmedSessionId
        self.sequenceStart = sequenceStart
        self.sequenceEnd = sequenceEnd
        self.question = trimmedQuestion
        self.evidence = evidence
    }

    private static func defaultEvidenceSelection(from evidence: [EvidenceRef]) -> [EvidenceRef] {
        let ordered = evidence.sorted { lhs, rhs in
            if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
            if lhs.ts != rhs.ts { return lhs.ts < rhs.ts }
            if lhs.agentId != rhs.agentId { return lhs.agentId < rhs.agentId }
            return lhs.id < rhs.id
        }
        return Array(ordered.suffix(Self.maximumEvidenceCount))
    }
}

public struct GroundedInferenceResult: Sendable {
    public let questionAnswer: QuestionAnswer
    public let metrics: InferenceRunMetrics

    public init(questionAnswer: QuestionAnswer, metrics: InferenceRunMetrics) {
        self.questionAnswer = questionAnswer
        self.metrics = metrics
    }
}

public struct ModelPreparationMetrics: Codable, Equatable, Sendable {
    public let modelIdentifier: String
    public let backend: InferenceBackend
    public let loadMilliseconds: Double
    public let residentMemoryBytes: UInt64?
    public let thermalState: ThermalLevel

    public init(
        modelIdentifier: String,
        backend: InferenceBackend,
        loadMilliseconds: Double,
        residentMemoryBytes: UInt64?,
        thermalState: ThermalLevel
    ) {
        self.modelIdentifier = modelIdentifier
        self.backend = backend
        self.loadMilliseconds = loadMilliseconds
        self.residentMemoryBytes = residentMemoryBytes
        self.thermalState = thermalState
    }
}

public struct InferenceRunMetrics: Codable, Equatable, Sendable {
    public let timeToFirstTokenMilliseconds: Double
    public let totalMilliseconds: Double
    public let outputCharacterCount: Int
    public let residentMemoryBytes: UInt64?
    public let thermalState: ThermalLevel

    public init(
        timeToFirstTokenMilliseconds: Double,
        totalMilliseconds: Double,
        outputCharacterCount: Int,
        residentMemoryBytes: UInt64?,
        thermalState: ThermalLevel
    ) {
        self.timeToFirstTokenMilliseconds = timeToFirstTokenMilliseconds
        self.totalMilliseconds = totalMilliseconds
        self.outputCharacterCount = outputCharacterCount
        self.residentMemoryBytes = residentMemoryBytes
        self.thermalState = thermalState
    }
}

public struct DeviceBenchmarkReport: Codable, Equatable, Sendable {
    public let measuredAt: Date
    public let deviceModel: String
    public let operatingSystem: String
    public let modelIdentifier: String
    public let backend: InferenceBackend
    public let initializationSeconds: Double
    public let timeToFirstTokenSeconds: Double
    public let prefillTokenCount: Int
    public let decodeTokenCount: Int
    public let prefillTokensPerSecond: Double
    public let decodeTokensPerSecond: Double
    public let residentMemoryBytes: UInt64?
    public let thermalState: ThermalLevel

    public init(
        measuredAt: Date,
        deviceModel: String,
        operatingSystem: String,
        modelIdentifier: String,
        backend: InferenceBackend,
        initializationSeconds: Double,
        timeToFirstTokenSeconds: Double,
        prefillTokenCount: Int,
        decodeTokenCount: Int,
        prefillTokensPerSecond: Double,
        decodeTokensPerSecond: Double,
        residentMemoryBytes: UInt64?,
        thermalState: ThermalLevel
    ) {
        self.measuredAt = measuredAt
        self.deviceModel = deviceModel
        self.operatingSystem = operatingSystem
        self.modelIdentifier = modelIdentifier
        self.backend = backend
        self.initializationSeconds = initializationSeconds
        self.timeToFirstTokenSeconds = timeToFirstTokenSeconds
        self.prefillTokenCount = prefillTokenCount
        self.decodeTokenCount = decodeTokenCount
        self.prefillTokensPerSecond = prefillTokensPerSecond
        self.decodeTokensPerSecond = decodeTokensPerSecond
        self.residentMemoryBytes = residentMemoryBytes
        self.thermalState = thermalState
    }
}

public enum InferenceBackend: String, Codable, Equatable, Sendable {
    case cpu
    case gpu
}

public enum ThermalLevel: String, Codable, Equatable, Sendable {
    case nominal
    case fair
    case serious
    case critical
    case unavailable
}

public enum InferenceError: Error, Equatable, Sendable {
    case invalidRequest(String)
    case modelNotPrepared
    case superseded
    case cancelled
    case malformedModelOutput
    case unsupportedModelOutputField(String)
    case ungroundedAnswer
    case unknownCitation(String)
    case duplicateCitation(String)
}

extension InferenceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let reason): return "Invalid inference request: \(reason)"
        case .modelNotPrepared: return "The local model is not prepared"
        case .superseded: return "The inference run was superseded"
        case .cancelled: return "The inference run was cancelled"
        case .malformedModelOutput: return "The local model returned malformed JSON"
        case .unsupportedModelOutputField(let field): return "Unsupported model output field: \(field)"
        case .ungroundedAnswer: return "The answer is not grounded in checkpoint evidence"
        case .unknownCitation(let id): return "The answer cited unknown evidence: \(id)"
        case .duplicateCitation(let id): return "The answer cited evidence more than once: \(id)"
        }
    }
}
