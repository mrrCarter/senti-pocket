// extract.test.mjs — hermetic tests for Relay checkpoint extraction + scrubbing.
// Run: node --test   (zero external deps; uses node:test)
// Test secrets are built dynamically at runtime so no token-shaped literal lives in source
// (avoids security-scanner false positives on fixtures).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { scrubText, scrubPayload } from '../src/scrub.mjs';
import {
  sliceEvents, toRawEvent, buildRawCheckpoint, validateRawCheckpoint, extractCheckpoint, normalizeTs,
} from '../src/extract.mjs';

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
});
