import XCTest
import PocketContracts
@testable import SentiPocketApp

/// Locks the load-bearing invariants of DialHydration.merge — the LEAN-push → authed-fetch → RenderableRing seam.
/// Two things must hold, forever:
///  1. AUTHENTICATED PROVENANCE — kind/priority/caller plus message/options/evidence/confidence come ONLY from the
///     fetched signal, never the push core (warden's LEAN/doorbell ruling #319761).
///  2. SUBSTITUTION REFUSAL — a fetched signal that doesn't match the ring the push announced (id / session /
///     checkpoint) is REFUSED, so an authed fetch returning a different signal can never paint onto this ring.
final class DialHydrationTests: XCTestCase {

    // MARK: - fixtures

    private func core(id: String = "need_1",
                      kind: String = "decisionYours",
                      priority: String = "high",
                      callerName: String = "Senti · claude-warden needs your decision",
                      sessionId: String = "6cf7e861",
                      checkpointId: String? = "cp_9",
                      binding: DeviceRingBindingFence? = nil) -> RingCore {
        RingCore(id: id, kind: kind, priority: priority,
                 callerName: callerName,
                 sessionId: sessionId, checkpointId: checkpointId, binding: binding)
    }

    private func signal(id: String = "need_1",
                        kind: NeedCarterKind = .decisionYours,
                        sessionId: String = "6cf7e861",
                        checkpointId: String? = "cp_9",
                        question: String = "Ship the consolidation to master?",
                        evidenceSeqs: [Int] = [315038, 315050],
                        confidence: Double = 0.9) -> NeedCarterSignal {
        NeedCarterSignal(
            id: id, kind: kind, question: question,
            context: NeedCarterContext(sessionId: sessionId, checkpointId: checkpointId, whatWeNeed: "master merge go"),
            confidence: confidence, evidenceSeqs: evidenceSeqs, requestedBy: "claude-warden",
            createdAt: Date(timeIntervalSince1970: 1_784_370_900)
        )
    }

    // MARK: - 1. governed content comes ONLY from the authed fetch

    func test_happy_merge_pulls_governed_content_from_the_fetch() throws {
        let r = try DialHydration.merge(
            core: core(kind: "pickOption"),
            fetched: signal(kind: .pickOption(["Merge now", "Wait for forge"]),
                            question: "Which path?", evidenceSeqs: [1, 2], confidence: 0.8)
        )
        // routing identity remains bound to the push/fetch agreement; semantic presentation is authenticated-fetch only
        XCTAssertEqual(r.core.id, "need_1")
        XCTAssertEqual(r.core.kind, "pickOption")
        XCTAssertEqual(r.core.priority, "medium")
        XCTAssertEqual(r.core.callerName, "Senti · claude-warden needs you to choose")
        XCTAssertEqual(r.core.sessionId, "6cf7e861")
        // governed content (from the AUTHED FETCH only)
        XCTAssertEqual(r.message, "Which path?")
        XCTAssertEqual(r.options, ["Merge now", "Wait for forge"]) // options derive from signal.kind, not the push
        XCTAssertEqual(r.evidenceSeqs, [1, 2])
        XCTAssertEqual(r.confidence ?? -1, 0.8, accuracy: 1e-9)
    }

    func test_authenticated_signal_overwrites_push_semantic_fields() throws {
        let ring = try DialHydration.merge(
            core: core(
                kind: "decisionYours",
                priority: "high",
                callerName: "Attacker-controlled push label"
            ),
            fetched: signal(kind: .info)
        )

        XCTAssertEqual(ring.core.kind, "info")
        XCTAssertEqual(ring.core.priority, "medium")
        XCTAssertEqual(ring.core.callerName, "Senti · update from claude-warden")
    }

    func test_registry_v2_binding_fence_survives_authenticated_merge_exactly() throws {
        let fence = DeviceRingBindingFence(
            id: "bind_0123456789abcdef0123456789abcdef",
            revision: 7
        )

        let ring = try DialHydration.merge(
            core: core(binding: fence),
            fetched: signal()
        )

        XCTAssertEqual(ring.core.binding, fence)
    }

    func test_non_pickOption_kind_has_no_options() throws {
        let r = try DialHydration.merge(core: core(kind: "go"), fetched: signal(kind: .go))
        XCTAssertEqual(r.options, [])                              // only pickOption carries options
    }

    // MARK: - 2. substitution refusal (the security invariant)

    func test_id_mismatch_is_refused() {
        XCTAssertThrowsError(try DialHydration.merge(core: core(id: "need_1"),
                                                     fetched: signal(id: "need_HIJACK"))) { err in
            guard case DialHydrationError.idMismatch(let pushId, let fetchedId) = err else {
                return XCTFail("expected idMismatch, got \(err)")
            }
            XCTAssertEqual(pushId, "need_1")
            XCTAssertEqual(fetchedId, "need_HIJACK")
        }
    }

    func test_session_mismatch_is_refused() {
        XCTAssertThrowsError(try DialHydration.merge(core: core(sessionId: "sessionA"),
                                                     fetched: signal(sessionId: "sessionB"))) { err in
            guard case DialHydrationError.contextMismatch = err else {
                return XCTFail("expected contextMismatch, got \(err)")
            }
        }
    }

    func test_checkpoint_disagreement_is_refused() {
        // both push core and fetched signal carry a checkpoint AND they differ → refuse
        XCTAssertThrowsError(try DialHydration.merge(core: core(checkpointId: "cp_A"),
                                                     fetched: signal(checkpointId: "cp_B"))) { err in
            guard case DialHydrationError.contextMismatch = err else {
                return XCTFail("expected contextMismatch, got \(err)")
            }
        }
    }

    func test_unicode_canonical_but_byte_distinct_identity_is_refused() {
        let composed = "caf\u{00E9}"
        let decomposed = "cafe\u{0301}"
        XCTAssertEqual(composed, decomposed, "precondition: Swift String equality is Unicode-canonical")
        XCTAssertFalse(composed.utf8.elementsEqual(decomposed.utf8))

        XCTAssertThrowsError(try DialHydration.merge(
            core: core(id: "need_\(composed)"),
            fetched: signal(id: "need_\(decomposed)")
        )) { error in
            guard case DialHydrationError.idMismatch = error else {
                return XCTFail("expected byte-exact idMismatch, got \(error)")
            }
        }
        XCTAssertThrowsError(try DialHydration.merge(
            core: core(sessionId: "session_\(composed)"),
            fetched: signal(sessionId: "session_\(decomposed)")
        )) { error in
            guard case DialHydrationError.contextMismatch = error else {
                return XCTFail("expected byte-exact session mismatch, got \(error)")
            }
        }
        XCTAssertThrowsError(try DialHydration.merge(
            core: core(checkpointId: "cp_\(composed)"),
            fetched: signal(checkpointId: "cp_\(decomposed)")
        )) { error in
            guard case DialHydrationError.contextMismatch = error else {
                return XCTFail("expected byte-exact checkpoint mismatch, got \(error)")
            }
        }
    }

    // MARK: - checkpoint fallback (lean push shed the checkpoint; the authed fetch is authoritative)

    func test_checkpoint_from_fetch_when_lean_push_omitted_it() throws {
        // dialId + session match, push core carried NO checkpoint → the fetch's checkpoint is accepted (not a mismatch)
        let r = try DialHydration.merge(core: core(checkpointId: nil),
                                        fetched: signal(checkpointId: "cp_from_authed_fetch"))
        XCTAssertEqual(r.core.checkpointId, "cp_from_authed_fetch")
    }

    func test_matching_checkpoint_is_preserved() throws {
        let r = try DialHydration.merge(core: core(checkpointId: "cp_9"),
                                        fetched: signal(checkpointId: "cp_9"))
        XCTAssertEqual(r.core.checkpointId, "cp_9")               // agreement → preserved, no throw
    }

    func test_push_only_checkpoint_is_dropped_authed_fetch_wins() throws {
        // forge finding on #91: a LEAN push announces a checkpoint the authed signal does NOT carry. The both-present
        // guard doesn't trip, so this is exactly where authed-only sourcing matters — the merged checkpoint must be the
        // SIGNAL's (nil here), NEVER the untrusted push value (which would otherwise scope a follow-up's grounding).
        let r = try DialHydration.merge(core: core(checkpointId: "cp_from_PUSH_only"),
                                        fetched: signal(checkpointId: nil))
        XCTAssertNil(r.core.checkpointId)                         // the push's checkpoint is NOT trusted as the value
    }
}
