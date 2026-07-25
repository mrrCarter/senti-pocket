// dial-signal-store.test.mjs — the dispatch-time store a LEAN (fetch=true) ring's GET /dial?id= hydration reads back.
// Proves: full-signal round-trip within TTL, LOGICAL expiry (DynamoDB deletion lags), fail-closed (bad/oversized signal
// + blank dialId), DynamoDB ttl passthrough for cleanup, idempotent re-dispatch, and store-shape validation.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createDialSignalStore, DIAL_SIGNAL_TTL_SECONDS } from '../src/dial-signal-store.mjs';
import { createInMemoryStore } from '../src/store.mjs';

const NOW = 1_770_000_000_000; // fixed clock (ms)
const SIGNAL = { id: 'need_1', kind: { decisionYours: {} }, question: 'Ship it?', context: { sessionId: '6cf7e861', checkpointId: 'cp_9', whatWeNeed: 'go' }, confidence: 0.9, evidenceSeqs: [315038, 315050], requestedBy: 'claude-warden' };

test('put + get round-trips the full signal within TTL', async () => {
  const s = createDialSignalStore({ store: createInMemoryStore(), now: () => NOW });
  const r = await s.put('need_1', SIGNAL);
  assert.equal(r.stored, true);
  assert.equal(r.expiresAtSec, Math.floor(NOW / 1000) + DIAL_SIGNAL_TTL_SECONDS);
  assert.deepEqual(await s.get('need_1'), SIGNAL);
});

test('LOGICAL expiry: get returns undefined once now passes expiresAtSec (DynamoDB deletion lags)', async () => {
  let t = NOW;
  const s = createDialSignalStore({ store: createInMemoryStore(), now: () => t, ttlSeconds: 900 });
  await s.put('need_1', SIGNAL);
  t = NOW + 900 * 1000; // exactly at expiry (now === expiresAtSec) -> still valid
  assert.deepEqual(await s.get('need_1'), SIGNAL, 'valid at exactly expiresAtSec');
  t = NOW + 901 * 1000; // 1s past -> expired
  assert.equal(await s.get('need_1'), undefined, 'expired 1s past TTL -> undefined (endpoint 410)');
});

test('absent dialId -> get undefined; empty/blank dialId -> put throws, get undefined', async () => {
  const s = createDialSignalStore({ store: createInMemoryStore(), now: () => NOW });
  assert.equal(await s.get('never-stored'), undefined);
  await assert.rejects(s.put('', SIGNAL), /dialId required/);
  await assert.rejects(s.put('   ', SIGNAL), /dialId required/);
  assert.equal(await s.get(''), undefined);
});

test('fail-closed: non-object signal + oversized signal throw', async () => {
  const s = createDialSignalStore({ store: createInMemoryStore(), now: () => NOW });
  await assert.rejects(s.put('need_1', null), /signal object required/);
  await assert.rejects(s.put('need_1', 'a-string'), /signal object required/);
  await assert.rejects(s.put('need_1', { blob: 'x'.repeat(9000) }), /exceeds/);
});

test('distinct dialIds are isolated (length-prefixed key)', async () => {
  const s = createDialSignalStore({ store: createInMemoryStore(), now: () => NOW });
  await s.put('a', { ...SIGNAL, id: 'A' });
  await s.put('a:sig:1:a', { ...SIGNAL, id: 'B' });
  assert.equal((await s.get('a')).id, 'A');
  assert.equal((await s.get('a:sig:1:a')).id, 'B');
});

test('DynamoDB cleanup: putIfAbsent receives the top-level ttlEpochSec', async () => {
  const calls = [];
  const store = { async get() { return undefined; }, async put() {}, async putIfAbsent(k, v, opts) { calls.push({ k, v, opts }); return true; } };
  const s = createDialSignalStore({ store, now: () => NOW });
  await s.put('need_1', SIGNAL);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].opts.ttlEpochSec, Math.floor(NOW / 1000) + DIAL_SIGNAL_TTL_SECONDS, 'DynamoDB ttl set for eventual cleanup');
});

test('idempotency: a re-dispatch of the same dialId keeps the FIRST-stored signal (stored:false)', async () => {
  const s = createDialSignalStore({ store: createInMemoryStore(), now: () => NOW });
  await s.put('need_1', { ...SIGNAL, question: 'first' });
  const r2 = await s.put('need_1', { ...SIGNAL, question: 'second' });
  assert.equal(r2.stored, false, 're-dispatch did not overwrite');
  assert.equal((await s.get('need_1')).question, 'first', 'first-stored signal retained for hydration');
});

test('put falls back to store.put when putIfAbsent is absent (still logical-expiry correct)', async () => {
  const m = new Map();
  const store = { async get(k) { return m.get(k); }, async put(k, v) { m.set(k, v); return v; } }; // no putIfAbsent
  const s = createDialSignalStore({ store, now: () => NOW });
  assert.equal((await s.put('need_1', SIGNAL)).stored, true);
  assert.deepEqual(await s.get('need_1'), SIGNAL);
});

test('ttlSeconds: default 900; positive override honored; invalid -> default', () => {
  assert.equal(createDialSignalStore({ store: createInMemoryStore() }).ttlSeconds, 900);
  assert.equal(createDialSignalStore({ store: createInMemoryStore(), ttlSeconds: 300 }).ttlSeconds, 300);
  assert.equal(createDialSignalStore({ store: createInMemoryStore(), ttlSeconds: -5 }).ttlSeconds, 900);
});

test('requires a { get, put } store', () => {
  assert.throws(() => createDialSignalStore({}), /requires a \{ get, put \} store/);
  assert.throws(() => createDialSignalStore({ store: { get() {} } }), /requires a \{ get, put \} store/);
});
