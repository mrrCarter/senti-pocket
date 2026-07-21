// dial-registry.test.mjs — device registration (/dial/register logic) + the deterministic dispatch payload wire.
// Hermetic: in-memory deviceRegistry + injected clock. Proves humanId-from-token binding, membership gating,
// fail-closed (no registry -> 501), and a stable/testable payload for forge decode() (id/who/priority).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  createDialRegistry, createDialPushBackend, createStoreDeviceRegistry, validateRegistration, buildDialPayload, computeDialId,
  DIAL_LIMITS, DIAL_PRIORITIES,
} from '../src/dial-registry.mjs';

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

test('buildDialPayload: forge-decode shape (id/who/priority), deterministic, defaults + bounds', () => {
  const p = buildDialPayload({ humanId: 'u', sessionId: 'sess-1', message: 'Two shipped; one blocker.', priority: 'high', who: 'Warden' }, NOW);
  assert.deepEqual(Object.keys(p).sort(), ['id', 'message', 'priority', 'sessionId', 'ts', 'who']);
  assert.equal(p.id, computeDialId('u', 'sess-1', 'Two shipped; one blocker.', NOW));
  assert.equal(p.who, 'Warden');
  assert.equal(p.priority, 'high');
  assert.equal(p.ts, new Date(NOW).toISOString());
  assert.deepEqual(p, buildDialPayload({ humanId: 'u', sessionId: 'sess-1', message: 'Two shipped; one blocker.', priority: 'high', who: 'Warden' }, NOW));
  // defaults: who -> senti-pocket, unknown priority -> medium, empty context omitted
  const d = buildDialPayload({ humanId: 'u', sessionId: 'sess-1', message: 'x', priority: 'nope' }, NOW);
  assert.equal(d.who, 'senti-pocket');
  assert.equal(d.priority, 'medium');
  assert.equal('context' in d, false, 'no context key when absent');
  assert.ok(DIAL_PRIORITIES.includes('urgent'), 'urgent kept in sync with warden /dial');
  // context present -> included + bounded; who bounded
  const c = buildDialPayload({ humanId: 'u', sessionId: 's', message: 'm', context: 'y'.repeat(DIAL_LIMITS.CONTEXT + 500), who: 'W'.repeat(DIAL_LIMITS.WHO + 50) }, NOW);
  assert.equal(c.context.length, DIAL_LIMITS.CONTEXT);
  assert.equal(c.who.length, DIAL_LIMITS.WHO);
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
