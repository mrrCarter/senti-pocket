import Foundation

public struct SpeechBenchmarkSample: Sendable {
    public let id: String
    public let request: TranscriptionRequest
    public let expectedTranscript: String

    public init(id: String, request: TranscriptionRequest, expectedTranscript: String) throws {
        let expected = expectedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.count <= 128, !expected.isEmpty, expected.count <= 4_000 else {
            throw VoiceError.invalidAudio
        }
        self.id = id
        self.request = request
        self.expectedTranscript = expected
    }
}

public struct SpeechBenchmarkResult: Codable, Equatable, Sendable {
    public let sampleId: String
    public let transcript: String
    public let expectedTranscript: String
    public let wordErrorRate: Double
    public let metrics: TranscriptionMetrics

    public init(
        sampleId: String,
        transcript: String,
        expectedTranscript: String,
        wordErrorRate: Double,
        metrics: TranscriptionMetrics
    ) {
        self.sampleId = sampleId
        self.transcript = transcript
        self.expectedTranscript = expectedTranscript
        self.wordErrorRate = wordErrorRate
        self.metrics = metrics
    }
}

public struct DeviceSpeechBenchmarkReport: Codable, Equatable, Sendable {
    public let measuredAt: Date
    public let deviceModel: String
    public let operatingSystem: String
    public let modelIdentifier: String
    public let modelLoad: SpeechModelMetrics
    public let results: [SpeechBenchmarkResult]
    public let meanWordErrorRate: Double
    public let residentMemoryBytes: UInt64?
    public let thermalState: VoiceThermalLevel

    public init(
        measuredAt: Date,
        deviceModel: String,
        operatingSystem: String,
        modelIdentifier: String,
        modelLoad: SpeechModelMetrics,
        results: [SpeechBenchmarkResult],
        meanWordErrorRate: Double,
        residentMemoryBytes: UInt64?,
        thermalState: VoiceThermalLevel
    ) {
        self.measuredAt = measuredAt
        self.deviceModel = deviceModel
        self.operatingSystem = operatingSystem
        self.modelIdentifier = modelIdentifier
        self.modelLoad = modelLoad
        self.results = results
        self.meanWordErrorRate = meanWordErrorRate
        self.residentMemoryBytes = residentMemoryBytes
        self.thermalState = thermalState
    }
}

public struct SpeechBenchmarkHarness: Sendable {
    public init() {}

    public func run(
        modelURL: URL,
        samples: [SpeechBenchmarkSample],
        recognizer: any SpeechRecognizer
    ) async throws -> DeviceSpeechBenchmarkReport {
        guard !samples.isEmpty, samples.count <= 100 else { throw VoiceError.invalidAudio }
        let modelLoad = try await recognizer.prepareModel(at: modelURL)
        var results: [SpeechBenchmarkResult] = []
        results.reserveCapacity(samples.count)

        for sample in samples {
            let result = try await recognizer.transcribe(sample.request)
            results.append(
                SpeechBenchmarkResult(
                    sampleId: sample.id,
                    transcript: result.text,
                    expectedTranscript: sample.expectedTranscript,
                    wordErrorRate: Self.wordErrorRate(
                        reference: sample.expectedTranscript,
                        hypothesis: result.text
                    ),
                    metrics: result.metrics
                )
            )
        }

        let mean = results.reduce(0.0) { $0 + $1.wordErrorRate } / Double(results.count)
        return DeviceSpeechBenchmarkReport(
            measuredAt: Date(),
            deviceModel: VoiceRuntimeSnapshot.deviceModel,
            operatingSystem: VoiceRuntimeSnapshot.operatingSystem,
            modelIdentifier: modelLoad.modelIdentifier,
            modelLoad: modelLoad,
            results: results,
            meanWordErrorRate: mean,
            residentMemoryBytes: VoiceRuntimeSnapshot.residentMemoryBytes,
            thermalState: VoiceRuntimeSnapshot.thermalLevel
        )
    }

    public static func wordErrorRate(reference: String, hypothesis: String) -> Double {
        let referenceWords = words(reference)
        let hypothesisWords = words(hypothesis)
        guard !referenceWords.isEmpty else { return hypothesisWords.isEmpty ? 0 : 1 }

        var previous = Array(0...hypothesisWords.count)
        for (referenceIndex, referenceWord) in referenceWords.enumerated() {
            var current = [referenceIndex + 1]
            current.reserveCapacity(hypothesisWords.count + 1)
            for (hypothesisIndex, hypothesisWord) in hypothesisWords.enumerated() {
                let substitutionCost = referenceWord == hypothesisWord ? 0 : 1
                current.append(
                    Swift.min(
                        Swift.min(
                            current[hypothesisIndex] + 1,
                            previous[hypothesisIndex + 1] + 1
                        ),
                        previous[hypothesisIndex] + substitutionCost
                    )
                )
            }
            previous = current
        }
        return Double(previous[hypothesisWords.count]) / Double(referenceWords.count)
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
