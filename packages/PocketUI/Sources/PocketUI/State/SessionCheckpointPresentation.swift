import Foundation
import PocketContracts

/// Read-only presentation for ordinary room checkpoints.
///
/// A `MembershipAuthorizedCheckpoint` is intentionally not a `VerifiedBundle`. This state never projects one into
/// the other and never emits a cryptographic trust claim. Opening a row must remain on the membership-authorized
/// checkpoint path unless a separately signed Pocket bundle is fetched and verified by the deterministic host.
public struct SessionCheckpointListPresentationState: Equatable, Sendable {
    public let sessionId: String
    public let rows: [SessionCheckpointRowPresentation]
    public let resultCount: Int
    public let provenance: SessionPresentationProvenance
    public let isRefreshing: Bool
    public let failure: SessionLoadFailure?

    public init(
        sessionId: String,
        page: SessionCheckpointListPage,
        provenance: SessionPresentationProvenance,
        isRefreshing: Bool = false,
        failure: SessionLoadFailure? = nil
    ) {
        let checkpoints = page.checkpoints.map(MembershipAuthorizedCheckpoint.init)
        let checkpointIDs = checkpoints.map(\.id)
        let identitiesAreValid = sessionId.pocketCheckpointNonblank != nil
            && checkpointIDs.allSatisfy { $0.pocketCheckpointNonblank != nil }
            && Set(checkpointIDs).count == checkpointIDs.count
        let sessionsMatch = checkpoints.allSatisfy { $0.checkpoint.sessionId == sessionId }
        let countsAreValid = page.count >= 0 && page.count == checkpoints.count
        let sequencesAreValid = checkpoints.allSatisfy { checkpoint in
            let value = checkpoint.checkpoint
            guard value.eventSequence > 0 else { return false }
            if let start = value.startSequence, start < 0 { return false }
            if let end = value.endSequence, end < 0 { return false }
            if let start = value.startSequence, let end = value.endSequence, start > end { return false }
            return true
        }
        let sourceAllowsContent: Bool
        if case .unavailable = provenance {
            sourceAllowsContent = false
        } else {
            sourceAllowsContent = true
        }
        let canPresentRows = identitiesAreValid
            && sessionsMatch
            && countsAreValid
            && sequencesAreValid
            && sourceAllowsContent
            && failure?.suppressesProtectedContent != true

        self.sessionId = sessionId
        self.rows = canPresentRows ? checkpoints.map(SessionCheckpointRowPresentation.init) : []
        self.resultCount = canPresentRows ? page.count : 0
        self.provenance = provenance
        self.isRefreshing = isRefreshing
        self.failure = identitiesAreValid && sessionsMatch && countsAreValid && sequencesAreValid
            ? failure
            : .invalidData
    }
}

public struct SessionCheckpointRowPresentation: Equatable, Identifiable, Sendable {
    public struct ID: Hashable, Sendable {
        public let sessionId: String
        public let checkpointId: String
    }

    public let id: ID
    public let sessionId: String
    public let checkpointId: String
    public let title: String
    public let summary: String?
    public let kind: String
    public let grade: String
    public let createdBy: String
    public let createdAt: ParsedSessionTimestamp
    public let startSequence: Int64?
    public let endSequence: Int64?
    public let eventSequence: Int64

    init(_ authorized: MembershipAuthorizedCheckpoint) {
        let checkpoint = authorized.checkpoint
        self.id = ID(sessionId: checkpoint.sessionId, checkpointId: checkpoint.checkpointId)
        self.sessionId = checkpoint.sessionId
        self.checkpointId = checkpoint.checkpointId
        self.title = checkpoint.title.pocketCheckpointNonblank ?? "Untitled checkpoint"
        self.summary = checkpoint.summary.pocketCheckpointNonblank
        self.kind = checkpoint.kind
        self.grade = checkpoint.grade
        self.createdBy = checkpoint.createdBy.pocketCheckpointNonblank ?? "Unknown participant"
        self.createdAt = authorized.createdAt
        self.startSequence = checkpoint.startSequence
        self.endSequence = checkpoint.endSequence
        self.eventSequence = checkpoint.eventSequence
    }

    public var kindLabel: String { kind.pocketCheckpointTokenLabel }
    public var gradeLabel: String { grade.pocketCheckpointNonblank ?? "Not graded" }

    /// Deliberately neutral copy: membership permits reading, but does not prove a signed Pocket briefing.
    public var trustNotice: String {
        "Available through your room membership. Not a signed Pocket briefing."
    }

    public var sequenceLabel: String {
        switch (startSequence, endSequence) {
        case let (start?, end?): return "Events #\(start)–#\(end)"
        case let (start?, nil): return "From event #\(start)"
        case let (nil, end?): return "Through event #\(end)"
        case (nil, nil): return "Checkpoint event #\(eventSequence)"
        }
    }
}

private extension String {
    var pocketCheckpointNonblank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var pocketCheckpointTokenLabel: String {
        replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }
}
