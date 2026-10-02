import Foundation

public protocol VoiceMediaTransport: Sendable {
    func connect(grant: VoiceJoinGrant) async throws -> VoiceRoomSnapshot
    func disconnect(reason: VoiceClientLeaveReason) async
    func setMicrophoneEnabled(_ enabled: Bool) async throws -> VoiceRoomSnapshot
    func selectInput(deviceId: String) async throws -> VoiceRoomSnapshot
    func selectOutput(routeId: String) async throws -> VoiceRoomSnapshot
    func raiseHand() async throws -> VoiceRoomSnapshot
    func cancelHandRaise() async throws -> VoiceRoomSnapshot
    func moderate(command: VoiceModerationCommand) async throws -> VoiceRoomSnapshot
    func snapshots() async -> AsyncStream<VoiceRoomSnapshot>
    func terminalErrors() async -> AsyncStream<VoiceRoomErrorEnvelope>
}

public struct VoiceMediaDriverParticipant: Equatable, Sendable {
    public let principalId: String
    public let providerParticipantId: String
    public let kind: VoicePrincipalKind
    public let role: VoiceParticipantRole
    public let displayName: String?
    public let microphoneEnabled: Bool
    public let canPublish: Bool
    public let handRaised: Bool
    public let isOnStage: Bool

    public init(
        principalId: String,
        providerParticipantId: String,
        kind: VoicePrincipalKind,
        role: VoiceParticipantRole,
        displayName: String?,
        microphoneEnabled: Bool,
        canPublish: Bool,
        handRaised: Bool,
        isOnStage: Bool
    ) {
        self.principalId = principalId
        self.providerParticipantId = providerParticipantId
        self.kind = kind
        self.role = role
        self.displayName = displayName
        self.microphoneEnabled = microphoneEnabled
        self.canPublish = canPublish
        self.handRaised = handRaised
        self.isOnStage = isOnStage
    }
}

public struct VoiceMediaDriverState: Equatable, Sendable {
    public let presenceRevision: UInt64
    public let roomState: VoiceRoomLifecycle
    public let connectionState: VoiceRoomConnectionState
    public let selfProviderParticipantId: String
    public let selfProviderCorrelationId: String?
    public let selfMicrophoneEnabled: Bool
    public let selfCanPublish: Bool
    public let selfHandRaised: Bool
    public let participants: [VoiceMediaDriverParticipant]
    public let activeSpeakerPrincipalIds: [String]
    public let joinedCount: Int
    public let availableInputDevices: [VoiceAudioRoute]
    public let availableOutputRoutes: [VoiceAudioRoute]
    public let selectedInputDeviceId: String?
    public let selectedOutputRouteId: String?
    public let outputSelectionSupported: Bool

    public init(
        presenceRevision: UInt64,
        roomState: VoiceRoomLifecycle,
        connectionState: VoiceRoomConnectionState,
        selfProviderParticipantId: String,
        selfProviderCorrelationId: String?,
        selfMicrophoneEnabled: Bool,
        selfCanPublish: Bool,
        selfHandRaised: Bool,
        participants: [VoiceMediaDriverParticipant],
        activeSpeakerPrincipalIds: [String],
        joinedCount: Int,
        availableInputDevices: [VoiceAudioRoute],
        availableOutputRoutes: [VoiceAudioRoute],
        selectedInputDeviceId: String?,
        selectedOutputRouteId: String?,
        outputSelectionSupported: Bool
    ) {
        self.presenceRevision = presenceRevision
        self.roomState = roomState
        self.connectionState = connectionState
        self.selfProviderParticipantId = selfProviderParticipantId
        self.selfProviderCorrelationId = selfProviderCorrelationId
        self.selfMicrophoneEnabled = selfMicrophoneEnabled
        self.selfCanPublish = selfCanPublish
        self.selfHandRaised = selfHandRaised
        self.participants = participants
        self.activeSpeakerPrincipalIds = activeSpeakerPrincipalIds
        self.joinedCount = joinedCount
        self.availableInputDevices = availableInputDevices
        self.availableOutputRoutes = availableOutputRoutes
        self.selectedInputDeviceId = selectedInputDeviceId
        self.selectedOutputRouteId = selectedOutputRouteId
        self.outputSelectionSupported = outputSelectionSupported
    }
}

public enum VoiceMediaDriverEvent: Equatable, Sendable {
    case stateChanged(VoiceMediaDriverState)
    case terminal(VoiceRoomErrorEnvelope)
}

public protocol VoiceMediaDriver: Sendable {
    func connect(
        credential: String,
        initialMicrophoneEnabled: Bool
    ) async throws -> VoiceMediaDriverState
    func disconnect(reason: VoiceClientLeaveReason) async
    func setMicrophoneEnabled(_ enabled: Bool) async throws -> VoiceMediaDriverState
    func selectInput(deviceId: String) async throws -> VoiceMediaDriverState
    func selectOutput(routeId: String) async throws -> VoiceMediaDriverState
    func raiseHand() async throws -> VoiceMediaDriverState
    func cancelHandRaise() async throws -> VoiceMediaDriverState
    func events() async -> AsyncStream<VoiceMediaDriverEvent>
}

public protocol VoiceMediaDriverFactory: Sendable {
    func makeDriver() async -> any VoiceMediaDriver
}

public protocol VoiceRoomControlClient: Sendable {
    func moderate(
        command: VoiceModerationCommand,
        identity: VoiceRoomIdentity,
        actorPrincipalId: String,
        actorRole: VoiceParticipantRole
    ) async throws -> VoiceRoomSnapshot
}

public struct UnavailableVoiceRoomControlClient: VoiceRoomControlClient {
    public init() {}

    public func moderate(
        command: VoiceModerationCommand,
        identity: VoiceRoomIdentity,
        actorPrincipalId: String,
        actorRole: VoiceParticipantRole
    ) async throws -> VoiceRoomSnapshot {
        throw VoiceTransportError.controlPlaneRequired
    }
}

public actor ProviderNeutralVoiceMediaTransport: VoiceMediaTransport {
    private let driverFactory: any VoiceMediaDriverFactory
    private let controlClient: any VoiceRoomControlClient

    private var generation: UInt64 = 0
    private var driver: (any VoiceMediaDriver)?
    private var activeGrant: VoiceJoinGrant?
    private var snapshot: VoiceRoomSnapshot?
    private var eventTask: Task<Void, Never>?
    private var snapshotContinuations:
        [UUID: AsyncStream<VoiceRoomSnapshot>.Continuation] = [:]
    private var errorContinuations:
        [UUID: AsyncStream<VoiceRoomErrorEnvelope>.Continuation] = [:]

    public init(
        driverFactory: any VoiceMediaDriverFactory,
        controlClient: any VoiceRoomControlClient = UnavailableVoiceRoomControlClient()
    ) {
        self.driverFactory = driverFactory
        self.controlClient = controlClient
    }

    public func connect(grant: VoiceJoinGrant) async throws -> VoiceRoomSnapshot {
        generation &+= 1
        let operationGeneration = generation
        eventTask?.cancel()
        eventTask = nil

        let previousDriver = driver
        driver = nil
        activeGrant = nil
        if let previousDriver {
            await previousDriver.disconnect(reason: .superseded)
        }
        guard operationGeneration == generation else {
            throw VoiceTransportError.staleEpoch
        }

        let nextDriver = await driverFactory.makeDriver()
        guard operationGeneration == generation else {
            await nextDriver.disconnect(reason: .superseded)
            throw VoiceTransportError.staleEpoch
        }

        var credential = try await grant.credential.take()
        defer {
            credential.removeAll(keepingCapacity: false)
        }

        driver = nextDriver
        activeGrant = grant
        let joiningSnapshot = try Self.joiningSnapshot(for: grant)
        snapshot = joiningSnapshot
        emit(joiningSnapshot)
        beginConsumingEvents(
            from: nextDriver,
            generation: operationGeneration,
            requestId: grant.requestId
        )

        do {
            let state = try await nextDriver.connect(
                credential: credential,
                initialMicrophoneEnabled: false
            )
            guard operationGeneration == generation,
                  activeGrant?.identity == grant.identity,
                  driver != nil else {
                await nextDriver.disconnect(reason: .superseded)
                throw VoiceTransportError.staleEpoch
            }
            let connected = try Self.render(
                state: state,
                grant: grant,
                controlRevision: grant.initialControlRevision
            )
            snapshot = connected
            emit(connected)
            return connected
        } catch {
            await nextDriver.disconnect(reason: .connectionFailed)
            if operationGeneration == generation {
                driver = nil
                activeGrant = nil
                eventTask?.cancel()
                eventTask = nil
                let envelope = Self.providerFailure(requestId: grant.requestId)
                emit(envelope)
                snapshot = try? Self.failedSnapshot(from: joiningSnapshot)
                if let snapshot {
                    emit(snapshot)
                }
            }
            if let error = error as? VoiceTransportError {
                throw error
            }
            throw VoiceTransportError.providerUnavailable
        }
    }

    public func disconnect(reason: VoiceClientLeaveReason) async {
        generation &+= 1
        eventTask?.cancel()
        eventTask = nil
        let activeDriver = driver
        driver = nil
        activeGrant = nil

        if let current = snapshot,
           let disconnected = try? Self.disconnectedSnapshot(from: current) {
            snapshot = disconnected
            emit(disconnected)
        }
        if let activeDriver {
            await activeDriver.disconnect(reason: reason)
        }
    }

    public func setMicrophoneEnabled(_ enabled: Bool) async throws -> VoiceRoomSnapshot {
        let context = try connectedContext()
        if enabled && (
            !context.grant.capabilities.canPublishAudio
                || (context.grant.role != .speaker
                    && context.grant.role != .moderator)
        ) {
            throw VoiceTransportError.capabilityDenied
        }
        let state = try await context.driver.setMicrophoneEnabled(enabled)
        return try apply(
            state,
            generation: context.generation,
            identity: context.grant.identity
        )
    }

    public func selectInput(deviceId: String) async throws -> VoiceRoomSnapshot {
        let context = try connectedContext()
        guard context.snapshot.availableInputDevices.contains(where: { $0.id == deviceId }) else {
            throw VoiceTransportError.routeUnavailable
        }
        let state = try await context.driver.selectInput(deviceId: deviceId)
        return try apply(
            state,
            generation: context.generation,
            identity: context.grant.identity
        )
    }

    public func selectOutput(routeId: String) async throws -> VoiceRoomSnapshot {
        let context = try connectedContext()
        guard context.snapshot.outputSelectionSupported,
              context.snapshot.availableOutputRoutes.contains(where: { $0.id == routeId }) else {
            throw VoiceTransportError.routeUnavailable
        }
        let state = try await context.driver.selectOutput(routeId: routeId)
        return try apply(
            state,
            generation: context.generation,
            identity: context.grant.identity
        )
    }

    public func raiseHand() async throws -> VoiceRoomSnapshot {
        let context = try connectedContext()
        guard context.grant.capabilities.canRaiseHand else {
            throw VoiceTransportError.capabilityDenied
        }
        let state = try await context.driver.raiseHand()
        return try apply(
            state,
            generation: context.generation,
            identity: context.grant.identity
        )
    }

    public func cancelHandRaise() async throws -> VoiceRoomSnapshot {
        let context = try connectedContext()
        guard context.grant.capabilities.canCancelHandRaise else {
            throw VoiceTransportError.capabilityDenied
        }
        let state = try await context.driver.cancelHandRaise()
        return try apply(
            state,
            generation: context.generation,
            identity: context.grant.identity
        )
    }

    public func moderate(command: VoiceModerationCommand) async throws -> VoiceRoomSnapshot {
        let context = try connectedContext()
        guard context.grant.capabilities.moderationActions.contains(command.action) else {
            throw VoiceTransportError.capabilityDenied
        }
        let serverSnapshot = try await controlClient.moderate(
            command: command,
            identity: context.grant.identity,
            actorPrincipalId: context.grant.principalId,
            actorRole: context.grant.role
        )
        guard generation == context.generation,
              serverSnapshot.identity == context.grant.identity else {
            throw VoiceTransportError.staleEpoch
        }
        guard serverSnapshot.controlRevision >= context.snapshot.controlRevision else {
            throw VoiceTransportError.invalidSnapshot
        }
        snapshot = serverSnapshot
        emit(serverSnapshot)
        return serverSnapshot
    }

    public func snapshots() async -> AsyncStream<VoiceRoomSnapshot> {
        let id = UUID()
        let pair = AsyncStream<VoiceRoomSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        snapshotContinuations[id] = pair.continuation
        if let snapshot {
            pair.continuation.yield(snapshot)
        }
        pair.continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeSnapshotContinuation(id)
            }
        }
        return pair.stream
    }

    public func terminalErrors() async -> AsyncStream<VoiceRoomErrorEnvelope> {
        let id = UUID()
        let pair = AsyncStream<VoiceRoomErrorEnvelope>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
        )
        errorContinuations[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeErrorContinuation(id)
            }
        }
        return pair.stream
    }

    public func currentSnapshot() -> VoiceRoomSnapshot? {
        snapshot
    }

    private func connectedContext() throws -> ConnectedContext {
        guard let grant = activeGrant,
              let driver,
              let snapshot,
              snapshot.connectionState == .joined
                || snapshot.connectionState == .reconnecting else {
            throw VoiceTransportError.notConnected
        }
        return ConnectedContext(
            generation: generation,
            grant: grant,
            driver: driver,
            snapshot: snapshot
        )
    }

    private func apply(
        _ state: VoiceMediaDriverState,
        generation operationGeneration: UInt64,
        identity: VoiceRoomIdentity
    ) throws -> VoiceRoomSnapshot {
        guard operationGeneration == generation,
              let grant = activeGrant,
              grant.identity == identity else {
            throw VoiceTransportError.staleEpoch
        }
        let updated = try Self.render(
            state: state,
            grant: grant,
            controlRevision: snapshot?.controlRevision ?? grant.initialControlRevision
        )
        snapshot = updated
        emit(updated)
        return updated
    }

    private func beginConsumingEvents(
        from driver: any VoiceMediaDriver,
        generation operationGeneration: UInt64,
        requestId: String
    ) {
        eventTask = Task { [weak self] in
            let stream = await driver.events()
            for await event in stream {
                guard !Task.isCancelled else { return }
                await self?.receive(
                    event,
                    from: driver,
                    generation: operationGeneration,
                    requestId: requestId
                )
            }
        }
    }

    private func receive(
        _ event: VoiceMediaDriverEvent,
        from eventDriver: any VoiceMediaDriver,
        generation operationGeneration: UInt64,
        requestId: String
    ) async {
        guard operationGeneration == generation,
              driver != nil,
              let grant = activeGrant else {
            return
        }
        switch event {
        case .stateChanged(let state):
            if let updated = try? Self.render(
                state: state,
                grant: grant,
                controlRevision: snapshot?.controlRevision ?? grant.initialControlRevision
            ) {
                snapshot = updated
                emit(updated)
            }
        case .terminal(let envelope):
            let safeEnvelope = VoiceRoomErrorEnvelope(
                code: envelope.code,
                message: envelope.message,
                requestId: requestId,
                recoverable: envelope.recoverable,
                retryAfterMs: envelope.retryAfterMs
            )
            emit(safeEnvelope)
            generation &+= 1
            eventTask?.cancel()
            eventTask = nil
            driver = nil
            activeGrant = nil
            if let current = snapshot,
               let failed = try? Self.terminalSnapshot(
                   from: current,
                   code: safeEnvelope.code
               ) {
                snapshot = failed
                emit(failed)
            }
            await eventDriver.disconnect(reason: .connectionFailed)
        }
    }

    private func emit(_ snapshot: VoiceRoomSnapshot) {
        for continuation in snapshotContinuations.values {
            continuation.yield(snapshot)
        }
    }

    private func emit(_ error: VoiceRoomErrorEnvelope) {
        for continuation in errorContinuations.values {
            continuation.yield(error)
        }
    }

    private func removeSnapshotContinuation(_ id: UUID) {
        snapshotContinuations.removeValue(forKey: id)
    }

    private func removeErrorContinuation(_ id: UUID) {
        errorContinuations.removeValue(forKey: id)
    }

    private static func joiningSnapshot(for grant: VoiceJoinGrant) throws -> VoiceRoomSnapshot {
        try VoiceRoomSnapshot(
            identity: grant.identity,
            controlRevision: grant.initialControlRevision,
            providerPresenceRevision: "client:0",
            roomState: .open,
            selfParticipant: VoiceParticipantSummary(
                principalId: grant.principalId,
                providerParticipantId: grant.providerParticipantId,
                kind: .human,
                role: grant.role,
                mediaState: .joining,
                microphoneEnabled: false,
                canPublish: grant.capabilities.canPublishAudio,
                handRaised: false,
                displayName: nil
            ),
            stage: [],
            activeSpeakerPrincipalIds: [],
            connectionState: .joining,
            joinedCount: 0,
            rosterNextCursor: nil,
            availableInputDevices: [],
            availableOutputRoutes: [],
            selectedInputDeviceId: nil,
            selectedOutputRouteId: nil,
            outputSelectionSupported: false
        )
    }

    private static func render(
        state: VoiceMediaDriverState,
        grant: VoiceJoinGrant,
        controlRevision: UInt64
    ) throws -> VoiceRoomSnapshot {
        guard state.selfProviderCorrelationId == grant.providerCorrelationId else {
            throw VoiceTransportError.invalidSnapshot
        }
        let selfCanPublish = grant.capabilities.canPublishAudio && state.selfCanPublish
        let selfParticipant = VoiceParticipantSummary(
            principalId: grant.principalId,
            providerParticipantId: state.selfProviderParticipantId,
            kind: .human,
            role: grant.role,
            mediaState: mediaState(for: state.connectionState),
            microphoneEnabled: selfCanPublish && state.selfMicrophoneEnabled,
            canPublish: selfCanPublish,
            handRaised: state.selfHandRaised,
            displayName: nil
        )
        let stage = state.participants
            .filter(\.isOnStage)
            .prefix(64)
            .map {
                VoiceParticipantSummary(
                    principalId: $0.principalId,
                    providerParticipantId: $0.providerParticipantId,
                    kind: $0.kind,
                    role: $0.role,
                    mediaState: .joined,
                    microphoneEnabled: $0.microphoneEnabled,
                    canPublish: $0.canPublish,
                    handRaised: $0.handRaised,
                    displayName: $0.displayName
                )
            }
        return try VoiceRoomSnapshot(
            identity: grant.identity,
            controlRevision: controlRevision,
            providerPresenceRevision: "client:\(state.presenceRevision)",
            roomState: state.roomState,
            selfParticipant: selfParticipant,
            stage: Array(stage),
            activeSpeakerPrincipalIds: Array(
                state.activeSpeakerPrincipalIds.prefix(64)
            ),
            connectionState: state.connectionState,
            joinedCount: max(0, state.joinedCount),
            rosterNextCursor: nil,
            availableInputDevices: Array(state.availableInputDevices.prefix(64)),
            availableOutputRoutes: Array(state.availableOutputRoutes.prefix(64)),
            selectedInputDeviceId: state.selectedInputDeviceId,
            selectedOutputRouteId: state.selectedOutputRouteId,
            outputSelectionSupported: state.outputSelectionSupported
        )
    }

    private static func mediaState(
        for connectionState: VoiceRoomConnectionState
    ) -> VoiceParticipantMediaState {
        switch connectionState {
        case .joining: return .joining
        case .joined: return .joined
        case .reconnecting: return .reconnecting
        case .disconnected: return .left
        case .failed: return .left
        }
    }

    private static func failedSnapshot(
        from snapshot: VoiceRoomSnapshot
    ) throws -> VoiceRoomSnapshot {
        try replacing(snapshot, roomState: .failed, connectionState: .failed)
    }

    private static func disconnectedSnapshot(
        from snapshot: VoiceRoomSnapshot
    ) throws -> VoiceRoomSnapshot {
        try replacing(snapshot, roomState: snapshot.roomState, connectionState: .disconnected)
    }

    private static func terminalSnapshot(
        from snapshot: VoiceRoomSnapshot,
        code: VoiceRoomErrorCode
    ) throws -> VoiceRoomSnapshot {
        try replacing(
            snapshot,
            roomState: code == .roomEnded ? .ended : .failed,
            connectionState: code == .roomEnded ? .disconnected : .failed
        )
    }

    private static func replacing(
        _ snapshot: VoiceRoomSnapshot,
        roomState: VoiceRoomLifecycle,
        connectionState: VoiceRoomConnectionState
    ) throws -> VoiceRoomSnapshot {
        try VoiceRoomSnapshot(
            identity: snapshot.identity,
            controlRevision: snapshot.controlRevision,
            providerPresenceRevision: snapshot.providerPresenceRevision,
            roomState: roomState,
            selfParticipant: VoiceParticipantSummary(
                principalId: snapshot.selfParticipant.principalId,
                providerParticipantId: snapshot.selfParticipant.providerParticipantId,
                kind: snapshot.selfParticipant.kind,
                role: snapshot.selfParticipant.role,
                mediaState: mediaState(for: connectionState),
                microphoneEnabled: false,
                canPublish: snapshot.selfParticipant.canPublish,
                handRaised: false,
                displayName: snapshot.selfParticipant.displayName
            ),
            stage: snapshot.stage,
            activeSpeakerPrincipalIds: [],
            connectionState: connectionState,
            joinedCount: snapshot.joinedCount,
            rosterNextCursor: snapshot.rosterNextCursor,
            availableInputDevices: snapshot.availableInputDevices,
            availableOutputRoutes: snapshot.availableOutputRoutes,
            selectedInputDeviceId: snapshot.selectedInputDeviceId,
            selectedOutputRouteId: snapshot.selectedOutputRouteId,
            outputSelectionSupported: snapshot.outputSelectionSupported
        )
    }

    private static func providerFailure(requestId: String) -> VoiceRoomErrorEnvelope {
        VoiceRoomErrorEnvelope(
            code: .providerUnavailable,
            message: "The voice media provider is unavailable.",
            requestId: requestId,
            recoverable: true
        )
    }
}

private struct ConnectedContext: Sendable {
    let generation: UInt64
    let grant: VoiceJoinGrant
    let driver: any VoiceMediaDriver
    let snapshot: VoiceRoomSnapshot
}
