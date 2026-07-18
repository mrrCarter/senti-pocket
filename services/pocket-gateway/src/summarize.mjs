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
const clamp = (s, max) => (utf8(s) > max ? Buffer.from(String(s), 'utf8').subarray(0, max).toString('utf8') + '…' : String(s ?? ''));
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
    // grounded, factual prose: counts + exact span. No claim is made that isn't backed by the cited evidence.
    const summary = clamp(`${agentId}: ${evs.length} message${evs.length === 1 ? '' : 's'} (${span}).`, LIMITS.SUMMARY_BYTES);
    // bounded citations: first, last, and evenly-spread interior events (deterministic).
    const picks = pickSpread(evs, LIMITS.EVIDENCE_PER_AGENT);
    return { agentId, summary, evidence: picks.map((e) => evidenceFrom(rc, e)) };
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
