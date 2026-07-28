// demo-bearer-guard.test.mjs — the PUBLIC extractable demo capability must be server-bounded (Pulse/Echo P1 containment):
//   pocket:voice-ONLY scope · absolute server expiry (401) · lifetime total + per-60s rate caps (429) · FAIL-CLOSED.
// Proves the guard arithmetic (Part A) AND the edge wiring: /tts scope-passes, every other route is 403 with ZERO
// upstream, and expiry/rate reject at the edge before gateway.handle (Part B).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { createDemoBearerGuard, createLiveDemoServer } from '../src/live-demo.mjs';

const BEARER = 'pd-test-capability-000';
const AUTH = { authorization: 'Bearer ' + BEARER, 'content-type': 'application/json' };

// ---- Part A: guard arithmetic (deterministic, injected clock) ----
test('guard: absolute expiry rejects with 401 (fail-closed when unset)', () => {
  const t0 = 1_800_000_000_000; // fixed ms
  const expSec = Math.floor(t0 / 1000) + 3600; // 1h future
  const g = createDemoBearerGuard({ expiresUnixSec: expSec, maxTotal: 10, maxPerMin: 10, now: () => t0 });
  assert.equal(g.admit().ok, true, 'before expiry admits');
  const gExpired = createDemoBearerGuard({ expiresUnixSec: expSec, maxTotal: 10, maxPerMin: 10, now: () => t0 + 3601_000 });
  const v = gExpired.admit();
  assert.equal(v.ok, false); assert.equal(v.status, 401); assert.equal(v.error, 'demo_capability_expired');
  const gUnset = createDemoBearerGuard({ expiresUnixSec: 0, maxTotal: 10, maxPerMin: 10, now: () => t0 });
  assert.equal(gUnset.admit().status, 401, 'unset expiry is fail-closed 401');
});

test('guard: lifetime total-usage cap rejects with 429 after N (fail-closed when 0)', () => {
  const t0 = 1_800_000_000_000;
  const expSec = Math.floor(t0 / 1000) + 3600;
  const g = createDemoBearerGuard({ expiresUnixSec: expSec, maxTotal: 3, maxPerMin: 100, now: () => t0 });
  assert.equal(g.admit().ok, true); assert.equal(g.admit().ok, true); assert.equal(g.admit().ok, true);
  const v = g.admit();
  assert.equal(v.ok, false); assert.equal(v.status, 429); assert.equal(v.error, 'demo_usage_exhausted');
  const gZero = createDemoBearerGuard({ expiresUnixSec: expSec, maxTotal: 0, maxPerMin: 100, now: () => t0 });
  assert.equal(gZero.admit().status, 429, 'unset total is fail-closed 429');
});

test('guard: per-60s rate cap rejects with 429 then resets next window (fail-closed when 0)', () => {
  let t = 1_800_000_000_000;
  const expSec = Math.floor(t / 1000) + 3600;
  const g = createDemoBearerGuard({ expiresUnixSec: expSec, maxTotal: 1000, maxPerMin: 2, now: () => t });
  assert.equal(g.admit().ok, true); assert.equal(g.admit().ok, true);
  const v = g.admit();
  assert.equal(v.ok, false); assert.equal(v.status, 429); assert.equal(v.error, 'demo_rate_limited');
  assert.ok(v.retryAfterSec >= 1 && v.retryAfterSec <= 60, 'retry-after within the window');
  t += 60_000; // roll to the next window
  assert.equal(g.admit().ok, true, 'new window admits again');
  const gZero = createDemoBearerGuard({ expiresUnixSec: expSec, maxTotal: 1000, maxPerMin: 0, now: () => t });
  assert.equal(gZero.admit().status, 429, 'unset rate is fail-closed 429');
});

// ---- Part B: server edge — scope-deny with ZERO upstream, guard 401/429 before gateway.handle ----
async function boot(guardOpts) {
  let fetchCalls = 0;
  const fetchSpy = async () => { fetchCalls += 1; throw new Error('UPSTREAM CALLED — must not happen for a denied demo-bearer request'); };
  const t0 = 1_800_000_000_000;
  const guard = createDemoBearerGuard({ expiresUnixSec: Math.floor(t0 / 1000) + 3600, maxTotal: 50, maxPerMin: 50, now: () => t0, ...guardOpts });
  const { server } = createLiveDemoServer({
    apiBaseUrl: 'https://api.invalid', fetch: fetchSpy, run: () => '{}', knownSessionIdsFor: async () => ['sid'],
    demoBearer: BEARER, demoGuard: guard,
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const base = 'http://127.0.0.1:' + server.address().port;
  const post = (path, body = {}) => fetch(base + path, { method: 'POST', headers: AUTH, body: JSON.stringify(body) });
  return { server, base, post, fetchCalls: () => fetchCalls };
}

test('edge: /tts scope-passes (pocket:voice); execute/brief/dial are 403 with ZERO upstream', async () => {
  const h = await boot();
  try {
    const tts = await h.post('/tts', { text: 'hi' });
    assert.notEqual(tts.status, 403, '/tts must NOT be scope-denied (pocket:voice is granted)');
    assert.equal(tts.status, 501, '/tts reaches the handler (501 = tts backend not configured in test)');

    const exec = await h.post('/actions/execute', { proposal: {} });
    assert.equal(exec.status, 403); assert.match((await exec.json()).error, /sessions:write/);

    const brief = await h.post('/brief', {});
    assert.equal(brief.status, 403); assert.match((await brief.json()).error, /sessions:read/);

    const dial = await h.post('/dial', {});
    assert.equal(dial.status, 403); assert.match((await dial.json()).error, /pocket:dial/);

    assert.equal(h.fetchCalls(), 0, 'NO upstream fetch for any denied demo-bearer route');
  } finally { h.server.close(); }
});

test('edge: expired capability -> 401 before gateway.handle', async () => {
  const t0 = 1_800_000_000_000;
  const h = await boot({ expiresUnixSec: Math.floor(t0 / 1000) - 1, now: () => t0 });
  try {
    const r = await h.post('/tts', { text: 'hi' });
    assert.equal(r.status, 401); assert.equal((await r.json()).error, 'demo_capability_expired');
    assert.equal(h.fetchCalls(), 0);
  } finally { h.server.close(); }
});

test('edge: rate cap -> 429 with retry-after at the edge', async () => {
  const t0 = 1_800_000_000_000;
  const h = await boot({ maxPerMin: 1, now: () => t0 });
  try {
    const ok = await h.post('/tts', { text: 'a' });      // 1st in window: scope-passes -> 501
    assert.equal(ok.status, 501);
    const limited = await h.post('/tts', { text: 'b' });  // 2nd in window: rate-limited at edge
    assert.equal(limited.status, 429);
    assert.equal((await limited.json()).error, 'demo_rate_limited');
    assert.ok(limited.headers.get('retry-after'), 'retry-after header present');
  } finally { h.server.close(); }
});
