import Foundation
import XCTest
@testable import PocketVoice

final class AVSpeechSynthesizerAdapterTests: XCTestCase {
    func testStopInvalidatesSpeechWaitingForInitialDriverResolution() async throws {
        let driver = ControlledAVSpeechDriver()
        let provider = ControlledAVSpeechDriverProvider(driver: driver)
        let driverTask = Task<any AVSpeechDriving, Never> { await provider.value() }
        let synthesizer = AVSpeechSynthesizerAdapter(driverTask: driverTask)
        let request = try SpeechSynthesisRequest(text: "must remain stopped")

        let speech = Task { try await synthesizer.speak(request) }
        try await waitForCurrentRequest(request.id, on: synthesizer)
        let stop = Task { await synthesizer.stop() }
        try await waitForCurrentRequest(nil, on: synthesizer)

        await provider.resolve()
        try await driver.waitForStopCallCount(1)
        await driver.resumeNextStop()
        await stop.value
        do {
            _ = try await speech.value
            XCTFail("a later stop must invalidate speech waiting for the driver")
        } catch {
            XCTAssertEqual(error as? VoiceError, .cancelled)
        }
        let startedRequestIDs = await driver.startedRequestIDs()
        XCTAssertTrue(startedRequestIDs.isEmpty)
    }

    func testSpeechJoinsPublicStopBarrierBeforeStarting() async throws {
        let driver = ControlledAVSpeechDriver()
        let synthesizer = AVSpeechSynthesizerAdapter(driver: driver)
        let request = try SpeechSynthesisRequest(text: "after stop")

        let stop = Task { await synthesizer.stop() }
        try await driver.waitForStopCallCount(1)
        let speech = Task { try await synthesizer.speak(request) }
        try await waitForCurrentRequest(request.id, on: synthesizer)
        let startedBeforeStop = await driver.startedRequestIDs()
        XCTAssertTrue(startedBeforeStop.isEmpty)

        await driver.resumeNextStop()
        await stop.value
        try await driver.waitForSpeechCallCount(1)
        let stopCallCount = await driver.currentStopCallCount()
        XCTAssertEqual(stopCallCount, 1)

        await driver.resumeSpeech(
            requestID: request.id,
            with: .success(
                AVSpeechTiming(firstAudioMilliseconds: 1, totalMilliseconds: 2)
            )
        )
        let metrics = try await speech.value
        XCTAssertEqual(metrics.characterCount, request.text.count)
    }

    func testSpeechOrdersBehindPublicStopWaitingForDriverResolution() async throws {
        let driver = ControlledAVSpeechDriver()
        let provider = ControlledAVSpeechDriverProvider(driver: driver)
        let driverTask = Task<any AVSpeechDriving, Never> { await provider.value() }
        let synthesizer = AVSpeechSynthesizerAdapter(driverTask: driverTask)
        let request = try SpeechSynthesisRequest(text: "after unresolved stop")

        let stop = Task { await synthesizer.stop() }
        try await waitForStoppingState(on: synthesizer)
        let speech = Task { try await synthesizer.speak(request) }
        try await waitForCurrentRequest(request.id, on: synthesizer)

        await provider.resolve()
        try await driver.waitForStopCallCount(1)
        let startedBeforeStop = await driver.startedRequestIDs()
        XCTAssertTrue(startedBeforeStop.isEmpty)

        await driver.resumeNextStop()
        await stop.value
        try await driver.waitForSpeechCallCount(1)
        let startedAfterStop = await driver.startedRequestIDs()
        XCTAssertEqual(startedAfterStop, [request.id])

        await driver.resumeSpeech(
            requestID: request.id,
            with: .success(
                AVSpeechTiming(firstAudioMilliseconds: 1, totalMilliseconds: 2)
            )
        )
        _ = try await speech.value
    }

    func testOnlyLatestSupersederStartsAfterOverlappingDriverStops() async throws {
        let driver = ControlledAVSpeechDriver()
        let synthesizer = AVSpeechSynthesizerAdapter(driver: driver)
        let firstRequest = try SpeechSynthesisRequest(text: "first")
        let secondRequest = try SpeechSynthesisRequest(text: "second")
        let thirdRequest = try SpeechSynthesisRequest(text: "third")

        let first = Task { try await synthesizer.speak(firstRequest) }
        try await driver.waitForSpeechCallCount(1)

        let second = Task { try await synthesizer.speak(secondRequest) }
        try await driver.waitForStopCallCount(1)
        let third = Task { try await synthesizer.speak(thirdRequest) }
        try await waitForCurrentRequest(thirdRequest.id, on: synthesizer)
        let sharedStopCallCount = await driver.currentStopCallCount()
        XCTAssertEqual(sharedStopCallCount, 1)

        await driver.resumeNextStop()
        do {
            _ = try await second.value
            XCTFail("an older superseder must not start after its stop suspension")
        } catch {
            XCTAssertEqual(error as? VoiceError, .cancelled)
        }

        try await driver.waitForSpeechCallCount(2)
        let startedRequestIDs = await driver.startedRequestIDs()
        let stopCallCount = await driver.currentStopCallCount()
        XCTAssertEqual(startedRequestIDs, [firstRequest.id, thirdRequest.id])
        XCTAssertEqual(stopCallCount, 1)

        await driver.resumeSpeech(
            requestID: firstRequest.id,
            with: .failure(VoiceError.cancelled)
        )
        do {
            _ = try await first.value
            XCTFail("the original request must be superseded")
        } catch {
            XCTAssertEqual(error as? VoiceError, .cancelled)
        }

        await driver.resumeSpeech(
            requestID: thirdRequest.id,
            with: .success(
                AVSpeechTiming(firstAudioMilliseconds: 1, totalMilliseconds: 2)
            )
        )
        let metrics = try await third.value
        XCTAssertEqual(metrics.backend, .avSpeechOffline)
        XCTAssertEqual(metrics.characterCount, thirdRequest.text.count)
    }

    func testCancelledCurrentSupersederStopsPriorSpeechBeforeReturning() async throws {
        let driver = ControlledAVSpeechDriver()
        let synthesizer = AVSpeechSynthesizerAdapter(driver: driver)
        let firstRequest = try SpeechSynthesisRequest(text: "first")
        let cancelledRequest = try SpeechSynthesisRequest(text: "cancelled superseder")

        let first = Task { try await synthesizer.speak(firstRequest) }
        try await driver.waitForSpeechCallCount(1)
        let cancelled = Task { try await synthesizer.speak(cancelledRequest) }
        try await driver.waitForStopCallCount(1)
        cancelled.cancel()

        await driver.resumeNextStop()
        do {
            _ = try await cancelled.value
            XCTFail("a cancelled superseder must not start")
        } catch {
            XCTAssertEqual(error as? VoiceError, .cancelled)
        }

        let startedRequestIDs = await driver.startedRequestIDs()
        XCTAssertEqual(startedRequestIDs, [firstRequest.id])
        await driver.resumeSpeech(
            requestID: firstRequest.id,
            with: .failure(VoiceError.cancelled)
        )
        do {
            _ = try await first.value
            XCTFail("the prior request is stopped by the cancelled superseder")
        } catch {
            XCTAssertEqual(error as? VoiceError, .cancelled)
        }
    }

    func testNewSpeechJoinsCancelledCurrentCleanupBeforeStarting() async throws {
        let driver = ControlledAVSpeechDriver()
        let synthesizer = AVSpeechSynthesizerAdapter(driver: driver)
        let cancelledRequest = try SpeechSynthesisRequest(text: "cancelled current")
        let latestRequest = try SpeechSynthesisRequest(text: "latest")

        let cancelled = Task { try await synthesizer.speak(cancelledRequest) }
        try await driver.waitForSpeechCallCount(1)
        cancelled.cancel()
        try await driver.waitForStopCallCount(1)

        let latest = Task { try await synthesizer.speak(latestRequest) }
        try await waitForCurrentRequest(latestRequest.id, on: synthesizer)
        let startedBeforeCleanup = await driver.startedRequestIDs()
        XCTAssertEqual(startedBeforeCleanup, [cancelledRequest.id])

        await driver.resumeNextStop()
        try await driver.waitForSpeechCallCount(2)
        let stopCallCount = await driver.currentStopCallCount()
        XCTAssertEqual(stopCallCount, 1)

        await driver.resumeSpeech(
            requestID: cancelledRequest.id,
            with: .failure(VoiceError.cancelled)
        )
        do {
            _ = try await cancelled.value
            XCTFail("the canceled request must remain stale after cleanup")
        } catch {
            XCTAssertEqual(error as? VoiceError, .cancelled)
        }

        await driver.resumeSpeech(
            requestID: latestRequest.id,
            with: .success(
                AVSpeechTiming(firstAudioMilliseconds: 1, totalMilliseconds: 2)
            )
        )
        let metrics = try await latest.value
        XCTAssertEqual(metrics.characterCount, latestRequest.text.count)
    }

    func testCancellationDoesNotHideAudioSessionCleanupFailure() async throws {
        let driver = ControlledAVSpeechDriver()
        let synthesizer = AVSpeechSynthesizerAdapter(driver: driver)
        let request = try SpeechSynthesisRequest(text: "preserve cleanup failure")
        let cleanupError = VoiceError.audioSessionFailed("deactivation failed")

        let speech = Task { try await synthesizer.speak(request) }
        try await driver.waitForSpeechCallCount(1)
        speech.cancel()
        try await driver.waitForStopCallCount(1)
        await driver.resumeNextStop()
        await driver.resumeSpeech(requestID: request.id, with: .failure(cleanupError))

        do {
            _ = try await speech.value
            XCTFail("cancellation must not mask an audio-session cleanup failure")
        } catch {
            XCTAssertEqual(error as? VoiceError, cleanupError)
        }
    }

    func testCancellationClassificationPreservesAudioSessionFailures() {
        XCTAssertFalse(
            AVSpeechSynthesizerAdapter.shouldReportCancellation(
                VoiceError.audioSessionFailed("deactivation failed"),
                taskCancelled: true
            )
        )
        XCTAssertTrue(
            AVSpeechSynthesizerAdapter.shouldReportCancellation(
                VoiceError.synthesisFailed("cancelled while speaking"),
                taskCancelled: true
            )
        )
    }

    private func waitForCurrentRequest(
        _ requestID: UUID?,
        on synthesizer: AVSpeechSynthesizerAdapter
    ) async throws {
        for _ in 0..<100_000 {
            if await synthesizer.currentRequestID() == requestID { return }
            await Task.yield()
        }
        throw AVSpeechTestWaitError.expectedStateDidNotArrive
    }

    private func waitForStoppingState(on synthesizer: AVSpeechSynthesizerAdapter) async throws {
        for _ in 0..<100_000 {
            if await synthesizer.isStopping() { return }
            await Task.yield()
        }
        throw AVSpeechTestWaitError.expectedStateDidNotArrive
    }
}

private enum AVSpeechTestWaitError: Error {
    case expectedStateDidNotArrive
}

private actor ControlledAVSpeechDriverProvider {
    private let driver: any AVSpeechDriving
    private var isResolved = false
    private var waiters: [CheckedContinuation<any AVSpeechDriving, Never>] = []

    init(driver: any AVSpeechDriving) {
        self.driver = driver
    }

    func value() async -> any AVSpeechDriving {
        if isResolved { return driver }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func resolve() {
        guard !isResolved else { return }
        isResolved = true
        let driver = self.driver
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume(returning: driver) }
    }
}

private actor ControlledAVSpeechDriver: AVSpeechDriving {
    private enum WaitError: Error {
        case expectedCallDidNotArrive
    }

    private var speechRequestIDs: [UUID] = []
    private var speechContinuations: [UUID: CheckedContinuation<AVSpeechTiming, Error>] = [:]
    private var stopCallCount = 0
    private var stopContinuations: [CheckedContinuation<Void, Never>] = []

    func speak(_ request: SpeechSynthesisRequest) async throws -> AVSpeechTiming {
        speechRequestIDs.append(request.id)
        return try await withCheckedThrowingContinuation { continuation in
            speechContinuations[request.id] = continuation
        }
    }

    func stop() async {
        stopCallCount += 1
        await withCheckedContinuation { continuation in
            stopContinuations.append(continuation)
        }
    }

    func waitForSpeechCallCount(_ expected: Int) async throws {
        for _ in 0..<100_000 {
            if speechRequestIDs.count >= expected { return }
            await Task.yield()
        }
        throw WaitError.expectedCallDidNotArrive
    }

    func waitForStopCallCount(_ expected: Int) async throws {
        for _ in 0..<100_000 {
            if stopCallCount >= expected { return }
            await Task.yield()
        }
        throw WaitError.expectedCallDidNotArrive
    }

    func resumeNextStop() {
        guard !stopContinuations.isEmpty else { return }
        stopContinuations.removeFirst().resume()
    }

    func resumeSpeech(
        requestID: UUID,
        with result: Result<AVSpeechTiming, Error>
    ) {
        speechContinuations.removeValue(forKey: requestID)?.resume(with: result)
    }

    func startedRequestIDs() -> [UUID] {
        speechRequestIDs
    }

    func currentStopCallCount() -> Int {
        stopCallCount
    }
}
