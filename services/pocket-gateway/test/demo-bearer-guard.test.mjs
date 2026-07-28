// demo-bearer-guard.test.mjs — the PUBLIC extractable demo capability must be server-bounded (Pulse/Echo P1 containment).
// Covers Echo's request-changes on 88f190e6: finite-positive config (no NaN/Infinity fail-OPEN), restart-safe persistent
// budget keyed by capability fingerprint, CHARACTER budget (not just calls), accepted-/tts metered SEPARATELY from abuse,
// >= expiry, and EXHAUSTIVE route-table denial with zero upstream.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createDemoBearerGuard, createLiveDemoServer } from '../src/live-demo.mjs';

const BEARER = 'pd-test-capability-000';
const AUTH = { authorization: 'Bearer ' + BEARER, 'content-type': 'application/json' };
const FP = 'fptest0000000000';
const T0 = 1_800_000_000_000; // fixed ms
const EXP_FUTURE = Math.floor(T0 / 1000) + 3600;
const freshDir = () => mkdtempSync(join(tmpdir(), 'pdt-'));

// ---- Part A: guard arithmetic ----
test('guard: NON-FINITE config is fail-CLOSED, not admit (NaN/Infinity holes)', () => {
  const dir = freshDir();
  // Infinity expiry must NOT admit-forever; NaN rate/caps must NOT admit.
  const g = createDemoBearerGuard({ expiresUnixSec: Infinity, maxPerMin: NaN, maxTotalCalls: NaN, maxTotalChars: Infinity, fingerprint: FP, persistDir: dir, now: () => T0 });
  assert.equal(g.admitRequest().status, 401, 'Infinity expiry -> fail-closed 401 (not admit)');
  const g2 = createDemoBearerGuard({ expiresUnixSec: EXP_FUTURE, maxPerMin: Number('abc'), maxTotalCalls: 5, maxTotalChars: 5, fingerprint: FP, persistDir: dir, now: () => T0 });
  assert.equal(g2.admitRequest().status, 429, 'NaN rate -> fail-closed 429 (not admit)');
  const g3 = createDemoBearerGuard({ expiresUnixSec: EXP_FUTURE, maxPerMin: 10, maxTotalCalls: NaN, maxTotalChars: Infinity, fingerprint: FP, persistDir: dir, now: () => T0 });
  assert.equal(g3.debitTts(1).status, 429, 'NaN calls / Infinity chars -> fail-closed 429 (not admit)');
});

test('guard: expiry uses >= (rejects AT the expiry second)', () => {
  const dir = freshDir();
  const exp = Math.floor(T0 / 1000);
  const g = createDemoBearerGuard({ expiresUnixSec: exp, maxPerMin: 10, maxTotalCalls: 10, maxTotalChars: 100, fingerprint: FP, persistDir: dir, now: () => exp * 1000 });
  assert.equal(g.admitRequest().status, 401, 'now == expiry second -> 401');
});

test('guard: anti-abuse rate cap (admitRequest) -> 429 then resets next window', () => {
  const dir = freshDir(); let t = T0;
  const g = createDemoBearerGuard({ expiresUnixSec: EXP_FUTURE, maxPerMin: 2, maxTotalCalls: 1000, maxTotalChars: 1e6, fingerprint: FP, persistDir: dir, now: () => t });
  assert.equal(g.admitRequest().ok, true); assert.equal(g.admitRequest().ok, true);
  const v = g.admitRequest(); assert.equal(v.status, 429); assert.equal(v.error, 'demo_rate_limited'); assert.ok(v.retryAfterSec >= 1);
  t += 60_000; assert.equal(g.admitRequest().ok, true, 'new window admits');
});

test('guard: CHARACTER budget (debitTts) -> 429 when chars exceed, independent of call count', () => {
  const dir = freshDir();
  const g = createDemoBearerGuard({ expiresUnixSec: EXP_FUTURE, maxPerMin: 100, maxTotalCalls: 100, maxTotalChars: 100, fingerprint: FP, persistDir: dir, now: () => T0 });
  assert.equal(g.debitTts(60).ok, true);
  const v = g.debitTts(60); assert.equal(v.status, 429); assert.equal(v.error, 'demo_usage_exhausted'); // 60+60 > 100 chars
});

test('guard: CALL budget (debitTts) -> 429 after N calls', () => {
  const dir = freshDir();
  const g = createDemoBearerGuard({ expiresUnixSec: EXP_FUTURE, maxPerMin: 100, maxTotalCalls: 2, maxTotalChars: 1e6, fingerprint: FP, persistDir: dir, now: () => T0 });
  assert.equal(g.debitTts(1).ok, true); assert.equal(g.debitTts(1).ok, true);
  assert.equal(g.debitTts(1).status, 429, '3rd call -> exhausted');
});

test('guard: budget is RESTART-SAFE (persists across a fresh instance, same fingerprint+dir)', () => {
  const dir = freshDir();
  const mk = () => createDemoBearerGuard({ expiresUnixSec: EXP_FUTURE, maxPerMin: 100, maxTotalCalls: 5, maxTotalChars: 1000, fingerprint: FP, persistDir: dir, now: () => T0 });
  const g1 = mk(); assert.equal(g1.debitTts(40).ok, true); assert.equal(g1.debitTts(40).ok, true); // calls=2 chars=80
  const g2 = mk(); // simulated RESTART: new in-memory instance, same persisted fingerprint
  const st = g2.stats(); assert.equal(st.used.calls, 2, 'calls persisted'); assert.equal(st.used.chars, 80, 'chars persisted');
  assert.equal(g2.debitTts(10).remainingCalls, 2, 'continues from persisted (calls 3/5), NOT reset');
});

test('guard: fail-closed 503 when persistence unconfigured', () => {
  const g = createDemoBearerGuard({ expiresUnixSec: EXP_FUTURE, maxPerMin: 10, maxTotalCalls: 10, maxTotalChars: 100, fingerprint: '', persistDir: '', now: () => T0 });
  assert.equal(g.debitTts(1).status, 503, 'no persistence -> 503 unconfigured (fail-closed)');
});

// ---- Part B: server edge — EXHAUSTIVE route denial (zero upstream) + split metering ----
async function boot(guardOpts) {
  let fetchCalls = 0;
  const fetchSpy = async () => { fetchCalls += 1; throw new Error('UPSTREAM CALLED — must not happen for a denied demo-bearer request'); };
  const dir = freshDir();
  const guard = createDemoBearerGuard({ expiresUnixSec: EXP_FUTURE, maxPerMin: 500, maxTotalCalls: 500, maxTotalChars: 1e6, fingerprint: FP, persistDir: dir, now: () => T0, ...guardOpts });
  const { server } = createLiveDemoServer({ apiBaseUrl: 'https://api.invalid', fetch: fetchSpy, run: () => '{}', knownSessionIdsFor: async () => ['sid'], demoBearer: BEARER, demoGuard: guard });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const base = 'http://127.0.0.1:' + server.address().port;
  const req = (method, path, body) => fetch(base + path, { method, headers: AUTH, body: body === undefined ? undefined : JSON.stringify(body) });
  return { server, base, req, guard, fetchCalls: () => fetchCalls };
}

test('edge: EXHAUSTIVE route table — every non-voice route 403 scope-denied with ZERO upstream', async () => {
  const h = await boot();
  try {
    const cases = [
      ['GET', '/sync', undefined, /sessions:read/], ['GET', '/checkpoint', undefined, /sessions:read/],
      ['POST', '/answer', {}, /sessions:read/], ['POST', '/brief', {}, /sessions:read/], ['POST', '/deck', {}, /sessions:read/],
      ['POST', '/actions/execute', { proposal: {} }, /sessions:write/],
      ['POST', '/dial', {}, /pocket:dial/], ['POST', '/dial/ring-owner', {}, /pocket:dial/],
      ['POST', '/dial/register', {}, /pocket:dial/], ['GET', '/dial', undefined, /pocket:dial/],
    ];
    for (const [m, p, b, rx] of cases) {
      const r = await h.req(m, p, b);
      assert.equal(r.status, 403, `${m} ${p} -> 403`);
      assert.match((await r.json()).error, rx, `${m} ${p} scope error`);
    }
    assert.equal(h.fetchCalls(), 0, 'ZERO upstream for the entire denied route table');
    assert.equal(h.guard.stats().used.calls, 0, 'abuse/denied traffic did NOT debit the /tts budget');
  } finally { h.server.close(); }
});

test('edge: /tts scope-passes + debits budget; exhaustion -> 429 (abuse metered separately)', async () => {
  const h = await boot({ maxTotalCalls: 2 });
  try {
    // 5 denied /actions/execute first — must NOT touch the /tts budget
    for (let i = 0; i < 5; i++) { const r = await h.req('POST', '/actions/execute', { proposal: {} }); assert.equal(r.status, 403); }
    assert.equal(h.guard.stats().used.calls, 0, 'abuse left /tts budget untouched');
    const a = await h.req('POST', '/tts', { text: 'hi' }); assert.equal(a.status, 501, '/tts scope-passes (501 no backend in test)');
    const b = await h.req('POST', '/tts', { text: 'yo' }); assert.equal(b.status, 501);
    const c = await h.req('POST', '/tts', { text: 'no' }); assert.equal(c.status, 429, '3rd /tts -> budget exhausted');
    assert.equal((await c.json()).error, 'demo_usage_exhausted');
  } finally { h.server.close(); }
});

test('edge: expired -> 401 and rate -> 429 at the edge (before gateway.handle)', async () => {
  const hExp = await boot({ expiresUnixSec: Math.floor(T0 / 1000) - 1 });
  try { const r = await hExp.req('POST', '/tts', { text: 'x' }); assert.equal(r.status, 401); assert.equal((await r.json()).error, 'demo_capability_expired'); assert.equal(hExp.fetchCalls(), 0); }
  finally { hExp.server.close(); }
  const hRate = await boot({ maxPerMin: 1 });
  try {
    const ok = await hRate.req('POST', '/tts', { text: 'a' }); assert.equal(ok.status, 501);
    const lim = await hRate.req('POST', '/tts', { text: 'b' }); assert.equal(lim.status, 429); assert.ok(lim.headers.get('retry-after'));
  } finally { hRate.server.close(); }
});
