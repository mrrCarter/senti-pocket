// DialHydration — the LEAN-push hydration-merge (Atlas, warden hand-off #319077). When a ring arrives LEAN
// (fetch==true, governed content shed for the PushKit budget), DialPayloadV1 decode yields `.needsHydration(id, core)`.
// The app then fetches the FULL signal over the AUTHENTICATED GET /dial?id= (relay's PR-B2; warden froze the response
// shape = the full stored NeedCarterSignal — the exact object this app already models in PocketContracts). This merges
// the LEAN core + that fetched signal → a RenderableRing, so the ring paints the governed content ONLY after the authed
// fetch, never from the unauthenticated push.
//
// SECURITY INVARIANT (load-bearing): the fetched signal's id MUST equal the push core's id, and its session/checkpoint
// must match the core — else we refuse the merge. All semantic presentation fields are then derived from that fetched
// signal, so untrusted push kind/caller/priority values cannot be mixed with authenticated governed content.

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
    /// substituted signal. Governed content and semantic presentation come ONLY from the authenticated fetch.
    static func merge(core: RingCore, fetched signal: NeedCarterSignal) throws -> RenderableRing {
        guard UTF8ExactIdentity.matches(signal.id, core.id) else {
            throw DialHydrationError.idMismatch(pushId: core.id, fetchedId: signal.id)
        }
        guard UTF8ExactIdentity.matches(signal.context.sessionId, core.sessionId) else {
            throw DialHydrationError.contextMismatch("session \(signal.context.sessionId) != push \(core.sessionId)")
        }
        // checkpointId: refuse a substitution (both present + differ). The merged VALUE is taken AUTHED-ONLY from the
        // signal below — NEVER the push — so a push that announces a checkpoint the authed signal doesn't carry can't
        // scope a follow-up's grounding with an unauthenticated value (forge finding on #91: checkpointId flows
        // push→RingCore→LiveDialVoice→reasoner.answerFollowUp, so the push must never source it).
        if let pushCp = core.checkpointId,
           let sigCp = signal.context.checkpointId,
           !UTF8ExactIdentity.matches(pushCp, sigCp) {
            throw DialHydrationError.contextMismatch("checkpoint \(sigCp) != push \(pushCp)")
        }

        // pickOption labels come from the signal's kind; every other kind has no options.
        let options: [String]
        if case .pickOption(let labels) = signal.kind { options = labels } else { options = [] }
        let authenticatedDialFields = signal.dialFields()

        return RenderableRing(
            core: RingCore(
                id: core.id,
                kind: signal.kind.dialWireKind,
                priority: authenticatedDialFields.priority,
                callerName: authenticatedDialFields.callerName,
                sessionId: core.sessionId,
                checkpointId: signal.context.checkpointId,  // AUTHED-ONLY: the push's checkpoint is never trusted as the value
                // Registry V2 already authorized this exact server fence before the fetch. Preserve it verbatim so
                // the post-await gate can prove the same binding is still current; hydration never invents a fence.
                binding: core.binding
            ),
            message: signal.question,                  // the governed content, from the AUTHED fetch only
            options: options,
            evidenceSeqs: signal.evidenceSeqs,
            confidence: signal.confidence
        )
    }
}
