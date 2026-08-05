import Foundation
import PocketContracts

public struct SessionListSnapshot: Equatable, Sendable {
    public let sessions: [SessionSummary]
    public let includesArchived: Bool
    public let nextCursor: String?
    public let hasMore: Bool
    public let loadedAt: Date

    public var count: Int { sessions.count }
}

/// Actor-owned cursor state for a bounded, deterministic session list.
///
/// Each server page is validated before it can replace or extend visible state. Cursor loops, duplicate identities,
/// response-mode drift, count mismatch, and unbounded accumulation fail closed instead of producing a subtly corrupt
/// list. A failed refresh leaves the last validated snapshot intact for the coordinator to label as cached/stale.
public actor SessionRepository {
    private let transport: any SessionTransport
    private let pageSize: Int
    private let maximumAccumulatedSessions: Int
    private let clock: @Sendable () -> Date

    private var sessions: [SessionSummary] = []
    private var includeArchived = false
    private var nextCursor: String?
    private var hasMore = false
    private var seenCursors: Set<String> = []
    private var loadedAt: Date?
    private var revision: UInt64 = 0
    private var loadingCursor: String?
    private var loadingRevision: UInt64?

    public init(
        transport: any SessionTransport,
        pageSize: Int = 50,
        maximumAccumulatedSessions: Int = 2_000,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.pageSize = min(max(pageSize, 1), 200)
        self.maximumAccumulatedSessions = max(maximumAccumulatedSessions, 1)
        self.clock = clock
    }

    @discardableResult
    public func refreshSessions(includeArchived: Bool = false) async throws -> SessionListSnapshot {
        revision &+= 1
        let operationRevision = revision
        loadingCursor = nil
        loadingRevision = nil
        let page = try await transport.listSessions(
            includeArchived: includeArchived,
            limit: pageSize,
            cursor: nil
        )
        guard revision == operationRevision else { throw SessionTransportError.cancelled }
        let validated = try Self.validate(page: page, expectedArchived: includeArchived)
        guard validated.sessions.count <= maximumAccumulatedSessions else {
            throw SessionTransportError.invalidData
        }

        sessions = validated.sessions
        self.includeArchived = includeArchived
        nextCursor = validated.nextCursor
        hasMore = validated.hasMore
        seenCursors = Set(validated.nextCursor.map { [$0] } ?? [])
        loadedAt = clock()
        return snapshot()
    }

    @discardableResult
    public func loadMoreSessions() async throws -> SessionListSnapshot {
        guard loadedAt != nil else { throw SessionTransportError.invalidRequest }
        guard hasMore, let cursor = nextCursor else { return snapshot() }
        guard seenCursors.contains(cursor) else {
            throw SessionTransportError.invalidData
        }
        guard loadingCursor == nil, loadingRevision == nil else { return snapshot() }
        let operationRevision = revision
        loadingCursor = cursor
        loadingRevision = operationRevision
        defer {
            if loadingCursor == cursor, loadingRevision == operationRevision {
                loadingCursor = nil
                loadingRevision = nil
            }
        }

        let page = try await transport.listSessions(
            includeArchived: includeArchived,
            limit: pageSize,
            cursor: cursor
        )
        guard revision == operationRevision, nextCursor == cursor else {
            throw SessionTransportError.cancelled
        }
        let validated = try Self.validate(page: page, expectedArchived: includeArchived)
        let existingIDs = Set(sessions.map(\.sessionId))
        guard validated.sessions.allSatisfy({ !existingIDs.contains($0.sessionId) }),
              sessions.count + validated.sessions.count <= maximumAccumulatedSessions else {
            throw SessionTransportError.invalidData
        }
        if let newCursor = validated.nextCursor {
            guard newCursor != cursor, !seenCursors.contains(newCursor) else {
                throw SessionTransportError.invalidData
            }
        }

        sessions.append(contentsOf: validated.sessions)
        nextCursor = validated.nextCursor
        hasMore = validated.hasMore
        if let nextCursor { seenCursors.insert(nextCursor) }
        loadedAt = clock()
        return snapshot()
    }

    public func currentSnapshot() -> SessionListSnapshot? {
        guard loadedAt != nil else { return nil }
        return snapshot()
    }

    public func reset() {
        revision &+= 1
        sessions = []
        includeArchived = false
        nextCursor = nil
        hasMore = false
        seenCursors = []
        loadedAt = nil
        loadingCursor = nil
        loadingRevision = nil
    }

    private func snapshot() -> SessionListSnapshot {
        SessionListSnapshot(
            sessions: sessions,
            includesArchived: includeArchived,
            nextCursor: nextCursor,
            hasMore: hasMore,
            loadedAt: loadedAt ?? clock()
        )
    }

    private static func validate(
        page: SessionListPage,
        expectedArchived: Bool
    ) throws -> (
        sessions: [SessionSummary],
        nextCursor: String?,
        hasMore: Bool
    ) {
        let ids = page.sessions.map(\.sessionId)
        let cursorIsValid = page.nextCursor.map {
            !$0.isEmpty
                && $0.utf8.count <= 512
                && $0.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
                && $0.rangeOfCharacter(from: .controlCharacters) == nil
        } ?? true
        guard page.includeArchived == expectedArchived,
              page.count == page.sessions.count,
              ids.allSatisfy(SessionIdentifier.isValid),
              Set(ids).count == ids.count,
              cursorIsValid,
              !page.hasMore || !page.sessions.isEmpty,
              page.hasMore == (page.nextCursor != nil) else {
            throw SessionTransportError.invalidData
        }
        return (page.sessions, page.nextCursor, page.hasMore)
    }
}
