import type {
  RawCheckpoint,
  CheckpointSummary,
  GroundedClaim,
  EvidenceRef,
  SentiEvent,
} from "./contracts.interim.ts";

const SUMMARIZER_VERSION = "relay-baseline-stub-0";
const MAX_QUOTE = 240;

/**
 * STUB grounded summarizer.
 *
 * WHAT IT DOES (real, testable): turns each material message into a per-agent FACT claim with a
 * substring-verifiable EvidenceRef {sequenceId, cursor, quote}. "agent X said Y" is a genuine
 * fact, so these claims are grounded and every quote is verifiable against the raw event.
 *
 * WHAT IT DOES NOT YET DO (why grounding = "baseline_unverified"):
 *   - INFERENCE / RECOMMENDATION classification of message content (needs the model pass).
 *   - Cross-agent disagreement synthesis (positions[] left empty; must PRESERVE, never flatten).
 *   - De-duplication / abstraction of repeated statements into a bounded briefing.
 * The real summarizer (mobile-swarm / on-device Gemma summarize step, or a gateway model pass)
 * replaces this and MUST verify every quote before promoting grounding to "grounded".
 */
export function summarizeCheckpoint(raw: RawCheckpoint): CheckpointSummary {
  const claims: GroundedClaim[] = [];
  for (const e of raw.events) {
    const text = String(e.payload?.message ?? "").trim();
    if (!text) continue;
    const agentId = e.agent?.id ?? e.agent?.agentId ?? "unknown";
    const ref: EvidenceRef = {
      sequenceId: e.sequenceId,
      cursor: e.cursor,
      quote: clampQuote(text),
      agentId,
    };
    claims.push({
      kind: "FACT",
      text: `${agentId} @#${e.sequenceId}: ${clampQuote(text)}`,
      evidence: [ref],
      agentId,
    });
  }

  return {
    sessionId: raw.sessionId,
    startSequence: raw.startSequence,
    endSequence: raw.endSequence,
    grounding: "baseline_unverified",
    claims,
    disagreements: [], // TODO(real summarizer): detect + PRESERVE opposing agent positions
    risks: [], // TODO(real summarizer): promote from content, cite evidence
    blockers: [], // TODO(real summarizer): promote "blocked"/"cannot" statements, cite evidence
    nextSteps: [], // TODO(real summarizer)
    summarizerVersion: SUMMARIZER_VERSION,
  };
}

function clampQuote(text: string): string {
  const oneLine = text.replace(/\s+/g, " ").trim();
  return oneLine.length > MAX_QUOTE ? `${oneLine.slice(0, MAX_QUOTE)}…` : oneLine;
}

/** Grounding invariant: every FACT cites >=1 evidence ref whose quote is a verifiable substring
 *  of the raw event's message. Returns the list of violations (empty = grounded-safe). */
export function verifyGrounding(summary: CheckpointSummary, raw: RawCheckpoint): string[] {
  const bySeq = new Map<number, SentiEvent>();
  for (const e of raw.events) bySeq.set(e.sequenceId, e);
  const violations: string[] = [];
  const check = (label: string, list: GroundedClaim[]): void => {
    for (const c of list) {
      if (c.kind === "FACT" && c.evidence.length === 0) {
        violations.push(`${label}: FACT claim with no evidence: "${c.text.slice(0, 60)}"`);
      }
      for (const ref of c.evidence) {
        const src = bySeq.get(ref.sequenceId);
        if (!src) {
          violations.push(`${label}: evidence cites missing sequence #${ref.sequenceId}`);
          continue;
        }
        const msg = String(src.payload?.message ?? "").replace(/\s+/g, " ");
        const q = ref.quote.replace(/…$/, "");
        if (q && !msg.includes(q)) {
          violations.push(`${label}: quote not found in #${ref.sequenceId}: "${q.slice(0, 40)}"`);
        }
      }
    }
  };
  check("claims", summary.claims);
  check("risks", summary.risks);
  check("blockers", summary.blockers);
  check("nextSteps", summary.nextSteps);
  return violations;
}
