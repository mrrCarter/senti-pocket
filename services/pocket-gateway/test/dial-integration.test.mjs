// dial-integration.test.mjs — the FULL DIAL-ME wire through createGateway(): /dial/register (relay) populates the
// device registry that POST /dial (warden) resolves via the registry-backed pushBackend (relay). Proves the split
// works TOGETHER end-to-end AND that the humanId isolation holds through the real handler boundary — a caller can only
// ring a device THEY registered, keyed by the VERIFIED token. Hermetic: in-mem registry + fake apnsSend + injected now.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createGateway } from '../src/handlers.mjs';
import { createDialPushBackend, computeDialId } from '../src/dial-registry.mjs';

const NOW = 1_770_000_000_000;
const FULL = ['sessions:read', 'sessions:write', 'pocket:voice', 'pocket:dial'];

function inMemRegistry() {
  const records = [];
  return {
    records,
    async register(r) { records.push(r); return { deviceCount: records.filter((x) => x.humanId === r.humanId && x.sessionId === r.sessionId).length }; },
    async lookup({ humanId, sessionId }) { return records.filter((x) => x.humanId === humanId && x.sessionId === sessionId).map((x) => ({ voipToken: x.voipToken, platform: x.platform })); },
  };
}

// Gateway wired EXACTLY as the deploy would: deps.deviceRegistry = the store, deps.pushBackend = the registry-backed
// impl. verifyToken derives humanId from the bearer so we can exercise two distinct callers.
function makeGateway({ scopes = FULL } = {}) {
  const deviceRegistry = inMemRegistry();
  const apnsSent = [];
  const gw = createGateway({
    verifyToken: async (h) => { const m = /Bearer (\w+)/.exec((h && h.authorization) || ''); return m ? { humanId: m[1], principal: m[1], scopes } : null; },
    knownSessionIdsFor: async () => ['sess-1'],
    deviceRegistry,
    pushBackend: createDialPushBackend({ deviceRegistry, apnsSend: async (a) => { apnsSent.push(a); return { delivered: true }; }, now: () => NOW }),
    run: () => '{}',       // benign; dial paths never author
    signingKey: {},
  });
  return { gw, deviceRegistry, apnsSent };
}
const call = (gw, path, body, token = 'u1') => gw.handle({ method: 'POST', path, headers: { authorization: `Bearer ${token}` }, body });
const parse = (r) => (typeof r.body === 'string' ? JSON.parse(r.body) : r.body);

test('e2e: /dial before any device is registered -> 502 no-device-token (fail-closed, honest)', async () => {
  const { gw, apnsSent } = makeGateway();
  const res = await call(gw, '/dial', { message: 'ship?', sessionId: 'sess-1' });
  assert.equal(res.status, 502);
  assert.equal(parse(res).reason, 'no-device-token');
  assert.equal(apnsSent.length, 0);
});

test('e2e: register -> /dial resolves the token + rings it with the deterministic payload (the whole wire)', async () => {
  const { gw, deviceRegistry, apnsSent } = makeGateway();
  // 1) the phone registers its VoIP token (onVoipToken seam)
  const reg = await call(gw, '/dial/register', { voipToken: 'apns-tok-1', sessionId: 'sess-1' });
  assert.equal(reg.status, 200);
  assert.deepEqual(parse(reg), { registered: true, sessionId: 'sess-1', platform: 'apns', deviceCount: 1 });
  assert.equal(deviceRegistry.records[0].humanId, 'u1', 'device bound to the VERIFIED token humanId, not the body');
  // 2) /dial resolves that token via the registry-backed pushBackend + rings it
  const res = await call(gw, '/dial', { message: 'Two shipped; one blocker. GO?', sessionId: 'sess-1', priority: 'high' });
  assert.equal(res.status, 200);
  assert.equal(parse(res).dispatched, true);
  assert.equal(parse(res).dialId, computeDialId('u1', 'sess-1', 'Two shipped; one blocker. GO?', NOW), 'dialId deterministic + consistent across the wire');
  // the APNs send got the resolved token + the deterministic forge-decode payload
  assert.equal(apnsSent.length, 1);
  assert.equal(apnsSent[0].voipToken, 'apns-tok-1');
  assert.equal(apnsSent[0].payload.id, parse(res).dialId);
  assert.equal(apnsSent[0].payload.message, 'Two shipped; one blocker. GO?');
  assert.equal(apnsSent[0].payload.priority, 'high');
  assert.equal(apnsSent[0].payload.sessionId, 'sess-1');
});

test('e2e ISOLATION: a caller rings only THEIR OWN device — u2 cannot ring u1 device for the same session', async () => {
  const { gw, apnsSent } = makeGateway();
  await call(gw, '/dial/register', { voipToken: 'u1-device', sessionId: 'sess-1' }, 'u1'); // u1 registers
  // u2 is ALSO a sess-1 member (passes membership) but the dispatch resolves for (u2, sess-1) = NO device -> 502.
  // u1's device is NEVER rung: dispatch is keyed by the VERIFIED humanId, not just session membership.
  const res = await call(gw, '/dial', { message: 'ring', sessionId: 'sess-1' }, 'u2');
  assert.equal(res.status, 502);
  assert.equal(parse(res).reason, 'no-device-token');
  assert.equal(apnsSent.length, 0, "u1's device was never rung by u2 — humanId isolation holds through the boundary");
});

test('e2e: /dial/register is membership + scope + auth gated', async () => {
  const { gw } = makeGateway();
  assert.equal((await call(gw, '/dial/register', { voipToken: 't', sessionId: 'other-sess' })).status, 403, 'non-member session');
  assert.equal((await call(gw, '/dial/register', { sessionId: 'sess-1' })).status, 400, 'missing voipToken');
  const { gw: noScope } = makeGateway({ scopes: ['sessions:read', 'sessions:write'] });
  assert.equal((await call(noScope, '/dial/register', { voipToken: 't', sessionId: 'sess-1' })).status, 403, 'missing pocket:dial');
  assert.equal((await gw.handle({ method: 'POST', path: '/dial/register', headers: {}, body: { voipToken: 't', sessionId: 'sess-1' } })).status, 401, 'no token');
});

test('e2e: /dial/register fail-closed when no deviceRegistry is wired -> 501', async () => {
  const gw = createGateway({
    verifyToken: async () => ({ humanId: 'u1', principal: 'u1', scopes: FULL }),
    knownSessionIdsFor: async () => ['sess-1'],
    run: () => '{}', signingKey: {},
    // no deviceRegistry, no pushBackend
  });
  const res = await gw.handle({ method: 'POST', path: '/dial/register', headers: { authorization: 'Bearer u1' }, body: { voipToken: 't', sessionId: 'sess-1' } });
  assert.equal(res.status, 501);
  assert.equal(parse(res).reason, 'dial-not-configured');
});
