#if canImport(CallKit) && canImport(PushKit)
import AVFoundation
import CallKit
import Foundation
import PocketCall
import XCTest
@testable import SentiPocketApp

@MainActor
final class DialHostTests: XCTestCase {
    private final class CancellationGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var cancelled = false
        private let onCancel: () -> Void

        init(onCancel: @escaping () -> Void) {
            self.onCancel = onCancel
        }

        func wait() async {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    self.lock.lock()
                    if self.cancelled {
                        self.lock.unlock()
                        continuation.resume()
                    } else {
                        self.continuation = continuation
                        self.lock.unlock()
                    }
                }
            } onCancel: {
                self.cancel()
            }
        }

        private func cancel() {
            self.lock.lock()
            self.cancelled = true
            let continuation = self.continuation
            self.continuation = nil
            self.lock.unlock()
            self.onCancel()
            continuation?.resume()
        }
    }

    private final class ManualGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false

        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if isOpen {
                    lock.unlock()
                    continuation.resume()
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }

        func open() {
            lock.lock()
            isOpen = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume()
        }
    }

    private let fence = DeviceRingBindingFence(
        id: "bind_0123456789abcdef0123456789abcdef",
        revision: 7
    )

    private func core() -> RingCore {
        RingCore(
            id: "dial-a",
            kind: "decisionYours",
            priority: "high",
            callerName: "Senti",
            sessionId: "session-a",
            checkpointId: nil,
            binding: fence
        )
    }

    private func pushPayload() -> [AnyHashable: Any] {
        [
            "v": 2,
            "id": "dial-a",
            "kind": "decisionYours",
            "priority": "high",
            "callerName": "Senti",
            "who": "senti-pocket",
            "sessionId": "session-a",
            "fetch": true,
            "ts": "2026-07-31T12:00:00.000Z",
            "binding": ["v": 2, "id": fence.id, "revision": fence.revision],
        ]
    }

    private func bindingRecord() -> DeviceRingBindingRecord {
        DeviceRingBindingRecord(
            sessionId: "session-a",
            platform: "apns",
            tokenDigest: DeviceRingFingerprint.digest("aabbcc"),
            credentialFingerprint: DeviceRingFingerprint.digest("bearer-a"),
            ownerVersion: DeviceRingRegistryOwnerContext.version,
            ownerHandle: DeviceRingFingerprint.digest("owner-a"),
            bindingId: fence.id,
            bindingRevision: fence.revision,
            tokenClaimId: "claim_0123456789abcdef0123456789abcdef",
            tokenClaimRevision: 9,
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
            leaseAuthority: DeviceRingLeaseAuthority(
                serverTime: Date(timeIntervalSince1970: 2_000_000_000 - 604_800),
                wallTimeAtReceipt: Date(timeIntervalSince1970: 1_900_000_000),
                continuousTimeAtReceipt: 10_000,
                authorizedLifetime: 604_800
            )
        )
    }

    private func ring(_ dialId: String) -> RenderableRing {
        RenderableRing(
            core: RingCore(
                id: dialId,
                kind: "decisionYours",
                priority: "high",
                callerName: "Senti",
                sessionId: "session-a",
                checkpointId: nil,
                binding: fence
            ),
            message: "Ship it?",
            options: [],
            evidenceSeqs: [],
            confidence: nil
        )
    }

    private func call(_ dialId: String, callUUID: UUID = UUID()) -> IncomingDecisionCall {
        IncomingDecisionCall(
            id: callUUID,
            dialId: dialId,
            callerDisplayName: "Senti",
            message: "",
            context: nil,
            priority: "high"
        )
    }

    private func coordinator(
        runDial: @escaping (RenderableRing, UUID) async -> DialOutcome,
        endCall: @escaping (UUID) -> Void = { _ in }
    ) -> DialCoordinator {
        DialCoordinator(
            hydrate: { state in
                guard case .renderable(let ring) = state else {
                    throw DialHostError.sessionNotSelected
                }
                return ring
            },
            runDial: runDial,
            endCall: endCall
        )
    }

    func test_binding_revoked_before_hydration_prevents_network_work() async {
        let selection = DialSessionSelectionGate()
        selection.select("session-a")
        var hydrateCalls = 0
        let hydrator = SelectedSessionDialHydrator(
            selectionGate: selection,
            isBindingAuthorized: { _, _ in false },
            hydrate: { _ in
                hydrateCalls += 1
                return RenderableRing(
                    core: self.core(),
                    message: "must not load",
                    options: [],
                    evidenceSeqs: [],
                    confidence: nil
                )
            }
        )

        do {
            _ = try await hydrator.hydrate(.needsHydration(id: "dial-a", core: core()))
            XCTFail("revoked binding must refuse")
        } catch DialHostError.sessionNotSelected {
            XCTAssertEqual(hydrateCalls, 0)
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func test_binding_rotated_during_hydration_discards_fetched_content() async {
        let selection = DialSessionSelectionGate()
        selection.select("session-a")
        var bindingCurrent = true
        var authorizationChecks = 0
        let hydrator = SelectedSessionDialHydrator(
            selectionGate: selection,
            isBindingAuthorized: { _, fence in
                authorizationChecks += 1
                return bindingCurrent && fence == self.fence
            },
            hydrate: { state in
                guard case .needsHydration(_, let core) = state else {
                    throw DialHostError.sessionNotSelected
                }
                bindingCurrent = false
                return RenderableRing(
                    core: core,
                    message: "fetched but now stale",
                    options: [],
                    evidenceSeqs: [],
                    confidence: nil
                )
            }
        )

        do {
            _ = try await hydrator.hydrate(.needsHydration(id: "dial-a", core: core()))
            XCTFail("post-await binding recheck must refuse")
        } catch DialHostError.sessionNotSelected {
            XCTAssertEqual(authorizationChecks, 2)
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func test_fresh_process_restores_clean_selection_and_exact_token_authorizes_push() throws {
        let storage = TestDeviceRingSecureStorage()
        let stateStore = DeviceRingRegistryStateStore(
            storage: storage,
            authorityDenyStore: TestDeviceRingAuthorityDenyStore()
        )
        let record = bindingRecord()
        try stateStore.save(DeviceRingRegistryState(binding: record))

        let selection = DialSessionSelectionGate()
        let restored = stateStore.restorableSelectedSessionId(credential: "bearer-a")
        selection.select(restored)
        var token = "aabbcc"
        let gate = DeviceRingBindingGate(
            stateStore: stateStore,
            credentialProvider: { "bearer-a" },
            voipTokenProvider: { token },
            isSessionSelected: selection.permits,
            now: { Date(timeIntervalSince1970: 1_900_000_000) },
            continuousNow: { 10_000 }
        )

        let authorized = SentiCallManager.prepareIncomingPush(
            pushPayload(),
            isBindingAuthorized: gate.permits
        )
        XCTAssertEqual(restored, "session-a")
        XCTAssertNotNil(authorized.state)
        XCTAssertEqual(authorized.dialId, "dial-a")

        token = "rotated"
        let mismatched = SentiCallManager.prepareIncomingPush(
            pushPayload(),
            isBindingAuthorized: gate.permits
        )
        XCTAssertNil(mismatched.state)
        XCTAssertNil(mismatched.dialId)
        XCTAssertEqual(mismatched.call.callerDisplayName, "Senti")
    }

    func test_config_loss_with_retained_binding_blocks_bearer_deletion_and_persists_denial() async throws {
        let storage = TestDeviceRingSecureStorage()
        let denial = TestDeviceRingAuthorityDenyStore()
        let stateStore = DeviceRingRegistryStateStore(
            storage: storage,
            authorityDenyStore: denial
        )
        try stateStore.save(DeviceRingRegistryState(binding: bindingRecord()))
        let host = DialHost(gatewayURL: nil, registryStateStore: stateStore)

        try host.beginSignOut()

        XCTAssertTrue(stateStore.authorityIsDenied())
        XCTAssertTrue(try stateStore.load().revocationRequested)
        do {
            try await host.prepareForSignOut()
            XCTFail("an unconfigured host must retain the bearer while a server binding still needs exact revoke")
        } catch {
            XCTAssertEqual(error as? DeviceRingSignOutError, .revocationIncomplete)
        }
    }

    func test_answer_waits_for_its_own_callkit_audio_activation() async {
        let provider = CXProvider(configuration: CXProviderConfiguration())
        let manager = SentiCallManager(provider: provider)
        let started = expectation(description: "governed dial started after audio activation")
        let call = call("dial-a")
        var startedCallUUIDs: [UUID] = []
        var audioEvents: [String] = []
        let coordinator = coordinator(
            runDial: { _, callUUID in
                startedCallUUIDs.append(callUUID)
                started.fulfill()
                return .posted
            },
            endCall: { manager.end($0) }
        )
        let host = DialHost(
            callManager: manager,
            coordinator: coordinator,
            selectedSessionId: "session-a",
            prepareCallKitAudioSession: { audioEvents.append("prepare") },
            callKitDidActivateAudioSession: { audioEvents.append("activate") },
            callKitDidDeactivateAudioSession: { audioEvents.append("deactivate") }
        )
        manager.ring(call)
        manager.onDialReceived?(.renderable(ring("dial-a")), "dial-a", call.id)

        manager.provider(provider, perform: CXAnswerCallAction(call: call.id))

        XCTAssertTrue(startedCallUUIDs.isEmpty, "answer alone must not start hydration or voice")
        manager.provider(provider, didActivate: AVAudioSession.sharedInstance())
        await fulfillment(of: [started], timeout: 1)
        manager.provider(provider, didDeactivate: AVAudioSession.sharedInstance())
        XCTAssertEqual(startedCallUUIDs, [call.id])
        XCTAssertEqual(audioEvents, ["prepare", "activate", "deactivate"])
        XCTAssertNotNil(host.callManager)
    }

    func test_call_audio_preempts_checkpoint_audio_before_governed_dial_starts() async {
        let provider = CXProvider(configuration: CXProviderConfiguration())
        let manager = SentiCallManager(provider: provider)
        let stopGate = ManualGate()
        let started = expectation(description: "governed dial starts after checkpoint audio stops")
        var runCalls = 0
        var revocations = 0
        let coordinator = coordinator(
            runDial: { _, _ in
                runCalls += 1
                started.fulfill()
                return .posted
            },
            endCall: { manager.end($0) }
        )
        let host = DialHost(
            callManager: manager,
            coordinator: coordinator,
            selectedSessionId: "session-a"
        )
        let revokerId = host.installPreemptibleAudioRevoker {
            revocations += 1
            return Task { await stopGate.wait() }
        }
        let call = call("dial-audio-owner")

        manager.ring(call)
        manager.onDialReceived?(.renderable(ring("dial-audio-owner")), "dial-audio-owner", call.id)
        XCTAssertEqual(revocations, 1)
        XCTAssertTrue(host.callAudioReservationIsActive)
        XCTAssertFalse(host.permitsPreemptibleAudio)

        manager.provider(provider, perform: CXAnswerCallAction(call: call.id))
        manager.provider(provider, didActivate: AVAudioSession.sharedInstance())
        await Task.yield()
        XCTAssertEqual(runCalls, 0, "dial speech/capture must wait for the preempted narration stop barrier")

        stopGate.open()
        await fulfillment(of: [started], timeout: 1)
        manager.provider(provider, didDeactivate: AVAudioSession.sharedInstance())
        host.removePreemptibleAudioRevoker(revokerId)
        XCTAssertTrue(host.permitsPreemptibleAudio)
    }

    func test_removed_checkpoint_audio_owner_still_blocks_immediate_governed_dial_until_stop_finishes() async {
        let provider = CXProvider(configuration: CXProviderConfiguration())
        let manager = SentiCallManager(provider: provider)
        let stopGate = ManualGate()
        let started = expectation(description: "governed dial starts after removed checkpoint owner finishes stopping")
        var runCalls = 0
        var revocations = 0
        let coordinator = coordinator(
            runDial: { _, _ in
                runCalls += 1
                started.fulfill()
                return .posted
            },
            endCall: { manager.end($0) }
        )
        let host = DialHost(
            callManager: manager,
            coordinator: coordinator,
            selectedSessionId: "session-a"
        )
        let revokerId = host.installPreemptibleAudioRevoker {
            revocations += 1
            return Task { await stopGate.wait() }
        }

        host.removePreemptibleAudioRevoker(revokerId)
        XCTAssertEqual(revocations, 1, "owner teardown must synchronously fence its asynchronous stop")

        let call = call("dial-after-checkpoint-teardown")
        manager.ring(call)
        manager.onDialReceived?(
            .renderable(ring("dial-after-checkpoint-teardown")),
            "dial-after-checkpoint-teardown",
            call.id
        )
        manager.provider(provider, perform: CXAnswerCallAction(call: call.id))
        manager.provider(provider, didActivate: AVAudioSession.sharedInstance())
        await Task.yield()
        XCTAssertEqual(runCalls, 0, "an immediate call must retain the removed owner's pending stop barrier")

        stopGate.open()
        await fulfillment(of: [started], timeout: 1)
        manager.provider(provider, didDeactivate: AVAudioSession.sharedInstance())
        XCTAssertEqual(revocations, 1)
        XCTAssertTrue(host.permitsPreemptibleAudio)
    }

    func test_audio_preparation_failure_ends_call_without_starting_governed_dial() {
        let provider = CXProvider(configuration: CXProviderConfiguration())
        var reportedEnds: [UUID] = []
        let manager = SentiCallManager(
            provider: provider,
            reportEndedCall: { reportedEnds.append($0) }
        )
        var runCalls = 0
        let coordinator = coordinator { _, _ in
            runCalls += 1
            return .posted
        }
        let host = DialHost(
            callManager: manager,
            coordinator: coordinator,
            selectedSessionId: "session-a",
            prepareCallKitAudioSession: {
                throw NSError(domain: "DialHostTests.AudioSession", code: 1)
            }
        )
        let call = call("dial-audio-setup-failed")
        manager.ring(call)
        manager.onDialReceived?(.renderable(ring("dial-audio-setup-failed")), "dial-audio-setup-failed", call.id)

        manager.provider(provider, perform: CXAnswerCallAction(call: call.id))
        manager.provider(provider, didActivate: AVAudioSession.sharedInstance())

        XCTAssertEqual(runCalls, 0)
        XCTAssertEqual(reportedEnds, [call.id])
        XCTAssertNotNil(host.callManager)
    }

    func test_deactivation_while_answer_is_pending_ends_call_and_later_activation_cannot_start() {
        let provider = CXProvider(configuration: CXProviderConfiguration())
        var reportedEnds: [UUID] = []
        let manager = SentiCallManager(
            provider: provider,
            reportEndedCall: { reportedEnds.append($0) }
        )
        var runCalls = 0
        let coordinator = coordinator { _, _ in
            runCalls += 1
            return .posted
        }
        let host = DialHost(
            callManager: manager,
            coordinator: coordinator,
            selectedSessionId: "session-a"
        )
        let call = call("dial-pending")
        manager.ring(call)
        manager.onDialReceived?(.renderable(ring("dial-pending")), "dial-pending", call.id)
        manager.provider(provider, perform: CXAnswerCallAction(call: call.id))

        manager.provider(provider, didDeactivate: AVAudioSession.sharedInstance())
        manager.provider(provider, didActivate: AVAudioSession.sharedInstance())

        XCTAssertEqual(runCalls, 0)
        XCTAssertEqual(reportedEnds, [call.id], "fail-closed deactivation must also dismiss the dead CallKit call")
        XCTAssertNotNil(host.callManager)
    }

    func test_deactivation_cancels_an_active_dial_and_ends_call() async {
        let provider = CXProvider(configuration: CXProviderConfiguration())
        var reportedEnds: [UUID] = []
        let manager = SentiCallManager(
            provider: provider,
            reportEndedCall: { reportedEnds.append($0) }
        )
        let started = expectation(description: "active dial entered governed run")
        let cancelled = expectation(description: "active dial task received cancellation")
        let finished = expectation(description: "cancelled governed run returned")
        let cancellationGate = CancellationGate(onCancel: { cancelled.fulfill() })
        let coordinator = coordinator { _, _ in
            started.fulfill()
            await cancellationGate.wait()
            finished.fulfill()
            return Task.isCancelled ? .declined("cancelled") : .posted
        }
        let host = DialHost(
            callManager: manager,
            coordinator: coordinator,
            selectedSessionId: "session-a"
        )
        let call = call("dial-active")
        manager.ring(call)
        manager.onDialReceived?(.renderable(ring("dial-active")), "dial-active", call.id)
        manager.provider(provider, perform: CXAnswerCallAction(call: call.id))
        manager.provider(provider, didActivate: AVAudioSession.sharedInstance())
        await fulfillment(of: [started], timeout: 1)

        manager.provider(provider, didDeactivate: AVAudioSession.sharedInstance())
        await fulfillment(of: [cancelled, finished], timeout: 1)

        XCTAssertEqual(reportedEnds, [call.id])
        XCTAssertNotNil(host.callManager)
    }

    func test_voip_token_rotation_cancels_active_dial_and_ends_exact_call() async {
        let provider = CXProvider(configuration: CXProviderConfiguration())
        var reportedEnds: [UUID] = []
        let manager = SentiCallManager(
            provider: provider,
            reportEndedCall: { reportedEnds.append($0) }
        )
        let started = expectation(description: "active dial entered governed run")
        let cancelled = expectation(description: "token rotation cancelled active dial")
        let finished = expectation(description: "cancelled governed run returned")
        let cancellationGate = CancellationGate(onCancel: { cancelled.fulfill() })
        let coordinator = coordinator { _, _ in
            started.fulfill()
            await cancellationGate.wait()
            finished.fulfill()
            return Task.isCancelled ? .declined("cancelled") : .posted
        }
        let host = DialHost(
            callManager: manager,
            coordinator: coordinator,
            selectedSessionId: "session-a"
        )
        manager.onVoipToken?("token-a")
        let call = call("dial-token-rotation")
        manager.ring(call)
        manager.onDialReceived?(.renderable(ring("dial-token-rotation")), "dial-token-rotation", call.id)
        manager.provider(provider, perform: CXAnswerCallAction(call: call.id))
        manager.provider(provider, didActivate: AVAudioSession.sharedInstance())
        await fulfillment(of: [started], timeout: 1)

        manager.onVoipToken?("token-b")
        XCTAssertEqual(reportedEnds, [call.id], "route rotation must synchronously dismiss the old CallKit UUID")
        await fulfillment(of: [cancelled, finished], timeout: 1)
        manager.provider(provider, didDeactivate: AVAudioSession.sharedInstance())

        XCTAssertEqual(reportedEnds, [call.id])
        XCTAssertNotNil(host.callManager)
    }

    func test_voip_token_invalidation_cancels_active_dial_and_ends_exact_call() async {
        let provider = CXProvider(configuration: CXProviderConfiguration())
        var reportedEnds: [UUID] = []
        let manager = SentiCallManager(
            provider: provider,
            reportEndedCall: { reportedEnds.append($0) }
        )
        let started = expectation(description: "active dial entered governed run")
        let cancelled = expectation(description: "token invalidation cancelled active dial")
        let finished = expectation(description: "cancelled governed run returned")
        let cancellationGate = CancellationGate(onCancel: { cancelled.fulfill() })
        let coordinator = coordinator { _, _ in
            started.fulfill()
            await cancellationGate.wait()
            finished.fulfill()
            return Task.isCancelled ? .declined("cancelled") : .posted
        }
        let host = DialHost(
            callManager: manager,
            coordinator: coordinator,
            selectedSessionId: "session-a"
        )
        manager.onVoipToken?("token-a")
        let call = call("dial-token-invalidated")
        manager.ring(call)
        manager.onDialReceived?(.renderable(ring("dial-token-invalidated")), "dial-token-invalidated", call.id)
        manager.provider(provider, perform: CXAnswerCallAction(call: call.id))
        manager.provider(provider, didActivate: AVAudioSession.sharedInstance())
        await fulfillment(of: [started], timeout: 1)

        manager.onVoipTokenInvalidated?()
        XCTAssertEqual(reportedEnds, [call.id], "route invalidation must synchronously dismiss the old CallKit UUID")
        await fulfillment(of: [cancelled, finished], timeout: 1)
        manager.provider(provider, didDeactivate: AVAudioSession.sharedInstance())

        XCTAssertEqual(reportedEnds, [call.id])
        XCTAssertNotNil(host.callManager)
    }

    func test_binding_authority_invalidation_cancels_active_dial_and_ends_exact_call() async {
        let provider = CXProvider(configuration: CXProviderConfiguration())
        var reportedEnds: [UUID] = []
        let manager = SentiCallManager(
            provider: provider,
            reportEndedCall: { reportedEnds.append($0) }
        )
        let started = expectation(description: "active dial entered governed run")
        let cancelled = expectation(description: "binding invalidation cancelled active dial")
        let finished = expectation(description: "cancelled governed run returned")
        let cancellationGate = CancellationGate(onCancel: { cancelled.fulfill() })
        let coordinator = coordinator { _, _ in
            started.fulfill()
            await cancellationGate.wait()
            finished.fulfill()
            return Task.isCancelled ? .declined("cancelled") : .posted
        }
        let host = DialHost(
            callManager: manager,
            coordinator: coordinator,
            selectedSessionId: "session-a"
        )
        let call = call("dial-binding-invalidated")
        manager.ring(call)
        manager.onDialReceived?(.renderable(ring("dial-binding-invalidated")), "dial-binding-invalidated", call.id)
        manager.provider(provider, perform: CXAnswerCallAction(call: call.id))
        manager.provider(provider, didActivate: AVAudioSession.sharedInstance())
        await fulfillment(of: [started], timeout: 1)

        host.bindingAuthorityInvalidated()
        XCTAssertEqual(reportedEnds, [call.id], "binding loss must synchronously dismiss the old CallKit UUID")
        await fulfillment(of: [cancelled, finished], timeout: 1)
        manager.provider(provider, didDeactivate: AVAudioSession.sharedInstance())

        XCTAssertEqual(reportedEnds, [call.id])
        XCTAssertNotNil(host.callManager)
    }

    func test_same_voip_token_replay_preserves_active_dial() async {
        let provider = CXProvider(configuration: CXProviderConfiguration())
        var reportedEnds: [UUID] = []
        let manager = SentiCallManager(
            provider: provider,
            currentVoipToken: { "token-a" },
            reportEndedCall: { reportedEnds.append($0) }
        )
        let started = expectation(description: "active dial entered governed run")
        let cancelled = expectation(description: "cleanup cancelled active dial")
        let finished = expectation(description: "cancelled governed run returned")
        let cancellationGate = CancellationGate(onCancel: { cancelled.fulfill() })
        let coordinator = coordinator { _, _ in
            started.fulfill()
            await cancellationGate.wait()
            finished.fulfill()
            return Task.isCancelled ? .declined("cancelled") : .posted
        }
        let host = DialHost(
            callManager: manager,
            coordinator: coordinator,
            selectedSessionId: "session-a"
        )
        let call = call("dial-token-replay")
        manager.ring(call)
        manager.onDialReceived?(.renderable(ring("dial-token-replay")), "dial-token-replay", call.id)
        manager.provider(provider, perform: CXAnswerCallAction(call: call.id))
        manager.provider(provider, didActivate: AVAudioSession.sharedInstance())
        await fulfillment(of: [started], timeout: 1)

        manager.replayCurrentVoipToken()
        XCTAssertEqual(reportedEnds, [], "replaying the current route must not revoke a live call")

        manager.onVoipTokenInvalidated?()
        await fulfillment(of: [cancelled, finished], timeout: 1)
        manager.provider(provider, didDeactivate: AVAudioSession.sharedInstance())
        XCTAssertEqual(reportedEnds, [call.id])
        XCTAssertNotNil(host.callManager)
    }

    func test_sequential_answer_requires_fresh_activation_after_first_dial_finishes() async {
        let provider = CXProvider(configuration: CXProviderConfiguration())
        let firstStarted = expectation(description: "first dial started")
        let firstEnded = expectation(description: "first CallKit episode ended")
        let secondStarted = expectation(description: "second dial started")
        var firstCallUUID: UUID?
        let manager = SentiCallManager(
            provider: provider,
            reportEndedCall: { uuid in
                if uuid == firstCallUUID { firstEnded.fulfill() }
            }
        )
        var startedCallUUIDs: [UUID] = []
        let coordinator = coordinator(
            runDial: { _, callUUID in
                startedCallUUIDs.append(callUUID)
                if startedCallUUIDs.count == 1 {
                    firstStarted.fulfill()
                } else if startedCallUUIDs.count == 2 {
                    secondStarted.fulfill()
                }
                return .posted
            },
            endCall: { manager.end($0) }
        )
        let host = DialHost(
            callManager: manager,
            coordinator: coordinator,
            selectedSessionId: "session-a"
        )
        let first = call("dial-first")
        firstCallUUID = first.id
        manager.ring(first)
        manager.onDialReceived?(.renderable(ring("dial-first")), "dial-first", first.id)
        manager.provider(provider, perform: CXAnswerCallAction(call: first.id))
        manager.provider(provider, didActivate: AVAudioSession.sharedInstance())
        await fulfillment(of: [firstStarted, firstEnded], timeout: 1)
        manager.provider(provider, didDeactivate: AVAudioSession.sharedInstance())

        let second = call("dial-second")
        manager.ring(second)
        manager.onDialReceived?(.renderable(ring("dial-second")), "dial-second", second.id)
        manager.provider(provider, perform: CXAnswerCallAction(call: second.id))

        XCTAssertEqual(startedCallUUIDs, [first.id], "the first call's activation must not authorize a later answer")
        manager.provider(provider, didActivate: AVAudioSession.sharedInstance())
        await fulfillment(of: [secondStarted], timeout: 1)
        manager.provider(provider, didDeactivate: AVAudioSession.sharedInstance())
        XCTAssertEqual(startedCallUUIDs, [first.id, second.id])
        XCTAssertNotNil(host.callManager)
    }
}
#endif
