import Foundation
import PocketVoice
import XCTest

final class DeterministicBargeInControllerTests: XCTestCase {
    func testSpeechStartStopsSpeechAndInferenceExactlyOnce() async {
        let calls = CallCounter()
        let controller = DeterministicBargeInController()
        let targetId = UUID()
        await controller.arm(
            VoiceInterruptionTarget(
                id: targetId,
                stopSpeech: { await calls.recordSpeechStop() },
                cancelInference: { await calls.recordInferenceCancel() }
            )
        )

        async let first = controller.speechStarted()
        async let duplicate = controller.speechStarted()
        let (firstReceipt, duplicateReceipt) = await (first, duplicate)
        let receipts = [firstReceipt, duplicateReceipt].compactMap { $0 }
        let speechStops = await calls.speechStops
        let inferenceCancels = await calls.inferenceCancels

        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts.first?.targetId, targetId)
        XCTAssertEqual(receipts.first?.reason, .speechStarted)
        XCTAssertEqual(speechStops, 1)
        XCTAssertEqual(inferenceCancels, 1)
    }

    func testStopIsIdempotentAfterInterrupt() async {
        let calls = CallCounter()
        let controller = DeterministicBargeInController()
        await controller.arm(
            VoiceInterruptionTarget(
                id: UUID(),
                stopSpeech: { await calls.recordSpeechStop() },
                cancelInference: { await calls.recordInferenceCancel() }
            )
        )

        let firstReceipt = await controller.stop()
        let secondReceipt = await controller.stop()
        let speechStops = await calls.speechStops
        let inferenceCancels = await calls.inferenceCancels

        XCTAssertNotNil(firstReceipt)
        XCTAssertNil(secondReceipt)
        XCTAssertEqual(speechStops, 1)
        XCTAssertEqual(inferenceCancels, 1)
    }

    func testSuspendedSupersessionCannotOverwriteNewerArm() async {
        let oldStop = AsyncLatch()
        let controller = DeterministicBargeInController()
        let firstId = UUID()
        let secondId = UUID()
        let newestId = UUID()

        await controller.arm(
            VoiceInterruptionTarget(
                id: firstId,
                stopSpeech: { await oldStop.suspend() },
                cancelInference: {}
            )
        )
        let secondArm = Task {
            await controller.arm(
                VoiceInterruptionTarget(
                    id: secondId,
                    stopSpeech: {},
                    cancelInference: {}
                )
            )
        }
        await oldStop.waitUntilStarted()

        await controller.arm(
            VoiceInterruptionTarget(
                id: newestId,
                stopSpeech: {},
                cancelInference: {}
            )
        )
        await oldStop.release()
        await secondArm.value

        let receipt = await controller.stop()
        XCTAssertEqual(receipt?.targetId, newestId)
    }
}

private actor CallCounter {
    private(set) var speechStops = 0
    private(set) var inferenceCancels = 0

    func recordSpeechStop() { speechStops += 1 }
    func recordInferenceCancel() { inferenceCancels += 1 }
}

private actor AsyncLatch {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
