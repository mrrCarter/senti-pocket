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
}

/// A bundle-scoped lookup reused by every visible claim and transcript row. Building this once per
/// `ConversationView` render avoids rebuilding the full evidence dictionary for each citation group.
struct EvidenceIndex: Equatable, Sendable {
    private let evidenceById: [String: EvidenceRef]

    init(evidence: [EvidenceRef]) {
        var index: [String: EvidenceRef] = [:]
        index.reserveCapacity(evidence.count)
        for reference in evidence where index[reference.id] == nil {
            index[reference.id] = reference
        }
        self.evidenceById = index
    }

    func resolve(ids: [String]) -> EvidenceResolution {
        var seen = Set<String>()
        var resolved: [EvidenceRef] = []
        var missing: [String] = []

        for id in ids where seen.insert(id).inserted {
            if let match = evidenceById[id] {
                resolved.append(match)
            } else {
                missing.append(id)
            }
        }

        return EvidenceResolution(resolved: resolved, missingIds: missing)
    }
}
