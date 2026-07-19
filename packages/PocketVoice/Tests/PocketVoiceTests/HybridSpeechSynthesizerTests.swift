@testable import PocketVoice
import XCTest

final class HybridSpeechSynthesizerTests: XCTestCase {
    func testOfflineConnectivitySkipsPremium() async throws {
        let premium = FakeSynthesizer(result: .failure(.synthesisFailed("must not run")))
        let offline = FakeSynthesizer(result: .success(metrics(.avSpeechOffline)))
        let hybrid = HybridSpeechSynthesizer(
            premium: premium,
            offline: offline,
            connectivity: FixedConnectivity(online: false)
        )

        let result = try await hybrid.speak(try SpeechSynthesisRequest(text: "Checkpoint ready"))
        let premiumCalls = await premium.callCount()
        let offlineCalls = await offline.callCount()

        XCTAssertEqual(result.backend, .avSpeechOffline)
        XCTAssertEqual(premiumCalls, 0)
        XCTAssertEqual(offlineCalls, 1)
    }

    func testPremiumFailureFallsBackOffline() async throws {
        let premium = FakeSynthesizer(result: .failure(.gatewayRejected(503)))
        let offline = FakeSynthesizer(result: .success(metrics(.avSpeechOffline)))
        let hybrid = HybridSpeechSynthesizer(
            premium: premium,
            offline: offline,
            connectivity: FixedConnectivity(online: true)
        )

        let result = try await hybrid.speak(try SpeechSynthesisRequest(text: "Checkpoint ready"))
        let premiumCalls = await premium.callCount()
        let offlineCalls = await offline.callCount()

        XCTAssertEqual(result.backend, .avSpeechOffline)
        XCTAssertEqual(premiumCalls, 1)
        XCTAssertEqual(offlineCalls, 1)
    }

    func testSameRequestIDSupersessionDoesNotReviveOldOfflinePlayback() async throws {
        let oldRequestStarted = HybridAsyncLatch()
        let newRequestStarted = HybridAsyncLatch()
        let premium = SupersedingPremiumSynthesizer(
            oldRequestStarted: oldRequestStarted,
            newRequestStarted: newRequestStarted
        )
        let offline = FakeSynthesizer(result: .success(metrics(.avSpeechOffline)))
        let hybrid = HybridSpeechSynthesizer(
            premium: premium,
            offline: offline,
            connectivity: FixedConnectivity(online: true)
        )
        let sharedRequestID = UUID()
        let oldRequest = try SpeechSynthesisRequest(id: sharedRequestID, text: "old request")
        let newRequest = try SpeechSynthesisRequest(id: sharedRequestID, text: "new request")

        let oldTask = Task { () -> VoiceError? in
            do {
                _ = try await hybrid.speak(oldRequest)
                return nil
            } catch {
                return error as? VoiceError
            }
        }
        try await oldRequestStarted.waitUntilStarted()

        let newTask = Task { try await hybrid.speak(newRequest) }
        try await newRequestStarted.waitUntilStarted()
        await oldRequestStarted.release()

        let oldError = await oldTask.value
        let offlineCalls = await offline.callCount()
        let newRequestStillActive = await hybrid.hasActiveRequest(sharedRequestID)

        await newRequestStarted.release()
        let newestMetrics = try await newTask.value

        XCTAssertEqual(newestMetrics.backend, .elevenLabsGateway)
        XCTAssertEqual(oldError, .cancelled)
        XCTAssertEqual(offlineCalls, 0)
        XCTAssertTrue(newRequestStillActive)
    }

    func testOlderStopCannotCrossIntoNewerPlaybackGeneration() async throws {
        let firstStop = HybridAsyncLatch()
        let premium = BlockingFirstStopSynthesizer(firstStop: firstStop)
        let offline = FakeSynthesizer(result: .success(metrics(.avSpeechOffline)))
        let hybrid = HybridSpeechSynthesizer(
            premium: premium,
            offline: offline,
            connectivity: FixedConnectivity(online: true)
        )
        let oldRequest = try SpeechSynthesisRequest(text: "old request")
        let newRequest = try SpeechSynthesisRequest(text: "new request")

        let oldTask = Task { () -> VoiceError? in
            do {
                _ = try await hybrid.speak(oldRequest)
                return nil
            } catch {
                return error as? VoiceError
            }
        }
        try await firstStop.waitUntilStarted()

        let newTask = Task { try await hybrid.speak(newRequest) }
        var newRequestBecameActive = false
        for _ in 0..<1_000 {
            if await hybrid.hasActiveRequest(newRequest.id) {
                newRequestBecameActive = true
                break
            }
            await Task.yield()
        }
        await firstStop.release()

        let newMetrics = try await newTask.value
        let oldError = await oldTask.value
        let spoken = await premium.spokenTexts()

        XCTAssertTrue(newRequestBecameActive)
        XCTAssertEqual(oldError, .cancelled)
        XCTAssertEqual(newMetrics.backend, .elevenLabsGateway)
        XCTAssertEqual(spoken, ["new request"])
    }

    func testCancellationDuringBackendQuiescenceClearsLifecycle() async throws {
        let firstStop = HybridAsyncLatch()
        let premium = BlockingFirstStopSynthesizer(firstStop: firstStop)
        let offline = FakeSynthesizer(result: .success(metrics(.avSpeechOffline)))
        let hybrid = HybridSpeechSynthesizer(
            premium: premium,
            offline: offline,
            connectivity: FixedConnectivity(online: true)
        )
        let request = try SpeechSynthesisRequest(text: "cancel while stopping")

        let task = Task { () -> VoiceError? in
            do {
                _ = try await hybrid.speak(request)
                return nil
            } catch {
                return error as? VoiceError
            }
        }
        try await firstStop.waitUntilStarted()

        task.cancel()
        await firstStop.release()

        let error = await task.value
        let remainsActive = await hybrid.hasActiveRequest(request.id)
        let spoken = await premium.spokenTexts()

        XCTAssertEqual(error, .cancelled)
        XCTAssertFalse(remainsActive)
        XCTAssertTrue(spoken.isEmpty)
    }

    private func metrics(_ backend: SpeechSynthesisBackend) -> SpeechPlaybackMetrics {
        SpeechPlaybackMetrics(
            backend: backend,
            firstAudioMeasurement: .avSpeechDidStartCallback,
            firstAudioMilliseconds: 10,
            totalMilliseconds: 20,
            characterCount: 10,
            residentMemoryBytes: nil,
            thermalState: .nominal
        )
    }
}

private actor FakeSynthesizer: SpeechSynthesizer {
    private let result: FakeSynthesisResult
    private var calls = 0

    init(result: FakeSynthesisResult) {
        self.result = result
    }

    func speak(_ request: SpeechSynthesisRequest) async throws -> SpeechPlaybackMetrics {
        calls += 1
        switch result {
        case .success(let metrics): return metrics
        case .failure(let error): throw error
        }
    }

    func stop() async {}

    func callCount() -> Int { calls }
}

private enum FakeSynthesisResult: Sendable {
    case success(SpeechPlaybackMetrics)
    case failure(VoiceError)
}

private actor SupersedingPremiumSynthesizer: SpeechSynthesizer {
    private let oldRequestStarted: HybridAsyncLatch
    private let newRequestStarted: HybridAsyncLatch

    init(oldRequestStarted: HybridAsyncLatch, newRequestStarted: HybridAsyncLatch) {
        self.oldRequestStarted = oldRequestStarted
        self.newRequestStarted = newRequestStarted
    }

    func speak(_ request: SpeechSynthesisRequest) async throws -> SpeechPlaybackMetrics {
        if request.text == "old request" {
            await oldRequestStarted.suspend()
            throw VoiceError.gatewayRejected(503)
        }
        await newRequestStarted.suspend()
        return SpeechPlaybackMetrics(
            backend: .elevenLabsGateway,
            firstAudioMeasurement: .pcmFirstBufferScheduled,
            firstAudioMilliseconds: 10,
            totalMilliseconds: 20,
            characterCount: request.text.count,
            residentMemoryBytes: nil,
            thermalState: .nominal
        )
    }

    func stop() async {}
}

private actor BlockingFirstStopSynthesizer: SpeechSynthesizer {
    private let firstStop: HybridAsyncLatch
    private var stops = 0
    private var spoken: [String] = []

    init(firstStop: HybridAsyncLatch) {
        self.firstStop = firstStop
    }

    func speak(_ request: SpeechSynthesisRequest) async throws -> SpeechPlaybackMetrics {
        spoken.append(request.text)
        return SpeechPlaybackMetrics(
            backend: .elevenLabsGateway,
            firstAudioMeasurement: .pcmFirstBufferScheduled,
            firstAudioMilliseconds: 10,
            totalMilliseconds: 20,
            characterCount: request.text.count,
            residentMemoryBytes: nil,
            thermalState: .nominal
        )
    }

    func stop() async {
        stops += 1
        if stops == 1 { await firstStop.suspend() }
    }

    func spokenTexts() -> [String] { spoken }
}

private actor HybridAsyncLatch {
    enum WaitError: Error {
        case didNotStart
    }

    private var started = false
    private var released = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        started = true
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if released {
                    continuation.resume()
                } else {
                    releaseContinuation = continuation
                }
            }
        }, onCancel: {
            Task { await self.release() }
        })
    }

    func waitUntilStarted() async throws {
        for _ in 0..<100_000 {
            if started { return }
            await Task.yield()
        }
        release()
        throw WaitError.didNotStart
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
