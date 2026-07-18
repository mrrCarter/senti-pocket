import Foundation

public struct VoiceActivityConfiguration: Equatable, Sendable {
    public let speechStartRMS: Float
    public let speechEndRMS: Float
    public let attackMilliseconds: Double
    public let releaseMilliseconds: Double

    public init(
        speechStartRMS: Float = 0.025,
        speechEndRMS: Float = 0.015,
        attackMilliseconds: Double = 80,
        releaseMilliseconds: Double = 280
    ) throws {
        guard speechStartRMS.isFinite,
              speechEndRMS.isFinite,
              speechStartRMS > speechEndRMS,
              speechStartRMS <= 1,
              speechEndRMS >= 0,
              (20...1_000).contains(attackMilliseconds),
              (40...3_000).contains(releaseMilliseconds) else {
            throw VoiceError.invalidAudio
        }
        self.speechStartRMS = speechStartRMS
        self.speechEndRMS = speechEndRMS
        self.attackMilliseconds = attackMilliseconds
        self.releaseMilliseconds = releaseMilliseconds
    }
}

public enum VoiceActivityState: String, Codable, Equatable, Sendable {
    case silence
    case speech
}

public enum VoiceActivityTransition: String, Codable, Equatable, Sendable {
    case speechStarted
    case speechEnded
}

public struct VoiceActivityUpdate: Equatable, Sendable {
    public let state: VoiceActivityState
    public let transition: VoiceActivityTransition?
    public let rms: Float

    public init(state: VoiceActivityState, transition: VoiceActivityTransition?, rms: Float) {
        self.state = state
        self.transition = transition
        self.rms = rms
    }
}

public struct EnergyVoiceActivityDetector: Sendable {
    public private(set) var state: VoiceActivityState = .silence

    private let configuration: VoiceActivityConfiguration
    private var sampleRate: Double?
    private var attackSamples = 0
    private var releaseSamples = 0

    public init(configuration: VoiceActivityConfiguration) {
        self.configuration = configuration
    }

    public mutating func process(samples: [Float], sampleRate: Double) throws -> VoiceActivityUpdate {
        guard !samples.isEmpty,
              sampleRate.isFinite,
              (8_000...192_000).contains(sampleRate),
              samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else {
            throw VoiceError.invalidAudio
        }
        if let currentSampleRate = self.sampleRate, currentSampleRate != sampleRate {
            reset()
            throw VoiceError.invalidAudio
        }
        self.sampleRate = sampleRate

        let rms = rootMeanSquare(samples)
        var transition: VoiceActivityTransition?

        switch state {
        case .silence:
            releaseSamples = 0
            if rms >= configuration.speechStartRMS {
                attackSamples += samples.count
                if attackSamples >= requiredSamples(configuration.attackMilliseconds, sampleRate: sampleRate) {
                    state = .speech
                    attackSamples = 0
                    transition = .speechStarted
                }
            } else {
                attackSamples = 0
            }

        case .speech:
            attackSamples = 0
            if rms <= configuration.speechEndRMS {
                releaseSamples += samples.count
                if releaseSamples >= requiredSamples(configuration.releaseMilliseconds, sampleRate: sampleRate) {
                    state = .silence
                    releaseSamples = 0
                    transition = .speechEnded
                }
            } else {
                releaseSamples = 0
            }
        }

        return VoiceActivityUpdate(state: state, transition: transition, rms: rms)
    }

    public mutating func reset() {
        state = .silence
        sampleRate = nil
        attackSamples = 0
        releaseSamples = 0
    }

    private func requiredSamples(_ milliseconds: Double, sampleRate: Double) -> Int {
        Int((milliseconds / 1_000 * sampleRate).rounded(.up))
    }

    private func rootMeanSquare(_ samples: [Float]) -> Float {
        let sum = samples.reduce(0.0) { partial, sample in
            partial + Double(sample * sample)
        }
        return Float((sum / Double(samples.count)).squareRoot())
    }
}
