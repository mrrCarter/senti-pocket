import Foundation
import XCTest
@testable import PocketVoice

final class GatewayStreamingSpeechSynthesizerTests: XCTestCase {
    func testCurrentGatewayFailureIsNotReclassifiedAsCancellation() {
        let error = VoiceError.gatewayRejected(503)

        XCTAssertFalse(
            GatewayStreamingSpeechSynthesizer.shouldReportCancellation(
                error,
                wasCurrent: true,
                parentTaskCancelled: false
            )
        )
    }

    func testSupersededRequestIsReportedAsCancellation() {
        XCTAssertTrue(
            GatewayStreamingSpeechSynthesizer.shouldReportCancellation(
                VoiceError.gatewayRejected(503),
                wasCurrent: false,
                parentTaskCancelled: false
            )
        )
    }

    func testSupersededAudioSessionFailureIsNotHiddenAsCancellation() {
        XCTAssertFalse(
            GatewayStreamingSpeechSynthesizer.shouldReportCancellation(
                VoiceError.audioSessionFailed("deactivation failed"),
                wasCurrent: false,
                parentTaskCancelled: false
            )
        )
    }

    func testExplicitCancellationIsReportedAsCancellation() {
        XCTAssertTrue(
            GatewayStreamingSpeechSynthesizer.shouldReportCancellation(
                VoiceError.cancelled,
                wasCurrent: true,
                parentTaskCancelled: false
            )
        )
        XCTAssertTrue(
            GatewayStreamingSpeechSynthesizer.shouldReportCancellation(
                VoiceError.gatewayRejected(503),
                wasCurrent: true,
                parentTaskCancelled: true
            )
        )
    }

    func testPrimaryAndCleanupFailuresAreCombined() {
        let cleanupError = VoiceError.audioSessionFailed("deactivation failed")

        XCTAssertEqual(
            GatewayStreamingSpeechSynthesizer.errorByAddingCleanupFailure(
                VoiceError.malformedPCMStream,
                cleanupError: cleanupError
            ),
            .audioSessionFailed(
                "\(VoiceError.malformedPCMStream.localizedDescription); "
                    + cleanupError.localizedDescription
            )
        )
    }

    func testDeferredStopFailureIsRetainedUntilNextSpeechPreflight() {
        let first = VoiceError.audioSessionFailed("first")
        var failures = GatewayAudioSessionCleanupFailures()

        failures.record(nil)
        failures.record(first)
        failures.record(.audioSessionFailed("second"))
        XCTAssertEqual(failures.pendingError, first)
        XCTAssertThrowsError(try failures.requireNoPendingError()) { error in
            XCTAssertEqual(error as? VoiceError, first)
        }
        XCTAssertNil(failures.pendingError)
        XCTAssertNoThrow(try failures.requireNoPendingError())
    }

    func testSpeechPreflightRefusesImmediateCleanupFailure() {
        let cleanupError = VoiceError.audioSessionFailed("preflight deactivation failed")

        XCTAssertThrowsError(
            try GatewayStreamingSpeechSynthesizer.requireCleanStop(cleanupError)
        ) { error in
            XCTAssertEqual(error as? VoiceError, cleanupError)
        }
        XCTAssertNoThrow(try GatewayStreamingSpeechSynthesizer.requireCleanStop(nil))
    }

    func testOverlappingSpeechOnlyStartsTheLatestRequestAfterPreflight() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://speech.example.test/tts"))
        let configuration = try SpeechGatewayConfiguration(
            endpoint: endpoint,
            allowedHosts: ["speech.example.test"],
            voiceId: "test-voice"
        )
        let authorizer = CountingFailingGatewayAuthorizer()
        let controlledStop = ControlledGatewayStop()
        let player = try XCTUnwrap(PCM16StreamPlayer(sampleRate: 24_000))
        let synthesizer = GatewayStreamingSpeechSynthesizer(
            configuration: configuration,
            authorizer: authorizer,
            session: URLSession(configuration: .ephemeral),
            player: player,
            stopPlayer: { await controlledStop.stop() }
        )
        let firstRequest = try SpeechSynthesisRequest(text: "first")
        let secondRequest = try SpeechSynthesisRequest(text: "second")

        let first = Task { try await synthesizer.speak(firstRequest) }
        try await controlledStop.waitForCallCount(1)
        let second = Task { try await synthesizer.speak(secondRequest) }
        try await waitForCurrentRequest(secondRequest.id, on: synthesizer)
        let preflightCallCount = await controlledStop.currentCallCount()
        XCTAssertEqual(preflightCallCount, 1)

        await controlledStop.resumeNext()
        do {
            _ = try await first.value
            XCTFail("the superseded request must not pass preflight")
        } catch {
            XCTAssertEqual(error as? VoiceError, .cancelled)
        }

        try await controlledStop.waitForCallCount(2)
        await controlledStop.resumeNext()
        do {
            _ = try await second.value
            XCTFail("the test authorizer must fail the latest request")
        } catch {
            XCTAssertEqual(error as? VoiceError, .insecureGateway)
        }
        let authorizationCallCount = await authorizer.authorizationCallCount()
        XCTAssertEqual(authorizationCallCount, 1)
    }

    func testStopAndSpeechShareCleanupBarrierAndFailurePreventsAuthorization() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://speech.example.test/tts"))
        let configuration = try SpeechGatewayConfiguration(
            endpoint: endpoint,
            allowedHosts: ["speech.example.test"],
            voiceId: "test-voice"
        )
        let authorizer = CountingFailingGatewayAuthorizer()
        let controlledStop = ControlledGatewayStop()
        let player = try XCTUnwrap(PCM16StreamPlayer(sampleRate: 24_000))
        let synthesizer = GatewayStreamingSpeechSynthesizer(
            configuration: configuration,
            authorizer: authorizer,
            session: URLSession(configuration: .ephemeral),
            player: player,
            stopPlayer: { await controlledStop.stop() }
        )
        let request = try SpeechSynthesisRequest(text: "must wait for cleanup")
        let cleanupError = VoiceError.audioSessionFailed("deactivation failed")

        let stop = Task { await synthesizer.stop() }
        try await controlledStop.waitForCallCount(1)
        let speech = Task { try await synthesizer.speak(request) }
        try await waitForCurrentRequest(request.id, on: synthesizer)
        let sharedCallCount = await controlledStop.currentCallCount()
        XCTAssertEqual(sharedCallCount, 1)

        await controlledStop.resumeNext(with: cleanupError)
        await stop.value
        do {
            _ = try await speech.value
            XCTFail("speech must not start after the shared cleanup fails")
        } catch {
            XCTAssertEqual(error as? VoiceError, cleanupError)
        }
        let authorizationCallCount = await authorizer.authorizationCallCount()
        let pendingError = await synthesizer.pendingAudioSessionError()
        XCTAssertEqual(authorizationCallCount, 0)
        XCTAssertNil(pendingError)
    }

    func testCancelledWaiterDoesNotCancelSharedCleanupOrStartSpeech() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://speech.example.test/tts"))
        let configuration = try SpeechGatewayConfiguration(
            endpoint: endpoint,
            allowedHosts: ["speech.example.test"],
            voiceId: "test-voice"
        )
        let authorizer = CountingFailingGatewayAuthorizer()
        let controlledStop = ControlledGatewayStop()
        let player = try XCTUnwrap(PCM16StreamPlayer(sampleRate: 24_000))
        let synthesizer = GatewayStreamingSpeechSynthesizer(
            configuration: configuration,
            authorizer: authorizer,
            session: URLSession(configuration: .ephemeral),
            player: player,
            stopPlayer: { await controlledStop.stop() }
        )
        let cancelledRequest = try SpeechSynthesisRequest(text: "cancelled")
        let latestRequest = try SpeechSynthesisRequest(text: "latest")

        let cancelled = Task { try await synthesizer.speak(cancelledRequest) }
        try await controlledStop.waitForCallCount(1)
        cancelled.cancel()
        let latest = Task { try await synthesizer.speak(latestRequest) }
        try await waitForCurrentRequest(latestRequest.id, on: synthesizer)
        let sharedCallCount = await controlledStop.currentCallCount()
        XCTAssertEqual(sharedCallCount, 1)

        await controlledStop.resumeNext()
        do {
            _ = try await cancelled.value
            XCTFail("the cancelled waiter must not start speech")
        } catch {
            XCTAssertEqual(error as? VoiceError, .cancelled)
        }

        try await controlledStop.waitForCallCount(2)
        await controlledStop.resumeNext()
        do {
            _ = try await latest.value
            XCTFail("the latest request reaches the intentionally failing authorizer")
        } catch {
            XCTAssertEqual(error as? VoiceError, .insecureGateway)
        }
        let authorizationCallCount = await authorizer.authorizationCallCount()
        XCTAssertEqual(authorizationCallCount, 1)
    }

    func testSupersededTaskCannotReachNetworkAfterAuthorizerIgnoresCancellation() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://speech.example.test/tts"))
        let configuration = try SpeechGatewayConfiguration(
            endpoint: endpoint,
            allowedHosts: ["speech.example.test"],
            voiceId: "test-voice"
        )
        let authorizer = ControlledGatewayAuthorizer()
        let controlledStop = ControlledGatewayStop()
        let player = try XCTUnwrap(PCM16StreamPlayer(sampleRate: 24_000))
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [FailIfLoadedURLProtocol.self]
        NetworkLoadRecorder.shared.reset()
        let synthesizer = GatewayStreamingSpeechSynthesizer(
            configuration: configuration,
            authorizer: authorizer,
            session: URLSession(configuration: sessionConfiguration),
            player: player,
            stopPlayer: { await controlledStop.stop() }
        )
        let request = try SpeechSynthesisRequest(text: "cancel before network")

        let speech = Task { try await synthesizer.speak(request) }
        try await controlledStop.waitForCallCount(1)
        await controlledStop.resumeNext()
        try await authorizer.waitForCallCount(1)

        let stop = Task { await synthesizer.stop() }
        try await controlledStop.waitForCallCount(2)
        await controlledStop.resumeNext()
        await stop.value
        await authorizer.resumeIgnoringCancellation()

        do {
            _ = try await speech.value
            XCTFail("a superseded task must stop after authorization")
        } catch {
            XCTAssertEqual(error as? VoiceError, .cancelled)
        }
        XCTAssertEqual(NetworkLoadRecorder.shared.count, 0)
    }

    func testSupersededPrepareCannotEnqueueAfterStopAndNewSpeech() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://speech.example.test/tts"))
        let configuration = try SpeechGatewayConfiguration(
            endpoint: endpoint,
            allowedHosts: ["speech.example.test"],
            voiceId: "test-voice"
        )
        let authorizer = PassingGatewayAuthorizer()
        let controlledStop = ControlledGatewayStop()
        let controlledPlayer = ControlledGatewayPlayer()
        let player = try XCTUnwrap(PCM16StreamPlayer(sampleRate: 24_000))
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [FixedPCMURLProtocol.self]
        let synthesizer = GatewayStreamingSpeechSynthesizer(
            configuration: configuration,
            authorizer: authorizer,
            session: URLSession(configuration: sessionConfiguration),
            player: player,
            preparePlayer: { try await controlledPlayer.prepareIgnoringCancellation() },
            enqueuePlayer: { data in try await controlledPlayer.enqueue(data) },
            finishPlayer: { try await controlledPlayer.finish() },
            stopPlayer: { await controlledStop.stop() }
        )
        let staleRequest = try SpeechSynthesisRequest(text: "stale prepare")
        let latestRequest = try SpeechSynthesisRequest(text: "current prepare")

        let stale = Task { try await synthesizer.speak(staleRequest) }
        try await controlledStop.waitForCallCount(1)
        await controlledStop.resumeNext()
        try await controlledPlayer.waitForPrepareCallCount(1)

        let stop = Task { await synthesizer.stop() }
        try await controlledStop.waitForCallCount(2)
        let latest = Task { try await synthesizer.speak(latestRequest) }
        try await waitForCurrentRequest(latestRequest.id, on: synthesizer)
        await controlledStop.resumeNext()
        await stop.value
        try await controlledPlayer.waitForPrepareCallCount(2)

        await controlledPlayer.resumeNextPrepare()
        do {
            _ = try await stale.value
            XCTFail("a stale prepare must not enqueue PCM after it resumes")
        } catch {
            XCTAssertEqual(error as? VoiceError, .cancelled)
        }
        let staleEnqueueCallCount = await controlledPlayer.currentEnqueueCallCount()
        let staleFinishCallCount = await controlledPlayer.currentFinishCallCount()
        XCTAssertEqual(staleEnqueueCallCount, 0)
        XCTAssertEqual(staleFinishCallCount, 0)

        await controlledPlayer.resumeNextPrepare()
        let metrics = try await latest.value
        XCTAssertEqual(metrics.characterCount, latestRequest.text.count)
        let finalEnqueueCallCount = await controlledPlayer.currentEnqueueCallCount()
        let finalFinishCallCount = await controlledPlayer.currentFinishCallCount()
        let authorizationCallCount = await authorizer.authorizationCallCount()
        XCTAssertEqual(finalEnqueueCallCount, 1)
        XCTAssertEqual(finalFinishCallCount, 1)
        XCTAssertEqual(authorizationCallCount, 2)
    }

    func testPCMPrepareReleasesLeaseWhenCancelledDuringActivation() async throws {
        let system = BlockingDuplexAudioSessionSystem()
        let leases = DuplexAudioSessionLeaseManager(system: system)
        let player = try XCTUnwrap(
            PCM16StreamPlayer(sampleRate: 24_000, audioSessionLeases: leases)
        )

        let prepare = Task.detached { try await player.prepare() }
        try await system.waitForActivation()
        prepare.cancel()
        system.resumeActivation()

        do {
            try await prepare.value
            XCTFail("a cancelled prepare must not commit its audio-session lease")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(leases.activeLeaseCount, 0)
        XCTAssertEqual(system.currentDeactivationCount(), 1)
    }

    func testPCMEnqueueRejectsCancellationAtActorEntry() async throws {
        let player = try XCTUnwrap(PCM16StreamPlayer(sampleRate: 24_000))
        let gate = ControlledVoidGate()
        let enqueue = Task {
            await gate.wait()
            try await player.enqueue(Data([0, 0]))
        }
        try await gate.waitUntilWaiting()
        enqueue.cancel()
        await gate.resume()

        do {
            try await enqueue.value
            XCTFail("a cancelled task must not schedule a PCM buffer")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testStaleWaiterCannotConsumeFailedCleanupBeforeCurrentRequest() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://speech.example.test/tts"))
        let configuration = try SpeechGatewayConfiguration(
            endpoint: endpoint,
            allowedHosts: ["speech.example.test"],
            voiceId: "test-voice"
        )
        let authorizer = CountingFailingGatewayAuthorizer()
        let controlledStop = ControlledGatewayStop()
        let resumeOrder = ControlledGatewayCleanupResumeOrder()
        let player = try XCTUnwrap(PCM16StreamPlayer(sampleRate: 24_000))
        let synthesizer = GatewayStreamingSpeechSynthesizer(
            configuration: configuration,
            authorizer: authorizer,
            session: URLSession(configuration: .ephemeral),
            player: player,
            stopPlayer: { await controlledStop.stop() },
            cleanupWaitObserver: { requestID in await resumeOrder.wait(requestID) }
        )
        let staleRequest = try SpeechSynthesisRequest(text: "stale")
        let currentRequest = try SpeechSynthesisRequest(text: "current")
        let cleanupError = VoiceError.audioSessionFailed("shared cleanup failed")

        let stale = Task { try await synthesizer.speak(staleRequest) }
        try await controlledStop.waitForCallCount(1)
        let current = Task { try await synthesizer.speak(currentRequest) }
        try await waitForCurrentRequest(currentRequest.id, on: synthesizer)

        await controlledStop.resumeNext(with: cleanupError)
        try await resumeOrder.waitForArrivalCount(2)
        await resumeOrder.resume(staleRequest.id)
        do {
            _ = try await stale.value
            XCTFail("the stale request must not pass the lifecycle guard")
        } catch {
            XCTAssertEqual(error as? VoiceError, .cancelled)
        }

        let pendingAfterStale = await synthesizer.pendingAudioSessionError()
        let authorizationsAfterStale = await authorizer.authorizationCallCount()
        XCTAssertEqual(pendingAfterStale, cleanupError)
        XCTAssertEqual(authorizationsAfterStale, 0)

        await resumeOrder.resume(currentRequest.id)
        do {
            _ = try await current.value
            XCTFail("the current request must consume and throw the failed preflight")
        } catch {
            XCTAssertEqual(error as? VoiceError, cleanupError)
        }
        let pendingAfterCurrent = await synthesizer.pendingAudioSessionError()
        let finalAuthorizationCount = await authorizer.authorizationCallCount()
        XCTAssertNil(pendingAfterCurrent)
        XCTAssertEqual(finalAuthorizationCount, 0)
    }

    func testStaleSpeechCannotDrainFailedNonthrowingStopCleanup() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://speech.example.test/tts"))
        let configuration = try SpeechGatewayConfiguration(
            endpoint: endpoint,
            allowedHosts: ["speech.example.test"],
            voiceId: "test-voice"
        )
        let authorizer = CountingFailingGatewayAuthorizer()
        let controlledStop = ControlledGatewayStop()
        let resumeOrder = ControlledGatewayCleanupResumeOrder()
        let player = try XCTUnwrap(PCM16StreamPlayer(sampleRate: 24_000))
        let synthesizer = GatewayStreamingSpeechSynthesizer(
            configuration: configuration,
            authorizer: authorizer,
            session: URLSession(configuration: .ephemeral),
            player: player,
            stopPlayer: { await controlledStop.stop() },
            cleanupWaitObserver: { requestID in await resumeOrder.wait(requestID) }
        )
        let staleRequest = try SpeechSynthesisRequest(text: "stale before stop")
        let nextRequest = try SpeechSynthesisRequest(text: "next after failed stop")
        let cleanupError = VoiceError.audioSessionFailed("nonthrowing stop failed")

        let stale = Task { try await synthesizer.speak(staleRequest) }
        try await controlledStop.waitForCallCount(1)
        let stop = Task { await synthesizer.stop() }
        try await waitForCurrentRequest(nil, on: synthesizer)
        await controlledStop.resumeNext(with: cleanupError)
        try await resumeOrder.waitForArrivalCount(1)
        await stop.value

        await resumeOrder.resume(staleRequest.id)
        do {
            _ = try await stale.value
            XCTFail("speech superseded by stop must remain stale")
        } catch {
            XCTAssertEqual(error as? VoiceError, .cancelled)
        }
        let retainedError = await synthesizer.pendingAudioSessionError()
        XCTAssertEqual(retainedError, cleanupError)

        do {
            _ = try await synthesizer.speak(nextRequest)
            XCTFail("the next request must consume and throw the retained stop failure")
        } catch {
            XCTAssertEqual(error as? VoiceError, cleanupError)
        }
        let authorizationCallCount = await authorizer.authorizationCallCount()
        let pendingAfterNext = await synthesizer.pendingAudioSessionError()
        XCTAssertEqual(authorizationCallCount, 0)
        XCTAssertNil(pendingAfterNext)
    }

    func testStaleSpeechCannotDrainFailureFromNewerCleanupBarrier() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://speech.example.test/tts"))
        let configuration = try SpeechGatewayConfiguration(
            endpoint: endpoint,
            allowedHosts: ["speech.example.test"],
            voiceId: "test-voice"
        )
        let authorizer = CountingFailingGatewayAuthorizer()
        let controlledStop = ControlledGatewayStop()
        let resumeOrder = ControlledGatewayCleanupResumeOrder()
        let player = try XCTUnwrap(PCM16StreamPlayer(sampleRate: 24_000))
        let synthesizer = GatewayStreamingSpeechSynthesizer(
            configuration: configuration,
            authorizer: authorizer,
            session: URLSession(configuration: .ephemeral),
            player: player,
            stopPlayer: { await controlledStop.stop() },
            cleanupWaitObserver: { requestID in await resumeOrder.wait(requestID) }
        )
        let staleRequest = try SpeechSynthesisRequest(text: "stale after clean barrier")
        let nextRequest = try SpeechSynthesisRequest(text: "next after newer failure")
        let cleanupError = VoiceError.audioSessionFailed("newer cleanup failed")

        let stale = Task { try await synthesizer.speak(staleRequest) }
        try await controlledStop.waitForCallCount(1)
        await controlledStop.resumeNext()
        try await resumeOrder.waitForArrivalCount(1)

        let stop = Task { await synthesizer.stop() }
        try await controlledStop.waitForCallCount(2)
        await controlledStop.resumeNext(with: cleanupError)
        await stop.value

        await resumeOrder.resume(staleRequest.id)
        do {
            _ = try await stale.value
            XCTFail("a stale waiter must not consume a newer barrier failure")
        } catch {
            XCTAssertEqual(error as? VoiceError, .cancelled)
        }
        let retainedError = await synthesizer.pendingAudioSessionError()
        XCTAssertEqual(retainedError, cleanupError)

        do {
            _ = try await synthesizer.speak(nextRequest)
            XCTFail("the next current request must throw the newer barrier failure")
        } catch {
            XCTAssertEqual(error as? VoiceError, cleanupError)
        }
        let authorizationCallCount = await authorizer.authorizationCallCount()
        XCTAssertEqual(authorizationCallCount, 0)
    }

    func testNonthrowingStopRetainsCleanupFailureWithoutAConsumer() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://speech.example.test/tts"))
        let configuration = try SpeechGatewayConfiguration(
            endpoint: endpoint,
            allowedHosts: ["speech.example.test"],
            voiceId: "test-voice"
        )
        let controlledStop = ControlledGatewayStop()
        let player = try XCTUnwrap(PCM16StreamPlayer(sampleRate: 24_000))
        let synthesizer = GatewayStreamingSpeechSynthesizer(
            configuration: configuration,
            authorizer: CountingFailingGatewayAuthorizer(),
            session: URLSession(configuration: .ephemeral),
            player: player,
            stopPlayer: { await controlledStop.stop() }
        )
        let cleanupError = VoiceError.audioSessionFailed("deactivation failed")

        let stop = Task { await synthesizer.stop() }
        try await controlledStop.waitForCallCount(1)
        await controlledStop.resumeNext(with: cleanupError)
        await stop.value

        let pendingError = await synthesizer.pendingAudioSessionError()
        XCTAssertEqual(pendingError, cleanupError)
    }

    private func waitForCurrentRequest(
        _ requestID: UUID?,
        on synthesizer: GatewayStreamingSpeechSynthesizer
    ) async throws {
        for _ in 0..<100_000 {
            if await synthesizer.currentRequestID() == requestID { return }
            await Task.yield()
        }
        throw ControlledGatewayStop.WaitError.expectedCallDidNotArrive
    }
}

private actor ControlledGatewayCleanupResumeOrder {
    private enum WaitError: Error {
        case expectedWaiterDidNotArrive
    }

    private var arrivals: Set<UUID> = []
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func wait(_ requestID: UUID) async {
        arrivals.insert(requestID)
        await withCheckedContinuation { continuation in
            waiters[requestID] = continuation
        }
    }

    func waitForArrivalCount(_ expected: Int) async throws {
        for _ in 0..<100_000 {
            if arrivals.count >= expected { return }
            await Task.yield()
        }
        throw WaitError.expectedWaiterDidNotArrive
    }

    func resume(_ requestID: UUID) {
        waiters.removeValue(forKey: requestID)?.resume()
    }
}

private actor ControlledGatewayAuthorizer: SpeechGatewayAuthorizer {
    private enum WaitError: Error {
        case expectedCallDidNotArrive
    }

    private var callCount = 0
    private var pendingRequest: URLRequest?
    private var continuation: CheckedContinuation<URLRequest, Error>?

    func authorize(_ request: URLRequest) async throws -> URLRequest {
        callCount += 1
        pendingRequest = request
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitForCallCount(_ expected: Int) async throws {
        for _ in 0..<100_000 {
            if callCount >= expected { return }
            await Task.yield()
        }
        throw WaitError.expectedCallDidNotArrive
    }

    func resumeIgnoringCancellation() {
        guard let request = pendingRequest else { return }
        pendingRequest = nil
        continuation?.resume(returning: request)
        continuation = nil
    }
}

private final class NetworkLoadRecorder: @unchecked Sendable {
    static let shared = NetworkLoadRecorder()

    private let lock = NSLock()
    private var requestCount = 0

    var count: Int {
        lock.withLock { requestCount }
    }

    func record() {
        lock.withLock { requestCount += 1 }
    }

    func reset() {
        lock.withLock { requestCount = 0 }
    }
}

private final class FailIfLoadedURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        NetworkLoadRecorder.shared.record()
        client?.urlProtocol(self, didFailWithError: VoiceError.cancelled)
    }

    override func stopLoading() {}
}

private final class FixedPCMURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: [
                      "Content-Length": "2",
                      "X-Senti-Audio-Format": "pcm_s16le_24000"
                  ]
              ) else {
            client?.urlProtocol(self, didFailWithError: VoiceError.gatewayRejected(0))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data([0, 0]))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor ControlledGatewayPlayer {
    private enum WaitError: Error {
        case expectedPrepareDidNotArrive
    }

    private var prepareCallCount = 0
    private var prepareWaiters: [CheckedContinuation<Void, Never>] = []
    private var enqueueCallCount = 0
    private var finishCallCount = 0

    func prepareIgnoringCancellation() async throws {
        prepareCallCount += 1
        await withCheckedContinuation { continuation in
            prepareWaiters.append(continuation)
        }
    }

    func enqueue(_ data: Data) throws {
        enqueueCallCount += 1
    }

    func finish() throws {
        finishCallCount += 1
    }

    func waitForPrepareCallCount(_ expected: Int) async throws {
        for _ in 0..<100_000 {
            if prepareCallCount >= expected { return }
            await Task.yield()
        }
        throw WaitError.expectedPrepareDidNotArrive
    }

    func resumeNextPrepare() {
        guard !prepareWaiters.isEmpty else { return }
        prepareWaiters.removeFirst().resume()
    }

    func currentEnqueueCallCount() -> Int {
        enqueueCallCount
    }

    func currentFinishCallCount() -> Int {
        finishCallCount
    }
}

private actor PassingGatewayAuthorizer: SpeechGatewayAuthorizer {
    private var callCount = 0

    func authorize(_ request: URLRequest) async throws -> URLRequest {
        callCount += 1
        return request
    }

    func authorizationCallCount() -> Int {
        callCount
    }
}

private actor ControlledVoidGate {
    private enum WaitError: Error {
        case waiterDidNotArrive
    }

    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }

    func waitUntilWaiting() async throws {
        for _ in 0..<100_000 {
            if continuation != nil { return }
            await Task.yield()
        }
        throw WaitError.waiterDidNotArrive
    }
}

private final class BlockingDuplexAudioSessionSystem: DuplexAudioSessionSystem, @unchecked Sendable {
    private enum WaitError: Error {
        case activationDidNotStart
    }

    private let condition = NSCondition()
    private var activationStarted = false
    private var mayReturnFromActivation = false
    private var deactivationCount = 0

    func activate() throws {
        condition.lock()
        activationStarted = true
        condition.broadcast()
        while !mayReturnFromActivation {
            condition.wait()
        }
        condition.unlock()
    }

    func deactivate() throws {
        condition.lock()
        deactivationCount += 1
        condition.unlock()
    }

    func waitForActivation() async throws {
        for _ in 0..<100_000 {
            let started = condition.withLock { activationStarted }
            if started { return }
            await Task.yield()
        }
        throw WaitError.activationDidNotStart
    }

    func resumeActivation() {
        condition.lock()
        mayReturnFromActivation = true
        condition.broadcast()
        condition.unlock()
    }

    func currentDeactivationCount() -> Int {
        condition.lock()
        defer { condition.unlock() }
        return deactivationCount
    }
}

private actor ControlledGatewayStop {
    enum WaitError: Error {
        case expectedCallDidNotArrive
    }

    private var callCount = 0
    private var waiters: [CheckedContinuation<VoiceError?, Never>] = []

    func stop() async -> VoiceError? {
        callCount += 1
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func waitForCallCount(_ expected: Int) async throws {
        for _ in 0..<100_000 {
            if callCount >= expected { return }
            await Task.yield()
        }
        throw WaitError.expectedCallDidNotArrive
    }

    func resumeNext(with error: VoiceError? = nil) {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume(returning: error)
    }

    func currentCallCount() -> Int {
        callCount
    }
}

private actor CountingFailingGatewayAuthorizer: SpeechGatewayAuthorizer {
    private var callCount = 0

    func authorize(_ request: URLRequest) async throws -> URLRequest {
        callCount += 1
        throw VoiceError.insecureGateway
    }

    func authorizationCallCount() -> Int {
        callCount
    }
}
