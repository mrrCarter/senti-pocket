import Foundation

public actor DeterministicBargeInController: BargeInController {
    private enum State {
        case idle
        case armed(VoiceInterruptionTarget)
    }

    private var state: State = .idle

    public init() {}

    public func arm(_ target: VoiceInterruptionTarget) async {
        let superseded: VoiceInterruptionTarget?
        if case .armed(let current) = state, current.id != target.id {
            superseded = current
        } else {
            superseded = nil
        }

        // Publish the newest target before awaiting cleanup of the old one. A concurrent re-arm can no longer
        // be overwritten when this suspension resumes.
        state = .armed(target)
        if let superseded {
            _ = await interruptTarget(superseded, reason: .superseded)
        }
    }

    public func speechStarted() async -> VoiceInterruptionReceipt? {
        await interrupt(reason: .speechStarted)
    }

    public func stop() async -> VoiceInterruptionReceipt? {
        await interrupt(reason: .stop)
    }

    public func hold() async -> VoiceInterruptionReceipt? {
        await interrupt(reason: .hold)
    }

    public func disarm() async {
        state = .idle
    }

    private func interrupt(reason: VoiceInterruptionReason) async -> VoiceInterruptionReceipt? {
        guard case .armed(let target) = state else { return nil }

        // The state changes before either async callback runs, making duplicate speech/Stop events idempotent.
        state = .idle
        return await interruptTarget(target, reason: reason)
    }

    private func interruptTarget(
        _ target: VoiceInterruptionTarget,
        reason: VoiceInterruptionReason
    ) async -> VoiceInterruptionReceipt {
        let started = ContinuousClock.now

        async let stopSpeech: Void = target.stopSpeech()
        async let cancelInference: Void = target.cancelInference()
        _ = await (stopSpeech, cancelInference)

        return VoiceInterruptionReceipt(
            targetId: target.id,
            reason: reason,
            completedAt: Date(),
            interruptionMilliseconds: started.duration(to: .now).voiceMilliseconds
        )
    }
}
