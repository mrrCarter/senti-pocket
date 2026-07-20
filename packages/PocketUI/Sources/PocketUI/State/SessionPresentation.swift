import Foundation
import PocketContracts

/// Provenance is supplied by the repository coordinator; PocketUI never infers live data from non-empty rows.
public enum SessionPresentationProvenance: Equatable, Sendable {
    case network(lastUpdated: Date)
    case cache(cachedAt: Date, authenticationExpired: Bool)
    case fixture
    case unavailable
}

public enum SessionLoadFailure: Equatable, Sendable {
    case reauthenticationRequired
    case accessDenied
    case offlineNoCache
    case network
    case invalidData
    case service

    public var title: String {
        switch self {
        case .reauthenticationRequired: return "Sign in again"
        case .accessDenied: return "Access denied"
        case .offlineNoCache: return "Nothing available offline"
        case .network: return "Connection unavailable"
        case .invalidData: return "Session data unavailable"
        case .service: return "Sessions unavailable"
        }
    }

    public var detail: String {
        switch self {
        case .reauthenticationRequired:
            return "Your Senti authorization is no longer valid. Sign in again before loading protected sessions."
        case .accessDenied:
            return "This account is not authorized to open that session. No protected cached content is shown."
        case .offlineNoCache:
            return "Connect to Senti once to make authorized session data available on this device."
        case .network:
            return "Check your connection and try again."
        case .invalidData:
            return "Senti returned session data that this app could not safely present."
        case .service:
            return "Senti could not load sessions right now."
        }
    }

    fileprivate var suppressesProtectedContent: Bool {
        switch self {
        case .reauthenticationRequired, .accessDenied, .offlineNoCache, .invalidData:
            return true
        case .network, .service:
            return false
        }
    }
}

public struct SessionListPresentationState: Equatable, Sendable {
    public let rows: [SessionRowPresentation]
    public let resultCount: Int
    public let includesArchived: Bool
    public let hasMore: Bool
    public let provenance: SessionPresentationProvenance
    public let isRefreshing: Bool
    public let failure: SessionLoadFailure?

    public init(
        page: SessionListPage,
        provenance: SessionPresentationProvenance,
        isRefreshing: Bool = false,
        failure: SessionLoadFailure? = nil
    ) {
        let ids = page.sessions.map(\.sessionId)
        let identitiesAreValid = ids.allSatisfy { $0.pocketNonblank != nil }
            && Set(ids).count == ids.count
        let sourceAllowsContent: Bool
        if case .unavailable = provenance {
            sourceAllowsContent = false
        } else {
            sourceAllowsContent = true
        }
        let failureAllowsContent = failure?.suppressesProtectedContent != true
        let canPresentRows = identitiesAreValid && sourceAllowsContent && failureAllowsContent

        self.rows = canPresentRows ? page.sessions.map(SessionRowPresentation.init) : []
        self.resultCount = page.count
        self.includesArchived = page.includeArchived
        self.hasMore = page.hasMore
        self.provenance = provenance
        self.isRefreshing = isRefreshing
        self.failure = identitiesAreValid ? failure : .invalidData
    }
}

public struct SessionRowPresentation: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let summary: String?
    public let status: String
    public let archiveStatus: String
    public let membershipRole: String
    public let agentCount: Int
    public let eventCount: Int
    public let lastActivity: ParsedSessionTimestamp?

    fileprivate init(_ session: SessionSummary) {
        self.id = session.sessionId
        self.title = session.title.pocketNonblank ?? "Untitled session"
        self.summary = session.summaryText.pocketNonblank
        self.status = session.status
        self.archiveStatus = session.archiveStatus
        self.membershipRole = session.membershipRole
        self.agentCount = session.agentCount
        self.eventCount = session.eventCount
        self.lastActivity = ParsedSessionTimestamp(session.lastActivityAt)
    }

    public var statusLabel: String { status.pocketTokenLabel }
    public var archiveStatusLabel: String { archiveStatus.pocketTokenLabel }
    public var membershipRoleLabel: String { membershipRole.pocketTokenLabel }
}

public struct SessionActivityPresentationState: Equatable, Sendable {
    public let sessionId: String
    public let events: [SessionEventRowPresentation]
    public let actions: [SessionActionRowPresentation]
    public let provenance: SessionPresentationProvenance
    public let isRefreshing: Bool
    public let failure: SessionLoadFailure?

    public init(
        sessionId: String,
        eventPage: SessionEventForwardPage,
        actionPage: SessionActionPage,
        provenance: SessionPresentationProvenance,
        isRefreshing: Bool = false,
        failure: SessionLoadFailure? = nil
    ) {
        let eventSessionsMatch = eventPage.events.allSatisfy { $0.sessionId == sessionId }
        let actionSessionsMatch = actionPage.sessionId == sessionId
            && actionPage.actions.allSatisfy { $0.sessionId == sessionId }
        let eventIDs = eventPage.events.map(\.id)
        let actionIDs = actionPage.actions.map(\.id)
        let identitiesAreValid = sessionId.pocketNonblank != nil
            && eventIDs.allSatisfy { $0.pocketNonblank != nil }
            && actionIDs.allSatisfy { $0.pocketNonblank != nil }
            && Set(eventIDs).count == eventIDs.count
            && Set(actionIDs).count == actionIDs.count
        let sourceAllowsContent: Bool
        if case .unavailable = provenance {
            sourceAllowsContent = false
        } else {
            sourceAllowsContent = true
        }
        let failureAllowsContent = failure?.suppressesProtectedContent != true

        self.sessionId = sessionId
        self.provenance = provenance
        self.isRefreshing = isRefreshing

        guard eventSessionsMatch, actionSessionsMatch, identitiesAreValid,
              sourceAllowsContent, failureAllowsContent else {
            self.events = []
            self.actions = []
            self.failure = identitiesAreValid && eventSessionsMatch && actionSessionsMatch
                ? failure
                : .invalidData
            return
        }

        self.events = eventPage.events.map(SessionEventRowPresentation.init)
        self.actions = actionPage.actions.map(SessionActionRowPresentation.init)
        self.failure = failure
    }
}

public struct SessionEventRowPresentation: Equatable, Identifiable, Sendable {
    public struct ID: Hashable, Sendable {
        public let sessionId: String
        public let eventId: String
    }

    public let id: ID
    public let sessionId: String
    public let sequenceId: Int64
    public let eventType: String
    public let author: String
    public let text: String?
    public let timestamp: ParsedSessionTimestamp

    fileprivate init(_ event: SessionEventDTO) {
        self.id = ID(sessionId: event.sessionId, eventId: event.id)
        self.sessionId = event.sessionId
        self.sequenceId = event.sequenceId
        self.eventType = event.event
        self.author = event.agent["displayName"]?.stringValue.pocketNonblank
            ?? event.agentId.pocketNonblank
            ?? "Unknown participant"
        self.text = event.payload["text"]?.stringValue.pocketNonblank
        self.timestamp = ParsedSessionTimestamp(event.ts)
    }

    public var eventTypeLabel: String { eventType.pocketTokenLabel }
}

public struct SessionActionRowPresentation: Equatable, Identifiable, Sendable {
    public struct ID: Hashable, Sendable {
        public let sessionId: String
        public let actionId: String
    }

    public let id: ID
    public let sessionId: String
    public let targetSequenceId: Int64
    public let actionType: String
    public let actor: String
    public let note: String?
    public let createdAt: ParsedSessionTimestamp

    fileprivate init(_ action: SessionActionDTO) {
        self.id = ID(sessionId: action.sessionId, actionId: action.id)
        self.sessionId = action.sessionId
        self.targetSequenceId = action.targetSequenceId
        self.actionType = action.actionType
        self.actor = action.actorId.pocketNonblank ?? "Unknown participant"
        self.note = action.note.pocketNonblank
        self.createdAt = ParsedSessionTimestamp(action.createdAt)
    }

    public var actionTypeLabel: String { actionType.pocketTokenLabel }
}

private extension Optional where Wrapped == String {
    var pocketNonblank: String? {
        guard let value = self else { return nil }
        return value.pocketNonblank
    }
}

private extension String {
    var pocketNonblank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var pocketTokenLabel: String {
        replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }
}
