import Foundation

private enum VoiceCredentialPolicy {
    static let maximumRetentionSeconds: TimeInterval = 5 * 60
}

public struct VoiceRoomIdentity: Codable, Equatable, Hashable, Sendable {
    public let tenantId: String
    public let sentiSessionId: String
    public let voiceRoomEpochId: String

    public init(
        tenantId: String,
        sentiSessionId: String,
        voiceRoomEpochId: String
    ) throws {
        try Self.validate(tenantId)
        try Self.validate(sentiSessionId)
        try Self.validate(voiceRoomEpochId)
        self.tenantId = tenantId
        self.sentiSessionId = sentiSessionId
        self.voiceRoomEpochId = voiceRoomEpochId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            tenantId: container.decode(String.self, forKey: .tenantId),
            sentiSessionId: container.decode(String.self, forKey: .sentiSessionId),
            voiceRoomEpochId: container.decode(String.self, forKey: .voiceRoomEpochId)
        )
    }

    private static func validate(_ value: String) throws {
        guard !value.isEmpty, value.count <= 160 else {
            throw VoiceTransportError.invalidGrant
        }
    }
}

public enum VoiceParticipantRole: String, Codable, Equatable, Hashable, Sendable {
    case owner
    case moderator
    case speaker
    case listener
    case agent
}

public enum VoicePrincipalKind: String, Codable, Equatable, Sendable {
    case human
    case agent
    case service
}

public enum VoiceParticipantMediaState: String, Codable, Equatable, Sendable {
    case invited
    case joining
    case joined
    case reconnecting
    case left
    case removed
}

public enum VoiceRoomLifecycle: String, Codable, Equatable, Sendable {
    case provisioning
    case open
    case draining
    case ended
    case failed
}

public enum VoiceRoomConnectionState: String, Codable, Equatable, Sendable {
    case joining
    case joined
    case reconnecting
    case disconnected
    case failed
}

public enum VoiceModerationAction: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case promote
    case demote
    case mute
    case remove
    case denyPublish = "deny_publish"
    case allowPublish = "allow_publish"
}

public struct VoiceJoinCapabilities: Codable, Equatable, Sendable {
    public let canPublishAudio: Bool
    public let canRaiseHand: Bool
    public let canCancelHandRaise: Bool
    public let moderationActions: Set<VoiceModerationAction>

    public init(
        canPublishAudio: Bool,
        canRaiseHand: Bool,
        canCancelHandRaise: Bool,
        moderationActions: Set<VoiceModerationAction>
    ) {
        self.canPublishAudio = canPublishAudio
        self.canRaiseHand = canRaiseHand
        self.canCancelHandRaise = canCancelHandRaise
        self.moderationActions = moderationActions
    }
}

public enum VoiceProvider: String, Codable, Equatable, Sendable {
    case cloudflareRealtimeKit = "cloudflare-realtimekit"
}

public enum VoiceCredentialScope: String, Codable, Equatable, Sendable {
    case singleParticipantSingleMeeting = "single-participant-single-meeting"
}

public enum VoiceProviderExpiry: String, Codable, Equatable, Sendable {
    case timeBoundUndisclosed = "time-bound-undisclosed"
}

public actor VoiceJoinCredentialHandle: CustomStringConvertible {
    private var credential: String?
    public nonisolated let discardAfter: Date

    public init(credential: String, discardAfter: Date) throws {
        guard !credential.isEmpty, credential.count <= 16_384 else {
            throw VoiceTransportError.invalidGrant
        }
        self.credential = credential
        self.discardAfter = discardAfter
    }

    public func take(at now: Date = Date()) throws -> String {
        guard now < discardAfter else {
            credential = nil
            throw VoiceTransportError.credentialExpired
        }
        guard let credential else {
            throw VoiceTransportError.credentialConsumed
        }
        self.credential = nil
        return credential
    }

    public func discard() {
        credential = nil
    }

    public func isAvailable(at now: Date = Date()) -> Bool {
        credential != nil && now < discardAfter
    }

    public nonisolated var description: String {
        "<VoiceJoinCredentialHandle redacted>"
    }
}

public struct VoiceJoinGrant: Sendable, CustomStringConvertible {
    public let requestId: String
    public let identity: VoiceRoomIdentity
    public let provider: VoiceProvider
    public let principalId: String
    public let providerParticipantId: String
    public let providerCorrelationId: String
    public let role: VoiceParticipantRole
    public let capabilities: VoiceJoinCapabilities
    public let initialControlRevision: UInt64
    public let issuedAt: Date
    public let credentialScope: VoiceCredentialScope
    public let providerExpiry: VoiceProviderExpiry
    public let credential: VoiceJoinCredentialHandle

    public init(
        requestId: String,
        identity: VoiceRoomIdentity,
        provider: VoiceProvider,
        principalId: String,
        providerParticipantId: String,
        providerCorrelationId: String,
        role: VoiceParticipantRole,
        capabilities: VoiceJoinCapabilities,
        initialControlRevision: UInt64,
        issuedAt: Date,
        credentialScope: VoiceCredentialScope,
        providerExpiry: VoiceProviderExpiry,
        credential: VoiceJoinCredentialHandle
    ) throws {
        guard !requestId.isEmpty,
              requestId.count <= 160,
              !principalId.isEmpty,
              principalId.count <= 160,
              !providerParticipantId.isEmpty,
              providerParticipantId.count <= 160,
              !providerCorrelationId.isEmpty,
              providerCorrelationId.count <= 200,
              credential.discardAfter > issuedAt,
              credential.discardAfter.timeIntervalSince(issuedAt)
                <= VoiceCredentialPolicy.maximumRetentionSeconds,
              Self.capabilitiesAreSafe(for: role, capabilities: capabilities) else {
            throw VoiceTransportError.invalidGrant
        }
        self.requestId = requestId
        self.identity = identity
        self.provider = provider
        self.principalId = principalId
        self.providerParticipantId = providerParticipantId
        self.providerCorrelationId = providerCorrelationId
        self.role = role
        self.capabilities = capabilities
        self.initialControlRevision = initialControlRevision
        self.issuedAt = issuedAt
        self.credentialScope = credentialScope
        self.providerExpiry = providerExpiry
        self.credential = credential
    }

    private static func capabilitiesAreSafe(
        for role: VoiceParticipantRole,
        capabilities: VoiceJoinCapabilities
    ) -> Bool {
        switch role {
        case .listener:
            return !capabilities.canPublishAudio
                && capabilities.moderationActions.isEmpty
        case .speaker:
            return capabilities.moderationActions.isEmpty
        case .moderator:
            return !capabilities.canRaiseHand
                && !capabilities.canCancelHandRaise
        case .owner, .agent:
            // These are valid room snapshot roles, but the current human iOS
            // join contract never issues them as provider grants.
            return false
        }
    }

    public var description: String {
        "VoiceJoinGrant(requestId: \(requestId), epoch: \(identity.voiceRoomEpochId), credential: <redacted>)"
    }
}

public struct VoiceJoinResponse: Decodable, Sendable {
    public let requestId: String
    public let grant: VoiceJoinGrant

    public init(from decoder: Decoder) throws {
        let envelope = try JoinEnvelope(from: decoder)
        let credential = envelope.credential
        let issuedAt = try Self.parseTimestamp(credential.issuedAt)
        let discardAfter = try Self.parseTimestamp(credential.clientDiscardAfter)
        guard discardAfter > issuedAt,
              discardAfter.timeIntervalSince(issuedAt)
                <= VoiceCredentialPolicy.maximumRetentionSeconds else {
            throw VoiceTransportError.invalidGrant
        }
        let handle = try VoiceJoinCredentialHandle(
            credential: credential.authToken,
            discardAfter: discardAfter
        )
        let identity = try VoiceRoomIdentity(
            tenantId: credential.room.tenantId,
            sentiSessionId: credential.room.sessionId,
            voiceRoomEpochId: credential.room.roomEpoch
        )
        self.requestId = envelope.requestId
        self.grant = try VoiceJoinGrant(
            requestId: envelope.requestId,
            identity: identity,
            provider: credential.room.provider,
            principalId: credential.principalId,
            providerParticipantId: credential.participantId,
            providerCorrelationId: credential.providerCorrelationId,
            role: credential.role,
            capabilities: credential.capabilities,
            initialControlRevision: credential.controlRevision,
            issuedAt: issuedAt,
            credentialScope: credential.providerScope,
            providerExpiry: credential.providerExpiry,
            credential: handle
        )
    }

    private static func parseTimestamp(_ value: String) throws -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        guard let date = standard.date(from: value) else {
            throw VoiceTransportError.invalidGrant
        }
        return date
    }
}

private struct JoinEnvelope: Decodable {
    let requestId: String
    let credential: Credential

    struct Credential: Decodable {
        let room: Room
        let role: VoiceParticipantRole
        let principalId: String
        let participantId: String
        let providerCorrelationId: String
        let authToken: String
        let issuedAt: String
        let clientDiscardAfter: String
        let providerScope: VoiceCredentialScope
        let providerExpiry: VoiceProviderExpiry
        let capabilities: VoiceJoinCapabilities
        let controlRevision: UInt64
    }

    struct Room: Decodable {
        let tenantId: String
        let provider: VoiceProvider
        let sessionId: String
        let roomEpoch: String
    }
}

public struct VoiceParticipantSummary: Codable, Equatable, Sendable {
    public let principalId: String
    public let providerParticipantId: String
    public let kind: VoicePrincipalKind
    public let role: VoiceParticipantRole
    public let mediaState: VoiceParticipantMediaState
    public let microphoneEnabled: Bool
    public let canPublish: Bool
    public let handRaised: Bool
    public let displayName: String?

    public init(
        principalId: String,
        providerParticipantId: String,
        kind: VoicePrincipalKind,
        role: VoiceParticipantRole,
        mediaState: VoiceParticipantMediaState,
        microphoneEnabled: Bool,
        canPublish: Bool,
        handRaised: Bool,
        displayName: String?
    ) {
        self.principalId = principalId
        self.providerParticipantId = providerParticipantId
        self.kind = kind
        self.role = role
        self.mediaState = mediaState
        self.microphoneEnabled = microphoneEnabled
        self.canPublish = canPublish
        self.handRaised = handRaised
        self.displayName = displayName
    }
}

public enum VoiceAudioRouteKind: String, Codable, Equatable, Sendable {
    case receiver
    case speaker
    case wired
    case bluetooth
    case unknown
}

public struct VoiceAudioRoute: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let kind: VoiceAudioRouteKind

    public init(id: String, displayName: String, kind: VoiceAudioRouteKind) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
    }
}

public struct VoiceRoomSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let identity: VoiceRoomIdentity
    public let controlRevision: UInt64
    public let providerPresenceRevision: String
    public let roomState: VoiceRoomLifecycle
    public let selfParticipant: VoiceParticipantSummary
    public let stage: [VoiceParticipantSummary]
    public let activeSpeakerPrincipalIds: [String]
    public let connectionState: VoiceRoomConnectionState
    public let joinedCount: Int
    public let rosterNextCursor: String?
    public let availableInputDevices: [VoiceAudioRoute]
    public let availableOutputRoutes: [VoiceAudioRoute]
    public let selectedInputDeviceId: String?
    public let selectedOutputRouteId: String?
    public let outputSelectionSupported: Bool

    public init(
        identity: VoiceRoomIdentity,
        controlRevision: UInt64,
        providerPresenceRevision: String,
        roomState: VoiceRoomLifecycle,
        selfParticipant: VoiceParticipantSummary,
        stage: [VoiceParticipantSummary],
        activeSpeakerPrincipalIds: [String],
        connectionState: VoiceRoomConnectionState,
        joinedCount: Int,
        rosterNextCursor: String?,
        availableInputDevices: [VoiceAudioRoute],
        availableOutputRoutes: [VoiceAudioRoute],
        selectedInputDeviceId: String?,
        selectedOutputRouteId: String?,
        outputSelectionSupported: Bool
    ) throws {
        guard !providerPresenceRevision.isEmpty,
              providerPresenceRevision.count <= 160,
              stage.count <= 64,
              activeSpeakerPrincipalIds.count <= 64,
              joinedCount >= 0,
              availableInputDevices.count <= 64,
              availableOutputRoutes.count <= 64 else {
            throw VoiceTransportError.invalidSnapshot
        }
        self.schemaVersion = "voice_room_snapshot.v1"
        self.identity = identity
        self.controlRevision = controlRevision
        self.providerPresenceRevision = providerPresenceRevision
        self.roomState = roomState
        self.selfParticipant = selfParticipant
        self.stage = stage
        self.activeSpeakerPrincipalIds = activeSpeakerPrincipalIds
        self.connectionState = connectionState
        self.joinedCount = joinedCount
        self.rosterNextCursor = rosterNextCursor
        self.availableInputDevices = availableInputDevices
        self.availableOutputRoutes = availableOutputRoutes
        self.selectedInputDeviceId = selectedInputDeviceId
        self.selectedOutputRouteId = selectedOutputRouteId
        self.outputSelectionSupported = outputSelectionSupported
    }
}

public enum VoiceRoomErrorCode: String, Codable, Equatable, Sendable {
    case badRequest = "VOICE_BAD_REQUEST"
    case notAuthenticated = "VOICE_NOT_AUTHENTICATED"
    case joinNotAuthorized = "VOICE_JOIN_NOT_AUTHORIZED"
    case entitlementExceeded = "VOICE_ENTITLEMENT_EXCEEDED"
    case providerQuotaExceeded = "VOICE_PROVIDER_QUOTA_EXCEEDED"
    case roomNotFound = "VOICE_ROOM_NOT_FOUND"
    case roomEnded = "VOICE_ROOM_ENDED"
    case controlConflict = "VOICE_CONTROL_CONFLICT"
    case providerUnavailable = "VOICE_PROVIDER_UNAVAILABLE"
    case agentMediaUnsupported = "VOICE_AGENT_MEDIA_UNSUPPORTED"
    case transcriptDegraded = "VOICE_TRANSCRIPT_DEGRADED"
    case exportPartial = "VOICE_EXPORT_PARTIAL"
    case streamResyncRequired = "VOICE_STREAM_RESYNC_REQUIRED"
    case internalError = "VOICE_INTERNAL"
}

public struct VoiceRoomErrorEnvelope: Codable, Equatable, Sendable {
    public let code: VoiceRoomErrorCode
    public let message: String
    public let requestId: String
    public let recoverable: Bool
    public let retryAfterMs: Int?

    public init(
        code: VoiceRoomErrorCode,
        message: String,
        requestId: String,
        recoverable: Bool,
        retryAfterMs: Int? = nil
    ) {
        self.code = code
        self.message = String(message.prefix(500))
        self.requestId = requestId
        self.recoverable = recoverable
        self.retryAfterMs = retryAfterMs
    }
}

public enum VoiceClientLeaveReason: String, Codable, Equatable, Sendable {
    case userInitiated
    case backgrounded
    case superseded
    case connectionFailed
}

public struct VoiceModerationCommand: Codable, Equatable, Sendable {
    public let commandId: String
    public let idempotencyKey: String
    public let expectedRevision: UInt64
    public let targetPrincipalId: String
    public let action: VoiceModerationAction

    public init(
        commandId: String,
        idempotencyKey: String,
        expectedRevision: UInt64,
        targetPrincipalId: String,
        action: VoiceModerationAction
    ) throws {
        guard !commandId.isEmpty,
              commandId.count <= 160,
              !idempotencyKey.isEmpty,
              idempotencyKey.count <= 256,
              !targetPrincipalId.isEmpty,
              targetPrincipalId.count <= 160 else {
            throw VoiceTransportError.invalidCommand
        }
        self.commandId = commandId
        self.idempotencyKey = idempotencyKey
        self.expectedRevision = expectedRevision
        self.targetPrincipalId = targetPrincipalId
        self.action = action
    }
}

public enum VoiceTransportError: Error, Equatable, Sendable {
    case invalidGrant
    case credentialExpired
    case credentialConsumed
    case invalidSnapshot
    case invalidCommand
    case notConnected
    case capabilityDenied
    case routeUnavailable
    case staleEpoch
    case controlPlaneRequired
    case providerUnavailable
}

extension VoiceTransportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidGrant: return "The voice join grant is invalid"
        case .credentialExpired: return "The voice join credential expired and must be refreshed"
        case .credentialConsumed: return "The voice join credential was already consumed"
        case .invalidSnapshot: return "The voice room snapshot is invalid"
        case .invalidCommand: return "The voice room command is invalid"
        case .notConnected: return "The voice room is not connected"
        case .capabilityDenied: return "The requested voice action is not permitted"
        case .routeUnavailable: return "The requested audio route is not available"
        case .staleEpoch: return "The voice response belongs to a superseded room epoch"
        case .controlPlaneRequired: return "The server-authoritative voice control plane is unavailable"
        case .providerUnavailable: return "The voice media provider is unavailable"
        }
    }
}
