import Foundation
import PocketContracts

/// Loads the canonical PocketBundle fixture from the app bundle (Resources/canonical_checkpoint.json).
/// Same fixture the whole swarm builds against — keeps the app's offline demo in lock-step with the lanes.
enum FixtureLoader {
    static func canonicalBundle() -> PocketBundle? {
        guard let url = Bundle.main.url(forResource: "canonical_checkpoint", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601   // fixture timestamps are ISO-8601 UTC
        return try? dec.decode(PocketBundle.self, from: data)
    }
}
