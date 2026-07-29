import Foundation

public struct VoiceRosterParticipant: Decodable, Equatable, Sendable {
    public let principalId: String
    public let providerParticipantId: String
    public let providerCorrelationId: String
    public let providerSessionId: String
    public let providerPeerId: String
    public let kind: VoicePrincipalKind
    public let role: VoiceParticipantRole
    public let displayName: String?
    public let joinedAt: Date

    public init(
        principalId: String,
        providerParticipantId: String,
        providerCorrelationId: String,
        providerSessionId: String,
        providerPeerId: String,
        kind: VoicePrincipalKind,
        role: VoiceParticipantRole,
        displayName: String?,
        joinedAt: Date
    ) throws {
        guard Self.validPrincipal(principalId),
              Self.validProviderIdentifier(providerParticipantId),
              Self.validProviderCorrelation(providerCorrelationId),
              principalId != providerCorrelationId,
              Self.validProviderIdentifier(providerSessionId),
              Self.validProviderIdentifier(providerPeerId),
              principalId != providerParticipantId,
              principalId != providerSessionId,
              principalId != providerPeerId,
              kind == .human || kind == .agent,
              role == .moderator || role == .speaker || role == .listener,
              displayName == nil
                || (!displayName!.isEmpty && displayName!.count <= 80) else {
            throw VoiceTransportError.invalidSnapshot
        }
        self.principalId = principalId
        self.providerParticipantId = providerParticipantId
        self.providerCorrelationId = providerCorrelationId
        self.providerSessionId = providerSessionId
        self.providerPeerId = providerPeerId
        self.kind = kind
        self.role = role
        self.displayName = displayName
        self.joinedAt = joinedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            principalId: container.decode(String.self, forKey: .principalId),
            providerParticipantId: container.decode(
                String.self,
                forKey: .providerParticipantId
            ),
            providerCorrelationId: container.decode(
                String.self,
                forKey: .providerCorrelationId
            ),
            providerSessionId: container.decode(
                String.self,
                forKey: .providerSessionId
            ),
            providerPeerId: container.decode(
                String.self,
                forKey: .providerPeerId
            ),
            kind: container.decode(VoicePrincipalKind.self, forKey: .kind),
            role: container.decode(VoiceParticipantRole.self, forKey: .role),
            displayName: container.decodeIfPresent(String.self, forKey: .displayName),
            joinedAt: try VoiceRosterTimestamp.parse(
                container.decode(String.self, forKey: .joinedAt)
            )
        )
    }

    private static func validPrincipal(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.count <= 160,
              let first = value.first,
              first.isASCII,
              first.isLetter || first.isNumber else {
            return false
        }
        return value.allSatisfy {
            $0.isASCII
                && ($0.isLetter
                    || $0.isNumber
                    || $0 == "."
                    || $0 == "_"
                    || $0 == ":"
                    || $0 == "@"
                    || $0 == "/"
                    || $0 == "-")
        }
    }

    private static func validProviderIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.count <= 200,
              let first = value.first,
              first.isASCII,
              first.isLetter || first.isNumber else {
            return false
        }
        return value.allSatisfy {
            $0.isASCII
                && ($0.isLetter
                    || $0.isNumber
                    || $0 == "."
                    || $0 == "_"
                    || $0 == ":"
                    || $0 == "-")
        }
    }

    private static func validProviderCorrelation(_ value: String) -> Bool {
        guard value.hasPrefix("senti_"), value.count == 49 else {
            return false
        }
        return value.dropFirst(6).allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        }
    }
}

public struct VoiceRosterPage: Decodable, Equatable, Sendable {
    public let schemaVersion: String
    public let identity: VoiceRoomIdentity
    public let snapshotId: String
    public let pageIndex: Int
    public let joinedCount: Int
    public let participants: [VoiceRosterParticipant]
    public let nextCursor: String?
    public let complete: Bool

    public init(
        identity: VoiceRoomIdentity,
        snapshotId: String,
        pageIndex: Int,
        joinedCount: Int,
        participants: [VoiceRosterParticipant],
        nextCursor: String?,
        complete: Bool
    ) throws {
        guard Self.validSnapshotId(snapshotId),
              pageIndex >= 0,
              joinedCount >= 0,
              joinedCount <= 100_000,
              participants.count <= 200,
              participants.count <= joinedCount,
              complete == (nextCursor == nil),
              nextCursor == nil || Self.validCursor(nextCursor!),
              (joinedCount > 0 || (complete && participants.isEmpty)),
              (complete || !participants.isEmpty),
              Self.hasUniqueBindings(participants) else {
            throw VoiceTransportError.invalidSnapshot
        }
        self.schemaVersion = "senti.voice_roster.page.v1"
        self.identity = identity
        self.snapshotId = snapshotId
        self.pageIndex = pageIndex
        self.joinedCount = joinedCount
        self.participants = participants
        self.nextCursor = nextCursor
        self.complete = complete
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .schemaVersion)
            == "senti.voice_roster.page.v1" else {
            throw VoiceTransportError.invalidSnapshot
        }
        let identity = try VoiceRoomIdentity(
            tenantId: container.decode(String.self, forKey: .tenantId),
            sentiSessionId: container.decode(String.self, forKey: .sessionId),
            voiceRoomEpochId: container.decode(String.self, forKey: .roomEpoch)
        )
        try self.init(
            identity: identity,
            snapshotId: container.decode(String.self, forKey: .snapshotId),
            pageIndex: container.decode(Int.self, forKey: .pageIndex),
            joinedCount: container.decode(Int.self, forKey: .joinedCount),
            participants: container.decode(
                [VoiceRosterParticipant].self,
                forKey: .participants
            ),
            nextCursor: container.decodeIfPresent(String.self, forKey: .nextCursor),
            complete: container.decode(Bool.self, forKey: .complete)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case tenantId
        case sessionId
        case roomEpoch
        case snapshotId
        case pageIndex
        case joinedCount
        case participants
        case nextCursor
        case complete
    }

    private static func validSnapshotId(_ value: String) -> Bool {
        value.count == 43 && value.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        }
    }

    private static func validCursor(_ value: String) -> Bool {
        value.hasPrefix("r1.") && value.count <= 8_192
    }

    private static func hasUniqueBindings(
        _ participants: [VoiceRosterParticipant]
    ) -> Bool {
        var principals = Set<String>()
        var providerParticipants = Set<String>()
        var correlations = Set<String>()
        var peers = Set<String>()
        for participant in participants {
            guard principals.insert(participant.principalId).inserted,
                  providerParticipants.insert(
                    participant.providerParticipantId
                  ).inserted,
                  correlations.insert(participant.providerCorrelationId).inserted,
                  peers.insert(
                    "\(participant.providerSessionId):\(participant.providerPeerId)"
                  ).inserted else {
                return false
            }
        }
        return true
    }
}

public struct VoiceRosterPageResponse: Decodable, Equatable, Sendable {
    public let requestId: String
    public let page: VoiceRosterPage

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let requestId = try container.decode(String.self, forKey: .requestId)
        guard requestId.count >= 8, requestId.count <= 128 else {
            throw VoiceTransportError.invalidSnapshot
        }
        self.requestId = requestId
        self.page = try container.decode(VoiceRosterPage.self, forKey: .page)
    }

    private enum CodingKeys: String, CodingKey {
        case requestId
        case page
    }
}

public struct VoiceRosterSnapshot: Equatable, Sendable {
    public let identity: VoiceRoomIdentity
    public let snapshotId: String
    public let participants: [VoiceRosterParticipant]
    public let joinedCount: Int

    fileprivate init(
        identity: VoiceRoomIdentity,
        snapshotId: String,
        participants: [VoiceRosterParticipant],
        joinedCount: Int
    ) {
        self.identity = identity
        self.snapshotId = snapshotId
        self.participants = participants
        self.joinedCount = joinedCount
    }
}

public actor VoiceRosterProjection {
    private struct Staging {
        let snapshotId: String
        let joinedCount: Int
        var nextPageIndex: Int
        var participants: [VoiceRosterParticipant]
        var principalIds: Set<String>
        var providerParticipantIds: Set<String>
        var providerCorrelationIds: Set<String>
        var providerPeerKeys: Set<String>
    }

    private let identity: VoiceRoomIdentity
    private var staging: Staging?
    private var committed: VoiceRosterSnapshot?

    public init(identity: VoiceRoomIdentity) {
        self.identity = identity
    }

    @discardableResult
    public func apply(
        _ page: VoiceRosterPage
    ) throws -> VoiceRosterSnapshot? {
        guard page.identity == identity else {
            staging = nil
            throw VoiceTransportError.staleEpoch
        }
        if page.pageIndex == 0 {
            staging = Staging(
                snapshotId: page.snapshotId,
                joinedCount: page.joinedCount,
                nextPageIndex: 0,
                participants: [],
                principalIds: [],
                providerParticipantIds: [],
                providerCorrelationIds: [],
                providerPeerKeys: []
            )
        }
        guard var next = staging,
              next.snapshotId == page.snapshotId,
              next.joinedCount == page.joinedCount,
              next.nextPageIndex == page.pageIndex else {
            staging = nil
            throw VoiceTransportError.invalidSnapshot
        }

        for participant in page.participants {
            let peerKey =
                "\(participant.providerSessionId):\(participant.providerPeerId)"
            guard next.principalIds.insert(participant.principalId).inserted,
                  next.providerParticipantIds.insert(
                    participant.providerParticipantId
                  ).inserted,
                  next.providerCorrelationIds.insert(
                    participant.providerCorrelationId
                  ).inserted,
                  next.providerPeerKeys.insert(peerKey).inserted else {
                staging = nil
                throw VoiceTransportError.invalidSnapshot
            }
            next.participants.append(participant)
        }
        guard next.participants.count <= next.joinedCount else {
            staging = nil
            throw VoiceTransportError.invalidSnapshot
        }
        if page.complete {
            guard next.participants.count == next.joinedCount else {
                staging = nil
                throw VoiceTransportError.invalidSnapshot
            }
            let snapshot = VoiceRosterSnapshot(
                identity: identity,
                snapshotId: page.snapshotId,
                participants: next.participants,
                joinedCount: next.joinedCount
            )
            committed = snapshot
            staging = nil
            return snapshot
        }
        guard next.participants.count < next.joinedCount else {
            staging = nil
            throw VoiceTransportError.invalidSnapshot
        }
        next.nextPageIndex += 1
        staging = next
        return nil
    }

    public func discardPending() {
        staging = nil
    }

    public func currentSnapshot() -> VoiceRosterSnapshot? {
        committed
    }
}

private enum VoiceRosterTimestamp {
    static func parse(_ value: String) throws -> Date {
        guard value.count <= 64 else {
            throw VoiceTransportError.invalidSnapshot
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        guard let date = standard.date(from: value) else {
            throw VoiceTransportError.invalidSnapshot
        }
        return date
    }
}
