// demo-bearer-guard.test.mjs — PUBLIC extractable demo capability containment (Pulse/Echo request-changes on 06a78001).
// Boot-validated safe-integer config; crash-safe cross-process fail-closed reservation ledger; reservation moved into
// handleTts (after validation, before provider, no refund); exhaustive route denial. Adversarial: contention, torn/
// corrupt/rollback state, crash-no-refund, ordering, 8192-before-reserve.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import { createDemoBearerGuard, createLiveDemoServer, validateDemoConfig } from '../src/live-demo.mjs';

const BEARER = 'pd-test-capability-000';
const AUTH = { authorization: 'Bearer ' + BEARER, 'content-type': 'application/json' };
const nowSec = () => Math.floor(Date.now() / 1000);
const EXP = () => nowSec() + 3600;
const freshDir = () => mkdtempSync(join(tmpdir(), 'pdt-'));
const mk = (dir, fp, over = {}) => createDemoBearerGuard({ expiresUnixSec: EXP(), maxPerMin: 1000, maxCalls: 100, maxBytes: 100000, fingerprint: fp, persistDir: dir, ...over });
const HERE = dirname(fileURLToPath(import.meta.url));

// ---- config validation + boot refusal ----
test('config: valid normalizes; NaN/Infinity/fraction/neg/zero/over-ceiling/past/horizon are INVALID', () => {
  const now = nowSec();
  assert.equal(validateDemoConfig({ expiresUnixSec: now + 3600, maxPerMin: 10, maxCalls: 100, maxBytes: 1000, nowSec: now }).valid, true);
  for (const bad of [NaN, Infinity, -1, 0, 1.5, Number.MAX_SAFE_INTEGER + 2]) {
    assert.equal(validateDemoConfig({ expiresUnixSec: now + 3600, maxPerMin: bad, maxCalls: 100, maxBytes: 1000, nowSec: now }).valid, false, `perMin=${bad}`);
  }
  assert.equal(validateDemoConfig({ expiresUnixSec: now - 1, maxPerMin: 10, maxCalls: 100, maxBytes: 1000, nowSec: now }).valid, false, 'past expiry');
  assert.equal(validateDemoConfig({ expiresUnixSec: now + 999 * 24 * 3600, maxPerMin: 10, maxCalls: 100, maxBytes: 1000, nowSec: now }).valid, false, 'beyond horizon');
  assert.equal(validateDemoConfig({ expiresUnixSec: now + 3600, maxPerMin: 10, maxCalls: 1e9, maxBytes: 1000, nowSec: now }).valid, false, 'maxCalls over ceiling');
});

// ---- reserveTts core ----
test('reserve: expiry >= (401), call budget (429), byte budget (429), restart-safe persistence', () => {
  const dir = freshDir();
  // expiry >= boundary
  const exp = nowSec();
  assert.equal(createDemoBearerGuard({ expiresUnixSec: exp, maxPerMin: 10, maxCalls: 10, maxBytes: 1000, fingerprint: 'e0', persistDir: dir, now: () => exp * 1000 }).reserveTts(1).status, 401);
  // call budget
  const g = mk(dir, 'c0', { maxCalls: 2, maxBytes: 1e6 });
  assert.equal(g.reserveTts(1).ok, true); assert.equal(g.reserveTts(1).ok, true); assert.equal(g.reserveTts(1).status, 429);
  // byte budget
  const gb = mk(dir, 'b0', { maxCalls: 100, maxBytes: 100 });
  assert.equal(gb.reserveTts(60).ok, true); assert.equal(gb.reserveTts(60).status, 429);
  // restart-safe: fresh instance, same fp+dir, continues from persisted
  const g1 = mk(dir, 'r0', { maxCalls: 5 }); g1.reserveTts(10); g1.reserveTts(10);
  const g2 = mk(dir, 'r0', { maxCalls: 5 });
  assert.equal(g2.stats().used.calls, 2, 'persisted across fresh instance'); assert.equal(g2.reserveTts(1).remainingCalls, 2);
});

test('reserve: fail-closed 503 when persistence unconfigured', () => {
  assert.equal(createDemoBearerGuard({ expiresUnixSec: EXP(), maxPerMin: 10, maxCalls: 10, maxBytes: 100, fingerprint: '', persistDir: '' }).reserveTts(1).status, 503);
});

// ---- adversarial: corruption / tamper / rollback -> DENY (never silent reset) ----
test('adversarial: corrupt ledger body -> 503 (fail-closed, no reset)', () => {
  const dir = freshDir(); const fp = 'corrupt000000000';
  writeFileSync(join(dir, `pocket-demo-usage-${fp}.log`), 'not-json-at-all\n');
  assert.equal(mk(dir, fp).reserveTts(1).status, 503);
});
test('adversarial: header fp mismatch -> 503', () => {
  const dir = freshDir(); const fp = 'fpA0000000000000';
  writeFileSync(join(dir, `pocket-demo-usage-${fp}.log`), JSON.stringify({ v: 1, fp: 'DIFFERENT', maxCalls: 5, maxBytes: 100 }) + '\n');
  assert.equal(mk(dir, fp).reserveTts(1).status, 503);
});
test('adversarial: non-contiguous seq (rollback/tamper) -> 503', () => {
  const dir = freshDir(); const fp = 'fpB0000000000000';
  writeFileSync(join(dir, `pocket-demo-usage-${fp}.log`),
    JSON.stringify({ v: 1, fp, maxCalls: 5, maxBytes: 100 }) + '\n' + JSON.stringify({ seq: 1, bytes: 1, ts: 0 }) + '\n' + JSON.stringify({ seq: 3, bytes: 1, ts: 0 }) + '\n');
  assert.equal(mk(dir, fp).reserveTts(1).status, 503);
});

test('adversarial: two-process contention -> exactly maxCalls reserved (no over-spend)', async () => {
  const dir = freshDir(); const fp = 'concur0000000000'; const maxCalls = 24;
  const env = { ...process.env, W_DIR: dir, W_FP: fp, W_CALLS: String(maxCalls), W_BYTES: '1000000', W_ATTEMPTS: String(maxCalls), W_EXP: String(EXP()) };
  const worker = () => new Promise((resolve) => { let out = ''; const p = spawn(process.execPath, [join(HERE, '_demo-reserve-worker.mjs')], { env }); p.stdout.on('data', (d) => (out += d)); p.on('close', () => resolve(Number(out.trim()) || 0)); });
  const oks = await Promise.all([worker(), worker(), worker()]);
  assert.equal(oks.reduce((a, b) => a + b, 0), maxCalls, `exactly ${maxCalls} across 3 processes, got ${oks}`);
});

// ---- server integration: ordering, crash-no-refund, exhaustive denial ----
async function boot(guardOver, { throwTts = false } = {}) {
  let fetchCalls = 0;
  const fetchSpy = async () => { fetchCalls += 1; throw new Error('UPSTREAM CALLED'); };
  const dir = freshDir();
  const guard = createDemoBearerGuard({ expiresUnixSec: EXP(), maxPerMin: 500, maxCalls: 500, maxBytes: 1e6, fingerprint: 'srv0000000000000', persistDir: dir, ...guardOver });
  const ttsBackend = throwTts ? (() => { throw new Error('provider down'); }) : ((text) => ({ audio: Buffer.from('RIFF....WAVEfake'), format: 'wav' }));
  const { server } = createLiveDemoServer({ apiBaseUrl: 'https://api.invalid', fetch: fetchSpy, run: () => '{}', knownSessionIdsFor: async () => ['sid'], ttsBackend, demoBearer: BEARER, demoGuard: guard });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const base = 'http://127.0.0.1:' + server.address().port;
  const req = (m, p, b, h) => fetch(base + p, { method: m, headers: h || AUTH, body: b === undefined ? undefined : (typeof b === 'string' ? b : JSON.stringify(b)) });
  return { server, req, guard, fetchCalls: () => fetchCalls };
}

test('server: EXHAUSTIVE non-voice routes 403 zero-upstream; NONE debit the budget', async () => {
  const h = await boot();
  try {
    const cases = [['GET', '/sync', undefined], ['GET', '/checkpoint', undefined], ['POST', '/answer', {}], ['POST', '/brief', {}], ['POST', '/deck', {}], ['POST', '/actions/execute', { proposal: {} }], ['POST', '/dial', {}], ['POST', '/dial/ring-owner', {}], ['POST', '/dial/register', {}], ['GET', '/dial', undefined]];
    for (const [m, p, b] of cases) { const r = await h.req(m, p, b); assert.equal(r.status, 403, `${m} ${p}`); }
    assert.equal(h.fetchCalls(), 0, 'zero upstream');
    assert.equal(h.guard.stats().used.calls, 0, 'no denied route debited the budget');
  } finally { h.server.close(); }
});

test('server: ordering — /health, scope-denied, malformed body, and >8192 never debit; only valid /tts does', async () => {
  const h = await boot();
  try {
    await h.req('GET', '/health', undefined, {}); // no auth
    await h.req('POST', '/brief', {}); // scope-denied
    await h.req('POST', '/tts', '{bad json'); // malformed -> 400
    const big = await h.req('POST', '/tts', { text: 'x'.repeat(9000) }); assert.equal(big.status, 413); // >8192 -> before reserve
    assert.equal(h.guard.stats().used.calls, 0, 'nothing debited yet');
    const okr = await h.req('POST', '/tts', { text: 'hello' }); assert.equal(okr.status, 200);
    assert.equal(h.guard.stats().used.calls, 1, 'only the valid /tts debited');
    assert.equal(h.guard.stats().used.bytes, 5);
  } finally { h.server.close(); }
});

test('server: crash-between-reserve-and-provider -> NO refund (budget stays debited)', async () => {
  const h = await boot({}, { throwTts: true });
  try {
    const r = await h.req('POST', '/tts', { text: 'hello' }); assert.equal(r.status, 502, 'provider failed');
    assert.equal(h.guard.stats().used.calls, 1, 'reservation NOT refunded after provider failure');
  } finally { h.server.close(); }
});

test('server: budget exhaustion -> 429; expired -> 401', async () => {
  const h = await boot({ maxCalls: 2 });
  try {
    assert.equal((await h.req('POST', '/tts', { text: 'a' })).status, 200);
    assert.equal((await h.req('POST', '/tts', { text: 'b' })).status, 200);
    assert.equal((await h.req('POST', '/tts', { text: 'c' })).status, 429);
  } finally { h.server.close(); }
  const he = await boot({ expiresUnixSec: nowSec() - 1 });
  try { const r = await he.req('POST', '/tts', { text: 'x' }); assert.equal(r.status, 401); assert.equal(he.fetchCalls(), 0); }
  finally { he.server.close(); }
});
