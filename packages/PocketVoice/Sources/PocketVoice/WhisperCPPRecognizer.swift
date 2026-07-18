import Foundation
import whisper

public actor WhisperCPPRecognizer: SpeechRecognizer {
    private let descriptor: WhisperModelDescriptor
    private let verifier: WhisperModelVerifier
    private var context: WhisperContextBox?
    private var preparationID: UUID?
    private var activeRun: WhisperRun?

    public init(
        descriptor: WhisperModelDescriptor = .baseEnglish,
        verifier: WhisperModelVerifier = WhisperModelVerifier()
    ) {
        self.descriptor = descriptor
        self.verifier = verifier
    }

    public func prepareModel(at modelURL: URL) async throws -> SpeechModelMetrics {
        guard activeRun == nil else { throw VoiceError.recognizerBusy }
        let currentPreparationID = UUID()
        preparationID = currentPreparationID
        defer {
            if preparationID == currentPreparationID { preparationID = nil }
        }

        let descriptor = self.descriptor
        let verifier = self.verifier
        let started = ContinuousClock.now
        let newContext = try await Task.detached(priority: .userInitiated) {
            let verifiedURL = try verifier.verify(modelURL, against: descriptor)
            return try WhisperContextBox.load(from: verifiedURL)
        }.value
        try Task.checkCancellation()

        guard preparationID == currentPreparationID else {
            throw VoiceError.cancelled
        }
        context = newContext
        return SpeechModelMetrics(
            modelIdentifier: descriptor.identifier,
            loadMilliseconds: started.duration(to: .now).voiceMilliseconds,
            residentMemoryBytes: VoiceRuntimeSnapshot.residentMemoryBytes,
            thermalState: VoiceRuntimeSnapshot.thermalLevel
        )
    }

    public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        guard preparationID == nil, let context else { throw VoiceError.modelNotPrepared }
        guard activeRun == nil else { throw VoiceError.recognizerBusy }

        let run = WhisperRun(id: UUID(), cancellation: CancellationFlag())
        activeRun = run
        let started = ContinuousClock.now

        do {
            let text = try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    try Self.runWhisper(context: context, request: request, cancellation: run.cancellation)
                }.value
            } onCancel: {
                run.cancellation.cancel()
            }

            if activeRun?.id == run.id { activeRun = nil }
            guard !run.cancellation.isCancelled else { throw VoiceError.cancelled }

            let elapsed = started.duration(to: .now).voiceMilliseconds
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { throw VoiceError.noSpeech }
            let audioDuration = request.durationSeconds
            return TranscriptionResult(
                text: normalized,
                metrics: TranscriptionMetrics(
                    audioDurationSeconds: audioDuration,
                    transcriptionMilliseconds: elapsed,
                    realTimeFactor: elapsed / 1_000 / audioDuration,
                    residentMemoryBytes: VoiceRuntimeSnapshot.residentMemoryBytes,
                    thermalState: VoiceRuntimeSnapshot.thermalLevel
                )
            )
        } catch {
            if activeRun?.id == run.id { activeRun = nil }
            if run.cancellation.isCancelled || error is CancellationError {
                throw VoiceError.cancelled
            }
            throw error
        }
    }

    public func cancel() async {
        activeRun?.cancellation.cancel()
    }

    private static func runWhisper(
        context: WhisperContextBox,
        request: TranscriptionRequest,
        cancellation: CancellationFlag
    ) throws -> String {
        var parameters = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        parameters.print_realtime = false
        parameters.print_progress = false
        parameters.print_timestamps = false
        parameters.print_special = false
        parameters.translate = false
        parameters.no_context = true
        parameters.single_segment = false
        parameters.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.processorCount - 2)))
        parameters.abort_callback = whisperCancellationCallback
        parameters.abort_callback_user_data = Unmanaged.passUnretained(cancellation).toOpaque()

        let result: Int32 = "en".withCString { language in
            parameters.language = language
            return request.samples.withUnsafeBufferPointer { samples in
                whisper_full(context.pointer, parameters, samples.baseAddress, Int32(samples.count))
            }
        }
        guard result == 0 else {
            if cancellation.isCancelled { throw VoiceError.cancelled }
            throw VoiceError.transcriptionFailed(result)
        }

        let count = whisper_full_n_segments(context.pointer)
        var segments: [String] = []
        segments.reserveCapacity(Int(max(0, count)))
        for index in 0..<count {
            guard let characters = whisper_full_get_segment_text(context.pointer, index) else { continue }
            let segment = String(cString: characters).trimmingCharacters(in: .whitespacesAndNewlines)
            if !segment.isEmpty { segments.append(segment) }
        }
        return segments.joined(separator: " ")
    }
}

private struct WhisperRun: Sendable {
    let id: UUID
    let cancellation: CancellationFlag
}

private final class WhisperContextBox: @unchecked Sendable {
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        whisper_free(pointer)
    }

    static func load(from modelURL: URL) throws -> WhisperContextBox {
        var parameters = whisper_context_default_params()
        #if targetEnvironment(simulator)
        parameters.use_gpu = false
        #else
        parameters.flash_attn = true
        #endif
        guard let pointer = whisper_init_from_file_with_params(modelURL.path, parameters) else {
            throw VoiceError.modelLoadFailed
        }
        return WhisperContextBox(pointer: pointer)
    }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}

private func whisperCancellationCallback(_ userData: UnsafeMutableRawPointer?) -> Bool {
    guard let userData else { return false }
    return Unmanaged<CancellationFlag>.fromOpaque(userData).takeUnretainedValue().isCancelled
}
