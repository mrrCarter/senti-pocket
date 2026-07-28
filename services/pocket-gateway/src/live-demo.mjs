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
import { createGateway } from './handlers.mjs';
import { createInMemoryStore } from './store.mjs';
import { createSentiSessionVerifier } from './senti-session-verifier.mjs';
import { createHumanMessageClient } from './human-message-client.mjs';
import { generateSigningKeypair } from './bundle.mjs';

const MAX_BODY = 256 * 1024;
const isJsonContentType = (v) => typeof v === 'string' && v.split(';')[0].trim().toLowerCase() === 'application/json';

/**
 * Bounds the PUBLIC login-free demo bearer. That capability is embedded in a sideloaded .ipa, so it is EXTRACTABLE by
 * anyone who has the app — it must therefore be tightly contained at the SERVER, independent of any client honesty:
 *   - an ABSOLUTE server-enforced expiry (a wall-clock deadline, NOT "we'll revoke it manually"),
 *   - a hard TOTAL-usage cap (a lifetime call budget for the capability),
 *   - a per-60s RATE cap.
 * ALL defaults are FAIL-CLOSED (0 => already expired / already exhausted) so a MISCONFIGURED deploy denies rather than
 * over-grants. State is in-memory (single demo instance). `admit()` is called ONLY when the demo bearer matched, and
 * returns { ok:true } to proceed or { ok:false, status, error, retryAfterSec? } to reject at the edge (zero upstream).
 * @param {{ expiresUnixSec?:number, maxTotal?:number, maxPerMin?:number, now?:Function }} opts
 */
export function createDemoBearerGuard({ expiresUnixSec = 0, maxTotal = 0, maxPerMin = 0, now = () => Date.now() } = {}) {
  let total = 0;
  let windowStartMs = -Infinity; // first admit() opens a fresh 60s window
  let windowCount = 0;
  return {
    admit() {
      const nowMs = now();
      const nowSec = Math.floor(nowMs / 1000);
      // 1) ABSOLUTE expiry (fail-closed: unset/past => expired). Server wall-clock, not manual revocation.
      if (!expiresUnixSec || nowSec > expiresUnixSec) return { ok: false, status: 401, error: 'demo_capability_expired' };
      // 2) lifetime TOTAL-usage cap (fail-closed: unset/<=0 => exhausted).
      if (maxTotal <= 0 || total >= maxTotal) return { ok: false, status: 429, error: 'demo_usage_exhausted' };
      // 3) per-60s RATE cap (fail-closed: unset/<=0 => rate-limited). Fixed, non-overlapping 60s windows.
      if (nowMs - windowStartMs >= 60_000) { windowStartMs = nowMs; windowCount = 0; }
      if (maxPerMin <= 0 || windowCount >= maxPerMin) {
        const retryAfterSec = Math.max(1, Math.ceil((windowStartMs + 60_000 - nowMs) / 1000));
        return { ok: false, status: 429, error: 'demo_rate_limited', retryAfterSec };
      }
      total += 1; windowCount += 1;
      return { ok: true, remainingTotal: maxTotal - total };
    },
    // Non-mutating snapshot for a startup/telemetry line (carries NO secret).
    stats() { return { total, maxTotal, maxPerMin, expiresUnixSec }; },
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

  // LOGIN-FREE demo bearer: a fixed rotated env bearer (POCKET_DEMO_BEARER) grants a TIGHTLY-SCOPED demo ctx WITHOUT
  // calling the real /auth/me. Scope is pocket:voice ONLY (the /tts route) — because this capability ships PUBLICLY in a
  // sideloaded .ipa and is extractable, it grants the MINIMUM viable surface: only text->speech. It does NOT carry
  // sessions:read (/sync,/checkpoint,/answer,/brief,/deck), nor sessions:write (/actions/execute), nor pocket:dial
  // (/dial*), so EVERY one of those is scope-DENIED (403) inside the gateway before any upstream call. ANY other token
  // falls through to the real verifier unchanged. Match is EXACT and case-sensitive on the full Authorization value.
  // Expiry / total-usage / rate bounds on this capability are enforced at the SERVER edge by createDemoBearerGuard
  // (createLiveDemoServer) — a publicly-extractable bearer cannot rely on client honesty, so the server bounds it.
  const realVerifyToken = createSentiSessionVerifier({ fetch, apiBaseUrl }); // validate a REAL SENTI token via /auth/me (no secret held)
  const DEMO_CTX = Object.freeze({ humanId: 'demo-user', principal: 'pocket.demo', scopes: Object.freeze(['pocket:voice']), site: null, tokenClaims: Object.freeze({}) });
  const demoBearerValue = opts.demoBearer || process.env.POCKET_DEMO_BEARER || ''; // SAME source the server-edge guard uses (createLiveDemoServer), so scope + bounds match one capability
  const verifyToken = async (headers) => {
    const authz = headers && (headers.authorization || headers.Authorization);
    if (demoBearerValue && authz === 'Bearer ' + demoBearerValue) return DEMO_CTX; // ROTATED bearer (opts.demoBearer||POCKET_DEMO_BEARER); hardcoded pocket-demo is REVOKED
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
 * server only requires a Bearer header present + bounds the body BEFORE buffering (mirrors demo-server's hardening).
 * The PUBLIC demo capability (opts.demoBearer) is additionally bounded at the edge by opts.demoGuard (expiry/total/rate)
 * BEFORE gateway.handle, so a spent/expired capability never reaches upstream. Real SENTI tokens are untouched.
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

    // PUBLIC demo-capability BOUNDING at the edge: if the extractable demo bearer is presented, enforce its server-side
    // absolute-expiry (401) + total-usage/rate (429) bounds BEFORE gateway.handle — so a spent/expired capability never
    // reaches upstream. A set bearer with NO guard is fail-closed (503 unconfigured). Real SENTI tokens skip this block.
    if (demoBearer && authz === 'Bearer ' + demoBearer) {
      const verdict = demoGuard ? demoGuard.admit() : { ok: false, status: 503, error: 'demo_capability_unconfigured' };
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
