// live-demo.mjs — LOCAL live-write demo composition (the first real message before prod Lambda infra exists).
//
// Runs the REAL governed gateway — real SENTI-session auth (createSentiSessionVerifier → GET /auth/me) + the real
// /human-message client — both pointing at the REAL api, over an in-memory idempotency store + a DEV Ed25519 receipt key
// + a local http server. A REAL message LANDS in the live room authored as human-mrrcarter, with a real read-back.
//
// HONEST scope (nothing about the crypto is faked — clearly labeled):
//   - runtime is LOCAL (a LAN URL), not a deployed Lambda;
//   - idempotency is the in-memory store (single instance — fine for a demo, not multi-instance exactly-once);
//   - the ActionReceipt is signed by a DEV Ed25519 key (a REAL signature, verifiable against the dev pubkey) — NOT the
//     prod KMS key. It is a dev key, not a fake wedge.
import http from 'node:http';
import { createPublicKey } from 'node:crypto';
import { openSync, writeSync, fsyncSync, closeSync, readFileSync, existsSync, unlinkSync, statSync } from 'node:fs';
import { createGateway } from './handlers.mjs';
import { createInMemoryStore } from './store.mjs';
import { createSentiSessionVerifier } from './senti-session-verifier.mjs';
import { createHumanMessageClient } from './human-message-client.mjs';
import { generateSigningKeypair } from './bundle.mjs';

const MAX_BODY = 256 * 1024;
const isJsonContentType = (v) => typeof v === 'string' && v.split(';')[0].trim().toLowerCase() === 'application/json';

// Hard ceilings for the PUBLIC demo capability config. A bound is valid only if it is a strictly-positive SAFE INTEGER
// within its ceiling; anything else (NaN, Infinity, fractional, negative, zero, absurdly huge) is INVALID → the caller
// (createLiveDemoServer) REFUSES to enable the capability at boot (fail-closed), rather than silently coercing.
export const DEMO_LIMIT_CEILINGS = Object.freeze({ expiryHorizonSec: 30 * 24 * 3600, maxCalls: 100000, maxBytes: 100 * 1024 * 1024, maxPerMin: 10000 });
const safeIntWithin = (x, max) => (Number.isSafeInteger(x) && x > 0 && x <= max) ? x : null;

/** Validate demo-capability config to strict positive safe integers within ceilings. Returns a normalized object or
 *  { valid:false, reason } — the server refuses to serve the capability if invalid (boot refusal). */
export function validateDemoConfig({ expiresUnixSec, maxPerMin, maxCalls, maxBytes, nowSec } = {}) {
  const errs = [];
  const exp = safeIntWithin(expiresUnixSec, Number.MAX_SAFE_INTEGER);
  if (exp === null) errs.push('expiry not a positive safe integer');
  else if (Number.isSafeInteger(nowSec) && exp > nowSec + DEMO_LIMIT_CEILINGS.expiryHorizonSec) errs.push('expiry beyond max horizon');
  else if (Number.isSafeInteger(nowSec) && exp <= nowSec) errs.push('expiry already passed');
  const perMin = safeIntWithin(maxPerMin, DEMO_LIMIT_CEILINGS.maxPerMin);
  if (perMin === null) errs.push('maxPerMin invalid');
  const calls = safeIntWithin(maxCalls, DEMO_LIMIT_CEILINGS.maxCalls);
  if (calls === null) errs.push('maxCalls invalid');
  const bytes = safeIntWithin(maxBytes, DEMO_LIMIT_CEILINGS.maxBytes);
  if (bytes === null) errs.push('maxBytes invalid');
  if (errs.length) return { valid: false, reason: errs.join('; ') };
  return { valid: true, expiresUnixSec: exp, maxPerMin: perMin, maxCalls: calls, maxBytes: bytes };
}

// ---- crash-safe, cross-process reservation ledger (append-only + O_EXCL lock + fsync; fail-closed) ----
function sleepMs(ms) { try { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms); } catch { /* */ } }
function acquireLock(lockPath, nowMs, { retries = 100, backoffMs = 5, staleMs = 5000 } = {}) {
  for (let i = 0; i < retries; i++) {
    try { return openSync(lockPath, 'wx'); } // O_CREAT|O_EXCL — atomic cross-process mutex
    catch (e) {
      if (e && e.code === 'EEXIST') {
        try { if (nowMs() - statSync(lockPath).mtimeMs > staleMs) { unlinkSync(lockPath); continue; } } catch { /* */ }
        sleepMs(backoffMs); continue;
      }
      throw e;
    }
  }
  throw new Error('lock timeout');
}
function releaseLock(fd, lockPath) { try { if (fd != null) closeSync(fd); } catch { /* */ } try { unlinkSync(lockPath); } catch { /* */ } }
function fsyncDir(dir) { let fd; try { fd = openSync(dir, 'r'); fsyncSync(fd); } catch { /* some FS disallow dir fsync */ } finally { try { if (fd !== undefined) closeSync(fd); } catch { /* */ } } }
function appendLineDurable(path, line) { const fd = openSync(path, 'a'); try { writeSync(fd, line + '\n'); fsyncSync(fd); } finally { closeSync(fd); } }
// Reads the append-only ledger. Missing/empty => fresh {0,0}. THROWS (⇒ caller fail-closed DENY) on corrupt/truncated/
// tampered content, header/fp mismatch, or non-contiguous seq (rollback/tamper detection). Never silently resets.
function readLedger(logPath, fingerprint) {
  if (!existsSync(logPath)) return { calls: 0, bytes: 0, hasHeader: false };
  const lines = readFileSync(logPath, 'utf8').split('\n').filter((l) => l.length > 0);
  if (lines.length === 0) return { calls: 0, bytes: 0, hasHeader: false };
  const header = JSON.parse(lines[0]); // throws on corrupt
  if (!header || header.v !== 1 || header.fp !== fingerprint) throw new Error('ledger header mismatch');
  let calls = 0, bytes = 0;
  for (let i = 1; i < lines.length; i++) {
    const r = JSON.parse(lines[i]); // throws on corrupt line
    if (!r || !Number.isSafeInteger(r.bytes) || r.bytes < 0 || r.seq !== i) throw new Error('ledger line invalid (tamper/rollback)');
    calls += 1; bytes += r.bytes;
  }
  return { calls, bytes, hasHeader: true };
}

/**
 * Bounds the PUBLIC login-free demo bearer (embedded in a sideloaded .ipa ⇒ EXTRACTABLE ⇒ SERVER-bounded, independent of
 * client honesty). ONE entry point: reserveTts(bytes), called from handleTts AFTER scope + 8192-byte validation and
 * IMMEDIATELY before the provider. Enforces, in order: absolute expiry (401, >=), per-60s anti-abuse rate (429), and a
 * crash-safe cross-process persistent lifetime call+BYTE reservation (429 exhausted / 503 on any I/O or corruption).
 * Reserve-before-provider; NEVER refunded (provider spend is ambiguous on timeout/error/crash). Config MUST be
 * pre-validated (validateDemoConfig) — this constructor trusts finite safe-integer inputs.
 * @param {{ expiresUnixSec:number, maxPerMin:number, maxCalls:number, maxBytes:number, fingerprint:string, persistDir:string, now?:Function }} opts
 */
export function createDemoBearerGuard({ expiresUnixSec, maxPerMin, maxCalls, maxBytes, fingerprint = '', persistDir = '', now = () => Date.now() } = {}) {
  const expSec = expiresUnixSec, perMin = maxPerMin, totCalls = maxCalls, totBytes = maxBytes;
  const paths = (persistDir && fingerprint)
    ? { log: `${persistDir}/pocket-demo-usage-${fingerprint}.log`, lock: `${persistDir}/pocket-demo-usage-${fingerprint}.lock`, dir: persistDir }
    : null;
  let windowStartMs = -Infinity, windowCount = 0;

  function reservePersistent(bytes) {
    if (!paths) return { ok: false, status: 503, error: 'demo_budget_unconfigured' };
    if (!totCalls || !totBytes) return { ok: false, status: 429, error: 'demo_usage_exhausted' };
    let fd = null;
    try { fd = acquireLock(paths.lock, now); } catch { return { ok: false, status: 503, error: 'demo_budget_locked' }; }
    try {
      const cur = readLedger(paths.log, fingerprint); // throws on corrupt/tamper -> caught -> 503 (fail-closed)
      if (cur.calls >= totCalls || cur.bytes + bytes > totBytes) return { ok: false, status: 429, error: 'demo_usage_exhausted' };
      if (!cur.hasHeader) appendLineDurable(paths.log, JSON.stringify({ v: 1, fp: fingerprint, maxCalls: totCalls, maxBytes: totBytes, expiry: expSec }));
      appendLineDurable(paths.log, JSON.stringify({ seq: cur.calls + 1, bytes, ts: Math.floor(now() / 1000) }));
      fsyncDir(paths.dir);
      return { ok: true, remainingCalls: totCalls - (cur.calls + 1), remainingBytes: totBytes - (cur.bytes + bytes) };
    } catch { return { ok: false, status: 503, error: 'demo_budget_io' }; } // ANY read/write/fsync error -> fail-closed
    finally { releaseLock(fd, paths.lock); }
  }

  return {
    // Called ONLY from handleTts for the demo ctx, after all local validation, immediately before the provider.
    reserveTts(bytes) {
      const nowMs = now(), nowSec = Math.floor(nowMs / 1000);
      if (!expSec || nowSec >= expSec) return { ok: false, status: 401, error: 'demo_capability_expired' }; // >= boundary
      if (nowMs - windowStartMs >= 60_000) { windowStartMs = nowMs; windowCount = 0; }
      if (!perMin || windowCount >= perMin) {
        const retryAfterSec = Math.max(1, Math.ceil((windowStartMs + 60_000 - nowMs) / 1000));
        return { ok: false, status: 429, error: 'demo_rate_limited', retryAfterSec };
      }
      const res = reservePersistent(nonNegInt(bytes));
      if (!res.ok) return res;
      windowCount += 1; // count the anti-abuse rate only on a fully reserved /tts
      return res;
    },
    stats() { let used = { calls: 0, bytes: 0 }; try { const c = paths ? readLedger(paths.log, fingerprint) : { calls: 0, bytes: 0 }; used = { calls: c.calls, bytes: c.bytes }; } catch { used = { calls: NaN, bytes: NaN }; } return { expSec, perMin, totCalls, totBytes, used, persisted: !!paths }; },
  };
}
const nonNegInt = (x) => (Number.isSafeInteger(x) && x >= 0) ? x : 0;

/** Compose the REAL governed gateway for a LOCAL live-write demo. @returns the gateway ({ handle }). */
export function createLiveDemoGateway(opts = {}) {
  const { apiBaseUrl, fetch = globalThis.fetch, run, knownSessionIdsFor, signingKey, signingKeyId = 'demo-live-receipt-key', now, reason, brief, ttsBackend, demoGuard } = opts;
  if (!apiBaseUrl) throw new Error('createLiveDemoGateway: apiBaseUrl (REAL api origin) is required');
  if (typeof fetch !== 'function') throw new Error('createLiveDemoGateway: fetch is required');
  if (typeof run !== 'function') throw new Error('createLiveDemoGateway: run (sl-runner for reads/read-back) is required');
  if (typeof knownSessionIdsFor !== 'function') throw new Error('createLiveDemoGateway: knownSessionIdsFor is required');
  const key = signingKey || generateSigningKeypair().privateKey; // DEV key: a REAL ed25519 signature, NOT prod KMS

  // LOGIN-FREE demo bearer → a pocket:voice-ONLY ctx (only /tts; every other route is 403 at the scope-check before any
  // upstream). The quantitative bounds (expiry/rate/lifetime call+byte budget) are enforced by demoGuard.reserveTts,
  // injected as deps.demoReserve and called INSIDE handleTts after validation, immediately before the provider.
  const realVerifyToken = createSentiSessionVerifier({ fetch, apiBaseUrl });
  const DEMO_CTX = Object.freeze({ humanId: 'demo-user', principal: 'pocket.demo', scopes: Object.freeze(['pocket:voice']), site: null, tokenClaims: Object.freeze({}) });
  const demoBearerValue = opts.demoBearer || process.env.POCKET_DEMO_BEARER || '';
  const verifyToken = async (headers) => {
    const authz = headers && (headers.authorization || headers.Authorization);
    if (demoBearerValue && authz === 'Bearer ' + demoBearerValue) return DEMO_CTX;
    return realVerifyToken(headers);
  };

  const gateway = createGateway({
    verifyToken,
    postHumanMessage: createHumanMessageClient({ fetch, apiBaseUrl }),
    store: createInMemoryStore(),
    run,
    knownSessionIdsFor,
    signingKey: key, signingKeyId,
    reason, brief, ttsBackend,
    // Demo /tts reservation: fires ONLY for the demo ctx (handleTts checks ctx.principal), after validation, before provider.
    demoReserve: demoGuard ? ((_ctx, bytes) => demoGuard.reserveTts(bytes)) : undefined,
    agent: 'claude-pocket-relay',
    now,
  });
  gateway.demoPublicKeyB64url = createPublicKey(key).export({ format: 'jwk' }).x;
  return gateway;
}

/** Local http server around the live-demo gateway. NO demo-specific edge logic — the capability's expiry/rate/budget are
 *  enforced inside handleTts (after validation, before the provider) so /health, 404, malformed, or scope-denied traffic
 *  never touches the bearer's rate or budget. @returns {{ server:http.Server }} */
export function createLiveDemoServer(opts = {}, { maxBody = MAX_BODY } = {}) {
  const gateway = createLiveDemoGateway(opts);
  const publicKeyB64url = gateway.demoPublicKeyB64url;
  const server = http.createServer((req, res) => {
    req.setTimeout(15_000, () => { try { res.writeHead(408).end('{"error":"request_timeout"}'); } catch { /* */ } req.destroy(); });
    const u = new URL(req.url, 'http://x');
    const send = (status, obj, hdrs) => { if (res.headersSent) return; res.writeHead(status, { 'content-type': 'application/json', ...(hdrs || {}) }); res.end(Buffer.isBuffer(obj) ? obj : JSON.stringify(obj)); };
    if (u.pathname === '/demo-pubkey') return send(200, { publicKeyBase64url: publicKeyB64url, signingKeyId: opts.signingKeyId || 'demo-live-receipt-key', alg: 'Ed25519' });
    const authz = req.headers.authorization;
    if (u.pathname !== '/health' && (typeof authz !== 'string' || !authz.startsWith('Bearer '))) return send(401, { error: 'unauthorized' }, { 'www-authenticate': 'Bearer' });
    if (req.method === 'POST') {
      if (!isJsonContentType(req.headers['content-type'])) return send(415, { error: 'unsupported_media_type' });
      if (Number(req.headers['content-length'] || 0) > maxBody) return send(413, { error: 'payload_too_large' });
    }
    const chunks = []; let bytes = 0; let killed = false;
    req.on('data', (c) => { bytes += c.length; if (bytes > maxBody) { killed = true; send(413, { error: 'payload_too_large' }); req.destroy(); return; } chunks.push(c); });
    req.on('aborted', () => { killed = true; });
    req.on('error', () => { if (!killed) send(400, { error: 'bad_request' }); });
    req.on('end', async () => {
      if (killed) return;
      const body = Buffer.concat(chunks).toString('utf8');
      const headers = {}; for (const [k, v] of Object.entries(req.headers)) headers[k.toLowerCase()] = v;
      const query = Object.fromEntries(u.searchParams.entries());
      try {
        const out = await gateway.handle({ method: req.method, path: u.pathname, query, headers, body: req.method === 'POST' ? body : undefined });
        send(out.status, out.body, out.headers);
      } catch { send(500, { error: 'internal' }); }
    });
  });
  return { server, publicKeyB64url };
}
