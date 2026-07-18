import AVFoundation
import Foundation

public struct PCMResampler: Sendable {
    public init() {}

    public func resampleTo16kMono(_ samples: [Float], sourceSampleRate: Double) throws -> [Float] {
        guard !samples.isEmpty,
              samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }),
              sourceSampleRate.isFinite,
              (8_000...192_000).contains(sourceSampleRate) else {
            throw VoiceError.invalidAudio
        }
        if sourceSampleRate == TranscriptionRequest.sampleRate { return samples }

        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceSampleRate,
            channels: 1,
            interleaved: false
        ),
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: TranscriptionRequest.sampleRate,
            channels: 1,
            interleaved: false
        ),
        let converter = AVAudioConverter(from: sourceFormat, to: targetFormat),
        let input = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw VoiceError.invalidAudio
        }

        input.frameLength = input.frameCapacity
        guard let inputChannel = input.floatChannelData?.pointee else { throw VoiceError.invalidAudio }
        try samples.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else { throw VoiceError.invalidAudio }
            inputChannel.update(from: baseAddress, count: samples.count)
        }

        let ratio = TranscriptionRequest.sampleRate / sourceSampleRate
        let outputCapacity = AVAudioFrameCount((Double(samples.count) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            throw VoiceError.invalidAudio
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .endOfStream
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error,
              conversionError == nil,
              let outputChannel = output.floatChannelData?.pointee else {
            throw VoiceError.invalidAudio
        }
        return Array(UnsafeBufferPointer(start: outputChannel, count: Int(output.frameLength)))
    }
}

public struct CapturedAudioAccumulator: Sendable {
    private let maximumSeconds: Double
    private var sampleRate: Double?
    private var samples: [Float] = []

    public init(maximumSeconds: Double = 30) throws {
        guard (1...30).contains(maximumSeconds) else { throw VoiceError.invalidAudio }
        self.maximumSeconds = maximumSeconds
    }

    public mutating func append(_ frame: MicrophoneFrame) throws {
        if let sampleRate, sampleRate != frame.sampleRate {
            throw VoiceError.audioSessionFailed("microphone sample rate changed during capture")
        }
        sampleRate = frame.sampleRate
        guard samples.count + frame.samples.count <= Int(frame.sampleRate * maximumSeconds) else {
            throw VoiceError.invalidAudio
        }
        samples.append(contentsOf: frame.samples)
    }

    public func transcriptionRequest(resampler: PCMResampler = PCMResampler()) throws -> TranscriptionRequest {
        guard let sampleRate else { throw VoiceError.invalidAudio }
        let resampled = try resampler.resampleTo16kMono(samples, sourceSampleRate: sampleRate)
        return try TranscriptionRequest(samples: resampled)
    }
}
