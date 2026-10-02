#if os(iOS) && canImport(RealtimeKit)
import Foundation
import RealtimeKit

public struct RealtimeKitVoiceMediaDriverFactory: VoiceMediaDriverFactory {
    public init() {}

    public func makeDriver() async -> any VoiceMediaDriver {
        RealtimeKitVoiceMediaDriver()
    }
}

public actor RealtimeKitVoiceMediaDriver: VoiceMediaDriver {
    private var client: RealtimeKitClient?
    private var relay: RealtimeKitEventRelay?
    private var roomConnectionState: VoiceRoomConnectionState = .disconnected
    private var mediaConnectionState: VoiceRoomConnectionState = .disconnected
    private var socketConnectionState: VoiceRoomConnectionState = .disconnected
    private var presenceRevision: UInt64 = 0
    private var eventContinuations:
        [UUID: AsyncStream<VoiceMediaDriverEvent>.Continuation] = [:]

    public init() {}

    public func connect(
        credential: String,
        initialMicrophoneEnabled: Bool
    ) async throws -> VoiceMediaDriverState {
        guard client == nil, !credential.isEmpty else {
            throw VoiceTransportError.providerUnavailable
        }

        let createdClient = RealtimeKitiOSClientBuilder().build()
        createdClient.enableLogging(enabled: false)
        let relay = RealtimeKitEventRelay { [weak self] signal in
            Task {
                await self?.receive(signal)
            }
        }
        add(relay: relay, to: createdClient)
        self.client = createdClient
        self.relay = relay
        roomConnectionState = .joining
        mediaConnectionState = .joining
        socketConnectionState = .joining

        do {
            let meetingInfo = RtkMeetingInfo(
                authToken: credential,
                enableAudio: initialMicrophoneEnabled,
                enableVideo: false
            )
            try await initialize(createdClient, meetingInfo: meetingInfo)
            try await join(createdClient)
            roomConnectionState = .joined
            mediaConnectionState = .joined
            socketConnectionState = .joined
            return try makeState()
        } catch {
            await release(createdClient, relay: relay)
            self.client = nil
            self.relay = nil
            roomConnectionState = .failed
            mediaConnectionState = .failed
            socketConnectionState = .failed
            throw VoiceTransportError.providerUnavailable
        }
    }

    public func disconnect(reason: VoiceClientLeaveReason) async {
        guard let client else {
            markAllChannels(.disconnected)
            return
        }
        let relay = self.relay
        self.client = nil
        self.relay = nil
        markAllChannels(.disconnected)
        await release(client, relay: relay)
    }

    public func setMicrophoneEnabled(_ enabled: Bool) async throws -> VoiceMediaDriverState {
        guard let client else {
            throw VoiceTransportError.notConnected
        }
        try await withCheckedThrowingContinuation { continuation in
            let completion: (AudioError?) -> Void = { error in
                if error == nil {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: VoiceTransportError.capabilityDenied)
                }
            }
            if enabled {
                client.localUser.enableAudio(onResult: completion)
            } else {
                client.localUser.disableAudio(onResult: completion)
            }
        }
        return try makeState()
    }

    public func selectInput(deviceId: String) async throws -> VoiceMediaDriverState {
        try selectAudioRoute(id: deviceId)
        return try makeState()
    }

    public func selectOutput(routeId: String) async throws -> VoiceMediaDriverState {
        try selectAudioRoute(id: routeId)
        return try makeState()
    }

    public func raiseHand() async throws -> VoiceMediaDriverState {
        guard let client else {
            throw VoiceTransportError.notConnected
        }
        guard client.stage.requestAccess() == nil else {
            throw VoiceTransportError.capabilityDenied
        }
        return try makeState()
    }

    public func cancelHandRaise() async throws -> VoiceMediaDriverState {
        guard let client else {
            throw VoiceTransportError.notConnected
        }
        guard client.stage.cancelRequestAccess() == nil else {
            throw VoiceTransportError.capabilityDenied
        }
        return try makeState()
    }

    public func events() async -> AsyncStream<VoiceMediaDriverEvent> {
        let id = UUID()
        let pair = AsyncStream<VoiceMediaDriverEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        eventContinuations[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeContinuation(id)
            }
        }
        return pair.stream
    }

    private func initialize(
        _ client: RealtimeKitClient,
        meetingInfo: RtkMeetingInfo
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            client.doInit(
                meetingInfo: meetingInfo,
                onSuccess: {
                    continuation.resume()
                },
                onFailure: { _ in
                    continuation.resume(throwing: VoiceTransportError.providerUnavailable)
                }
            )
        }
    }

    private func join(_ client: RealtimeKitClient) async throws {
        try await withCheckedThrowingContinuation { continuation in
            client.joinRoom(
                onSuccess: {
                    continuation.resume()
                },
                onFailure: { _ in
                    continuation.resume(throwing: VoiceTransportError.providerUnavailable)
                }
            )
        }
    }

    private func release(
        _ client: RealtimeKitClient,
        relay: RealtimeKitEventRelay?
    ) async {
        if let relay {
            remove(relay: relay, from: client)
        }
        await withCheckedContinuation { continuation in
            client.leaveRoom(
                onSuccess: {
                    continuation.resume()
                },
                onFailure: { _ in
                    continuation.resume()
                }
            )
        }
        await withCheckedContinuation { continuation in
            client.release(
                onSuccess: {
                    continuation.resume()
                },
                onFailure: { _ in
                    continuation.resume()
                }
            )
        }
    }

    private nonisolated func add(
        relay: RealtimeKitEventRelay,
        to client: RealtimeKitClient
    ) {
        client.addMeetingRoomEventListener(meetingRoomEventListener: relay)
        client.addSelfEventListener(selfEventListener: relay)
        client.addParticipantsEventListener(participantsEventListener: relay)
        client.addStageEventListener(stageEventListener: relay)
    }

    private nonisolated func remove(
        relay: RealtimeKitEventRelay,
        from client: RealtimeKitClient
    ) {
        client.removeMeetingRoomEventListener(meetingRoomEventListener: relay)
        client.removeSelfEventListener(selfEventListener: relay)
        client.removeParticipantsEventListener(participantsEventListener: relay)
        client.removeStageEventListener(stageEventListener: relay)
    }

    private func selectAudioRoute(id: String) throws {
        guard let client else {
            throw VoiceTransportError.notConnected
        }
        guard let route = client.localUser
            .getAudioDevices()
            .first(where: { $0.id == id }) else {
            throw VoiceTransportError.routeUnavailable
        }
        client.localUser.setAudioDevice(rtkAudioDevice: route)
    }

    private func receive(_ signal: RealtimeKitRelaySignal) async {
        switch signal {
        case .refresh:
            emitCurrentState()
        case .roomConnection(let state):
            roomConnectionState = state
            if state == .disconnected || state == .failed {
                mediaConnectionState = state
                socketConnectionState = state
            }
            emitCurrentState()
        case .mediaConnection(let state):
            mediaConnectionState = state
            emitCurrentState()
        case .socketConnection(let state):
            socketConnectionState = state
            emitCurrentState()
        case .terminal(let code, let message, let recoverable):
            let envelope = VoiceRoomErrorEnvelope(
                code: code,
                message: message,
                requestId: "driver",
                recoverable: recoverable
            )
            emit(.terminal(envelope))
        }
    }

    private func emitCurrentState() {
        guard let state = try? makeState() else { return }
        emit(.stateChanged(state))
    }

    private func emit(_ event: VoiceMediaDriverEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func removeContinuation(_ id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    private func markAllChannels(_ state: VoiceRoomConnectionState) {
        roomConnectionState = state
        mediaConnectionState = state
        socketConnectionState = state
    }

    private func makeState() throws -> VoiceMediaDriverState {
        guard let client else {
            throw VoiceTransportError.notConnected
        }
        presenceRevision &+= 1
        let localUser = client.localUser
        let routes = localUser.getAudioDevices().map(Self.route)
        let selectedRouteId = localUser.getSelectedAudioDevice()?.id
        // RealtimeKit's customParticipantId is the server-issued opaque
        // participant correlation key, not the canonical Senti principalId.
        // Do not invent a principal mapping in the media adapter. Remote
        // roster/stage projection remains empty until the authenticated Senti
        // control stream supplies the server-owned binding.
        let participants: [VoiceMediaDriverParticipant] = []
        let activeSpeakers: [String] = []
        let stageStatus = localUser.stageStatus
        let selfCanPublish = stageStatus == .onStage
            || stageStatus == .acceptedToJoinStage
            || localUser.canJoinStage()

        return VoiceMediaDriverState(
            presenceRevision: presenceRevision,
            roomState: .open,
            connectionState: combinedConnectionState(),
            selfProviderParticipantId: localUser.userId,
            selfProviderCorrelationId: localUser.customParticipantId,
            selfMicrophoneEnabled: localUser.audioEnabled,
            selfCanPublish: selfCanPublish,
            selfHandRaised: stageStatus == .requestedToJoinStage,
            participants: participants,
            activeSpeakerPrincipalIds: activeSpeakers,
            joinedCount: max(0, Int(client.participants.totalCount) + (localUser.roomJoined ? 1 : 0)),
            availableInputDevices: routes,
            availableOutputRoutes: routes,
            selectedInputDeviceId: selectedRouteId,
            selectedOutputRouteId: selectedRouteId,
            outputSelectionSupported: !routes.isEmpty
        )
    }

    private func combinedConnectionState() -> VoiceRoomConnectionState {
        let states = [
            roomConnectionState,
            mediaConnectionState,
            socketConnectionState,
        ]
        if states.contains(.failed) {
            return .failed
        }
        if states.contains(.disconnected) {
            return .disconnected
        }
        if states.contains(.reconnecting) {
            return .reconnecting
        }
        if states.allSatisfy({ $0 == .joined }) {
            return .joined
        }
        return .joining
    }

    private static func route(_ device: AudioDevice) -> VoiceAudioRoute {
        VoiceAudioRoute(
            id: device.id,
            displayName: String(device.type.displayName.prefix(200)),
            kind: routeKind(device.type)
        )
    }

    private static func routeKind(
        _ type: RealtimeKit.AudioDeviceType
    ) -> VoiceAudioRouteKind {
        switch type {
        case .earPiece: return .receiver
        case .speaker: return .speaker
        case .wired: return .wired
        case .bluetooth: return .bluetooth
        case .unknown: return .unknown
        }
    }
}

private enum RealtimeKitRelaySignal: Sendable {
    case refresh
    case roomConnection(VoiceRoomConnectionState)
    case mediaConnection(VoiceRoomConnectionState)
    case socketConnection(VoiceRoomConnectionState)
    case terminal(VoiceRoomErrorCode, String, Bool)
}

private final class RealtimeKitEventRelay:
    NSObject,
    RtkMeetingRoomEventListener,
    RtkSelfEventListener,
    RtkParticipantsEventListener,
    RtkStageEventListener,
    @unchecked Sendable
{
    private let handler: @Sendable (RealtimeKitRelaySignal) -> Void

    init(handler: @escaping @Sendable (RealtimeKitRelaySignal) -> Void) {
        self.handler = handler
    }

    func onActiveTabUpdate(meeting: RealtimeKitClient, activeTab: ActiveTab) {}
    func onMeetingEnded() {
        handler(.terminal(.roomEnded, "The voice room ended.", false))
    }
    func onMeetingInitCompleted(meeting: RealtimeKitClient) {
        handler(.refresh)
    }
    func onMeetingInitFailed(error: MeetingError) {
        handler(.terminal(.providerUnavailable, "The voice room could not initialize.", true))
    }
    func onMeetingInitStarted() {
        handler(.roomConnection(.joining))
    }
    func onMeetingRoomJoinCompleted(meeting: RealtimeKitClient) {
        handler(.roomConnection(.joined))
    }
    func onMeetingRoomJoinFailed(error: MeetingError) {
        handler(.terminal(.providerUnavailable, "The voice room could not connect.", true))
    }
    func onMeetingRoomJoinStarted() {
        handler(.roomConnection(.joining))
    }
    func onMeetingRoomLeaveCompleted() {
        handler(.roomConnection(.disconnected))
    }
    func onMeetingRoomLeaveStarted() {}

    func onMediaConnectionUpdate(update: MediaConnectionUpdate) {
        switch update.state {
        case .connected:
            handler(.mediaConnection(.joined))
        case .connecting, .theNew:
            handler(.mediaConnection(.joining))
        case .reconnecting:
            handler(.mediaConnection(.reconnecting))
        case .disconnected:
            handler(.mediaConnection(.disconnected))
        case .failed:
            handler(.terminal(.providerUnavailable, "The voice media connection failed.", true))
        }
    }

    func onSocketConnectionUpdate(newState: SocketConnectionState) {
        switch newState.socketState {
        case .connected:
            handler(.socketConnection(.joined))
        case .reconnecting:
            handler(.socketConnection(.reconnecting))
        case .disconnected:
            handler(.socketConnection(.disconnected))
        case .failed:
            handler(.terminal(.providerUnavailable, "The voice control connection failed.", true))
        }
    }

    func onAudioDeviceChanged(audioDevice: AudioDevice) {
        handler(.refresh)
    }
    func onAudioDevicesUpdated(devices: [AudioDevice]) {
        handler(.refresh)
    }
    func onAudioUpdate(isEnabled: Bool) {
        handler(.refresh)
    }
    func onMeetingRoomJoinedWithoutCameraPermission() {}
    func onMeetingRoomJoinedWithoutMicPermission() {
        // Listen-only joins are valid without microphone permission. A later
        // user-initiated enableAudio call remains the permission boundary.
        handler(.refresh)
    }
    func onPermissionsUpdated(permission: SelfPermissions) {
        handler(.refresh)
    }
    func onPinned() {
        handler(.refresh)
    }
    func onRemovedFromMeeting() {
        handler(.terminal(.joinNotAuthorized, "You were removed from the voice room.", false))
    }
    func onScreenShareStartFailed(reason: String) {}
    func onScreenShareUpdate(isEnabled: Bool) {}
    func onUnpinned() {
        handler(.refresh)
    }
    func onUpdate(participant: RtkSelfParticipant) {
        handler(.refresh)
    }
    func onVideoDeviceChanged(videoDevice: VideoDevice) {}
    func onVideoUpdate(isEnabled: Bool) {}
    func onWaitListStatusUpdate(waitListStatus: RealtimeKit.WaitListStatus) {
        handler(.refresh)
    }

    func onActiveParticipantsChanged(active: [RtkRemoteParticipant]) {
        handler(.refresh)
    }
    func onActiveSpeakerChanged(participant: RtkRemoteParticipant?) {
        handler(.refresh)
    }
    func onAllParticipantsUpdated(allParticipants: [RtkParticipant]) {
        handler(.refresh)
    }
    func onAudioUpdate(participant: RtkRemoteParticipant, isEnabled: Bool) {
        handler(.refresh)
    }
    func onNewBroadcastMessage(type: String, payload: [String: Any]) {}
    func onParticipantJoin(participant: RtkRemoteParticipant) {
        handler(.refresh)
    }
    func onParticipantLeave(participant: RtkRemoteParticipant) {
        handler(.refresh)
    }
    func onParticipantPinned(participant: RtkRemoteParticipant) {
        handler(.refresh)
    }
    func onParticipantUnpinned(participant: RtkRemoteParticipant) {
        handler(.refresh)
    }
    func onScreenShareUpdate(participant: RtkRemoteParticipant, isEnabled: Bool) {}
    func onUpdate(participants: RtkParticipants) {
        handler(.refresh)
    }
    func onVideoUpdate(participant: RtkRemoteParticipant, isEnabled: Bool) {}

    func onNewStageAccessRequest(participant: RtkRemoteParticipant) {
        handler(.refresh)
    }
    func onPeerStageStatusUpdated(
        participant: RtkRemoteParticipant,
        oldStatus: RealtimeKit.StageStatus,
        newStatus: RealtimeKit.StageStatus
    ) {
        handler(.refresh)
    }
    func onRemovedFromStage() {
        handler(.refresh)
    }
    func onStageAccessRequestAccepted() {
        handler(.refresh)
    }
    func onStageAccessRequestRejected() {
        handler(.refresh)
    }
    func onStageAccessRequestsUpdated(accessRequests: [RtkRemoteParticipant]) {
        handler(.refresh)
    }
    func onStageStatusUpdated(
        oldStatus: RealtimeKit.StageStatus,
        newStatus: RealtimeKit.StageStatus
    ) {
        handler(.refresh)
    }
}
#endif
