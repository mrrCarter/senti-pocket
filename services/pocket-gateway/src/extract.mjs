// extract.mjs — Relay checkpoint extraction.
// Turns a durable Senti checkpoint + the raw session export into a RawCheckpoint (PocketContracts v0.1).
// Proven surface (room 954233b7, 41 real auto-checkpoints):
//   sl session checkpoint list <SID> --json  -> durable checkpoints {checkpointId,startSequence,endSequence,...}
//   sl session export <SID>                  -> {session, agents, participants, events[{sequenceId,event,agent,payload,idempotencyToken,ts}], ...}
// RawCheckpoint = export.events sliced to [startSequence,endSequence] + agents, with every payload secret-scrubbed.

import { execFileSync } from 'node:child_process';
import { scrubPayload } from './scrub.mjs';

export const CONTRACTS_VERSION = '0.1.0';

/** Default runner: shells the real `sl` CLI. Injectable for hermetic tests. */
export function defaultRun(args) {
  return execFileSync('sl', args, { encoding: 'utf8', maxBuffer: 128 * 1024 * 1024 });
}

/** Run an `sl ... --json` command and parse it. */
export function slJson(args, run = defaultRun) {
  const out = run(args);
  return JSON.parse(out);
}

/** Normalize any timestamp to ISO8601 with a trailing Z (matches the frozen fixture date encoding). */
export function normalizeTs(ts) {
  if (!ts) return null;
  const d = new Date(ts);
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

/** Inclusive slice of export events to [start, end] by canonical sequenceId. */
export function sliceEvents(events, start, end) {
  const lo = Number(start);
  const hi = Number(end);
  return (events || [])
    .filter((e) => {
      const s = Number(e.sequenceId);
      return Number.isFinite(s) && s >= lo && s <= hi;
    })
    .sort((a, b) => Number(a.sequenceId) - Number(b.sequenceId));
}

/** Map one export event to a frozen-contract RawEvent (+ redaction count for audit). */
export function toRawEvent(e) {
  const { text, redactions } = scrubPayload(e.payload);
  const rawEvent = {
    sequenceId: Number(e.sequenceId),
    event: e.event ?? 'unknown',
    agentId: (e.agent && e.agent.id) || e.agentId || 'unknown',
    payload: text,
    idempotencyToken: e.idempotencyToken ?? null,
    ts: normalizeTs(e.ts || e.timestamp),
  };
  return { rawEvent, redactions: redactions.length };
}

/** Distinct agent ids appearing in the sliced events, unioned with export-level agent ids. */
export function collectAgents(rawEvents, exportData) {
  const set = new Set();
  for (const e of rawEvents) if (e.agentId && e.agentId !== 'unknown') set.add(e.agentId);
  const declared = (exportData?.agents || exportData?.participants || [])
    .map((a) => (typeof a === 'string' ? a : a?.id || a?.agentId))
    .filter(Boolean);
  for (const a of declared) set.add(a);
  return [...set].sort();
}

/**
 * Build a RawCheckpoint from a durable checkpoint descriptor + a full session export.
 * Pure function (no I/O) so it is fully unit-testable.
 * @returns {{ rawCheckpoint: object, redactionTotal: number }}
 */
export function buildRawCheckpoint(checkpoint, exportData) {
  const start = Number(checkpoint.startSequence);
  const end = Number(checkpoint.endSequence);
  if (!Number.isFinite(start) || !Number.isFinite(end) || end < start) {
    throw new Error(`invalid checkpoint range [${checkpoint.startSequence}, ${checkpoint.endSequence}]`);
  }
  const sliced = sliceEvents(exportData?.events, start, end);
  let redactionTotal = 0;
  const events = sliced.map((e) => {
    const { rawEvent, redactions } = toRawEvent(e);
    redactionTotal += redactions;
    return rawEvent;
  });
  const session = exportData?.session || {};
  const rawCheckpoint = {
    checkpointId: checkpoint.checkpointId,
    sessionId: checkpoint.sessionId || session.id || session.sessionId || '',
    sessionTitle: session.title || session.name || checkpoint.title || '',
    startSequence: start,
    endSequence: end,
    capturedAt: new Date().toISOString(),
    agents: collectAgents(events, exportData),
    events,
  };
  return { rawCheckpoint, redactionTotal };
}

/** Validate a RawCheckpoint against the frozen v0.1 contract shape. Returns string[] of problems ([] = valid). */
export function validateRawCheckpoint(rc) {
  const problems = [];
  const need = ['checkpointId', 'sessionId', 'sessionTitle', 'startSequence', 'endSequence', 'capturedAt', 'agents', 'events'];
  for (const k of need) if (!(k in rc)) problems.push(`missing field: ${k}`);
  if (rc.endSequence < rc.startSequence) problems.push('endSequence < startSequence');
  if (!Array.isArray(rc.agents)) problems.push('agents not array');
  if (!Array.isArray(rc.events)) problems.push('events not array');
  for (const [i, e] of (rc.events || []).entries()) {
    for (const k of ['sequenceId', 'event', 'agentId', 'payload', 'ts']) {
      if (!(k in e)) problems.push(`event[${i}] missing ${k}`);
    }
    if (typeof e.payload !== 'string') problems.push(`event[${i}].payload not string`);
    if (e.sequenceId < rc.startSequence || e.sequenceId > rc.endSequence) {
      problems.push(`event[${i}].sequenceId ${e.sequenceId} outside [${rc.startSequence},${rc.endSequence}]`);
    }
  }
  return problems;
}

/**
 * High-level extraction: list checkpoints for a session, pick one (by id or the latest), export, and build.
 * @param {string} sessionId
 * @param {{ checkpointId?: string, agent?: string, run?: Function }} opts
 */
export function extractCheckpoint(sessionId, opts = {}) {
  const run = opts.run || defaultRun;
  // Note: `checkpoint list` and `export` are already remote-scoped and take no --agent.
  // Export FIRST: `sl export` returns a recent event window, so the chosen checkpoint's range must
  // fall inside that window or its events cannot be extracted.
  const exportData = slJson(['session', 'export', sessionId, '--remote'], run);
  const seqs = (exportData.events || []).map((e) => Number(e.sequenceId)).filter(Number.isFinite);
  if (seqs.length === 0) throw new Error(`export returned no events for session ${sessionId}`);
  const exMin = Math.min(...seqs);
  const exMax = Math.max(...seqs);

  const list = slJson(['session', 'checkpoint', 'list', sessionId, '--json', '--limit', '200'], run);
  const checkpoints = Array.isArray(list) ? list : list.checkpoints || list.items || [];

  let chosen;
  if (opts.checkpointId) {
    chosen = checkpoints.find((c) => c.checkpointId === opts.checkpointId);
    if (!chosen) throw new Error(`checkpoint ${opts.checkpointId} not found`);
  } else {
    // Latest durable checkpoint whose range overlaps the available export window.
    chosen = checkpoints
      .filter((c) => Number(c.endSequence) >= exMin && Number(c.startSequence) <= exMax)
      .sort((a, b) => Number(b.endSequence) - Number(a.endSequence))[0];
    // Fallback: synthesize a checkpoint over the exported window so Relay can always bundle what it can see.
    // (Bundling an arbitrary OLDER checkpoint needs a range-export the CLI does not expose yet — flagged.)
    if (!chosen) {
      chosen = {
        checkpointId: `cp_${sessionId.slice(0, 8)}_live_${exMax}`,
        sessionId,
        startSequence: exMin,
        endSequence: exMax,
        title: exportData.session?.title || exportData.session?.name || '',
        synthesized: true,
      };
    }
  }
  return { ...buildRawCheckpoint(chosen, exportData), checkpoint: chosen };
}
