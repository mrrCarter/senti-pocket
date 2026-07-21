// summarize.mjs — RawCheckpoint -> CheckpointSummary (frozen PocketContracts v0.1). Relay lane.
//
// DETERMINISTIC + GROUNDED baseline (no LLM): every AgentSummary cites REAL EvidenceRefs anchored to actual event
// sequences in the checkpoint, and prose is a factual roll-up (counts + exact sequence span) — never invented. An
// LLM-enriched `summary` string is a drop-in fast-follow that reuses the SAME grounded evidence set. senti's own
// checkpoint summarySections (headline/grade/risks/blockers) are passed through as provenance when present.
// Output is bounded; buildBundle() re-applies the final egress scrub + strict schema projection before signing.

export const SUMMARY_BASELINE_SCHEMA = 'relay_deterministic_v1';

const LIMITS = Object.freeze({
  EVIDENCE_PER_AGENT: 5,   // bounded citations per agent
  SNIPPET_BYTES: 280,      // per-evidence excerpt
  HEADLINE_BYTES: 4096,
  SUMMARY_BYTES: 1024,     // per-agent roll-up string
  RISKS: 50, BLOCKERS: 50,
});

const utf8 = (s) => Buffer.byteLength(String(s ?? ''), 'utf8');
// scalar-safe truncation: iterate by CODE POINT so a byte-offset cut never splits a multibyte char into a U+FFFD
// replacement (which would surface a garbage char in a phone-visible snippet). Mirrors bundle.mjs boundStr.
const clamp = (s, max) => {
  const str = String(s ?? '');
  if (utf8(str) <= max) return str;
  let out = '', used = 0;
  for (const ch of str) { const cb = Buffer.byteLength(ch, 'utf8'); if (used + cb > max) break; out += ch; used += cb; }
  return out + '…';
};
const oneLine = (s) => String(s ?? '').replace(/\s+/g, ' ').trim();

/** Build one grounded EvidenceRef from a RawEvent (payload already scrubbed at extraction; bounded here again). */
function evidenceFrom(rc, e) {
  return {
    id: `ev_${rc.checkpointId}_${e.sequenceId}`,
    sessionId: rc.sessionId,
    sequence: e.sequenceId,
    agentId: e.agentId,
    snippet: clamp(oneLine(e.payload), LIMITS.SNIPPET_BYTES),
    ts: e.ts || '',
  };
}

/**
 * Produce a frozen CheckpointSummary from a validated RawCheckpoint. Pure (no I/O). Optionally pass the durable
 * checkpoint descriptor for senti summarySections passthrough (headline/grade/risks/blockers).
 * @param {object} rawCheckpoint  from extract.buildRawCheckpoint
 * @param {object} [descriptor]   the `sl session checkpoint list` descriptor (summarySections/grade), optional
 */
export function summarize(rawCheckpoint, descriptor = {}) {
  const rc = rawCheckpoint || {};
  const events = Array.isArray(rc.events) ? rc.events : [];
  const sections = descriptor.summarySections || {};

  // group events by author, preserving sequence order (events already strictly increasing from extraction).
  const byAgent = new Map();
  for (const e of events) {
    if (!e || e.agentId == null) continue;
    if (!byAgent.has(e.agentId)) byAgent.set(e.agentId, []);
    byAgent.get(e.agentId).push(e);
  }

  const perAgent = [...byAgent.keys()].sort().map((agentId) => {
    const evs = byAgent.get(agentId);
    const first = evs[0], last = evs[evs.length - 1];
    const span = first.sequenceId === last.sequenceId ? `seq ${first.sequenceId}` : `seq ${first.sequenceId}..${last.sequenceId}`;
    // bounded citations: first, last, and evenly-spread interior events (deterministic).
    const picks = pickSpread(evs, LIMITS.EVIDENCE_PER_AGENT);
    // DROP empty-snippet evidence: an event with an empty/whitespace/absent payload yields snippet:'' , but signBundle's
    // ingress gate REQUIRES snippet 1..8000 — so a single blank-payload event (a contentless control/system event or an
    // empty post) in the range would make the WHOLE bundle permanently unsignable -> /checkpoint,/answer,/brief 503
    // "retryable" forever on stable data. Filtering here matches the existing quotes/claims empty-filter intent; all
    // claim-cited evidence is non-empty anyway so citations still resolve.
    const evidence = picks.map((e) => evidenceFrom(rc, e)).filter((e) => e.snippet);
    // GROUNDED CONTENT prose: quote the agent's ACTUAL messages (bounded) so the briefing conveys WHAT was said, not
    // just how many. Every quote is a real cited event — nothing is paraphrased or invented. (The LLM-enriched
    // summarizer later refines phrasing + adds inference/recommendation claims, reusing these same evidence ids.)
    const quotes = evidence.map((e) => e.snippet).filter(Boolean);
    const summary = clamp(
      quotes.length
        ? `${agentId} (${evs.length} msg${evs.length === 1 ? '' : 's'}, ${span}): ${quotes.join('  |  ')}`
        : `${agentId}: ${evs.length} message${evs.length === 1 ? '' : 's'} (${span}).`,
      LIMITS.SUMMARY_BYTES,
    );
    // one GROUNDED fact claim per cited message — each claim IS the real message content, cited 1:1 to its source event
    // (empty-snippet events yield no claim). Directly supported by the cited evidence; kind=fact.
    const claims = evidence
      .filter((e) => e.snippet)
      .map((e) => ({ id: `claim_${rc.checkpointId}_${e.sequence}`, text: clamp(e.snippet, LIMITS.SUMMARY_BYTES), kind: 'fact', evidenceIds: [e.id] }));
    return { agentId, summary, claims, evidence };
  });

  const headline = clamp(
    oneLine(sections.headline || rc.sessionTitle || '') ||
      `${rc.checkpointId}: ${events.length} events from ${byAgent.size} agent${byAgent.size === 1 ? '' : 's'}`,
    LIMITS.HEADLINE_BYTES,
  );

  const grade = descriptor.grade != null ? String(descriptor.grade)
    : (descriptor.gradeScore != null ? String(descriptor.gradeScore) : null);

  return {
    checkpointId: rc.checkpointId,
    headline,
    summaryBaselineSchema: sections.headline ? 'checkpoint_summary_sections_v1' : SUMMARY_BASELINE_SCHEMA,
    grade,
    perAgent,
    risks: strList(sections.risks, LIMITS.RISKS),
    blockers: strList(sections.blockers, LIMITS.BLOCKERS),
  };
}

/** Deterministically pick up to n items: first, last, and evenly-spread interior (stable, no randomness). */
function pickSpread(arr, n) {
  if (arr.length <= n) return arr.slice();
  if (n <= 1) return [arr[0]];
  const out = [];
  for (let i = 0; i < n; i++) out.push(arr[Math.round((i * (arr.length - 1)) / (n - 1))]);
  // dedupe (rounding can repeat an index) while preserving order
  const seen = new Set();
  return out.filter((e) => (seen.has(e.sequenceId) ? false : (seen.add(e.sequenceId), true)));
}

function strList(v, max) {
  if (!Array.isArray(v)) return [];
  return v.filter((x) => typeof x === 'string' && x.length > 0).slice(0, max).map((x) => clamp(oneLine(x), 512));
}
