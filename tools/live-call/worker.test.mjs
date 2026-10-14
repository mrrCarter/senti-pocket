import test from 'node:test';
import assert from 'node:assert/strict';

globalThis.Response = class { constructor(body, init = {}) { this.body = body; this.status = init.status ?? 200; this.webSocket = init.webSocket; } };

const worker = await import('./worker.mjs');
const { authorizeEndpoint, authorize, buildForwardUrl, doName } = worker;

function mkReq(url, { method = 'GET', upgrade = false, auth = null } = {}) {
  const h = new Map();
  if (upgrade) h.set('upgrade', 'websocket');
  if (auth) h.set('authorization', auth);
  return { url, method, headers: { get: (k) => (h.has(k.toLowerCase()) ? h.get(k.toLowerCase()) : null) } };
}
const GW = { GATEWAY_AUTHORIZE_URL: 'https://gw.example/authorize', GATEWAY_HOST: 'gw.example' };

test('authorizeEndpoint pins https + host, and FAILS CLOSED when GATEWAY_HOST is unset', () => {
  assert.equal(authorizeEndpoint(GW), 'https://gw.example/authorize');
  assert.equal(authorizeEndpoint({ GATEWAY_AUTHORIZE_URL: 'https://gw.example/authorize' }), null); // host pin unset -> closed
  assert.equal(authorizeEndpoint({ GATEWAY_AUTHORIZE_URL: 'http://gw.example/x', GATEWAY_HOST: 'gw.example' }), null); // not https
  assert.equal(authorizeEndpoint({ GATEWAY_AUTHORIZE_URL: 'https://evil.example/x', GATEWAY_HOST: 'gw.example' }), null); // host mismatch
  assert.equal(authorizeEndpoint({}), null);
});

test('doName keys the DO by BOTH session and room (reverting to roomId-only is the squat regression)', () => {
  assert.notEqual(doName('S1', 'R'), doName('S2', 'R')); // different sessions, same room -> different DO
  assert.notEqual(doName('S', 'R1'), doName('S', 'R2'));
  // a session id containing the separator can't forge another (session, room) pair
  assert.notEqual(doName('a::b', 'c'), doName('a', 'b::c'));
});

test('buildForwardUrl strips the bearer token and binds the AUTHORIZED participant + role', () => {
  const u = new URL(buildForwardUrl('https://w/call/R/ws?session=S&token=secret&participant=iamroot&role=owner', {
    roomId: 'R', participantId: 'alice', role: 'viewer',
  }));
  assert.equal(u.searchParams.get('token'), null);
  assert.equal(u.searchParams.get('participant'), 'alice');
  assert.equal(u.searchParams.get('role'), 'viewer');
  assert.equal(u.searchParams.get('room'), 'R');
});

test('authorize fails closed with no endpoint (and never calls fetch)', async () => {
  let called = false;
  const saved = globalThis.fetch;
  globalThis.fetch = async () => { called = true; return { ok: true, json: async () => ({}) }; };
  try {
    assert.equal((await authorize({}, { authorization: 'Bearer t', sessionId: 'S', roomId: 'R' })).ok, false);
    assert.equal(called, false);
  } finally { globalThis.fetch = saved; }
});

test('authorize uses redirect:manual (never follow a redirect with the bearer) + returns the bound principal', async () => {
  const saved = globalThis.fetch;
  let opts;
  try {
    globalThis.fetch = async (_u, o) => { opts = o; return { ok: true, json: async () => ({ sessionId: 'S', roomId: 'R', role: 'admin', participantId: 'p1' }) }; };
    const r = await authorize(GW, { authorization: 'Bearer t', sessionId: 'S', roomId: 'R' });
    assert.deepEqual(r, { ok: true, participantId: 'p1', role: 'admin' });
    assert.equal(opts.redirect, 'manual'); // removing redirect:manual makes this fail
  } finally { globalThis.fetch = saved; }
});

test('authorize rejects a non-member role and a mismatched (session, room) echo', async () => {
  const saved = globalThis.fetch;
  try {
    globalThis.fetch = async () => ({ ok: true, json: async () => ({ sessionId: 'S', roomId: 'R', role: 'stranger', participantId: 'p1' }) });
    assert.equal((await authorize(GW, { authorization: 'Bearer t', sessionId: 'S', roomId: 'R' })).ok, false);
    globalThis.fetch = async () => ({ ok: true, json: async () => ({ sessionId: 'OTHER', roomId: 'R', role: 'owner', participantId: 'p1' }) });
    assert.equal((await authorize(GW, { authorization: 'Bearer t', sessionId: 'S', roomId: 'R' })).ok, false);
  } finally { globalThis.fetch = saved; }
});

test('default fetch: /health open; unauthorized call 403; a POST to /ws is refused (bind-bypass closed)', async () => {
  const health = await worker.default.fetch(mkReq('https://w/health'), {});
  assert.equal(health.status, 200);
  assert.equal(JSON.parse(health.body).ok, true);

  // No gateway config -> fail closed.
  assert.equal((await worker.default.fetch(mkReq('https://w/call/R/ws?session=S', { upgrade: true, auth: 'Bearer t' }), {})).status, 403);

  // Even an AUTHORIZED POST to /ws is refused (not forwarded) — the WS route is GET-only.
  const saved = globalThis.fetch;
  try {
    globalThis.fetch = async () => ({ ok: true, json: async () => ({ sessionId: 'S', roomId: 'R', role: 'owner', participantId: 'p1' }) });
    const res = await worker.default.fetch(
      mkReq('https://w/call/R/ws?session=S', { method: 'POST', upgrade: true, auth: 'Bearer t' }),
      { ...GW, CALL_ROOM: { idFromName: () => ({}), get: () => ({ fetch: async () => { throw new Error('must not forward'); } }) } },
    );
    assert.equal(res.status, 426); // removing the GET-only guard would forward the POST
  } finally { globalThis.fetch = saved; }
});
