import XCTest
import PocketContracts   // SEPARATE module — this test IS the external-consumer proof (v0.1.1 fix).

/// Cross-module construction (compile-guard on public inits); Codable round-trip; hash binding invalidates on
/// change; injection-proof canonicalization + a published known-answer HASH (Echo 84d463f) mirrored by Node;
/// isValidForConfirmation fails closed; ActionReceipt structural + signature invariants.
final class ContractsCrossModuleTests: XCTestCase {

    private let ts = Date(timeIntervalSince1970: 1_752_835_200)

    func testEveryContractConstructsCrossModule() throws {
        let ev = EvidenceRef(id: "ev_1", sessionId: "s1", sequence: 230141, agentId: "a", snippet: "x", ts: ts)
        let rawEvent = RawEvent(sequenceId: 230141, event: "session_message", agentId: "a1", payload: "hello", idempotencyToken: "tok1", ts: ts)
        let rawCp = RawCheckpoint(checkpointId: "cp1", sessionId: "s1", sessionTitle: "room", startSequence: 230100, endSequence: 230180, capturedAt: ts, agents: ["a1"], events: [rawEvent])
        let claim = Claim(id: "c1", text: "fact", kind: .fact, evidenceIds: ["ev_1"])
        let agentSummary = AgentSummary(agentId: "a1", summary: "s", claims: [claim], evidence: [ev])
        let summary = CheckpointSummary(checkpointId: "cp1", headline: "h", summaryBaselineSchema: "checkpoint_summary_sections_v1", grade: "A-", perAgent: [agentSummary], risks: ["r"], blockers: ["b"])
        let bundle = PocketBundle(contractsVersion: PocketContracts.version, checkpointId: "cp1", sessionId: "s1", sequenceStart: 230100, sequenceEnd: 230180, summary: summary, evidence: [ev], createdAt: ts, signature: "sig", signingKeyId: "k1")
        _ = BriefingPlan(checkpointId: "cp1", segments: [BriefingSegment(id: "b1", text: "t", evidenceIds: ["ev_1"])])
        _ = QuestionAnswer(id: "q1", checkpointId: "cp1", question: "?", answer: "a", citations: ["ev_1"], answeredOffline: true, createdAt: ts)
        _ = ActionProposal(id: "p1", kind: .threadedReply, targetSessionId: "s1", targetSequence: 230180, renderedPreview: "x", requiresConfirmation: true, createdAt: ts, sourceQuestionId: "q1", proposalHash: "H")

        XCTAssertEqual(rawCp.events.first?.sequenceId, 230141)
        XCTAssertEqual(bundle.contractsVersion, "0.1.8")
        XCTAssertEqual(agentSummary.claims.first?.kind, .fact)
    }

    /// Extreme decoded Date is rejected, NEVER trapped (Echo 62e08e9 A: Int(hugeDouble) crash/DoS).
    func testExtremeDateRejectedNonTrapping() {
        let extreme = Date(timeIntervalSince1970: 1e18)   // absurd; must be rejected, not crash
        let r = ActionReceipt(id: "r1", proposalId: "p1", status: .posted, result: .sequence(sequenceId: 200), targetSessionId: "s1", confirmedByHumanAt: extreme, confirmedProposalHash: "H", executedAt: ts, failureReason: nil, signature: "sig", signingKeyId: "k1")
        XCTAssertNil(ActionReceipt.safeEpochMillis(extreme))
        XCTAssertFalse(r.hasSaneDates())
        XCTAssertFalse(r.isStructurallyValid())
        _ = r.canonicalReceiptPayload()                   // must not trap even on the bad date
    }

    /// Receipt KAV + per-field tamper (Echo 43b796b): canonicalReceiptPayload v4 binds every field except
    /// `signature`, so substituting id / confirmedByHumanAt / signingKeyId changes the signed bytes. Node mirrors this.
    /// v4 (v0.1.7): the `result` field is the length-prefixed ActionResultRef token (here .sequence(200)).
    func testReceiptCanonicalPayloadBindsAllFields() {
        func receipt(id: String = "r1", confirmedAt: Date, keyId: String = "k1") -> ActionReceipt {
            ActionReceipt(id: id, proposalId: "p1", status: .posted, result: .sequence(sequenceId: 200), targetSessionId: "s1", confirmedByHumanAt: confirmedAt, confirmedProposalHash: "H", executedAt: ts, failureReason: nil, signature: "sig", signingKeyId: keyId)
        }
        let base = receipt(confirmedAt: ts)
        XCTAssertEqual(base.canonicalReceiptPayload(), "pocket.actionreceipt.v4\n2:r12:p16:posted15:8:sequence3:2002:s11:H13:175283520000013:17528352000000:2:k1")
        // each previously-omitted field now changes the signed bytes:
        XCTAssertNotEqual(base.canonicalReceiptPayload(), receipt(id: "r2", confirmedAt: ts).canonicalReceiptPayload())
        XCTAssertNotEqual(base.canonicalReceiptPayload(), receipt(confirmedAt: ts.addingTimeInterval(1)).canonicalReceiptPayload())
        XCTAssertNotEqual(base.canonicalReceiptPayload(), receipt(confirmedAt: ts, keyId: "k2").canonicalReceiptPayload())
    }

    /// ActionResultRef (v0.1.7) — the tagged union that replaced resultingSequence:Int. Codable round-trips both
    /// variants (explicit kind-discriminated JSON); canonical tokens are Node-mirrorable KAVs; nil cursor stays
    /// distinct from "" via the presence flag. Relay's gateway MUST match these tokens byte-for-byte.
    func testActionResultRefTaggedUnion() throws {
        let action = ActionResultRef.action(actionId: "act_1", targetSequenceId: 230180, targetCursor: "cur_9")
        let sequence = ActionResultRef.sequence(sequenceId: 230195)
        for ref in [action, sequence, ActionResultRef.action(actionId: "act_2", targetSequenceId: 5, targetCursor: nil)] {
            XCTAssertEqual(ref, try JSONDecoder().decode(ActionResultRef.self, from: JSONEncoder().encode(ref)))
        }
        // Canonical token KAVs (Node mirror):
        XCTAssertEqual(action.canonicalToken(), "6:action5:act_16:23018015:cur_9")
        XCTAssertEqual(sequence.canonicalToken(), "8:sequence6:230195")
        // nil cursor MUST stay distinct from an empty-string cursor (presence flag, injection-proof).
        XCTAssertNotEqual(
            ActionResultRef.action(actionId: "a", targetSequenceId: 1, targetCursor: nil).canonicalToken(),
            ActionResultRef.action(actionId: "a", targetSequenceId: 1, targetCursor: "").canonicalToken())
    }

    /// KAV — the exact `pocket.bundle.v1` canonical bytes (v0.1.9). Relay's Node gateway MUST reproduce this
    /// byte-for-byte to sign real bundles; the `signature` field is excluded (any value -> same canonical).
    func testBundleCanonicalKAV() {
        let summary = CheckpointSummary(checkpointId: "cp1", headline: "h", summaryBaselineSchema: "sch", grade: nil, perAgent: [], risks: [], blockers: [])
        let bundle = PocketBundle(contractsVersion: "0.1.8", checkpointId: "cp1", sessionId: "s1", sequenceStart: 1, sequenceEnd: 2, summary: summary, evidence: [], createdAt: ts, signature: "IGNORED", signingKeyId: "k1")
        XCTAssertEqual(bundle.canonicalBundlePayload(),
            "pocket.bundle.v1\n5:0.1.83:cp12:s11:11:23:cp11:h3:sch01:01:01:01:013:17528352000002:k1")
        // signature is NOT bound: changing it does not change the canonical.
        let other = PocketBundle(contractsVersion: "0.1.8", checkpointId: "cp1", sessionId: "s1", sequenceStart: 1, sequenceEnd: 2, summary: summary, evidence: [], createdAt: ts, signature: "DIFFERENT", signingKeyId: "k1")
        XCTAssertEqual(bundle.canonicalBundlePayload(), other.canonicalBundlePayload())

        // POPULATED KAV — pins nested element serialization (evidence/claim/agent + populated arrays + present grade),
        // so Relay's Node mirror is fully specified (the empty-array case above does not exercise these).
        let ev1 = EvidenceRef(id: "ev1", sessionId: "s1", sequence: 11, agentId: "a1", snippet: "sn", ts: ts)
        let ag = AgentSummary(agentId: "a1", summary: "sum", claims: [Claim(id: "c1", text: "t", kind: .fact, evidenceIds: ["ev1"])], evidence: [ev1])
        let sum2 = CheckpointSummary(checkpointId: "cp1", headline: "H", summaryBaselineSchema: "sch", grade: "A", perAgent: [ag], risks: ["r1"], blockers: ["b1"])
        let pop = PocketBundle(contractsVersion: "0.1.8", checkpointId: "cp1", sessionId: "s1", sequenceStart: 10, sequenceEnd: 20, summary: sum2, evidence: [ev1], createdAt: ts, signature: "X", signingKeyId: "k1")
        XCTAssertEqual(pop.canonicalBundlePayload(),
            "pocket.bundle.v1\n5:0.1.83:cp12:s12:102:203:cp11:H3:sch11:A1:12:a13:sum1:12:c11:t4:fact1:13:ev11:13:ev12:s12:112:a12:sn13:17528352000001:12:r11:12:b11:13:ev12:s12:112:a12:sn13:175283520000013:17528352000002:k1")
    }

    #if canImport(CryptoKit)
    /// SignatureState ordering (Echo): a signature PRESENT on a structurally-invalid receipt is .invalid (tamper), not .unsigned.
    func testSignatureStateInvalidOnStructuralTamper() {
        let tampered = ActionReceipt(id: "r1", proposalId: "p1", status: .pendingConnectivity, result: nil, targetSessionId: "s1", confirmedByHumanAt: ts, confirmedProposalHash: "H", executedAt: nil, failureReason: nil, signature: "sig", signingKeyId: "k1")
        XCTAssertEqual(tampered.signatureState(gatewayPublicKeyBase64url: "AA"), .invalid)   // present sig + bad structure
        let unsigned = ActionReceipt(id: "r1", proposalId: "p1", status: .pendingConnectivity, result: nil, targetSessionId: "s1", confirmedByHumanAt: ts, confirmedProposalHash: "H", executedAt: nil, failureReason: nil, signature: nil, signingKeyId: nil)
        XCTAssertEqual(unsigned.signatureState(gatewayPublicKeyBase64url: "AA"), .unsigned)  // truly no signature
    }
    #endif

    func testCodableRoundTripFromExternalModule() throws {
        let ev = EvidenceRef(id: "ev_1", sessionId: "s1", sequence: 1, agentId: "a1", snippet: "x", ts: ts)
        let data = try JSONEncoder().encode(ev)
        XCTAssertEqual(ev, try JSONDecoder().decode(EvidenceRef.self, from: data))
    }

    /// KAV_1 — the exact canonicalPayload string. Relay's Node gateway MUST match this byte-for-byte.
    func testKnownAnswerVectorCanonicalPayload() {
        XCTAssertEqual(
            ActionProposal.canonicalPayload(id: "p1", kind: .threadedReply, targetSessionId: "s1", targetSequence: 100, renderedPreview: "post X", createdAt: ts, sourceQuestionId: nil),
            "pocket.actionproposal.v3\n2:p113:threadedReply2:s13:1006:post X13:17528352000000")
    }

    /// Injection resistance: under OLD newline-delimiting these collide; length-prefix keeps them distinct.
    func testCanonicalizationIsInjectionProof() {
        let a = ActionProposal.canonicalPayload(id: "p", kind: .threadedReply, targetSessionId: "s", targetSequence: 1, renderedPreview: "1\nX", createdAt: ts, sourceQuestionId: nil)
        let b = ActionProposal.canonicalPayload(id: "p", kind: .threadedReply, targetSessionId: "s\n1", targetSequence: 1, renderedPreview: "X", createdAt: ts, sourceQuestionId: nil)
        XCTAssertNotEqual(a, b)
    }

    func testReceiptStructuralInvariants() {
        // pending: no posted fields -> valid.
        let pending = ActionReceipt(id: "p1", proposalId: "p1", status: .pendingConnectivity, result: nil, targetSessionId: "s1", confirmedByHumanAt: ts, confirmedProposalHash: "H", executedAt: nil, failureReason: nil, signature: nil, signingKeyId: nil)
        XCTAssertTrue(pending.isStructurallyValid())
        // pending WITH a signature -> invalid (a pending write must never look sent/signed).
        let pendingSigned = ActionReceipt(id: "p1", proposalId: "p1", status: .pendingConnectivity, result: nil, targetSessionId: "s1", confirmedByHumanAt: ts, confirmedProposalHash: "H", executedAt: nil, failureReason: nil, signature: "sig", signingKeyId: "k")
        XCTAssertFalse(pendingSigned.isStructurallyValid())
        // posted MISSING signature/seq -> invalid.
        let postedBad = ActionReceipt(id: "p1", proposalId: "p1", status: .posted, result: nil, targetSessionId: "s1", confirmedByHumanAt: ts, confirmedProposalHash: "H", executedAt: nil, failureReason: nil, signature: nil, signingKeyId: nil)
        XCTAssertFalse(postedBad.isStructurallyValid())
        // fully-formed posted -> valid.
        let postedGood = ActionReceipt(id: "p1", proposalId: "p1", status: .posted, result: .sequence(sequenceId: 200), targetSessionId: "s1", confirmedByHumanAt: ts, confirmedProposalHash: "H", executedAt: ts, failureReason: nil, signature: "sig", signingKeyId: "k")
        XCTAssertTrue(postedGood.isStructurallyValid())
    }

    #if canImport(CryptoKit)
    func testProposalHashBindingAndConfirmationGate() {
        let p = ActionProposal(id: "p1", kind: .threadedReply, targetSessionId: "s1", targetSequence: 100, renderedPreview: "post X", createdAt: ts, sourceQuestionId: nil)
        XCTAssertTrue(p.hashMatchesContent())
        XCTAssertTrue(p.isValidForConfirmation())
        // v0.1.8 KAV HASH: base64url(SHA-256(v3 canonical)) for (id p1, threadedReply, s1, 100, "post X", ts, nil).
        XCTAssertEqual(p.proposalHash, "Wk4lhnUOCRAiFMXVaroaDiv2lyHsRGJsmAJg_mjm1NY")
        let swapped = ActionProposal(id: "p1", kind: .threadedReply, targetSessionId: "s1", targetSequence: 100, renderedPreview: "post EVIL", createdAt: ts, sourceQuestionId: nil, proposalHash: p.proposalHash)
        XCTAssertFalse(swapped.isValidForConfirmation())
        let noConfirm = ActionProposal(id: "p1", kind: .threadedReply, targetSessionId: "s1", targetSequence: 100, renderedPreview: "post X", requiresConfirmation: false, createdAt: ts, sourceQuestionId: nil, proposalHash: p.proposalHash)
        XCTAssertFalse(noConfirm.isValidForConfirmation())
    }

    /// v0.1.8 (Echo #231350): two proposals with IDENTICAL kind/session/sequence/renderedPreview but different id
    /// (or createdAt, or sourceQuestionId) MUST get DISTINCT hashes — otherwise a stale confirm for A confirmed a
    /// same-content displayed B. Under v2 these collided; v3 binds id+createdAt+provenance so they don't.
    func testSameContentDifferentIdentityHashesDiffer() {
        let a = ActionProposal(id: "A", kind: .threadedReply, targetSessionId: "s1", targetSequence: 100, renderedPreview: "post X", createdAt: ts, sourceQuestionId: nil)
        let bDiffId = ActionProposal(id: "B", kind: .threadedReply, targetSessionId: "s1", targetSequence: 100, renderedPreview: "post X", createdAt: ts, sourceQuestionId: nil)
        let cDiffTime = ActionProposal(id: "A", kind: .threadedReply, targetSessionId: "s1", targetSequence: 100, renderedPreview: "post X", createdAt: ts.addingTimeInterval(1), sourceQuestionId: nil)
        let dDiffProvenance = ActionProposal(id: "A", kind: .threadedReply, targetSessionId: "s1", targetSequence: 100, renderedPreview: "post X", createdAt: ts, sourceQuestionId: "q9")
        let eEmptyProvenance = ActionProposal(id: "A", kind: .threadedReply, targetSessionId: "s1", targetSequence: 100, renderedPreview: "post X", createdAt: ts, sourceQuestionId: "")
        XCTAssertNotEqual(a.proposalHash, bDiffId.proposalHash)        // different id
        XCTAssertNotEqual(a.proposalHash, cDiffTime.proposalHash)      // different createdAt
        XCTAssertNotEqual(a.proposalHash, dDiffProvenance.proposalHash)// different sourceQuestionId
        XCTAssertNotEqual(a.proposalHash, eEmptyProvenance.proposalHash)// nil vs some("") — presence flag (Pulse #231475)
    }
    #endif
}
