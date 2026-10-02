// demo-bearer-guard.test.mjs — guard (expiry/rate/ledger) + server integration for the PUBLIC demo capability.
// Config boot-validation; reservation inside handleTts (after validation, before provider, no refund); pinned provider
// overrides; UNSKIPPABLE safe composition; exhaustive route denial. Ledger internals are covered by demo-ledger.test.mjs.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { mkdtempSync, chmodSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createDemoBearerGuard, createLiveDemoServer, validateDemoConfig } from '../src/live-demo.mjs';
import { createReservationLedger } from '../src/demo-ledger.mjs';

const BEARER = 'pd-test-capability-000';
const AUTH = { authorization: 'Bearer ' + BEARER, 'content-type': 'application/json' };
const CAP = 'c'.repeat(64);
const nowSec = () => Math.floor(Date.now() / 1000);
const EXP = () => nowSec() + 3600;
const provisionedLedger = (over = {}) => { const d = mkdtempSync(join(tmpdir(), 'pdg-')); chmodSync(d, 0o700); const L = createReservationLedger({ dir: d, capId: CAP, maxCalls: 500, maxBytes: 1e6, ...over }); L.provision(); return L; };

test('config: valid normalizes; NaN/Infinity/fraction/neg/zero/over-ceiling/past/horizon invalid', () => {
  const n = nowSec();
  assert.equal(validateDemoConfig({ expiresUnixSec: n + 3600, maxPerMin: 10, maxCalls: 100, maxBytes: 1000, nowSec: n }).valid, true);
  for (const bad of [NaN, Infinity, -1, 0, 1.5, Number.MAX_SAFE_INTEGER + 2]) assert.equal(validateDemoConfig({ expiresUnixSec: n + 3600, maxPerMin: bad, maxCalls: 100, maxBytes: 1000, nowSec: n }).valid, false, `perMin=${bad}`);
  assert.equal(validateDemoConfig({ expiresUnixSec: n - 1, maxPerMin: 10, maxCalls: 100, maxBytes: 1000, nowSec: n }).valid, false, 'past');
  assert.equal(validateDemoConfig({ expiresUnixSec: n + 999 * 86400, maxPerMin: 10, maxCalls: 100, maxBytes: 1000, nowSec: n }).valid, false, 'horizon');
  assert.equal(validateDemoConfig({ expiresUnixSec: Number.MAX_VALUE, maxPerMin: 10, maxCalls: 100, maxBytes: 1000, nowSec: n }).valid, false, 'MAX_VALUE expiry (no toISOString RangeError downstream)');
});

test('guard: expiry(>=)->401, rate->429, ledger exhaustion->429, no ledger->503', () => {
  const exp = nowSec();
  assert.equal(createDemoBearerGuard({ expiresUnixSec: exp, maxPerMin: 10, ledger: provisionedLedger(), now: () => exp * 1000 }).reserveTts(1).status, 401);
  const g = createDemoBearerGuard({ expiresUnixSec: EXP(), maxPerMin: 1, ledger: provisionedLedger() });
  assert.equal(g.reserveTts(1).ok, true); assert.equal(g.reserveTts(1).status, 429, 'rate');
  const g2 = createDemoBearerGuard({ expiresUnixSec: EXP(), maxPerMin: 100, ledger: provisionedLedger({ maxCalls: 1 }) });
  assert.equal(g2.reserveTts(1).ok, true); assert.equal(g2.reserveTts(1).status, 429, 'budget');
  assert.equal(createDemoBearerGuard({ expiresUnixSec: EXP(), maxPerMin: 10, ledger: null }).reserveTts(1).status, 503);
});

async function boot({ guardOver = {}, ledgerOver = {}, throwTts = false, withGuard = true, recordOpts = null } = {}) {
  let fetchCalls = 0;
  const fetchSpy = async () => { fetchCalls += 1; throw new Error('UPSTREAM CALLED'); };
  const ledger = provisionedLedger(ledgerOver);
  const guard = withGuard ? createDemoBearerGuard({ expiresUnixSec: EXP(), maxPerMin: 500, ledger, ...guardOver }) : undefined;
  const ttsBackend = throwTts
    ? (() => { throw new Error('provider down'); })
    : ((text, opts) => { if (recordOpts) recordOpts.push(opts); return { audio: Buffer.from('RIFF....WAVEfake'), format: 'wav' }; });
  const { server } = createLiveDemoServer({ apiBaseUrl: 'https://api.invalid', fetch: fetchSpy, run: () => '{}', knownSessionIdsFor: async () => ['sid'], ttsBackend, demoBearer: BEARER, demoGuard: guard });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const base = 'http://127.0.0.1:' + server.address().port;
  const req = (m, p, b, h) => fetch(base + p, { method: m, headers: h || AUTH, body: b === undefined ? undefined : (typeof b === 'string' ? b : JSON.stringify(b)) });
  return { server, req, guard, ledger, fetchCalls: () => fetchCalls };
}

test('server: EXHAUSTIVE non-voice routes 403 zero-upstream; none debit', async () => {
  const h = await boot();
  try {
    for (const [m, p, b] of [['GET', '/sync'], ['GET', '/checkpoint'], ['POST', '/answer', {}], ['POST', '/brief', {}], ['POST', '/deck', {}], ['POST', '/actions/execute', { proposal: {} }], ['POST', '/dial', {}], ['POST', '/dial/ring-owner', {}], ['POST', '/dial/register', {}], ['GET', '/dial']]) {
      assert.equal((await h.req(m, p, b)).status, 403, `${m} ${p}`);
    }
    assert.equal(h.fetchCalls(), 0); assert.equal(h.guard.stats().used.calls, 0);
  } finally { h.server.close(); }
});

test('server: ordering — /health, scope-denied, malformed, >8192 never debit; only valid /tts does', async () => {
  const h = await boot();
  try {
    await h.req('GET', '/health', undefined, {}); await h.req('POST', '/brief', {}); await h.req('POST', '/tts', '{bad');
    assert.equal((await h.req('POST', '/tts', { text: 'x'.repeat(9000) })).status, 413);
    assert.equal(h.guard.stats().used.calls, 0, 'nothing debited yet');
    assert.equal((await h.req('POST', '/tts', { text: 'hello' })).status, 200);
    assert.equal(h.guard.stats().used.calls, 1); assert.equal(h.guard.stats().used.bytes, 5);
  } finally { h.server.close(); }
});

test('server: crash-between-reserve-and-provider -> NO refund', async () => {
  const h = await boot({ throwTts: true });
  try { assert.equal((await h.req('POST', '/tts', { text: 'hello' })).status, 502); assert.equal(h.guard.stats().used.calls, 1, 'not refunded'); }
  finally { h.server.close(); }
});

test('server: UNSKIPPABLE — demo bearer with NO guard -> /tts 503 (never unbounded)', async () => {
  const h = await boot({ withGuard: false });
  try { assert.equal((await h.req('POST', '/tts', { text: 'hi' })).status, 503); assert.equal(h.fetchCalls(), 0); }
  finally { h.server.close(); }
});

test('server: PIN provider overrides — demo /tts ignores client voice/model/output/tone', async () => {
  const rec = []; const h = await boot({ recordOpts: rec });
  try {
    assert.equal((await h.req('POST', '/tts', { text: 'hi', voiceId: 'ATTACKER', modelId: 'expensive', outputFormat: 'huge', tone: 'x' })).status, 200);
    assert.deepEqual(rec[0], {}, 'demo ctx receives EMPTY opts (all client cost-affecting overrides ignored)');
  } finally { h.server.close(); }
});

test('server: 501 no-backend does not debit; exhaustion 429; expired 401', async () => {
  // no ttsBackend -> 501 before reserve
  const ledger = provisionedLedger();
  const guard = createDemoBearerGuard({ expiresUnixSec: EXP(), maxPerMin: 500, ledger });
  const { server } = createLiveDemoServer({ apiBaseUrl: 'https://api.invalid', fetch: async () => { throw new Error('x'); }, run: () => '{}', knownSessionIdsFor: async () => ['sid'], demoBearer: BEARER, demoGuard: guard });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const base = 'http://127.0.0.1:' + server.address().port;
  try {
    const r = await fetch(base + '/tts', { method: 'POST', headers: AUTH, body: JSON.stringify({ text: 'hi' }) });
    assert.equal(r.status, 501); assert.equal(guard.stats().used.calls, 0, '501 no-backend did not debit');
  } finally { server.close(); }
  const he = await boot({ guardOver: { expiresUnixSec: nowSec() - 1 } });
  try { assert.equal((await he.req('POST', '/tts', { text: 'x' })).status, 401); assert.equal(he.fetchCalls(), 0); } finally { he.server.close(); }
  const hx = await boot({ ledgerOver: { maxCalls: 1 } });
  try { assert.equal((await hx.req('POST', '/tts', { text: 'a' })).status, 200); assert.equal((await hx.req('POST', '/tts', { text: 'b' })).status, 429); } finally { hx.server.close(); }
});
