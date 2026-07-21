// dial-endpoint.test.mjs — POST /dial through createGateway().handle(): scope, membership, fail-closed dispatch,
// context scrub, and the invariant that /dial AUTHORS NOTHING (never calls the write path).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createGateway } from '../src/handlers.mjs';

const FULL = ['sessions:read', 'sessions:write', 'pocket:voice', 'pocket:dial'];
const gw = ({ scopes = FULL, pushBackend, calls } = {}) => createGateway({
  verifyToken: async (h) => (h && h.authorization ? { humanId: 'u', principal: 'p', scopes } : null),
  knownSessionIdsFor: async () => ['sess-1'],
  pushBackend,
  // trip-wires: if /dial ever touches the write path, these record it
  run: () => { (calls || []).push('run'); return '{}'; },
  postHumanMessage: async () => { (calls || []).push('postHumanMessage'); return '{}'; },
  signingKey: {},
});
const post = (g, body, headers = { authorization: 'Bearer t' }) => g.handle({ method: 'POST', path: '/dial', headers, body });
const parse = (r) => (typeof r.body === 'string' ? JSON.parse(r.body) : r.body);

test('/dial dispatches via pushBackend + AUTHORS NOTHING', async () => {
  const seen = []; const calls = [];
  const pushBackend = async (payload) => { seen.push(payload); return { dialId: 'd1', dispatched: true }; };
  const res = await post(gw({ pushBackend, calls }), { message: 'Two agents shipped; one blocker.', sessionId: 'sess-1', priority: 'high' });
  assert.equal(res.status, 200);
  assert.deepEqual(parse(res), { dialId: 'd1', dispatched: true });
  assert.equal(seen[0].message, 'Two agents shipped; one blocker.');
  assert.equal(seen[0].priority, 'high');
  assert.equal(seen[0].humanId, 'u');
  assert.deepEqual(calls, [], '/dial must NEVER call run/postHumanMessage (it authors nothing)');
});

test('no pushBackend -> 501 dial-not-configured (never a fake dispatch)', async () => {
  const res = await post(gw({}), { message: 'x', sessionId: 'sess-1' });
  assert.equal(res.status, 501);
  assert.match(parse(res).reason, /dial-not-configured/);
});

test('missing pocket:dial scope -> 403 (distinct capability, not sessions:write)', async () => {
  const res = await post(gw({ scopes: ['sessions:read', 'sessions:write'], pushBackend: async () => ({ dispatched: true }) }), { message: 'x', sessionId: 'sess-1' });
  assert.equal(res.status, 403);
  assert.match(parse(res).error, /pocket:dial/);
});

test('auth + membership gating', async () => {
  const pb = async () => ({ dialId: 'd', dispatched: true });
  assert.equal((await post(gw({ pushBackend: pb }), { message: 'x', sessionId: 'sess-1' }, {})).status, 401);      // no token
  assert.equal((await post(gw({ pushBackend: pb }), { message: 'x', sessionId: 'other' })).status, 403);            // not a member
});

test('validation: message + sessionId + size', async () => {
  const pb = async () => ({ dialId: 'd', dispatched: true });
  assert.equal((await post(gw({ pushBackend: pb }), { sessionId: 'sess-1' })).status, 400);                         // no message
  assert.equal((await post(gw({ pushBackend: pb }), { message: '   ', sessionId: 'sess-1' })).status, 400);        // blank
  assert.equal((await post(gw({ pushBackend: pb }), { message: 'x' })).status, 400);                               // no sessionId
  assert.equal((await post(gw({ pushBackend: pb }), { message: 'x'.repeat(4097), sessionId: 'sess-1' })).status, 413);
  assert.equal((await post(gw({ pushBackend: pb }), '{bad json')).status, 400);
});

test('context is scrubbed before it leaves in the push payload', async () => {
  let seen;
  const pushBackend = async (p) => { seen = p; return { dialId: 'd', dispatched: true }; };
  await post(gw({ pushBackend }), { message: 'ring', sessionId: 'sess-1', context: 'key sk-ABCDEFGHIJKLMNOP here' });
  assert.ok(!seen.context.includes('sk-ABCDEFGHIJKLMNOP'), 'a secret in context must be scrubbed');
  assert.ok(seen.context.includes('[REDACTED'), 'redaction marker present');
});

test('pushBackend failure / not-dispatched -> 502 with a reason (honest, no fake success)', async () => {
  assert.equal((await post(gw({ pushBackend: async () => { throw new Error('apns down'); } }), { message: 'x', sessionId: 'sess-1' })).status, 502);
  const res = await post(gw({ pushBackend: async () => ({ dispatched: false, reason: 'no-device-token' }) }), { message: 'x', sessionId: 'sess-1' });
  assert.equal(res.status, 502);
  assert.equal(parse(res).dispatched, false);
  assert.equal(parse(res).reason, 'no-device-token');
});
