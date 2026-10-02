// DemoDialFactory — the FOREGROUND-reachability seed for the demo dial (spec A, P0-3). Today SentiCallKit could ring
// a bare dialId="demo" that seeded NO DialReceiveState, so the DialCoordinator declined it and nothing ever reached
// presentDemoRing/the pickup voice. This factory instead mints ONE shared dialId/UUID pair PLUS a
// `.renderable(RenderableRing)` DialReceiveState the coordinator can hydrate + run — produced ONLY after the SAME
// trust gate the live path uses (VerifiedBundle.verify) accepts the canonical bundle. It never bypasses the
// hydrate/substitution/verify checks: an unverified bundle yields nil → NO ring.
//
// SCOPE (label it honestly): ring / audio / READ-ONLY. This reaches the pickup VOICE without PushKit, but WITHOUT a
// real SessionTokenStore token it is NOT authenticated LEAN /dial hydration (the `.renderable` path does no fetch) and
// NOT governed writeback (the write needs the user's Bearer). It is a reachability demo of the voice, not the live
// governed loop.

import Foundation
import PocketCall        // VerifiedBundle — the ONLY trusted way to accept a bundle (trusted key + semantics + ed25519)
import PocketContracts   // PocketBundle

/// A foreground demo dial: one dialId/UUID pair + a renderable ring built from AUTHED, verified bundle content.
struct DemoDialSeed: Equatable {
    let dialId: String
    let callUUID: UUID
    /// Always `.renderable` — the answer hydrates trivially (no fetch) and reaches the voice; it is never a LEAN push.
    let state: DialReceiveState
    let message: String
    let callerName: String
    let priority: String
}

enum DemoDialFactory {
    static let callerName = "Senti · decision needed"
    static let priority = "high"
    /// A stable display kind for the demo ring's core (NOT `pickOption`, so `options` stays empty by contract).
    static let kind = "decisionYours"

    /// PURE + deterministic: given a bundle + explicit ids, mint the seed IFF the bundle passes VerifiedBundle.verify
    /// (trusted signing key + semantic validity + ed25519 under the pinned key). An unverified bundle → nil → NO ring
    /// (never bypasses hydrate/substitution/verify). The spoken decision text is the AUTHED, verified bundle headline —
    /// never a fabricated string. RenderableRing.core.id == dialId, so the coordinator keys pending by the SAME id and
    /// the answer resolves the SAME ring.
    static func make(from bundle: PocketBundle, dialId: String, callUUID: UUID) -> DemoDialSeed? {
        guard VerifiedBundle.verify(bundle) != nil else { return nil }
        let core = RingCore(id: dialId, kind: kind, priority: priority,
                            callerName: callerName, sessionId: bundle.sessionId, checkpointId: bundle.checkpointId)
        let ring = RenderableRing(core: core, message: bundle.summary.headline,
                                  options: [], evidenceSeqs: [], confidence: nil)
        return DemoDialSeed(dialId: dialId, callUUID: callUUID, state: .renderable(ring),
                            message: bundle.summary.headline, callerName: callerName, priority: priority)
    }

    /// App convenience: load the canonical fixture + mint fresh ids. nil (NO ring) when the fixture is missing OR
    /// unverified — the demo trigger then simply does nothing (fail-closed, same posture as the live fail-closed screen).
    static func makeFromCanonical(dialId: String = "demo-\(UUID().uuidString)",
                                  callUUID: UUID = UUID()) -> DemoDialSeed? {
        guard let bundle = FixtureLoader.canonicalBundle() else { return nil }
        return make(from: bundle, dialId: dialId, callUUID: callUUID)
    }
}
