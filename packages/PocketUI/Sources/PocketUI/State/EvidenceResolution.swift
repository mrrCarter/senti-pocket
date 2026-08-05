import Foundation
import PocketContracts

public struct EvidenceResolution: Equatable, Sendable {
    public let resolved: [EvidenceRef]
    public let missingIds: [String]

    public init(resolved: [EvidenceRef], missingIds: [String]) {
        self.resolved = resolved
        self.missingIds = missingIds
    }

    public static func resolve(ids: [String], in evidence: [EvidenceRef]) -> Self {
        EvidenceIndex(evidence: evidence).resolve(ids: ids)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.resolved.count == rhs.resolved.count
            && zip(lhs.resolved, rhs.resolved).allSatisfy { pair in
                pair.0.pocketExactlyMatches(pair.1)
            }
            && lhs.missingIds.count == rhs.missingIds.count
            && zip(lhs.missingIds, rhs.missingIds).allSatisfy { pair in
                OpaqueUTF8Identity.matches(pair.0, pair.1)
            }
    }
}

extension EvidenceRef {
    var pocketOpaqueIdentity: OpaqueUTF8Identity { OpaqueUTF8Identity(id) }

    func pocketExactlyMatches(_ other: EvidenceRef) -> Bool {
        OpaqueUTF8Identity.matches(id, other.id)
            && OpaqueUTF8Identity.matches(sessionId, other.sessionId)
            && sequence == other.sequence
            && OpaqueUTF8Identity.matches(agentId, other.agentId)
            && OpaqueUTF8Identity.matches(snippet, other.snippet)
            && ts == other.ts
    }
}

/// A bundle-scoped lookup reused by every visible claim and transcript row. Building this once per
/// `ConversationView` render avoids rebuilding the full evidence dictionary for each citation group.
struct EvidenceIndex: Equatable, Sendable {
    private let evidenceById: [OpaqueUTF8Identity: EvidenceRef]

    init(evidence: [EvidenceRef]) {
        var index: [OpaqueUTF8Identity: EvidenceRef] = [:]
        index.reserveCapacity(evidence.count)
        for reference in evidence {
            let identity = OpaqueUTF8Identity(reference.id)
            if index[identity] == nil {
                index[identity] = reference
            }
        }
        self.evidenceById = index
    }

    func resolve(ids: [String]) -> EvidenceResolution {
        var seen = Set<OpaqueUTF8Identity>()
        var resolved: [EvidenceRef] = []
        var missing: [String] = []

        for id in ids {
            let identity = OpaqueUTF8Identity(id)
            guard seen.insert(identity).inserted else { continue }
            if let match = evidenceById[identity] {
                resolved.append(match)
            } else {
                missing.append(id)
            }
        }

        return EvidenceResolution(resolved: resolved, missingIds: missing)
    }
}
