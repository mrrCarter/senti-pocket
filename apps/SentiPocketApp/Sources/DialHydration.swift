// DialHydration — the LEAN-push hydration-merge (Atlas, warden hand-off #319077). When a ring arrives LEAN
// (fetch==true, governed content shed for the PushKit budget), DialPayloadV1 decode yields `.needsHydration(id, core)`.
// The app then fetches the FULL signal over the AUTHENTICATED GET /dial?id= (relay's PR-B2; warden froze the response
// shape = the full stored NeedCarterSignal — the exact object this app already models in PocketContracts). This merges
// the LEAN core + that fetched signal → a RenderableRing, so the ring paints the governed content ONLY after the authed
// fetch, never from the unauthenticated push.
//
// SECURITY INVARIANT (load-bearing): the fetched signal's id MUST equal the push core's id, and its session/checkpoint
// must match the core — else we refuse the merge (a mismatched/substituted signal must never paint onto this ring).
// This closes the "authenticated fetch returns a DIFFERENT signal than the push announced" substitution edge.

import Foundation
import PocketContracts

enum DialHydrationError: LocalizedError, Equatable {
    case idMismatch(pushId: String, fetchedId: String)
    case contextMismatch(String)
    var errorDescription: String? {
        switch self {
        case .idMismatch(let p, let f): return "Hydration id mismatch — push announced \(p), fetch returned \(f); refusing."
        case .contextMismatch(let d):   return "Hydration context mismatch — \(d); refusing."
        }
    }
}

enum DialHydration {
    /// Merge the LEAN push core with the authed-fetched full NeedCarterSignal → a RenderableRing.
    /// Throws if the fetched signal doesn't match the ring the push announced (id/session/checkpoint) — never merges a
    /// substituted signal. The governed content (message, options, evidenceSeqs) comes ONLY from the authed fetch.
    static func merge(core: RingCore, fetched signal: NeedCarterSignal) throws -> RenderableRing {
        guard signal.id == core.id else {
            throw DialHydrationError.idMismatch(pushId: core.id, fetchedId: signal.id)
        }
        guard signal.context.sessionId == core.sessionId else {
            throw DialHydrationError.contextMismatch("session \(signal.context.sessionId) != push \(core.sessionId)")
        }
        // checkpointId: refuse a substitution (both present + differ). The merged VALUE is taken AUTHED-ONLY from the
        // signal below — NEVER the push — so a push that announces a checkpoint the authed signal doesn't carry can't
        // scope a follow-up's grounding with an unauthenticated value (forge finding on #91: checkpointId flows
        // push→RingCore→LiveDialVoice→reasoner.answerFollowUp, so the push must never source it).
        if let pushCp = core.checkpointId, let sigCp = signal.context.checkpointId, pushCp != sigCp {
            throw DialHydrationError.contextMismatch("checkpoint \(sigCp) != push \(pushCp)")
        }

        // pickOption labels come from the signal's kind; every other kind has no options.
        let options: [String]
        if case .pickOption(let labels) = signal.kind { options = labels } else { options = [] }

        return RenderableRing(
            core: RingCore(
                id: core.id,
                kind: core.kind,                       // the push core's kind slug (already the display kind)
                priority: core.priority,
                callerName: core.callerName,
                sessionId: core.sessionId,
                checkpointId: signal.context.checkpointId   // AUTHED-ONLY: the push's checkpoint is never trusted as the value
            ),
            message: signal.question,                  // the governed content, from the AUTHED fetch only
            options: options,
            evidenceSeqs: signal.evidenceSeqs,
            confidence: signal.confidence
        )
    }
}
