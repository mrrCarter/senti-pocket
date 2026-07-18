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
        let evidenceById = Dictionary(evidence.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
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
