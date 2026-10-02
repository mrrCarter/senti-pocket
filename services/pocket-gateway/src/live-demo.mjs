// live-demo.mjs — LOCAL live-write demo composition (the first real message before prod Lambda infra exists).
//
// Runs the REAL governed gateway — real SENTI-session auth (createSentiSessionVerifier → GET /auth/me) + the real
// /human-message client — both pointing at the REAL api, over an in-memory idempotency store + a DEV Ed25519 receipt key
// + a local http server. A REAL message LANDS in the live room authored as human-mrrcarter, with a real read-back.
//
// HONEST scope: runtime LOCAL (not a deployed Lambda); idempotency in-memory (single instance); the ActionReceipt is
// signed by a DEV Ed25519 key (a REAL signature, verifiable against the dev pubkey) — NOT the prod KMS key.
import http from 'node:http';
import { createPublicKey } from 'node:crypto';
import { createGateway } from './handlers.mjs';
import { createInMemoryStore } from './store.mjs';
import { createSentiSessionVerifier } from './senti-session-verifier.mjs';
import { createHumanMessageClient } from './human-message-client.mjs';
import { generateSigningKeypair } from './bundle.mjs';

const MAX_BODY = 256 * 1024;
const isJsonContentType = (v) => typeof v === 'string' && v.split(';')[0].trim().toLowerCase() === 'application/json';

// Hard ceilings for the PUBLIC demo capability config. A bound is valid only if it is a strictly-positive SAFE INTEGER
// within its ceiling; anything else (NaN, Infinity, fractional, negative, zero, huge) is INVALID → the server REFUSES to
// enable the capability at boot (fail-closed), never coercing. Ceilings also keep expiry×1000 well inside Date range.
export const DEMO_LIMIT_CEILINGS = Object.freeze({ expiryHorizonSec: 30 * 24 * 3600, maxCalls: 100000, maxBytes: 100 * 1024 * 1024, maxPerMin: 10000 });
const safeIntWithin = (x, max) => (Number.isSafeInteger(x) && x > 0 && x <= max) ? x : null;

/** Validate demo-capability config to strict positive safe integers within ceilings + expiry horizon + now<expiry.
 *  Returns a normalized object or { valid:false, reason }. The server refuses the capability if invalid (boot refusal). */
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

/**
 * Bounds the PUBLIC login-free demo bearer. ONE entry point: reserveTts(bytes), called from handleTts AFTER scope + the
 * 8192-byte validation and IMMEDIATELY before the provider. Enforces, in order: absolute expiry (401, >=, re-checked
 * here right before the provider), per-60s anti-abuse rate (429), then a crash/concurrency-safe fail-closed persistent
 * reservation (ledger.reserve → 429 exhausted / 503 on any storage/lock/corruption). Reserve-before-provider; NEVER
 * refunded. Config (expiry/rate) MUST be pre-validated; `ledger` MUST be pre-provisioned (createReservationLedger).
 * @param {{ expiresUnixSec:number, maxPerMin:number, ledger:object, now?:Function }} opts
 */
export function createDemoBearerGuard({ expiresUnixSec, maxPerMin, ledger, now = () => Date.now() } = {}) {
  const expSec = expiresUnixSec, perMin = maxPerMin;
  let windowStartMs = -Infinity, windowCount = 0;
  return {
    reserveTts(bytes) {
      const nowMs = now(), nowSec = Math.floor(nowMs / 1000);
      if (!expSec || nowSec >= expSec) return { ok: false, status: 401, error: 'demo_capability_expired' }; // >= boundary; re-checked before provider
      if (nowMs - windowStartMs >= 60_000) { windowStartMs = nowMs; windowCount = 0; }
      if (!perMin || windowCount >= perMin) {
        const retryAfterSec = Math.max(1, Math.ceil((windowStartMs + 60_000 - nowMs) / 1000));
        return { ok: false, status: 429, error: 'demo_rate_limited', retryAfterSec };
      }
      if (!ledger) return { ok: false, status: 503, error: 'demo_budget_unconfigured' };
      const res = ledger.reserve(bytes);
      if (!res.ok) return res;
      windowCount += 1; // count anti-abuse rate only on a fully reserved /tts
      return res;
    },
    stats() { return { expSec, perMin, used: ledger ? ledger.stats() : { calls: NaN, bytes: NaN, provisioned: false } }; },
  };
}

/** Compose the REAL governed gateway for a LOCAL live-write demo. @returns the gateway ({ handle }). */
export function createLiveDemoGateway(opts = {}) {
  const { apiBaseUrl, fetch = globalThis.fetch, run, knownSessionIdsFor, signingKey, signingKeyId = 'demo-live-receipt-key', now, reason, brief, ttsBackend, demoGuard } = opts;
  if (!apiBaseUrl) throw new Error('createLiveDemoGateway: apiBaseUrl (REAL api origin) is required');
  if (typeof fetch !== 'function') throw new Error('createLiveDemoGateway: fetch is required');
  if (typeof run !== 'function') throw new Error('createLiveDemoGateway: run (sl-runner for reads/read-back) is required');
  if (typeof knownSessionIdsFor !== 'function') throw new Error('createLiveDemoGateway: knownSessionIdsFor is required');
  const key = signingKey || generateSigningKeypair().privateKey; // DEV key: a REAL ed25519 signature, NOT prod KMS

  // LOGIN-FREE demo bearer → a pocket:voice-ONLY ctx (only /tts; every other route 403 at the scope-check before any
  // upstream). The quantitative bounds are enforced by demoGuard.reserveTts, injected as deps.demoReserve and called
  // INSIDE handleTts after validation, immediately before the provider. A demo ctx with NO reserve fn is fail-closed
  // (503) in handleTts — the safe composition is UNSKIPPABLE (you cannot serve demo /tts without a provisioned guard).
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
    demoReserve: demoGuard ? ((_ctx, bytes) => demoGuard.reserveTts(bytes)) : undefined,
    agent: 'claude-pocket-relay',
    now,
  });
  gateway.demoPublicKeyB64url = createPublicKey(key).export({ format: 'jwk' }).x;
  return gateway;
}

/** Local http server around the live-demo gateway. NO demo-specific edge logic — the capability's expiry/rate/budget are
 *  enforced inside handleTts (after validation, before the provider). @returns {{ server:http.Server }} */
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
