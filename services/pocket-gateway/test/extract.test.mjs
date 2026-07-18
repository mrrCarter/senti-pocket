// extract.test.mjs — hermetic tests for Relay checkpoint extraction + scrubbing.
// Run: node --test   (zero external deps; uses node:test)
// Test secrets are built dynamically at runtime so no token-shaped literal lives in source
// (avoids security-scanner false positives on fixtures).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { scrubText, scrubPayload, scrubDeep } from '../src/scrub.mjs';
import {
  sliceEvents, toRawEvent, buildRawCheckpoint, validateRawCheckpoint, extractCheckpoint, normalizeTs, toSeq, LIMITS, scanExport,
} from '../src/extract.mjs';
import { buildBundle } from '../src/bundle.mjs';

// --- dynamic fake secrets (never real; assembled so scanners see no literal token) ---
const fakeApiKey = 'sk-' + 'A1b2C3d4'.repeat(3);          // OpenAI-style
const fakeAtk = 'atk_' + 'z'.repeat(24);                  // AIdenID
const fakeJwt = ['eyJ' + 'ab'.repeat(6), 'cd'.repeat(8), 'ef'.repeat(8)].join('.');
const fakeBearer = 'Bearer ' + 'q'.repeat(32);

test('scrubText redacts provider tokens, JWTs, and bearer headers', () => {
  const { text, redactions } = scrubText(
    `key=${fakeApiKey} tok=${fakeAtk} jwt=${fakeJwt} auth=${fakeBearer}`,
  );
  assert.ok(!text.includes(fakeApiKey), 'api key not redacted');
  assert.ok(!text.includes(fakeAtk), 'aidenid token not redacted');
  assert.ok(!text.includes(fakeJwt), 'jwt not redacted');
  assert.ok(!text.includes('q'.repeat(32)), 'bearer not redacted');
  assert.ok(redactions.includes('api-key') && redactions.includes('jwt'));
});

test('scrubText leaves ordinary prose untouched', () => {
  const clean = 'Warden STRONG PASS on #275; billing gate still blocks CI.';
  const { text, redactions } = scrubText(clean);
  assert.equal(text, clean);
  assert.equal(redactions.length, 0);
});

test('scrubText redacts PEM private keys', () => {
  const pem = '-----BEGIN PRIVATE KEY-----\n' + 'MIIB'.repeat(4) + '\n-----END PRIVATE KEY-----';
  const { text, redactions } = scrubText(`here: ${pem}`);
  assert.ok(!text.includes('MIIB'));
  assert.ok(redactions.includes('private-key'));
});

test('scrubPayload handles object payloads', () => {
  const { text } = scrubPayload({ text: `deploy token ${fakeAtk}` });
  assert.ok(text.startsWith('deploy token '));
  assert.ok(!text.includes(fakeAtk));
});

test('sliceEvents is inclusive and sorted', () => {
  const events = [
    { sequenceId: 105 }, { sequenceId: 100 }, { sequenceId: 103 }, { sequenceId: 110 }, { sequenceId: 99 },
  ];
  const out = sliceEvents(events, 100, 105);
  assert.deepEqual(out.map((e) => e.sequenceId), [100, 103, 105]);
});

test('normalizeTs yields ISO8601 Z', () => {
  assert.equal(normalizeTs('2026-07-18T10:35:00+00:00'), '2026-07-18T10:35:00.000Z');
  assert.equal(normalizeTs('nonsense'), null);
});

test('toRawEvent maps + scrubs a live-shaped export event', () => {
  const { rawEvent, redactions } = toRawEvent({
    sequenceId: 230141,
    event: 'session_message',
    agent: { id: 'claude-pocket-relay' },
    payload: { text: `parser fixed; secret ${fakeApiKey}` },
    idempotencyToken: 'idem-abc',
    ts: '2026-07-18T10:35:00Z',
  });
  assert.equal(rawEvent.sequenceId, 230141);
  assert.equal(rawEvent.agentId, 'claude-pocket-relay');
  assert.ok(!rawEvent.payload.includes(fakeApiKey));
  assert.equal(rawEvent.idempotencyToken, 'idem-abc');
  assert.equal(rawEvent.ts, '2026-07-18T10:35:00.000Z');
  assert.equal(redactions, 1);
});

// canned, real-shaped export (mirrors `sl session export` output) for a hermetic pipeline test
const CANNED_EXPORT = {
  session: { id: '954233b7-1822-42bc-9cfe-1eb95eb0357a', title: 'AIdenID-Live-Demo' },
  agents: ['claude-pocket-relay', 'claude-warden'],
  events: [
    { sequenceId: 229999, event: 'session_message', agent: { id: 'x' }, payload: { text: 'before window' }, ts: '2026-07-18T10:00:00Z' },
    { sequenceId: 230141, event: 'session_message', agent: { id: 'claude-pocket-relay' }, payload: { text: 'parser fixed' }, idempotencyToken: 'i1', ts: '2026-07-18T10:35:00Z' },
    { sequenceId: 230160, event: 'session_message', agent: { id: 'claude-warden' }, payload: { text: `STRONG PASS ${fakeBearer}` }, idempotencyToken: 'i2', ts: '2026-07-18T10:36:34Z' },
    { sequenceId: 230200, event: 'session_message', agent: { id: 'y' }, payload: { text: 'after window' }, ts: '2026-07-18T10:50:00Z' },
  ],
};
const CANNED_CKPT = { checkpointId: 'cp_954233b7_000012', sessionId: '954233b7-1822-42bc-9cfe-1eb95eb0357a', startSequence: 230100, endSequence: 230180 };

test('buildRawCheckpoint slices to range, scrubs, and validates clean', () => {
  const { rawCheckpoint, redactionTotal } = buildRawCheckpoint(CANNED_CKPT, CANNED_EXPORT);
  assert.equal(rawCheckpoint.checkpointId, 'cp_954233b7_000012');
  assert.equal(rawCheckpoint.events.length, 2, 'only in-range events kept');
  assert.deepEqual(rawCheckpoint.events.map((e) => e.sequenceId), [230141, 230160]);
  assert.deepEqual(rawCheckpoint.agents, ['claude-pocket-relay', 'claude-warden']);
  assert.ok(!JSON.stringify(rawCheckpoint).includes('q'.repeat(32)), 'bearer scrubbed from bundle');
  assert.equal(redactionTotal, 1);
  assert.deepEqual(validateRawCheckpoint(rawCheckpoint), [], 'raw checkpoint is contract-valid');
});

test('buildRawCheckpoint rejects an inverted range', () => {
  assert.throws(() => buildRawCheckpoint({ ...CANNED_CKPT, startSequence: 200, endSequence: 100 }, CANNED_EXPORT));
});

test('extractCheckpoint runs the full pipeline with an injected sl runner', () => {
  const run = (args) => {
    if (args.includes('list')) return JSON.stringify([CANNED_CKPT]);
    if (args.includes('export')) return JSON.stringify(CANNED_EXPORT);
    throw new Error('unexpected sl call: ' + args.join(' '));
  };
  const { rawCheckpoint } = extractCheckpoint('954233b7-1822-42bc-9cfe-1eb95eb0357a', { run });
  assert.equal(rawCheckpoint.checkpointId, 'cp_954233b7_000012');
  assert.equal(rawCheckpoint.events.length, 2);
  assert.deepEqual(validateRawCheckpoint(rawCheckpoint), []);
  assert.equal(rawCheckpoint.provenance.kind, 'durable');
});

// ---------- Echo extract/scrub batch regressions (locked) ----------
test('(P0 completeness) checkpoint range not fully contained in export => throws, no partial slice', () => {
  // extends BELOW the export window
  assert.throws(() => buildRawCheckpoint({ ...CANNED_CKPT, startSequence: 229900, endSequence: 230160 }, CANNED_EXPORT), /not fully contained|partial/i);
  // extends ABOVE the export window
  assert.throws(() => buildRawCheckpoint({ ...CANNED_CKPT, startSequence: 230141, endSequence: 230300 }, CANNED_EXPORT), /not fully contained|partial/i);
});

test('(P0 provenance) overlap-but-not-contained checkpoint is NOT selected; no synthesis fallback', () => {
  const older = { checkpointId: 'cp_old', sessionId: CANNED_CKPT.sessionId, startSequence: 229990, endSequence: 230050 }; // start < exMin
  const runOverlap = (args) => (args.includes('list') ? JSON.stringify([older]) : JSON.stringify(CANNED_EXPORT));
  assert.throws(() => extractCheckpoint(CANNED_CKPT.sessionId, { run: runOverlap }), /no durable checkpoint|contained|retryable/i);
  const runEmpty = (args) => (args.includes('list') ? JSON.stringify([]) : JSON.stringify(CANNED_EXPORT));
  assert.throws(() => extractCheckpoint(CANNED_CKPT.sessionId, { run: runEmpty }), /no durable checkpoint|retryable/i);
});

test('(P0 provenance) buildRawCheckpoint refuses a synthesized checkpoint', () => {
  assert.throws(() => buildRawCheckpoint({ ...CANNED_CKPT, synthesized: true }, CANNED_EXPORT), /synthesized/i);
});

test('(P1 numeric) sliceEvents drops fractional/out-of-range but REJECTS duplicate in-range ids (integrity error)', () => {
  // fractional + out-of-range are filtered (expected); strictly increasing result
  const clean = [
    { sequenceId: 230141, event: 'm', agent: { id: 'a' }, payload: { text: 'ok' }, ts: '2026-07-18T10:35:00Z' },
    { sequenceId: 230150.5, event: 'm', agent: { id: 'a' }, payload: { text: 'frac' }, ts: '2026-07-18T10:35:02Z' },
    { sequenceId: 999999, event: 'm', agent: { id: 'a' }, payload: { text: 'oob' }, ts: '2026-07-18T10:35:03Z' },
    { sequenceId: 230160, event: 'm', agent: { id: 'b' }, payload: { text: 'ok2' }, ts: '2026-07-18T10:36:00Z' },
  ];
  assert.deepEqual(sliceEvents(clean, 230100, 230180).map((e) => e.sequenceId), [230141, 230160]);
  // a DUPLICATE in-range sequenceId is a data-integrity violation => throw (never silently collapse [1,2,2,3]->[1,2,3])
  const dup = [
    { sequenceId: 230141, event: 'm', agent: { id: 'a' }, payload: { text: 'ok' }, ts: '2026-07-18T10:35:00Z' },
    { sequenceId: 230141, event: 'm', agent: { id: 'a' }, payload: { text: 'dup' }, ts: '2026-07-18T10:35:01Z' },
  ];
  assert.throws(() => sliceEvents(dup, 230100, 230180), /duplicate in-range sequenceId|integrity/i);
});

test('(P1 numeric) toSeq rejects fractional/unsafe/zero/negative/leading-zero', () => {
  for (const bad of [1.5, 0, -1, 9007199254740992, '1.5', '01', 'x', NaN, Infinity, true, null]) assert.equal(toSeq(bad), null, String(bad));
  assert.equal(toSeq(230141), 230141);
  assert.equal(toSeq('230141'), 230141);
});

test('(P1 bounding) oversized payload is byte-bounded with a marker', () => {
  // prose-like (spaces break the high-entropy opaque-token rule) so we exercise the SIZE bound, not redaction.
  const { rawEvent } = toRawEvent({ sequenceId: 100, event: 'm', agent: { id: 'a' }, payload: { text: 'word '.repeat(5000) }, ts: '2026-07-18T10:00:00Z' });
  assert.ok(Buffer.byteLength(rawEvent.payload, 'utf8') <= LIMITS.MAX_PAYLOAD_BYTES + 32);
  assert.ok(rawEvent.payload.endsWith('[truncated]'));
});

test('(P1 participants) export-only / out-of-range actor is never labeled a participant', () => {
  const exportData = {
    session: { id: 's', title: 't' },
    agents: ['inside', 'outside-only'],
    participants: ['outside-only'],
    events: [
      { sequenceId: 90, event: 'm', agent: { id: 'outside-only' }, payload: { text: 'before' }, ts: '2026-07-18T09:00:00Z' },
      { sequenceId: 100, event: 'm', agent: { id: 'inside' }, payload: { text: 'hi' }, ts: '2026-07-18T10:00:00Z' },
      { sequenceId: 110, event: 'm', agent: { id: 'outside-only' }, payload: { text: 'after' }, ts: '2026-07-18T11:00:00Z' },
    ],
  };
  const { rawCheckpoint } = buildRawCheckpoint({ checkpointId: 'cp_p', sessionId: 's', startSequence: 95, endSequence: 105 }, exportData);
  assert.deepEqual(rawCheckpoint.agents, ['inside']);
});

test('(P0 secret-egress) HONEST: unknown-format secret survives scrub; known formats redacted incl. nested', () => {
  const { text } = scrubText('the client credential is correct horse battery staple');
  assert.ok(text.includes('correct horse battery staple'), 'best-effort scrub does not claim to catch arbitrary secrets');
  const { value, redactions } = scrubDeep({ note: `key ${fakeApiKey}`, nested: { deep: `atk ${fakeAtk}` } });
  assert.ok(!JSON.stringify(value).includes(fakeApiKey));
  assert.ok(!JSON.stringify(value).includes(fakeAtk));
  assert.ok(redactions.includes('api-key') && redactions.includes('aidenid-token'));
});

test('(P0 secret-egress) buildBundle final-egress-scrubs summary + evidence; raw events never cross', () => {
  const rc = { checkpointId: 'cp_e', sessionId: 's', startSequence: 100, endSequence: 105 };
  const summary = {
    headline: `overall: token ${fakeApiKey}`,
    perAgent: [{ agentId: 'a', evidence: [{ id: 'e1', sequence: 100, snippet: `quote with ${fakeBearer}` }] }],
  };
  const bundle = buildBundle(rc, summary);
  const s = JSON.stringify(bundle);
  assert.ok(!s.includes(fakeApiKey), 'summary secret scrubbed at egress');
  assert.ok(!s.includes('q'.repeat(32)), 'evidence snippet secret scrubbed at egress');
  assert.equal(bundle.events, undefined, 'no raw room events in the phone bundle');
});

// ---------- Echo 94baad1 re-review refinements (locked) ----------
test('(P0 completeness) descriptor eventCount must EXACTLY match accepted events', () => {
  const ok = { ...CANNED_CKPT, summarySections: { window: { eventCount: 2 } } };
  assert.equal(buildRawCheckpoint(ok, CANNED_EXPORT).rawCheckpoint.events.length, 2);
  const bad = { ...CANNED_CKPT, summarySections: { window: { eventCount: 3 } } };
  assert.throws(() => buildRawCheckpoint(bad, CANNED_EXPORT), /incomplete|declares 3|partial/i);
});

test('(P0 completeness) contained range MISSING an interior event is rejected via eventCount (Echo proof 1..3 w/ [1,3])', () => {
  const exp = { session: { id: 's' }, events: [
    { sequenceId: 1, event: 'm', agent: { id: 'a' }, payload: { text: 'one' }, ts: '2026-07-18T10:00:00Z' },
    { sequenceId: 3, event: 'm', agent: { id: 'b' }, payload: { text: 'three' }, ts: '2026-07-18T10:02:00Z' },
  ] };
  const cp = { checkpointId: 'cp_x', sessionId: 's', startSequence: 1, endSequence: 3, summarySections: { window: { eventCount: 3 } } };
  assert.throws(() => buildRawCheckpoint(cp, exp), /incomplete|declares 3/i);
});

test('(P0 provenance) checkpoint sessionId must match the export session', () => {
  assert.throws(() => buildRawCheckpoint({ ...CANNED_CKPT, sessionId: 'different-session' }, CANNED_EXPORT), /does not match export session/i);
});

test('(P1 bounds) scanExport computes extrema iteratively + counts valid ids; rejects non-array', () => {
  assert.deepEqual(scanExport([{ sequenceId: 5 }, { sequenceId: 2 }, { sequenceId: 'x' }, { sequenceId: 9 }]), { min: 2, max: 9, count: 3 });
  assert.deepEqual(scanExport([]), { min: null, max: null, count: 0 });
  assert.throws(() => scanExport('nope'), /not an array/);
});

test('(P0 minimal egress) buildBundle projects the frozen summary schema: unknown keys dropped, nested bounded', () => {
  const rc = { checkpointId: 'cp', sessionId: 's', startSequence: 1, endSequence: 3 };
  const summary = {
    checkpointId: 'cp', headline: 'ok', summaryBaselineSchema: 'v1', risks: [], blockers: [],
    perAgent: [{ agentId: 'a', summary: 'did x', evidence: [{ id: 'e1', sessionId: 's', sequence: 2, agentId: 'a', snippet: 'word '.repeat(1000), ts: '2026-07-18T10:00:00Z', nested: { raw: 'z'.repeat(5000) } }] }],
    rawEvents: [{ payload: 'w'.repeat(14500) }], // UNKNOWN key -> must be dropped, never signed
    secretExtra: 'leak-me',
  };
  const b = buildBundle(rc, summary);
  const s = JSON.stringify(b);
  assert.equal(b.summary.rawEvents, undefined, 'unknown summary key dropped');
  assert.equal(b.summary.secretExtra, undefined, 'unknown summary key dropped');
  assert.ok(!s.includes('w'.repeat(100)), 'unknown-key content never crosses');
  assert.equal(b.evidence[0].nested, undefined, 'unknown EvidenceRef key dropped');
  assert.ok(Buffer.byteLength(b.evidence[0].snippet, 'utf8') <= 2048 + 4, 'snippet byte-bounded');
});

test('(P0 bounds) buildBundle throws when the projected body exceeds MAX_BUNDLE_BYTES', () => {
  const rc = { checkpointId: 'cp', sessionId: 's', startSequence: 1, endSequence: 3 };
  const perAgent = Array.from({ length: 200 }, (_, i) => ({ agentId: 'a' + i, summary: 'word '.repeat(1700), evidence: [] }));
  assert.throws(() => buildBundle(rc, { checkpointId: 'cp', headline: 'h', summaryBaselineSchema: 'v1', perAgent, risks: [], blockers: [] }), /MAX_BUNDLE_BYTES/);
});

test('(P0 bounds) cyclic/deep summary is safely projected (no recursion into unknown keys)', () => {
  const rc = { checkpointId: 'cp', sessionId: 's', startSequence: 1, endSequence: 3 };
  const summary = { checkpointId: 'cp', headline: 'h', summaryBaselineSchema: 'v1', perAgent: [], risks: [], blockers: [] };
  summary.self = summary;
  summary.perAgent.push({ agentId: 'a', summary: 'ok', evidence: [], extra: summary });
  const b = buildBundle(rc, summary);
  assert.equal(b.summary.self, undefined);
  assert.equal(b.summary.perAgent[0].extra, undefined);
});
