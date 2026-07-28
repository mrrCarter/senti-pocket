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
// Everything else — token validation, membership, the governed-write invariants, the landed message, the read-back — is
// the SAME gated code path as prod (app.mjs); only the three bindings above differ.
import http from 'node:http';
import { createPublicKey } from 'node:crypto';
import { readFileSync, writeFileSync, renameSync, mkdirSync } from 'node:fs';
import { createGateway } from './handlers.mjs';
import { createInMemoryStore } from './store.mjs';
import { createSentiSessionVerifier } from './senti-session-verifier.mjs';
import { createHumanMessageClient } from './human-message-client.mjs';
import { generateSigningKeypair } from './bundle.mjs';

const MAX_BODY = 256 * 1024;
const isJsonContentType = (v) => typeof v === 'string' && v.split(';')[0].trim().toLowerCase() === 'application/json';

// A publicly-extractable capability's bounds must be FINITE + POSITIVE or they are meaningless. Number(env) yields NaN
// for junk and Infinity for "1e999"; both slip past naive `<=0` / `>` checks and ADMIT (fail-OPEN). So every numeric
// bound is coerced here: non-finite or non-positive => 0, and 0 is treated everywhere as fail-CLOSED (deny).
const finPos = (x) => (Number.isFinite(x) && x > 0) ? x : 0;
const nonNeg = (x) => (Number.isFinite(x) && x >= 0) ? Math.floor(x) : 0;

// Restart-safe usage store for the demo capability, keyed by capability fingerprint. In-memory counters reset on
// restart and multiply per instance — so the lifetime call/char BUDGET is persisted to disk (single demo instance),
// atomic via write-temp + rename. A NEW capability (new fingerprint) starts fresh; the SAME capability's spend persists.
function loadUsage(path) {
  try { const j = JSON.parse(readFileSync(path, 'utf8')); return { calls: nonNeg(j.calls), chars: nonNeg(j.chars) }; }
  catch { return { calls: 0, chars: 0 }; }
}
function saveUsage(path, usage) {
  const tmp = `${path}.${process.pid}.tmp`;
  writeFileSync(tmp, JSON.stringify({ calls: nonNeg(usage.calls), chars: nonNeg(usage.chars), updatedAt: usage.updatedAt || 0 }), { mode: 0o600 });
  renameSync(tmp, path); // atomic replace on POSIX
}

/**
 * Bounds the PUBLIC login-free demo bearer (embedded in a sideloaded .ipa ⇒ EXTRACTABLE ⇒ must be SERVER-bounded,
 * independent of client honesty). TWO planes, deliberately separate:
 *   - admitRequest(): EDGE gate for EVERY demo-bearer request — absolute expiry (401) + per-60s ANTI-ABUSE rate (429).
 *     In-memory (a short-window throttle resetting on restart is acceptable; it is NOT the budget).
 *   - debitTts(textBytes): called ONLY for an ACCEPTED POST /tts — a RESTART-SAFE, fingerprint-keyed lifetime call+CHAR
 *     budget (429 when exhausted). Denied / malformed / non-/tts traffic never reaches here, so abuse cannot drain the
 *     legit /tts quota (metered separately from abuse).
 * ALL numeric bounds are finite-positive-validated ⇒ non-finite/non-positive config is fail-CLOSED (deny), not admit.
 * @param {{ expiresUnixSec?:number, maxPerMin?:number, maxTotalCalls?:number, maxTotalChars?:number, fingerprint?:string, persistDir?:string, now?:Function }} opts
 */
export function createDemoBearerGuard({ expiresUnixSec = 0, maxPerMin = 0, maxTotalCalls = 0, maxTotalChars = 0, fingerprint = '', persistDir = '', now = () => Date.now() } = {}) {
  const expSec = finPos(expiresUnixSec);
  const perMin = finPos(maxPerMin);
  const totCalls = finPos(maxTotalCalls);
  const totChars = finPos(maxTotalChars);
  const usagePath = (persistDir && fingerprint) ? `${persistDir}/pocket-demo-usage-${fingerprint}.json` : '';
  let windowStartMs = -Infinity;
  let windowCount = 0;
  return {
    // EDGE: expiry(401) + anti-abuse rate(429). Called for EVERY demo-bearer request; does NOT touch the persistent budget.
    admitRequest() {
      const nowMs = now();
      const nowSec = Math.floor(nowMs / 1000);
      if (!expSec || nowSec >= expSec) return { ok: false, status: 401, error: 'demo_capability_expired' }; // >= : reject AT the expiry second; !expSec catches unset/NaN/Infinity(→0)
      if (nowMs - windowStartMs >= 60_000) { windowStartMs = nowMs; windowCount = 0; }
      if (!perMin || windowCount >= perMin) {
        const retryAfterSec = Math.max(1, Math.ceil((windowStartMs + 60_000 - nowMs) / 1000));
        return { ok: false, status: 429, error: 'demo_rate_limited', retryAfterSec };
      }
      windowCount += 1;
      return { ok: true };
    },
    // /tts PATH: called ONLY for an accepted POST /tts, with the request's UTF-8 text byte length. Restart-safe,
    // fingerprint-keyed lifetime call + character budget. Fail-CLOSED if unconfigured (no persistence / unset caps).
    debitTts(textBytes) {
      const bytes = nonNeg(textBytes);
      if (!usagePath) return { ok: false, status: 503, error: 'demo_budget_unconfigured' };
      if (!totCalls || !totChars) return { ok: false, status: 429, error: 'demo_usage_exhausted' };
      const u = loadUsage(usagePath);
      if (u.calls >= totCalls || u.chars + bytes > totChars) return { ok: false, status: 429, error: 'demo_usage_exhausted' };
      u.calls += 1; u.chars += bytes; u.updatedAt = Math.floor(now() / 1000);
      saveUsage(usagePath, u);
      return { ok: true, remainingCalls: totCalls - u.calls, remainingChars: totChars - u.chars };
    },
    // Non-mutating snapshot for the redacted startup/telemetry line (NO secret).
    stats() { const u = usagePath ? loadUsage(usagePath) : { calls: 0, chars: 0 }; return { expSec, perMin, totCalls, totChars, used: u, usagePath: usagePath ? true : false }; },
  };
}

/**
 * Compose the REAL governed gateway for a LOCAL live-write demo.
 * @param {{ apiBaseUrl:string, fetch?:Function, run:Function, knownSessionIdsFor:Function, signingKey?:any, signingKeyId?:string }} opts
 *   - apiBaseUrl: the REAL api origin (e.g. https://api.sentinelayer.com) — /auth/me + /human-message target it.
 *   - run: a senti sl-runner for reads / the read-back (real, so the read-back sees the live room).
 *   - knownSessionIdsFor(humanId): membership (the sessions the human may write to).
 *   - signingKey: OPTIONAL dev Ed25519 private key; generated if absent (dev key, labeled — never the prod KMS key).
 * @returns the gateway ({ handle }).
 */
export function createLiveDemoGateway(opts = {}) {
  const { apiBaseUrl, fetch = globalThis.fetch, run, knownSessionIdsFor, signingKey, signingKeyId = 'demo-live-receipt-key', now, reason, brief, ttsBackend } = opts;
  if (!apiBaseUrl) throw new Error('createLiveDemoGateway: apiBaseUrl (REAL api origin) is required');
  if (typeof fetch !== 'function') throw new Error('createLiveDemoGateway: fetch is required');
  if (typeof run !== 'function') throw new Error('createLiveDemoGateway: run (sl-runner for reads/read-back) is required');
  if (typeof knownSessionIdsFor !== 'function') throw new Error('createLiveDemoGateway: knownSessionIdsFor is required');
  const key = signingKey || generateSigningKeypair().privateKey; // DEV key: a REAL ed25519 signature, NOT prod KMS

  // LOGIN-FREE demo bearer: a fixed rotated bearer (opts.demoBearer||POCKET_DEMO_BEARER) grants a TIGHTLY-SCOPED demo
  // ctx WITHOUT calling the real /auth/me. Scope is pocket:voice ONLY (the /tts route) — because this capability ships
  // PUBLICLY in a sideloaded .ipa and is extractable, it grants the MINIMUM viable surface: only text->speech. It does
  // NOT carry sessions:read (/sync,/checkpoint,/answer,/brief,/deck), nor sessions:write (/actions/execute), nor
  // pocket:dial (/dial*), so EVERY one of those is scope-DENIED (403) inside the gateway before any upstream call. ANY
  // other token falls through to the real verifier unchanged. Match is EXACT + case-sensitive. Expiry/rate + the
  // lifetime call/char budget on this capability are enforced at the SERVER edge / /tts path by createDemoBearerGuard.
  const realVerifyToken = createSentiSessionVerifier({ fetch, apiBaseUrl }); // validate a REAL SENTI token via /auth/me (no secret held)
  const DEMO_CTX = Object.freeze({ humanId: 'demo-user', principal: 'pocket.demo', scopes: Object.freeze(['pocket:voice']), site: null, tokenClaims: Object.freeze({}) });
  const demoBearerValue = opts.demoBearer || process.env.POCKET_DEMO_BEARER || ''; // SAME source the server-edge guard uses, so scope + bounds describe ONE capability
  const verifyToken = async (headers) => {
    const authz = headers && (headers.authorization || headers.Authorization);
    if (demoBearerValue && authz === 'Bearer ' + demoBearerValue) return DEMO_CTX; // ROTATED bearer; hardcoded pocket-demo is REVOKED
    return realVerifyToken(headers); // every OTHER token: unchanged real senti-session verifier
  };

  const gateway = createGateway({
    verifyToken,   // validate the REAL SENTI token via /auth/me (no secret held)
    postHumanMessage: createHumanMessageClient({ fetch, apiBaseUrl }),// post to the REAL /api/v1/sessions/{id}/human-message
    store: createInMemoryStore(),                                     // single-instance idempotency (demo)
    run,                                                              // real reads / read-back against the live room
    knownSessionIdsFor,
    signingKey: key, signingKeyId,
    reason,                                                           // optional Gemma-backed /answer (real Gemma over local Ollama in the demo)
    brief,                                                            // optional Gemma-backed /brief
    ttsBackend, // optional Cartesia TTS backend -> POST /tts (pocket:voice)
    agent: 'claude-pocket-relay',
    now,                                                              // optional injected clock (tests / freshness window)
  });
  // EXPOSE the dev PUBLIC key (raw ed25519 x, base64url) so the app + harness can VERIFY the ActionReceipt signature at
  // render — never show "sent" unless signatureState(gatewayPublicKeyBase64url)==.verified (a forged .posted must NOT
  // render sent). Closes the Forge/Warden #2 gap: generateSigningKeypair otherwise DISCARDS the pubkey, leaving the
  // receipt-sig unverifiable. The private key stays on the host; only the public key is exposed (a pubkey is public).
  gateway.demoPublicKeyB64url = createPublicKey(key).export({ format: 'jwk' }).x;
  return gateway;
}

/**
 * Local http server around the live-demo gateway. Auth is DELEGATED to the gateway's SENTI verifier (GET /auth/me); the
 * server only requires a Bearer header present + bounds the body BEFORE buffering. The PUBLIC demo capability
 * (opts.demoBearer) is bounded by opts.demoGuard: admitRequest() at the edge (expiry/rate) BEFORE gateway.handle, and
 * debitTts() on an accepted POST /tts (lifetime call/char budget). Real SENTI tokens are untouched.
 * @returns {{ server:http.Server }}
 */
export function createLiveDemoServer(opts = {}, { maxBody = MAX_BODY } = {}) {
  const gateway = createLiveDemoGateway(opts);
  const publicKeyB64url = gateway.demoPublicKeyB64url;
  const demoBearer = opts.demoBearer || process.env.POCKET_DEMO_BEARER || '';
  const demoGuard = opts.demoGuard; // createDemoBearerGuard(...) — bounds the PUBLIC extractable demo capability
  const server = http.createServer((req, res) => {
    req.setTimeout(15_000, () => { try { res.writeHead(408).end('{"error":"request_timeout"}'); } catch { /* */ } req.destroy(); });
    const u = new URL(req.url, 'http://x');
    const send = (status, obj, hdrs) => { if (res.headersSent) return; res.writeHead(status, { 'content-type': 'application/json', ...(hdrs || {}) }); res.end(Buffer.isBuffer(obj) ? obj : JSON.stringify(obj)); };

    // Public (no auth — a pubkey is public): the receipt-signing key so the app can verify ActionReceipt sigs at render.
    if (u.pathname === '/demo-pubkey') return send(200, { publicKeyBase64url: publicKeyB64url, signingKeyId: opts.signingKeyId || 'demo-live-receipt-key', alg: 'Ed25519' });

    // Cheap pre-checks BEFORE buffering: real token validation happens inside gateway.handle (verifyToken → /auth/me).
    const authz = req.headers.authorization;
    if (u.pathname !== '/health' && (typeof authz !== 'string' || !authz.startsWith('Bearer '))) return send(401, { error: 'unauthorized' }, { 'www-authenticate': 'Bearer' });

    // PUBLIC demo-capability EDGE gate: absolute expiry(401) + anti-abuse rate(429) for ANY demo-bearer request, BEFORE
    // buffering / gateway.handle. A set bearer with no guard is fail-closed (503). Real SENTI tokens skip this block.
    const isDemo = demoBearer && authz === 'Bearer ' + demoBearer;
    if (isDemo) {
      const verdict = demoGuard ? demoGuard.admitRequest() : { ok: false, status: 503, error: 'demo_capability_unconfigured' };
      if (!verdict.ok) return send(verdict.status, { error: verdict.error }, verdict.retryAfterSec ? { 'retry-after': String(verdict.retryAfterSec) } : undefined);
    }

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
      const body = Buffer.concat(chunks).toString('utf8'); // BYTE-bounded above
      // Demo /tts lifetime call+CHAR budget: debit ONLY an accepted demo-bearer POST /tts (has a text string). Denied /
      // malformed / non-/tts traffic never debits — abuse cannot drain Carter's public quota. Debit is restart-safe.
      if (isDemo && req.method === 'POST' && u.pathname === '/tts' && demoGuard) {
        let textBytes = 0;
        try { const p = JSON.parse(body); if (p && typeof p.text === 'string') textBytes = Buffer.byteLength(p.text, 'utf8'); } catch { /* handler will 400 the malformed body */ }
        if (textBytes > 0) {
          const deb = demoGuard.debitTts(textBytes);
          if (!deb.ok) return send(deb.status, { error: deb.error });
        }
      }
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
