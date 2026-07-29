import Foundation
@testable import PocketVoice
import XCTest

final class VoiceMediaTransportTests: XCTestCase {
    func testJoinResponseDecodesCredentialIntoRedactedSingleUseHandle() async throws {
        let token = "provider-token-that-must-never-enter-view-state"
        let data = Data(
            """
            {
              "requestId": "request-join-0001",
              "credential": {
                "room": {
                  "tenantId": "tenant-demo",
                  "provider": "cloudflare-realtimekit",
                  "sessionId": "6cf7e861-546a-4b9f-b937-39182a5bd395",
                  "roomEpoch": "5a73635c-cbd2-4e22-b24e-9a31520a939c"
                },
                "role": "listener",
                "principalId": "human-carter",
                "participantId": "participant-01",
                "providerCorrelationId": "senti_self-correlation",
                "authToken": "\(token)",
                "issuedAt": "2026-07-29T08:00:00.000Z",
                "clientDiscardAfter": "2026-07-29T08:05:00.000Z",
                "providerScope": "single-participant-single-meeting",
                "providerExpiry": "time-bound-undisclosed",
                "controlRevision": 7,
                "capabilities": {
                  "canPublishAudio": false,
                  "canRaiseHand": true,
                  "canCancelHandRaise": true,
                  "moderationActions": []
                }
              }
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(VoiceJoinResponse.self, from: data)

        XCTAssertEqual(response.grant.identity.tenantId, "tenant-demo")
        XCTAssertEqual(response.grant.initialControlRevision, 7)
        XCTAssertFalse(response.grant.capabilities.canPublishAudio)
        XCTAssertFalse(response.grant.description.contains(token))
        XCTAssertFalse(response.grant.credential.description.contains(token))

        let taken = try await response.grant.credential.take(
            at: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-29T08:01:00Z"))
        )
        XCTAssertEqual(taken, token)
        await XCTAssertThrowsVoiceError(.credentialConsumed) {
            try await response.grant.credential.take(
                at: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-29T08:02:00Z"))
            )
        }
    }

    func testExpiredCredentialFailsClosedAndIsDiscarded() async throws {
        let discardAfter = Date(timeIntervalSince1970: 100)
        let handle = try VoiceJoinCredentialHandle(
            credential: "expired-provider-token",
            discardAfter: discardAfter
        )

        await XCTAssertThrowsVoiceError(.credentialExpired) {
            try await handle.take(at: Date(timeIntervalSince1970: 101))
        }
        let isAvailable = await handle.isAvailable(at: Date(timeIntervalSince1970: 99))
        XCTAssertFalse(isAvailable)
    }

    func testJoinResponseRejectsCredentialRetentionBeyondFiveMinutes() throws {
        let data = Data(
            """
            {
              "requestId": "request-join-overlong",
              "credential": {
                "room": {
                  "tenantId": "tenant-demo",
                  "provider": "cloudflare-realtimekit",
                  "sessionId": "session-demo",
                  "roomEpoch": "epoch-demo"
                },
                "role": "listener",
                "principalId": "human-carter",
                "participantId": "participant-01",
                "providerCorrelationId": "senti_self-correlation",
                "authToken": "provider-token",
                "issuedAt": "2026-07-29T08:00:00.000Z",
                "clientDiscardAfter": "2026-07-29T08:05:01.000Z",
                "providerScope": "single-participant-single-meeting",
                "providerExpiry": "time-bound-undisclosed",
                "controlRevision": 0,
                "capabilities": {
                  "canPublishAudio": false,
                  "canRaiseHand": true,
                  "canCancelHandRaise": true,
                  "moderationActions": []
                }
              }
            }
            """.utf8
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(VoiceJoinResponse.self, from: data)
        ) { error in
            XCTAssertEqual(error as? VoiceTransportError, .invalidGrant)
        }
    }

    func testJoinResponseRejectsListenerPublishCapability() throws {
        let data = Data(
            """
            {
              "requestId": "request-join-escalated",
              "credential": {
                "room": {
                  "tenantId": "tenant-demo",
                  "provider": "cloudflare-realtimekit",
                  "sessionId": "session-demo",
                  "roomEpoch": "epoch-demo"
                },
                "role": "listener",
                "principalId": "human-carter",
                "participantId": "participant-01",
                "providerCorrelationId": "senti_self-correlation",
                "authToken": "provider-token",
                "issuedAt": "2026-07-29T08:00:00.000Z",
                "clientDiscardAfter": "2026-07-29T08:05:00.000Z",
                "providerScope": "single-participant-single-meeting",
                "providerExpiry": "time-bound-undisclosed",
                "controlRevision": 0,
                "capabilities": {
                  "canPublishAudio": true,
                  "canRaiseHand": true,
                  "canCancelHandRaise": true,
                  "moderationActions": []
                }
              }
            }
            """.utf8
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(VoiceJoinResponse.self, from: data)
        ) { error in
            XCTAssertEqual(error as? VoiceTransportError, .invalidGrant)
        }
    }

    func testListenerCannotEnableMicrophoneAndProviderStartsMuted() async throws {
        let driver = FakeVoiceMediaDriver(state: .connected())
        let factory = FakeVoiceMediaDriverFactory(drivers: [driver])
        let transport = ProviderNeutralVoiceMediaTransport(driverFactory: factory)
        let grant = try makeGrant(
            epoch: "epoch-listener",
            role: .listener,
            capabilities: VoiceJoinCapabilities(
                canPublishAudio: false,
                canRaiseHand: true,
                canCancelHandRaise: true,
                moderationActions: []
            )
        )

        let snapshot = try await transport.connect(grant: grant)
        let initialMicrophoneEnabled = await driver.initialMicrophoneEnabled

        XCTAssertEqual(snapshot.connectionState, .joined)
        XCTAssertFalse(snapshot.selfParticipant.microphoneEnabled)
        XCTAssertFalse(initialMicrophoneEnabled)
        await XCTAssertThrowsVoiceError(.capabilityDenied) {
            _ = try await transport.setMicrophoneEnabled(true)
        }
        let microphoneMutationCount = await driver.microphoneMutationCount
        XCTAssertEqual(microphoneMutationCount, 0)
    }

    func testSupersededDriverEventsCannotCorruptNewEpoch() async throws {
        let first = FakeVoiceMediaDriver(state: .connected())
        let second = FakeVoiceMediaDriver(state: .connected())
        let factory = FakeVoiceMediaDriverFactory(drivers: [first, second])
        let transport = ProviderNeutralVoiceMediaTransport(driverFactory: factory)
        let capabilities = VoiceJoinCapabilities(
            canPublishAudio: true,
            canRaiseHand: false,
            canCancelHandRaise: false,
            moderationActions: []
        )

        _ = try await transport.connect(
            grant: makeGrant(epoch: "epoch-first", role: .speaker, capabilities: capabilities)
        )
        _ = try await transport.connect(
            grant: makeGrant(epoch: "epoch-second", role: .speaker, capabilities: capabilities)
        )
        await first.emit(
            .stateChanged(
                .connected(
                    presenceRevision: 999,
                    activeSpeakerPrincipalIds: ["stale-principal"]
                )
            )
        )
        await Task.yield()
        await Task.yield()

        let observedSnapshot = await transport.currentSnapshot()
        let current = try XCTUnwrap(observedSnapshot)
        XCTAssertEqual(current.identity.voiceRoomEpochId, "epoch-second")
        XCTAssertFalse(current.activeSpeakerPrincipalIds.contains("stale-principal"))
    }

    func testModerationRequiresServerControlPlaneAndHasNoRemoteUnmuteAction() async throws {
        let driver = FakeVoiceMediaDriver(state: .connected())
        let factory = FakeVoiceMediaDriverFactory(drivers: [driver])
        let transport = ProviderNeutralVoiceMediaTransport(driverFactory: factory)
        let grant = try makeGrant(
            epoch: "epoch-moderator",
            role: .moderator,
            capabilities: VoiceJoinCapabilities(
                canPublishAudio: true,
                canRaiseHand: false,
                canCancelHandRaise: false,
                moderationActions: Set(VoiceModerationAction.allCases)
            )
        )
        _ = try await transport.connect(grant: grant)
        let command = try VoiceModerationCommand(
            commandId: "command-0001",
            idempotencyKey: "moderation-command-0001",
            expectedRevision: 0,
            targetPrincipalId: "target-principal",
            action: .mute
        )

        await XCTAssertThrowsVoiceError(.controlPlaneRequired) {
            _ = try await transport.moderate(command: command)
        }
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                VoiceModerationAction.self,
                from: Data(#""force_unmute""#.utf8)
            )
        )
    }

    private func makeGrant(
        epoch: String,
        role: VoiceParticipantRole,
        capabilities: VoiceJoinCapabilities
    ) throws -> VoiceJoinGrant {
        let issuedAt = Date(timeIntervalSince1970: 1_000)
        let handle = try VoiceJoinCredentialHandle(
            credential: "single-use-provider-token-\(epoch)",
            discardAfter: issuedAt.addingTimeInterval(5 * 60)
        )
        return try VoiceJoinGrant(
            requestId: "request-\(epoch)-0001",
            identity: VoiceRoomIdentity(
                tenantId: "tenant-demo",
                sentiSessionId: "session-demo",
                voiceRoomEpochId: epoch
            ),
            provider: .cloudflareRealtimeKit,
            principalId: "human-carter",
            providerParticipantId: "participant-\(epoch)",
            providerCorrelationId: "senti_self-correlation",
            role: role,
            capabilities: capabilities,
            initialControlRevision: 0,
            issuedAt: issuedAt,
            credentialScope: .singleParticipantSingleMeeting,
            providerExpiry: .timeBoundUndisclosed,
            credential: handle
        )
    }
}

private actor FakeVoiceMediaDriverFactory: VoiceMediaDriverFactory {
    private var drivers: [FakeVoiceMediaDriver]

    init(drivers: [FakeVoiceMediaDriver]) {
        self.drivers = drivers
    }

    func makeDriver() async -> any VoiceMediaDriver {
        precondition(!drivers.isEmpty)
        return drivers.removeFirst()
    }
}

private actor FakeVoiceMediaDriver: VoiceMediaDriver {
    private var state: VoiceMediaDriverState
    private let stream: AsyncStream<VoiceMediaDriverEvent>
    private let continuation: AsyncStream<VoiceMediaDriverEvent>.Continuation
    private(set) var initialMicrophoneEnabled = true
    private(set) var microphoneMutationCount = 0

    init(state: VoiceMediaDriverState) {
        self.state = state
        let pair = AsyncStream<VoiceMediaDriverEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
        )
        self.stream = pair.stream
        self.continuation = pair.continuation
    }

    func connect(
        credential: String,
        initialMicrophoneEnabled: Bool
    ) async throws -> VoiceMediaDriverState {
        precondition(!credential.isEmpty)
        self.initialMicrophoneEnabled = initialMicrophoneEnabled
        state = state.replacing(microphoneEnabled: initialMicrophoneEnabled)
        return state
    }

    func disconnect(reason: VoiceClientLeaveReason) async {}

    func setMicrophoneEnabled(_ enabled: Bool) async throws -> VoiceMediaDriverState {
        microphoneMutationCount += 1
        state = state.replacing(microphoneEnabled: enabled)
        return state
    }

    func selectInput(deviceId: String) async throws -> VoiceMediaDriverState {
        state
    }

    func selectOutput(routeId: String) async throws -> VoiceMediaDriverState {
        state
    }

    func raiseHand() async throws -> VoiceMediaDriverState {
        state = state.replacing(handRaised: true)
        return state
    }

    func cancelHandRaise() async throws -> VoiceMediaDriverState {
        state = state.replacing(handRaised: false)
        return state
    }

    func events() async -> AsyncStream<VoiceMediaDriverEvent> {
        stream
    }

    func emit(_ event: VoiceMediaDriverEvent) {
        continuation.yield(event)
    }
}

private extension VoiceMediaDriverState {
    static func connected(
        presenceRevision: UInt64 = 1,
        activeSpeakerPrincipalIds: [String] = []
    ) -> VoiceMediaDriverState {
        VoiceMediaDriverState(
            presenceRevision: presenceRevision,
            roomState: .open,
            connectionState: .joined,
            selfProviderParticipantId: "provider-self",
            selfProviderCorrelationId: "senti_self-correlation",
            selfMicrophoneEnabled: false,
            selfCanPublish: true,
            selfHandRaised: false,
            participants: [],
            activeSpeakerPrincipalIds: activeSpeakerPrincipalIds,
            joinedCount: 1,
            availableInputDevices: [
                VoiceAudioRoute(id: "builtin", displayName: "iPhone", kind: .receiver)
            ],
            availableOutputRoutes: [
                VoiceAudioRoute(id: "speaker", displayName: "Speaker", kind: .speaker)
            ],
            selectedInputDeviceId: "builtin",
            selectedOutputRouteId: "speaker",
            outputSelectionSupported: true
        )
    }

    func replacing(
        microphoneEnabled: Bool? = nil,
        handRaised: Bool? = nil
    ) -> VoiceMediaDriverState {
        VoiceMediaDriverState(
            presenceRevision: presenceRevision + 1,
            roomState: roomState,
            connectionState: connectionState,
            selfProviderParticipantId: selfProviderParticipantId,
            selfProviderCorrelationId: selfProviderCorrelationId,
            selfMicrophoneEnabled: microphoneEnabled ?? selfMicrophoneEnabled,
            selfCanPublish: selfCanPublish,
            selfHandRaised: handRaised ?? selfHandRaised,
            participants: participants,
            activeSpeakerPrincipalIds: activeSpeakerPrincipalIds,
            joinedCount: joinedCount,
            availableInputDevices: availableInputDevices,
            availableOutputRoutes: availableOutputRoutes,
            selectedInputDeviceId: selectedInputDeviceId,
            selectedOutputRouteId: selectedOutputRouteId,
            outputSelectionSupported: outputSelectionSupported
        )
    }
}

private func XCTAssertThrowsVoiceError<T>(
    _ expected: VoiceTransportError,
    operation: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await operation()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch let error as VoiceTransportError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}
