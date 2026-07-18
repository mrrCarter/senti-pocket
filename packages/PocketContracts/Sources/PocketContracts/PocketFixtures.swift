import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Canonical typed UI scenarios (Pulse review dea0776): ready-made example instances for #Previews of the
/// briefing, conversation, proposal-confirm, and receipt screens — so every Pulse view has fixture data and
/// nobody invents shapes. DEMO values (fixed timestamps, PLACEHOLDER signatures) — a placeholder signature
/// must NEVER render as verified; a pending receipt must NEVER render as sent.
public enum PocketFixtures {
    public static let ts = Date(timeIntervalSince1970: 1_752_835_200)
    public static let sessionId = "954233b7-1822-42bc-9cfe-1eb95eb0357a"

    public static let evidence: [EvidenceRef] = [
        EvidenceRef(id: "ev_1", sessionId: sessionId, sequence: 230141, agentId: "claude-pocket-relay", snippet: "atk_ parser now matches the live token format", ts: ts),
        EvidenceRef(id: "ev_2", sessionId: sessionId, sequence: 230160, agentId: "claude-warden", snippet: "entryPoint predicate is now exact-equality; positive-accept fixture present", ts: ts)
    ]

    public static let briefingPlan = BriefingPlan(checkpointId: "cp_954233b7_000012", segments: [
        BriefingSegment(id: "b1", text: "Two agents made progress on the AUTH-1C canary.", evidenceIds: ["ev_1", "ev_2"]),
        BriefingSegment(id: "b2", text: "Relay fixed the token parser to match the live format.", evidenceIds: ["ev_1"]),
        BriefingSegment(id: "b3", text: "Warden gave a strong pass once the predicate became exact-equality.", evidenceIds: ["ev_2"])
    ])

    public static let questionAnswer = QuestionAnswer(id: "q1", checkpointId: "cp_954233b7_000012",
        question: "Did the token parser get fixed?",
        answer: "Yes — Relay updated the access-token pattern to match the live atk_ format (evidence ev_1).",
        citations: ["ev_1"], answeredOffline: true, createdAt: ts)

    /// Governed-write proposal with a REAL hash where CryptoKit is available (explicit placeholder otherwise).
    public static let actionProposal: ActionProposal = {
        let kind = ActionKind.threadedReply
        let preview = "Rotate the token but do not deploy until Omar Gate is green."
        #if canImport(CryptoKit)
        return ActionProposal(id: "p1", kind: kind, targetSessionId: sessionId, targetSequence: 230180, renderedPreview: preview, createdAt: ts, sourceQuestionId: "q1")
        #else
        return ActionProposal(id: "p1", kind: kind, targetSessionId: sessionId, targetSequence: 230180, renderedPreview: preview, requiresConfirmation: true, createdAt: ts, sourceQuestionId: "q1", proposalHash: "UNCOMPUTED_ON_NON_CRYPTO_HOST")
        #endif
    }()

    /// PENDING (offline) receipt — MUST render "queued", never "sent"/"verified" (signature is nil).
    public static let pendingReceipt = ActionReceipt(id: "p1", proposalId: "p1", status: .pendingConnectivity,
        resultingSequence: nil, targetSessionId: sessionId, confirmedByHumanAt: ts,
        confirmedProposalHash: actionProposal.proposalHash, executedAt: nil, failureReason: nil,
        signature: nil, signingKeyId: nil)

    /// POSTED receipt — PLACEHOLDER signature; a real gateway ed25519 signature must VERIFY before "verified" shows.
    public static let postedReceipt = ActionReceipt(id: "p1", proposalId: "p1", status: .posted,
        resultingSequence: 230195, targetSessionId: sessionId, confirmedByHumanAt: ts,
        confirmedProposalHash: actionProposal.proposalHash, executedAt: ts, failureReason: nil,
        signature: "FIXTURE_PLACEHOLDER_SIG_verify_before_trust", signingKeyId: "pocket-gateway-fixture-key")
}
