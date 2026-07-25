// dial-registry.test.mjs — device registration (/dial/register logic) + the deterministic dispatch payload wire.
// Hermetic: in-memory deviceRegistry + injected clock. Proves humanId-from-token binding, membership gating,
// fail-closed (no registry -> 501), and a stable/testable payload for forge decode() (id/who/priority).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  createDialRegistry, createDialPushBackend, createStoreDeviceRegistry, validateRegistration, buildDialPayload, computeDialId,
  DIAL_LIMITS, DIAL_PRIORITIES, DIAL_PUSHKIT_CAP, DIAL_PAYLOAD_MAX_BYTES,
} from '../src/dial-registry.mjs';

// Shared byte fixtures — the SAME file forge's Swift decoder byte-matches (KAV parity). Generated from buildDialPayload.
const fixtures = JSON.parse(readFileSync(new URL('./fixtures/dial-payload-v1.json', import.meta.url), 'utf8'));

const NOW = 1_770_000_000_000; // fixed injected clock
const fakeRegistry = () => {
  const records = [];
  return {
    records,
    async register(r) { records.push(r); return { deviceCount: records.filter((x) => x.humanId === r.humanId && x.sessionId === r.sessionId).length }; },
    async lookup({ humanId, sessionId }) { return records.filter((x) => x.humanId === humanId && x.sessionId === sessionId).map((x) => ({ voipToken: x.voipToken, platform: x.platform })); },
  };
};

test('computeDialId: deterministic, prefixed, and injective over its inputs', () => {
  const id = computeDialId('u', 'sess-1', 'ring', NOW);
  assert.equal(id, computeDialId('u', 'sess-1', 'ring', NOW), 'same inputs -> same id');
  assert.match(id, /^dial_[A-Za-z0-9_-]{16}$/);
  // each field participates (length-prefixed join => no boundary collision)
  assert.notEqual(id, computeDialId('u2', 'sess-1', 'ring', NOW));
  assert.notEqual(id, computeDialId('u', 'sess-2', 'ring', NOW));
  assert.notEqual(id, computeDialId('u', 'sess-1', 'ring!', NOW));
  assert.notEqual(id, computeDialId('u', 'sess-1', 'ring', NOW + 1));
  // boundary-collision guard: ("a","bc") vs ("ab","c") must differ
  assert.notEqual(computeDialId('a', 'bc', 'm', NOW), computeDialId('ab', 'c', 'm', NOW));
});

test('validateRegistration: happy path defaults platform to apns', () => {
  assert.deepEqual(validateRegistration({ voipToken: ' abc ', sessionId: ' sess-1 ' }), { ok: true, value: { voipToken: 'abc', sessionId: 'sess-1', platform: 'apns' } });
  assert.deepEqual(validateRegistration({ voipToken: 'abc', sessionId: 'sess-1', platform: 'FCM' }).value.platform, 'fcm');
});

test('validateRegistration: rejects missing/oversized/bad fields', () => {
  assert.deepEqual(validateRegistration({ sessionId: 'sess-1' }), { ok: false, status: 400, error: 'voipToken required' });
  assert.equal(validateRegistration({ voipToken: 'x'.repeat(DIAL_LIMITS.VOIP_TOKEN + 1), sessionId: 'sess-1' }).status, 413);
  assert.deepEqual(validateRegistration({ voipToken: 'abc' }), { ok: false, status: 400, error: 'sessionId required' });
  assert.equal(validateRegistration({ voipToken: 'abc', sessionId: 'sess-1', platform: 'carrier-pigeon' }).status, 400);
  assert.equal(validateRegistration(null).ok, false);
});

test('buildDialPayload v1: RICH shape (core + governed), deterministic, legacy defaults', () => {
  const p = buildDialPayload({ humanId: 'u', sessionId: 'sess-1', message: 'Two shipped; one blocker.', priority: 'high', who: 'Warden' }, NOW);
  assert.deepEqual(Object.keys(p).sort(), ['callerName', 'fetch', 'id', 'kind', 'message', 'priority', 'sessionId', 'ts', 'v', 'who']);
  assert.equal(p.v, 1);
  assert.equal(p.fetch, false, 'fits -> complete/renderable');
  assert.equal(p.kind, 'info', 'legacy default kind');
  assert.equal(p.callerName, 'Senti needs you', 'legacy default callerName');
  assert.equal(p.id, computeDialId('u', 'sess-1', 'Two shipped; one blocker.', NOW), 'no override -> computeDialId');
  assert.equal(p.who, 'Warden');
  assert.equal(p.priority, 'high');
  assert.equal(p.ts, new Date(NOW).toISOString());
  assert.deepEqual(p, buildDialPayload({ humanId: 'u', sessionId: 'sess-1', message: 'Two shipped; one blocker.', priority: 'high', who: 'Warden' }, NOW), 'deterministic');
  const d = buildDialPayload({ humanId: 'u', sessionId: 'sess-1', message: 'x', priority: 'nope' }, NOW);
  assert.equal(d.who, 'senti-pocket', 'who default');
  assert.equal(d.priority, 'medium', 'unknown priority -> medium');
  assert.equal('context' in d, false, 'no context key when absent');
  assert.ok(DIAL_PRIORITIES.includes('urgent'), 'urgent kept in sync with warden /dial');
});

test('buildDialPayload v1: signal fields — opaque id override, kind, callerName, checkpointId, evidenceSeqs dedup+sort', () => {
  const p = buildDialPayload({ humanId: 'u', sessionId: '6cf7e861', id: 'need_1', kind: 'decisionYours', callerName: 'Senti needs your decision', message: 'Ship it?', checkpointId: 'cp_9', evidenceSeqs: [315050, 315038, 315038, 315050] }, NOW);
  assert.equal(p.id, 'need_1', 'opaque id override used verbatim (NOT computeDialId)');
  assert.equal(p.kind, 'decisionYours');
  assert.equal(p.callerName, 'Senti needs your decision');
  assert.equal(p.checkpointId, 'cp_9');
  assert.deepEqual(p.evidenceSeqs, [315038, 315050], 'de-duped + sorted ascending (deterministic)');
  assert.equal(p.fetch, false);
});

test('buildDialPayload v1: pickOption carries options; empty options is malformed -> throws (atomic unit)', () => {
  assert.deepEqual(buildDialPayload({ sessionId: 's', message: 'which?', kind: 'pickOption', options: ['A', 'B'] }, NOW).options, ['A', 'B']);
  assert.throws(() => buildDialPayload({ sessionId: 's', message: 'which?', kind: 'pickOption', options: [] }, NOW), /pickOption requires/);
});

test('buildDialPayload v1: over-budget -> LEAN (fetch=true, ALL governed shed, core-only); NEVER truncates the question', () => {
  const big = buildDialPayload({ humanId: 'u', sessionId: 's', id: 'need_big', kind: 'info', message: 'Q'.repeat(4000), context: 'C'.repeat(2000) }, NOW);
  assert.equal(big.fetch, true, 'message+context exceed budget -> LEAN');
  assert.equal('message' in big, false, 'governed content shed (hydrate via GET), not truncated');
  assert.equal('context' in big, false);
  assert.equal(big.id, 'need_big', 'core identity preserved for the ring + hydration');
  assert.ok(Buffer.byteLength(JSON.stringify(big)) <= DIAL_PAYLOAD_MAX_BYTES, 'lean core within budget');
});

test('buildDialPayload v1: confidence is non-governed (present when it fits; clamped)', () => {
  const p = buildDialPayload({ sessionId: 's', message: 'm', kind: 'go', confidence: 0.87 }, NOW);
  assert.equal(p.confidence, 0.87);
  assert.equal(p.fetch, false);
  assert.equal(buildDialPayload({ sessionId: 's', message: 'm', kind: 'go', confidence: 1.9 }, NOW).confidence, 1, 'clamped to [0,1]');
});

test('buildDialPayload v1: identity FAIL-CLOSED (blank/overbound/control id|sessionId, present-invalid checkpointId); opaque need_1 accepted', () => {
  assert.throws(() => buildDialPayload({ sessionId: '', message: 'x' }, NOW), /sessionId required/);
  assert.throws(() => buildDialPayload({ sessionId: 'x'.repeat(129), message: 'm' }, NOW), /exceeds/);
  assert.throws(() => buildDialPayload({ sessionId: 's', id: 'a' + String.fromCharCode(1) + 'b', message: 'm' }, NOW), /control chars/);
  assert.throws(() => buildDialPayload({ sessionId: 's', checkpointId: 'c'.repeat(129), message: 'm' }, NOW), /checkpointId exceeds/);
  // the SHIPPED NeedCarterSignal opaque vector is ACCEPTED — never require dial_/UUID syntax (Pulse C)
  assert.equal(buildDialPayload({ humanId: 'u', sessionId: '6cf7e861', id: 'need_1', kind: 'go', message: 'm' }, NOW).id, 'need_1');
});

test('buildDialPayload v1: EVERY shared fixture reproduced byte-for-byte + declared bytes locked (KAV parity for forge)', () => {
  assert.ok(Object.keys(fixtures.cases).length >= 5, 'fixtures present (incl max_core)');
  for (const [name, c] of Object.entries(fixtures.cases)) {
    const got = buildDialPayload(c.input, fixtures.meta.clockMs);
    assert.deepEqual(got, c.payload, `fixture ${name} reproduced exactly (drift -> regenerate the fixture)`);
    const bytes = Buffer.byteLength(JSON.stringify(got), 'utf8');
    assert.equal(bytes, c.bytes, `fixture ${name} declared byte count === actual (R6 metadata lock; catches serialization drift)`);
    assert.ok(bytes <= DIAL_PUSHKIT_CAP, `fixture ${name} <= 5120 (PushKit cap)`);
  }
  // R6: the max-core case proves the WORST-CASE core (exact 128-byte identities + 128 astral display codepoints) fits as LEAN.
  const mc = fixtures.cases.max_core;
  assert.ok(mc, 'max_core fixture present');
  assert.equal(mc.payload.fetch, true, 'max_core is LEAN (all governed shed)');
  assert.equal('message' in mc.payload, false, 'max_core is core-only');
  assert.ok(mc.bytes <= DIAL_PAYLOAD_MAX_BYTES, `max_core core (${mc.bytes}B) <= ${DIAL_PAYLOAD_MAX_BYTES} budget`);
});

test('pushBackend: a resolved device with invalid identity -> fail-closed invalid-dial-payload (never a garbage ring)', async () => {
  const badSession = 'bad' + String.fromCharCode(1); // control char -> buildDialPayload throws
  const reg = fakeRegistry();
  await reg.register({ humanId: 'u', sessionId: badSession, voipToken: 't', platform: 'apns' }); // device found -> reaches buildDialPayload
  const sent = [];
  const pb = createDialPushBackend({ deviceRegistry: reg, apnsSend: async (a) => { sent.push(a); return { delivered: true }; }, now: () => NOW });
  const out = await pb({ message: 'm', sessionId: badSession, humanId: 'u' });
  assert.deepEqual(out, { dispatched: false, reason: 'invalid-dial-payload' });
  assert.equal(sent.length, 0, 'no ring sent on a fail-closed payload');
});

// ── R1-R4 regression vectors (Pulse impl review of #77 @ ca1a095) ────────────────────────────────────────────
test('R1: pickOption options are COMPLETE — 9 stay 9, a long label is NOT truncated (never capped)', () => {
  const opts = Array.from({ length: 9 }, (_, i) => 'option-' + i);
  assert.deepEqual(buildDialPayload({ sessionId: 's', message: 'which?', kind: 'pickOption', options: opts }, NOW).options, opts, 'all 9 preserved (was capped to 8)');
  const longLabel = 'L'.repeat(200);
  assert.equal(buildDialPayload({ sessionId: 's', message: 'q', kind: 'pickOption', options: [longLabel] }, NOW).options[0], longLabel, '200-char label preserved (was truncated to 128)');
  assert.throws(() => buildDialPayload({ sessionId: 's', message: 'q', kind: 'pickOption', options: ['ok', ''] }, NOW), /non-empty string/, 'invalid label fails closed');
});

test('R1: evidenceSeqs are COMPLETE — 65 stay 65 (deduped/sorted, never capped); unsafe/invalid ints fail closed', () => {
  const seqs = Array.from({ length: 65 }, (_, i) => i + 1);
  assert.equal(buildDialPayload({ sessionId: 's', message: 'm', evidenceSeqs: seqs }, NOW).evidenceSeqs.length, 65, 'all 65 preserved (was capped to 64)');
  assert.throws(() => buildDialPayload({ sessionId: 's', message: 'm', evidenceSeqs: [9007199254740993] }, NOW), /positive safe integer/, 'unsafe int64 -> fail closed (no numeric corruption)');
  assert.throws(() => buildDialPayload({ sessionId: 's', message: 'm', evidenceSeqs: [-1] }, NOW), /positive safe integer/);
  assert.throws(() => buildDialPayload({ sessionId: 's', message: 'm', evidenceSeqs: [1.5] }, NOW), /positive safe integer/);
});

test('R5: PRESENT non-array evidenceSeqs/options/checkpointId fail closed; ONLY undefined is absent', () => {
  assert.equal('evidenceSeqs' in buildDialPayload({ sessionId: 's', message: 'm' }, NOW), false, 'absent (undefined) evidenceSeqs -> omitted');
  assert.throws(() => buildDialPayload({ sessionId: 's', message: 'm', evidenceSeqs: '315' }, NOW), /must be an array/, 'string evidenceSeqs rejected (was silently [])');
  assert.throws(() => buildDialPayload({ sessionId: 's', message: 'm', evidenceSeqs: { 0: 315 } }, NOW), /must be an array/, 'object evidenceSeqs rejected');
  assert.throws(() => buildDialPayload({ sessionId: 's', message: 'm', evidenceSeqs: null }, NOW), /must be an array/, 'null evidenceSeqs rejected (present-invalid, not absent)');
  assert.throws(() => buildDialPayload({ sessionId: 's', message: 'q', kind: 'pickOption', options: 'A' }, NOW), /must be an array/, 'string options rejected');
  assert.throws(() => buildDialPayload({ sessionId: 's', message: 'm', checkpointId: null }, NOW), /checkpointId/, 'null checkpointId rejected (only undefined is absent)');
});

test('R2: kind absent -> info (legacy); PRESENT-invalid -> fail closed; message required', () => {
  assert.equal(buildDialPayload({ sessionId: 's', message: 'm' }, NOW).kind, 'info', 'absent kind -> legacy info');
  assert.throws(() => buildDialPayload({ sessionId: 's', message: 'm', kind: 'bogus' }, NOW), /unknown kind/, 'present-invalid kind fails closed');
  assert.throws(() => buildDialPayload({ sessionId: 's', id: 'i' }, NOW), /message required/, 'no message -> fail closed (fetch=false must carry a validated question)');
  assert.throws(() => buildDialPayload({ sessionId: 's', message: '   ' }, NOW), /message required/, 'whitespace-only message -> fail closed');
});

test('R3: opaque id — whitespace-only rejected; a valid opaque value kept UNALTERED; C1 controls rejected', () => {
  assert.throws(() => buildDialPayload({ sessionId: 's', id: '   ', message: 'm' }, NOW), /required/, 'whitespace-only id rejected');
  assert.equal(buildDialPayload({ sessionId: 's', id: ' need 1 ', message: 'm' }, NOW).id, ' need 1 ', 'valid opaque value kept byte-for-byte (not trimmed)');
  const c1 = 'a' + String.fromCharCode(0x85) + 'b'; // U+0085 NEL — a C1 control
  assert.throws(() => buildDialPayload({ sessionId: 's', id: c1, message: 'm' }, NOW), /control chars/, 'C1 control in id rejected (was only C0+DEL)');
  assert.throws(() => buildDialPayload({ sessionId: c1, message: 'm' }, NOW), /control chars/, 'C1 control in sessionId rejected');
});

test('R4: display truncation is codepoint-safe — never a lone surrogate at the bound', () => {
  const emoji = String.fromCodePoint(0x1f600); // an astral char (surrogate pair)
  // 'a'*127 + emoji + 'b' = 129 codepoints -> slice(0,128) keeps 'a'*127 + the WHOLE emoji. OLD .slice(0,128) split the pair.
  const split = buildDialPayload({ sessionId: 's', message: 'm', callerName: 'a'.repeat(127) + emoji + 'b' }, NOW).callerName;
  assert.equal([...split].length, 128, 'bounded to 128 codepoints');
  assert.ok(split.endsWith(emoji), 'emoji at the 128th codepoint kept whole');
  assert.equal(Buffer.from(split, 'utf8').toString('utf8'), split, 'valid UTF-8 — no lone surrogate');
  assert.equal(buildDialPayload({ sessionId: 's', message: 'm', callerName: 'a'.repeat(200) + emoji }, NOW).callerName, 'a'.repeat(128), 'past-bound astral char dropped whole');
});

test('register: happy path binds token to the token-derived humanId (never the body)', async () => {
  const reg = fakeRegistry();
  const svc = createDialRegistry({ deviceRegistry: reg, now: () => NOW });
  const r = await svc.register({ humanId: 'u', body: { voipToken: 'tok-1', sessionId: 'sess-1' }, isMember: async () => true });
  assert.equal(r.status, 200);
  assert.deepEqual(r.body, { registered: true, sessionId: 'sess-1', platform: 'apns', deviceCount: 1 });
  // the stored record is keyed by the humanId ARGUMENT (from the verified token), with the injected registeredAt
  assert.equal(reg.records[0].humanId, 'u');
  assert.equal(reg.records[0].voipToken, 'tok-1');
  assert.equal(reg.records[0].registeredAt, new Date(NOW).toISOString());
  // idempotent-ish upsert bumps deviceCount for a 2nd device on the same session
  const r2 = await svc.register({ humanId: 'u', body: { voipToken: 'tok-2', sessionId: 'sess-1' }, isMember: async () => true });
  assert.equal(r2.body.deviceCount, 2);
});

test('register: fail-closed — invalid body 4xx, no registry 501, non-member 403', async () => {
  const reg = fakeRegistry();
  const svc = createDialRegistry({ deviceRegistry: reg, now: () => NOW });
  assert.equal((await svc.register({ humanId: 'u', body: { sessionId: 'sess-1' }, isMember: async () => true })).status, 400); // no token
  assert.equal((await svc.register({ humanId: 'u', body: { voipToken: 't', sessionId: 'other' }, isMember: async () => false })).status, 403);
  assert.equal(reg.records.length, 0, 'nothing written on a rejected register');
  // no registry wired -> 501 dial-not-configured (checked AFTER validation so a bad body still 400s first)
  const noReg = createDialRegistry({ now: () => NOW });
  const r = await noReg.register({ humanId: 'u', body: { voipToken: 't', sessionId: 'sess-1' }, isMember: async () => true });
  assert.equal(r.status, 501);
  assert.match(r.body.reason, /dial-not-configured/);
});

test('register: isMember throw -> 500; registry.register throw -> 502 (honest, never a silent success)', async () => {
  const svc500 = createDialRegistry({ deviceRegistry: fakeRegistry(), now: () => NOW });
  assert.equal((await svc500.register({ humanId: 'u', body: { voipToken: 't', sessionId: 's' }, isMember: async () => { throw new Error('lookup down'); } })).status, 500);
  const throwingReg = { async register() { throw new Error('dynamo down'); } };
  const svc502 = createDialRegistry({ deviceRegistry: throwingReg, now: () => NOW });
  const r = await svc502.register({ humanId: 'u', body: { voipToken: 't', sessionId: 's' }, isMember: async () => true });
  assert.equal(r.status, 502);
  assert.match(r.body.reason, /registry-write-failed/);
});

test('service buildPayload uses the injected clock', () => {
  const svc = createDialRegistry({ deviceRegistry: fakeRegistry(), now: () => NOW });
  assert.equal(svc.buildPayload({ humanId: 'u', sessionId: 's', message: 'm' }).ts, new Date(NOW).toISOString());
});

// ---- createDialPushBackend: the registry-backed impl warden's /dial calls ------------------------------------------

test('pushBackend: happy path resolves the registered device, sends the deterministic payload, dispatched=true', async () => {
  const reg = fakeRegistry();
  await reg.register({ humanId: 'u', sessionId: 'sess-1', voipToken: 'tok-1', platform: 'apns' });
  const sent = [];
  const apnsSend = async (a) => { sent.push(a); return { delivered: true }; };
  const pb = createDialPushBackend({ deviceRegistry: reg, apnsSend, now: () => NOW });
  const out = await pb({ message: 'ship it?', context: 'ctx', priority: 'high', sessionId: 'sess-1', humanId: 'u' });
  assert.deepEqual(out, { dispatched: true, dialId: computeDialId('u', 'sess-1', 'ship it?', NOW), delivered: 1, devices: 1 });
  assert.equal(sent[0].voipToken, 'tok-1');
  assert.equal(sent[0].payload.id, out.dialId, 'payload id == returned dialId');
  assert.equal(sent[0].payload.priority, 'high');
  assert.equal(sent[0].payload.message, 'ship it?');
});

test('pushBackend: 0 registered devices -> no-device-token (== warden /dial 502 expectation)', async () => {
  const pb = createDialPushBackend({ deviceRegistry: fakeRegistry(), apnsSend: async () => ({ delivered: true }), now: () => NOW });
  assert.deepEqual(await pb({ message: 'x', sessionId: 'sess-1', humanId: 'u' }), { dispatched: false, reason: 'no-device-token' });
});

test('pushBackend: fail-closed at every gap (never a fake dispatch)', async () => {
  // no registry
  assert.equal((await createDialPushBackend({ apnsSend: async () => ({ delivered: true }) })({ humanId: 'u', sessionId: 's' })).reason, 'dial-not-configured');
  // lookup throws
  const throwing = { lookup: async () => { throw new Error('dynamo down'); } };
  assert.equal((await createDialPushBackend({ deviceRegistry: throwing, apnsSend: async () => ({ delivered: true }) })({ humanId: 'u', sessionId: 's' })).reason, 'registry-lookup-failed');
  // registered device but no apnsSend transport
  const reg = fakeRegistry();
  await reg.register({ humanId: 'u', sessionId: 's', voipToken: 't', platform: 'apns' });
  assert.equal((await createDialPushBackend({ deviceRegistry: reg })({ humanId: 'u', sessionId: 's', message: 'm' })).reason, 'push-transport-not-configured');
});

test('pushBackend: fan-out — one dead token never fails the ring; all-fail is honest', async () => {
  const reg = fakeRegistry();
  await reg.register({ humanId: 'u', sessionId: 's', voipToken: 'good', platform: 'apns' });
  await reg.register({ humanId: 'u', sessionId: 's', voipToken: 'dead', platform: 'apns' });
  const apnsSend = async ({ voipToken }) => { if (voipToken === 'dead') throw new Error('BadDeviceToken'); return { delivered: true }; };
  const out = await createDialPushBackend({ deviceRegistry: reg, apnsSend, now: () => NOW })({ message: 'm', sessionId: 's', humanId: 'u' });
  assert.equal(out.dispatched, true);
  assert.equal(out.delivered, 1);
  assert.equal(out.devices, 2);
  // ALL deliveries fail -> honest all-deliveries-failed (still carries the dialId)
  const allFail = createDialPushBackend({ deviceRegistry: reg, apnsSend: async () => ({ delivered: false }), now: () => NOW });
  const r = await allFail({ message: 'm', sessionId: 's', humanId: 'u' });
  assert.equal(r.dispatched, false);
  assert.equal(r.reason, 'all-deliveries-failed');
  assert.equal(r.dialId, computeDialId('u', 's', 'm', NOW));
});

test('createStoreDeviceRegistry: register (atomic put) + lookup over the KV store; latest-wins single device v1', async () => {
  const m = new Map();
  const store = { async get(k) { return m.get(k); }, async put(k, v) { m.set(k, v); return v; } };
  const reg = createStoreDeviceRegistry({ store, now: () => NOW });
  assert.deepEqual(await reg.lookup({ humanId: 'u', sessionId: 's' }), [], 'empty before register');
  assert.deepEqual(await reg.register({ humanId: 'u', sessionId: 's', voipToken: 'tok-1', platform: 'apns' }), { deviceCount: 1 });
  assert.deepEqual(await reg.lookup({ humanId: 'u', sessionId: 's' }), [{ voipToken: 'tok-1', platform: 'apns' }]);
  // re-register the same session -> latest device wins (v1 single-device semantics, not a race)
  await reg.register({ humanId: 'u', sessionId: 's', voipToken: 'tok-2', platform: 'fcm' });
  assert.deepEqual(await reg.lookup({ humanId: 'u', sessionId: 's' }), [{ voipToken: 'tok-2', platform: 'fcm' }]);
  // isolation: a different human is a distinct record
  assert.deepEqual(await reg.lookup({ humanId: 'other', sessionId: 's' }), []);
  // key injection-safe (humanId length-prefixed): ("a","b:c") vs ("a:b","c") never collide
  await reg.register({ humanId: 'a', sessionId: 'b:c', voipToken: 'x', platform: 'apns' });
  await reg.register({ humanId: 'a:b', sessionId: 'c', voipToken: 'y', platform: 'apns' });
  assert.equal((await reg.lookup({ humanId: 'a', sessionId: 'b:c' }))[0].voipToken, 'x');
  assert.equal((await reg.lookup({ humanId: 'a:b', sessionId: 'c' }))[0].voipToken, 'y');
});

test('createStoreDeviceRegistry: requires a get/put store', () => {
  assert.throws(() => createStoreDeviceRegistry({}), /requires a \{ get, put \} store/);
});

test('createStoreDeviceRegistry composes with createDialPushBackend end-to-end (register -> lookup -> ring)', async () => {
  const m = new Map();
  const store = { async get(k) { return m.get(k); }, async put(k, v) { m.set(k, v); return v; } };
  const reg = createStoreDeviceRegistry({ store, now: () => NOW });
  await reg.register({ humanId: 'u', sessionId: 's', voipToken: 'tok-store', platform: 'apns' });
  const sent = [];
  const pb = createDialPushBackend({ deviceRegistry: reg, apnsSend: async (a) => { sent.push(a); return { delivered: true }; }, now: () => NOW });
  const out = await pb({ message: 'ring', sessionId: 's', humanId: 'u' });
  assert.equal(out.dispatched, true);
  assert.equal(sent[0].voipToken, 'tok-store', 'the store-registered token is resolved + rung');
});

test('pushBackend: duplicate voipToken records ring the device ONCE (dedup — no double-ring on re-login)', async () => {
  const reg = fakeRegistry();
  await reg.register({ humanId: 'u', sessionId: 's', voipToken: 'same', platform: 'apns' });
  await reg.register({ humanId: 'u', sessionId: 's', voipToken: 'same', platform: 'apns' }); // a re-login left a 2nd record for the same device
  const sent = [];
  const pb = createDialPushBackend({ deviceRegistry: reg, apnsSend: async (a) => { sent.push(a); return { delivered: true }; }, now: () => NOW });
  const out = await pb({ message: 'm', sessionId: 's', humanId: 'u' });
  assert.equal(sent.length, 1, 'the duplicate token is rung exactly once');
  assert.equal(out.devices, 1, 'device count reflects DISTINCT devices');
  assert.equal(out.dispatched, true);
});
