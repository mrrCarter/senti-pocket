// extract.mjs — Relay checkpoint extraction.
// Turns a durable Senti checkpoint + the raw session export into a RawCheckpoint (PocketContracts v0.1).
//
// COMPLETENESS / PROVENANCE (Echo P0): a RawCheckpoint is built ONLY from a REAL durable checkpoint whose ENTIRE
//   declared range is CONTAINED in the export window — never mere overlap, never a synthesized/fabricated fallback.
//   A missing/partial/out-of-window range is an honest RETRYABLE error that yields NO bundle (never a signed partial).
// NUMERIC / BOUNDING (Echo P1): sequence ids are positive SAFE integers, strictly increasing + unique (no fractional,
//   no unsafe collapse, no duplicates); event count, range span, agent count, id/title/payload sizes are all bounded
//   BEFORE allocation/signing (defends against a hostile or oversized export; CLI maxBuffer is 128 MiB).
// PARTICIPANTS (Echo P1): derived ONLY from accepted in-range events — an export-only / out-of-range actor is never
//   labeled a participant.
//
// Payload redaction (scrub.mjs) is BEST-EFFORT known-format defense-in-depth — NOT a guarantee of secret-free content.
// Proven surface (room 954233b7, 41 real auto-checkpoints):
//   sl session checkpoint list <SID> --json  -> durable checkpoints {checkpointId,startSequence,endSequence,...}
//   sl session export <SID>                  -> {session, agents, participants, events[{sequenceId,event,agent,payload,idempotencyToken,ts}], ...}

import { execFileSync } from 'node:child_process';
import { scrubPayload } from './scrub.mjs';

export const CONTRACTS_VERSION = '0.1.0';

/** Hard bounds enforced BEFORE any allocation/signing. Over-redaction/rejection is always the safe direction. */
export const LIMITS = Object.freeze({
  MAX_EVENTS: 10000,          // events in a single checkpoint slice
  MAX_SPAN: 1_000_000,        // endSequence - startSequence
  MAX_AGENTS: 500,            // distinct participants
  MAX_ID_BYTES: 256,          // checkpointId / sessionId
  MAX_TITLE_BYTES: 4096,      // sessionTitle
  MAX_PAYLOAD_BYTES: 16384,   // per-event scrubbed payload (truncated beyond, with a marker)
});

const utf8 = (s) => Buffer.byteLength(String(s ?? ''), 'utf8');
const clampUtf8 = (s, max, marker = '…[truncated]') =>
  utf8(s) > max ? Buffer.from(String(s), 'utf8').subarray(0, max).toString('utf8') + marker : s;

/** A canonical sequence id: a POSITIVE SAFE integer. Rejects fractional/unsafe/negative/non-numeric (Echo P1). */
export function toSeq(v) {
  if (typeof v === 'number') return Number.isSafeInteger(v) && v > 0 ? v : null;
  if (typeof v === 'string' && /^[1-9][0-9]*$/.test(v)) { const n = Number(v); return Number.isSafeInteger(n) && n > 0 ? n : null; }
  return null;
}

/** Default runner: shells the real `sl` CLI. Injectable for hermetic tests. */
export function defaultRun(args) {
  return execFileSync('sl', args, { encoding: 'utf8', maxBuffer: 128 * 1024 * 1024 });
}

/** Run an `sl ... --json` command and parse it. */
export function slJson(args, run = defaultRun) {
  return JSON.parse(run(args));
}

/** Normalize any timestamp to ISO8601 with a trailing Z (matches the frozen fixture date encoding). */
export function normalizeTs(ts) {
  if (!ts) return null;
  const d = new Date(ts);
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

/**
 * Inclusive slice of export events to [start, end] by canonical sequenceId. Keeps ONLY events with a positive
 * safe-integer sequenceId in range; sorts ascending and DEDUPES to strictly-increasing ids (a duplicate/unsafe id
 * is dropped, never silently collapsed to a neighbour — Echo P1).
 */
export function sliceEvents(events, start, end) {
  const kept = [];
  const seen = new Set();
  for (const e of (events || [])) {
    const s = toSeq(e && e.sequenceId);
    if (s == null || s < start || s > end) continue;
    if (seen.has(s)) continue; // reject duplicate sequence ids outright
    seen.add(s);
    kept.push([s, e]);
  }
  kept.sort((a, b) => a[0] - b[0]);
  return kept.map(([, e]) => e);
}

/** Map one export event to a frozen-contract RawEvent (+ redaction count). Payload is best-effort scrubbed + byte-bounded. */
export function toRawEvent(e) {
  const { text, redactions } = scrubPayload(e.payload);
  const rawEvent = {
    sequenceId: toSeq(e.sequenceId),
    event: typeof e.event === 'string' ? e.event : 'unknown',
    agentId: (e.agent && e.agent.id) || e.agentId || 'unknown',
    payload: clampUtf8(text, LIMITS.MAX_PAYLOAD_BYTES),
    idempotencyToken: e.idempotencyToken ?? null,
    ts: normalizeTs(e.ts || e.timestamp),
  };
  return { rawEvent, redactions: redactions.length };
}

/**
 * Participants derived ONLY from accepted in-range events (Echo P1). An actor that appears solely at export level or
 * outside the checkpoint window is NEVER labeled a participant. 'unknown'/system placeholders are excluded.
 */
export function collectAgents(rawEvents) {
  const set = new Set();
  for (const e of (rawEvents || [])) if (e.agentId && e.agentId !== 'unknown') set.add(e.agentId);
  return [...set].sort();
}

/**
 * Build a RawCheckpoint from a REAL durable checkpoint descriptor + a full session export.
 * Enforces containment + numeric bounds + provenance. Throws a retryable error on partial/missing/oversized input.
 * Pure (no I/O) so it is fully unit-testable.
 * @returns {{ rawCheckpoint: object, redactionTotal: number }}
 */
export function buildRawCheckpoint(checkpoint, exportData, opts = {}) {
  if (checkpoint && checkpoint.synthesized) {
    throw new Error('refusing to build from a synthesized checkpoint (no durable provenance) — retryable');
  }
  const start = toSeq(checkpoint && checkpoint.startSequence);
  const end = toSeq(checkpoint && checkpoint.endSequence);
  if (start == null || end == null || end < start) {
    throw new Error(`invalid checkpoint range [${checkpoint?.startSequence}, ${checkpoint?.endSequence}] (need positive safe ints, end>=start)`);
  }
  if (end - start > LIMITS.MAX_SPAN) throw new Error(`checkpoint span ${end - start} exceeds MAX_SPAN ${LIMITS.MAX_SPAN}`);

  const allSeqs = (exportData?.events || []).map((e) => toSeq(e && e.sequenceId)).filter((s) => s != null);
  if (allSeqs.length === 0) throw new Error('export contains no events with valid sequence ids — retryable');
  const exMin = Math.min(...allSeqs);
  const exMax = Math.max(...allSeqs);
  // CONTAINMENT (Echo P0): the export window must FULLY bracket the durable range, else the slice is PARTIAL and
  // would validate as clean while silently dropping events. Refuse — do not sign a partial checkpoint.
  if (start < exMin || end > exMax) {
    throw new Error(`checkpoint range [${start},${end}] not fully contained in export window [${exMin},${exMax}] (partial/missing) — retryable`);
  }

  const sliced = sliceEvents(exportData?.events, start, end);
  if (sliced.length > LIMITS.MAX_EVENTS) throw new Error(`sliced event count ${sliced.length} exceeds MAX_EVENTS ${LIMITS.MAX_EVENTS}`);

  let redactionTotal = 0;
  const events = sliced.map((e) => { const { rawEvent, redactions } = toRawEvent(e); redactionTotal += redactions; return rawEvent; });

  const agents = collectAgents(events);
  if (agents.length > LIMITS.MAX_AGENTS) throw new Error(`agent count ${agents.length} exceeds MAX_AGENTS ${LIMITS.MAX_AGENTS}`);

  const session = exportData?.session || {};
  const checkpointId = String(checkpoint.checkpointId ?? '');
  if (!checkpointId) throw new Error('checkpoint has no checkpointId (no provenance) — retryable');
  const sessionId = String(checkpoint.sessionId || session.id || session.sessionId || '');
  if (utf8(checkpointId) > LIMITS.MAX_ID_BYTES || utf8(sessionId) > LIMITS.MAX_ID_BYTES) {
    throw new Error('checkpointId/sessionId exceeds MAX_ID_BYTES');
  }
  const sessionTitle = clampUtf8(String(session.title || session.name || checkpoint.title || ''), LIMITS.MAX_TITLE_BYTES, '…');

  const rawCheckpoint = {
    checkpointId,
    sessionId,
    sessionTitle,
    startSequence: start,
    endSequence: end,
    capturedAt: opts.capturedAt || new Date().toISOString(),
    agents,
    events,
    // boundary/provenance evidence (Echo P0): a DURABLE checkpoint whose full range sat inside the export window.
    provenance: { kind: 'durable', exportWindow: { min: exMin, max: exMax }, contained: true },
  };
  return { rawCheckpoint, redactionTotal };
}

/** Validate a RawCheckpoint against the frozen v0.1 contract shape + numeric bounds. Returns string[] ([] = valid). */
export function validateRawCheckpoint(rc) {
  const problems = [];
  if (!rc || typeof rc !== 'object') return ['rawCheckpoint missing'];
  const need = ['checkpointId', 'sessionId', 'sessionTitle', 'startSequence', 'endSequence', 'capturedAt', 'agents', 'events', 'provenance'];
  for (const k of need) if (!(k in rc)) problems.push(`missing field: ${k}`);
  if (toSeq(rc.startSequence) == null) problems.push('startSequence not a positive safe integer');
  if (toSeq(rc.endSequence) == null) problems.push('endSequence not a positive safe integer');
  if (Number(rc.endSequence) < Number(rc.startSequence)) problems.push('endSequence < startSequence');
  if (Number(rc.endSequence) - Number(rc.startSequence) > LIMITS.MAX_SPAN) problems.push('range span exceeds MAX_SPAN');
  if (rc.provenance && rc.provenance.kind === 'synthesized') problems.push('synthesized provenance is not acceptable for a signed bundle');
  if (!Array.isArray(rc.agents)) problems.push('agents not array');
  else if (rc.agents.length > LIMITS.MAX_AGENTS) problems.push('agents exceed MAX_AGENTS');
  if (!Array.isArray(rc.events)) problems.push('events not array');
  else if (rc.events.length > LIMITS.MAX_EVENTS) problems.push('events exceed MAX_EVENTS');
  let lastSeq = -Infinity;
  for (const [i, e] of (rc.events || []).entries()) {
    for (const k of ['sequenceId', 'event', 'agentId', 'payload', 'ts']) if (!(k in e)) problems.push(`event[${i}] missing ${k}`);
    if (typeof e.payload !== 'string') problems.push(`event[${i}].payload not string`);
    else if (utf8(e.payload) > LIMITS.MAX_PAYLOAD_BYTES + 32) problems.push(`event[${i}].payload exceeds MAX_PAYLOAD_BYTES`);
    const s = toSeq(e.sequenceId);
    if (s == null) { problems.push(`event[${i}].sequenceId not a positive safe integer`); continue; }
    if (s < Number(rc.startSequence) || s > Number(rc.endSequence)) problems.push(`event[${i}].sequenceId ${s} outside [${rc.startSequence},${rc.endSequence}]`);
    if (s <= lastSeq) problems.push(`event[${i}].sequenceId ${s} not strictly increasing (dup/out-of-order)`);
    lastSeq = s;
  }
  return problems;
}

/**
 * High-level extraction: export the session, list checkpoints, pick the latest durable checkpoint whose ENTIRE range
 * is contained in the export window, and build. NO synthesis/fallback — a missing/partial range throws (retryable).
 * @param {string} sessionId
 * @param {{ checkpointId?: string, run?: Function, capturedAt?: string }} opts
 */
export function extractCheckpoint(sessionId, opts = {}) {
  const run = opts.run || defaultRun;
  // Export FIRST: `sl export` returns a recent event window; a checkpoint is extractable only if its full range
  // falls inside that window (enforced as containment in buildRawCheckpoint).
  const exportData = slJson(['session', 'export', sessionId, '--remote'], run);
  const seqs = (exportData.events || []).map((e) => toSeq(e && e.sequenceId)).filter((s) => s != null);
  if (seqs.length === 0) throw new Error(`export returned no events with valid sequence ids for session ${sessionId} — retryable`);
  const exMin = Math.min(...seqs);
  const exMax = Math.max(...seqs);

  const list = slJson(['session', 'checkpoint', 'list', sessionId, '--json', '--limit', '200'], run);
  const checkpoints = Array.isArray(list) ? list : list.checkpoints || list.items || [];

  let chosen;
  if (opts.checkpointId) {
    chosen = checkpoints.find((c) => c.checkpointId === opts.checkpointId);
    if (!chosen) throw new Error(`checkpoint ${opts.checkpointId} not found`);
    // containment is enforced in buildRawCheckpoint — a named checkpoint outside the export window throws (retryable).
  } else {
    // Latest DURABLE checkpoint whose ENTIRE range is CONTAINED in the export window (Echo P0 — not mere overlap).
    chosen = checkpoints
      .filter((c) => { const s = toSeq(c.startSequence), e = toSeq(c.endSequence); return s != null && e != null && s >= exMin && e <= exMax; })
      .sort((a, b) => toSeq(b.endSequence) - toSeq(a.endSequence))[0];
    // NO synthesis/fallback: a missing/partial range is an honest retryable error that yields no bundle.
    if (!chosen) {
      throw new Error(`no durable checkpoint fully contained in export window [${exMin},${exMax}] for session ${sessionId} — retryable (wait for a durable checkpoint or a wider export)`);
    }
  }
  return { ...buildRawCheckpoint(chosen, exportData, opts), checkpoint: chosen };
}
