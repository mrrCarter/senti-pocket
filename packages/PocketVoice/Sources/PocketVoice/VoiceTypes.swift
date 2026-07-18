import Foundation
import PocketContracts

public protocol SpeechRecognizer: Sendable {
    func prepareModel(at modelURL: URL) async throws -> SpeechModelMetrics
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult
    func cancel() async
}

public protocol SpeechSynthesizer: Sendable {
    func speak(_ request: SpeechSynthesisRequest) async throws -> SpeechPlaybackMetrics
    func stop() async
}

public protocol BargeInController: Sendable {
    func arm(_ target: VoiceInterruptionTarget) async
    func speechStarted() async -> VoiceInterruptionReceipt?
    func stop() async -> VoiceInterruptionReceipt?
    func hold() async -> VoiceInterruptionReceipt?
    func disarm() async
}

public struct MicrophoneFrame: Sendable {
    public let samples: [Float]
    public let sampleRate: Double
    public let capturedAt: Date

    public init(samples: [Float], sampleRate: Double, capturedAt: Date = Date()) throws {
        guard !samples.isEmpty,
              samples.count <= 16_384,
              samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }),
              sampleRate.isFinite,
              (8_000...192_000).contains(sampleRate) else {
            throw VoiceError.invalidAudio
        }
        self.samples = samples
        self.sampleRate = sampleRate
        self.capturedAt = capturedAt
    }
}

public struct TranscriptionRequest: Sendable {
    public static let sampleRate: Double = 16_000
    public static let maximumSampleCount = 16_000 * 30

    public let samples: [Float]

    public init(samples: [Float]) throws {
        guard (1_600...Self.maximumSampleCount).contains(samples.count),
              samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else {
            throw VoiceError.invalidAudio
        }
        self.samples = samples
    }

    public var durationSeconds: Double {
        Double(samples.count) / Self.sampleRate
    }
}

public struct TranscriptionResult: Codable, Equatable, Sendable {
    public let text: String
    public let metrics: TranscriptionMetrics

    public init(text: String, metrics: TranscriptionMetrics) {
        self.text = text
        self.metrics = metrics
    }
}

public struct SpeechModelMetrics: Codable, Equatable, Sendable {
    public let modelIdentifier: String
    public let loadMilliseconds: Double
    public let residentMemoryBytes: UInt64?
    public let thermalState: VoiceThermalLevel

    public init(
        modelIdentifier: String,
        loadMilliseconds: Double,
        residentMemoryBytes: UInt64?,
        thermalState: VoiceThermalLevel
    ) {
        self.modelIdentifier = modelIdentifier
        self.loadMilliseconds = loadMilliseconds
        self.residentMemoryBytes = residentMemoryBytes
        self.thermalState = thermalState
    }
}

public struct TranscriptionMetrics: Codable, Equatable, Sendable {
    public let audioDurationSeconds: Double
    public let transcriptionMilliseconds: Double
    public let realTimeFactor: Double
    public let residentMemoryBytes: UInt64?
    public let thermalState: VoiceThermalLevel

    public init(
        audioDurationSeconds: Double,
        transcriptionMilliseconds: Double,
        realTimeFactor: Double,
        residentMemoryBytes: UInt64?,
        thermalState: VoiceThermalLevel
    ) {
        self.audioDurationSeconds = audioDurationSeconds
        self.transcriptionMilliseconds = transcriptionMilliseconds
        self.realTimeFactor = realTimeFactor
        self.residentMemoryBytes = residentMemoryBytes
        self.thermalState = thermalState
    }
}

public struct SpeechSynthesisRequest: Sendable, Equatable {
    public let id: UUID
    public let text: String
    public let tone: BriefingTone
    public let localeIdentifier: String

    public init(
        id: UUID = UUID(),
        text: String,
        tone: BriefingTone = .neutral,
        localeIdentifier: String = "en-US"
    ) throws {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty,
              trimmedText.count <= 4_000,
              !localeIdentifier.isEmpty,
              localeIdentifier.count <= 32 else {
            throw VoiceError.invalidSpeechRequest
        }
        self.id = id
        self.text = trimmedText
        self.tone = tone
        self.localeIdentifier = localeIdentifier
    }
}

public struct SpeechPlaybackMetrics: Codable, Equatable, Sendable {
    public let backend: SpeechSynthesisBackend
    public let firstAudioMeasurement: FirstAudioMeasurement
    public let firstAudioMilliseconds: Double
    public let totalMilliseconds: Double
    public let characterCount: Int
    public let residentMemoryBytes: UInt64?
    public let thermalState: VoiceThermalLevel

    public init(
        backend: SpeechSynthesisBackend,
        firstAudioMeasurement: FirstAudioMeasurement,
        firstAudioMilliseconds: Double,
        totalMilliseconds: Double,
        characterCount: Int,
        residentMemoryBytes: UInt64?,
        thermalState: VoiceThermalLevel
    ) {
        self.backend = backend
        self.firstAudioMeasurement = firstAudioMeasurement
        self.firstAudioMilliseconds = firstAudioMilliseconds
        self.totalMilliseconds = totalMilliseconds
        self.characterCount = characterCount
        self.residentMemoryBytes = residentMemoryBytes
        self.thermalState = thermalState
    }
}

public enum SpeechSynthesisBackend: String, Codable, Equatable, Sendable {
    case avSpeechOffline
    case elevenLabsGateway
}

public enum FirstAudioMeasurement: String, Codable, Equatable, Sendable {
    case avSpeechDidStartCallback
    case pcmFirstBufferScheduled
}

public enum VoiceThermalLevel: String, Codable, Equatable, Sendable {
    case nominal
    case fair
    case serious
    case critical
    case unavailable
}

public enum VoiceInterruptionReason: String, Codable, Equatable, Sendable {
    case speechStarted
    case stop
    case hold
    case superseded
}

public struct VoiceInterruptionTarget: Sendable {
    public let id: UUID
    public let stopSpeech: @Sendable () async -> Void
    public let cancelInference: @Sendable () async -> Void

    public init(
        id: UUID,
        stopSpeech: @escaping @Sendable () async -> Void,
        cancelInference: @escaping @Sendable () async -> Void
    ) {
        self.id = id
        self.stopSpeech = stopSpeech
        self.cancelInference = cancelInference
    }
}

public struct VoiceInterruptionReceipt: Codable, Equatable, Sendable {
    public let targetId: UUID
    public let reason: VoiceInterruptionReason
    public let completedAt: Date
    public let interruptionMilliseconds: Double

    public init(
        targetId: UUID,
        reason: VoiceInterruptionReason,
        completedAt: Date,
        interruptionMilliseconds: Double
    ) {
        self.targetId = targetId
        self.reason = reason
        self.completedAt = completedAt
        self.interruptionMilliseconds = interruptionMilliseconds
    }
}

public enum VoiceError: Error, Equatable, Sendable {
    case invalidAudio
    case invalidSpeechRequest
    case modelNotPrepared
    case modelVerificationFailed
    case modelLoadFailed
    case recognizerBusy
    case cancelled
    case noSpeech
    case transcriptionFailed(Int32)
    case microphonePermissionDenied
    case audioSessionFailed(String)
    case synthesisFailed(String)
    case insecureGateway
    case gatewayRejected(Int)
    case malformedPCMStream
}

extension VoiceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidAudio: return "Audio must be finite 16 kHz mono PCM lasting 0.1...30 seconds"
        case .invalidSpeechRequest: return "Speech text or locale is invalid"
        case .modelNotPrepared: return "The speech model is not prepared"
        case .modelVerificationFailed: return "The speech model failed integrity verification"
        case .modelLoadFailed: return "whisper.cpp could not load the speech model"
        case .recognizerBusy: return "The speech recognizer is already running"
        case .cancelled: return "Voice processing was cancelled"
        case .noSpeech: return "No speech was recognized"
        case .transcriptionFailed(let code): return "whisper.cpp transcription failed with code \(code)"
        case .microphonePermissionDenied: return "Microphone permission was denied"
        case .audioSessionFailed(let reason): return "Audio session failed: \(reason)"
        case .synthesisFailed(let reason): return "Speech synthesis failed: \(reason)"
        case .insecureGateway: return "Premium speech requires an approved HTTPS gateway"
        case .gatewayRejected(let status): return "Premium speech gateway rejected the request with HTTP \(status)"
        case .malformedPCMStream: return "Premium speech returned malformed PCM audio"
        }
    }
}
