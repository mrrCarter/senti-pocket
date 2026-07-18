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

    func testSupersededPremiumFailureDoesNotReviveOldOfflinePlayback() async throws {
        let oldRequestStarted = HybridAsyncLatch()
        let premium = SupersedingPremiumSynthesizer(oldRequestStarted: oldRequestStarted)
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
        await oldRequestStarted.waitUntilStarted()

        let newestMetrics = try await hybrid.speak(newRequest)
        await oldRequestStarted.release()
        let oldError = await oldTask.value
        let offlineCalls = await offline.callCount()

        XCTAssertEqual(newestMetrics.backend, .elevenLabsGateway)
        XCTAssertEqual(oldError, .cancelled)
        XCTAssertEqual(offlineCalls, 0)
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
        await firstStop.waitUntilStarted()

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

    init(oldRequestStarted: HybridAsyncLatch) {
        self.oldRequestStarted = oldRequestStarted
    }

    func speak(_ request: SpeechSynthesisRequest) async throws -> SpeechPlaybackMetrics {
        if request.text == "old request" {
            await oldRequestStarted.suspend()
            throw VoiceError.gatewayRejected(503)
        }
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
