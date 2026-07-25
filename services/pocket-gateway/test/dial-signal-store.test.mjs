// dial-signal-store.test.mjs — the dispatch-time store a LEAN (fetch=true) ring's GET /dial?id= hydration reads back.
// Covers the R1-R4 witnesses from Pulse's #78 review: overwrite-replace (no deadlock) + exact expiry boundary,
// id-bind + idempotent-vs-collision, deep-clone snapshot + array/non-serializable reject + reference isolation,
// and fail-closed clock/ttl.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createDialSignalStore, DIAL_SIGNAL_TTL_SECONDS } from '../src/dial-signal-store.mjs';
import { createInMemoryStore } from '../src/store.mjs';

const NOW = 1_770_000_000_000; // fixed clock (ms); nowSec = 1_770_000_000
const NS = Math.floor(NOW / 1000);
const mkSignal = (over = {}) => ({ id: 'need_1', kind: { decisionYours: {} }, question: 'Ship it?', context: { sessionId: '6cf7e861', checkpointId: 'cp_9', whatWeNeed: 'go' }, confidence: 0.9, evidenceSeqs: [315038, 315050], requestedBy: 'claude-warden', ...over });

test('put + get round-trips the full signal within TTL', async () => {
  const s = createDialSignalStore({ store: createInMemoryStore(), now: () => NOW });
  const r = await s.put('need_1', mkSignal());
  assert.equal(r.stored, true);
  assert.equal(r.expiresAtSec, NS + DIAL_SIGNAL_TTL_SECONDS);
  assert.deepEqual(await s.get('need_1'), mkSignal());
});

test('R1a: expiry boundary — valid at +899s, EXPIRED at exactly +900s (nowSec >= expiresAtSec)', async () => {
  let t = NOW;
  const s = createDialSignalStore({ store: createInMemoryStore(), now: () => t, ttlSeconds: 900 });
  await s.put('need_1', mkSignal());
  t = NOW + 899 * 1000;
  assert.deepEqual(await s.get('need_1'), mkSignal(), 'valid 1s before TTL');
  t = NOW + 900 * 1000; // exactly at expiry -> expired (>=)
  assert.equal(await s.get('need_1'), undefined, 'expired AT the boundary');
});

test('R1b: a logically-expired record is OVERWRITTEN by a re-dispatch (no putIfAbsent deadlock)', async () => {
  let t = NOW;
  const s = createDialSignalStore({ store: createInMemoryStore(), now: () => t, ttlSeconds: 900 });
  await s.put('need_1', mkSignal({ question: 'first' }));
  t = NOW + 901 * 1000; // past TTL: logically expired but the item physically lingers (DynamoDB deletion lags)
  assert.equal(await s.get('need_1'), undefined, 'expired');
  const r = await s.put('need_1', mkSignal({ question: 'second' })); // must REPLACE, not deadlock
  assert.equal(r.stored, true, 're-dispatch overwrote the expired record');
  assert.equal((await s.get('need_1')).question, 'second', 'new ring hydrates the fresh signal');
});

test('R2: signal.id MUST equal dialId (no id substitution)', async () => {
  const s = createDialSignalStore({ store: createInMemoryStore(), now: () => NOW });
  await assert.rejects(s.put('dial-A', mkSignal({ id: 'dial-B' })), /signal.id must equal dialId/);
});

test('R2: live byte-identical retry is idempotent (actual retained expiry); different content within TTL fails closed', async () => {
  let t = NOW;
  const s = createDialSignalStore({ store: createInMemoryStore(), now: () => t, ttlSeconds: 900 });
  const first = await s.put('need_1', mkSignal({ question: 'same' }));
  t = NOW + 10 * 1000; // still live, later clock
  const retry = await s.put('need_1', mkSignal({ question: 'same' }));
  assert.deepEqual(retry, { stored: false, expiresAtSec: first.expiresAtSec }, 'idempotent -> ACTUAL retained expiry (not a new calc)');
  await assert.rejects(s.put('need_1', mkSignal({ question: 'DIFFERENT' })), /different content within TTL/, 'same id + different content -> fail closed');
  assert.equal((await s.get('need_1')).question, 'same', 'the live signal was not overwritten by the rejected collision');
});

test('R3: snapshot is isolated — mutating the input after put, or a get result, never changes the stored signal', async () => {
  const s = createDialSignalStore({ store: createInMemoryStore(), now: () => NOW });
  const input = mkSignal({ question: 'orig' });
  await s.put('need_1', input);
  input.question = 'mutated-input'; input.context.whatWeNeed = 'mutated';
  assert.equal((await s.get('need_1')).question, 'orig', 'post-put input mutation did not leak into the store');
  const got = await s.get('need_1');
  got.question = 'mutated-get'; got.context.whatWeNeed = 'mutated';
  assert.equal((await s.get('need_1')).question, 'orig', 'mutating a get result did not poison the store (deep clone on read)');
});

test('R3: a getter is evaluated ONCE at snapshot (no measure/write divergence)', async () => {
  let calls = 0;
  const withGetter = { id: 'need_1', kind: { go: {} }, requestedBy: 'x', get question() { calls += 1; return 'q' + calls; } };
  const s = createDialSignalStore({ store: createInMemoryStore(), now: () => NOW });
  await s.put('need_1', withGetter);
  const frozen = (await s.get('need_1')).question;
  assert.equal((await s.get('need_1')).question, frozen, 'stored value is frozen (getter not re-evaluated per read)');
});

test('R3: fail-closed — array, non-object, oversized, and non-serializable signals reject', async () => {
  const s = createDialSignalStore({ store: createInMemoryStore(), now: () => NOW });
  await assert.rejects(s.put('need_1', ['a', 'b']), /plain object/, 'array rejected');
  await assert.rejects(s.put('need_1', 'a-string'), /plain object/);
  await assert.rejects(s.put('need_1', null), /plain object/);
  await assert.rejects(s.put('need_1', mkSignal({ blob: 'x'.repeat(9000) })), /exceeds/);
  const circular = mkSignal(); circular.self = circular;
  await assert.rejects(s.put('need_1', circular), /not JSON-serializable/);
});

test('R3: a corrupt / id-mismatched stored record reads back as unavailable (never arbitrary content)', async () => {
  const store = createInMemoryStore();
  await store.put('dial:sig:6:need_1', { signal: { id: 'someone-else' }, expiresAtSec: NS + 900 }); // planted mismatch
  const s = createDialSignalStore({ store, now: () => NOW });
  assert.equal(await s.get('need_1'), undefined, 'stored signal.id != dialId -> unavailable');
});

test('R4: fail-closed clock/config — non-finite clock + invalid ttl reject (no silent fallback)', async () => {
  // put with a NaN clock -> reject
  await assert.rejects(createDialSignalStore({ store: createInMemoryStore(), now: () => NaN }).put('need_1', mkSignal()), /non-finite/);
  // get with a NaN clock over a PRESENT record -> reject (absent keys short-circuit before the clock, so plant one first)
  const store = createInMemoryStore();
  await createDialSignalStore({ store, now: () => NOW }).put('need_1', mkSignal());
  await assert.rejects(createDialSignalStore({ store, now: () => NaN }).get('need_1'), /non-finite/);
  // invalid config at construction (no silent fallback)
  assert.throws(() => createDialSignalStore({ store: createInMemoryStore(), ttlSeconds: -5 }), /positive integer/, 'negative ttl rejected');
  assert.throws(() => createDialSignalStore({ store: createInMemoryStore(), ttlSeconds: 1.5 }), /positive integer/);
  assert.throws(() => createDialSignalStore({ store: createInMemoryStore(), now: 'not-a-fn' }), /now must be a function/);
});

test('absent/blank dialId — get undefined; put throws; distinct dialIds isolated', async () => {
  const s = createDialSignalStore({ store: createInMemoryStore(), now: () => NOW });
  assert.equal(await s.get('never'), undefined);
  await assert.rejects(s.put('   ', mkSignal()), /dialId required/);
  await s.put('a', mkSignal({ id: 'a', question: 'A' }));
  await s.put('a:sig:1:a', mkSignal({ id: 'a:sig:1:a', question: 'B' }));
  assert.equal((await s.get('a')).question, 'A');
  assert.equal((await s.get('a:sig:1:a')).question, 'B');
});

test('ttlSeconds default 900; construction requires a lock-capable { get, put, acquireLock, releaseLock } store', () => {
  assert.equal(createDialSignalStore({ store: createInMemoryStore() }).ttlSeconds, 900);
  assert.equal(createDialSignalStore({ store: createInMemoryStore(), ttlSeconds: 300 }).ttlSeconds, 300);
  assert.throws(() => createDialSignalStore({}), /requires a/);
  assert.throws(() => createDialSignalStore({ store: { get() {}, put() {} } }), /acquireLock, releaseLock/, 'a store without lock methods is rejected (writes are lock-serialized)');
});

test('R2 concurrency (TOCTOU): two concurrent DIFFERENT-content puts for one id -> exactly one rings, never double-ring', async () => {
  const s = createDialSignalStore({ store: createInMemoryStore(), now: () => NOW });
  const results = await Promise.allSettled([
    s.put('need_1', mkSignal({ question: 'A' })),
    s.put('need_1', mkSignal({ question: 'B' })),
  ]);
  const rang = results.filter((r) => r.status === 'fulfilled' && r.value.stored === true);
  const failed = results.filter((r) => r.status === 'rejected');
  assert.equal(rang.length, 1, 'exactly one dispatch wrote/rings');
  assert.equal(failed.length, 1, 'the other fails closed (lock loser) — no silent last-writer substitution');
  assert.match(failed[0].reason.message, /lock unavailable|different content within TTL/);
  const held = (await s.get('need_1')).question;
  assert.ok(held === 'A' || held === 'B', 'the store holds exactly the winner content');
});

test('concurrency: two IDENTICAL-content puts -> the winner rings, the other is idempotent-or-lockloser (never a second ring)', async () => {
  const s = createDialSignalStore({ store: createInMemoryStore(), now: () => NOW });
  const results = await Promise.allSettled([s.put('need_1', mkSignal({ question: 'same' })), s.put('need_1', mkSignal({ question: 'same' }))]);
  const rang = results.filter((r) => r.status === 'fulfilled' && r.value.stored === true);
  assert.equal(rang.length, 1, 'exactly one ring even for identical concurrent retries');
});
