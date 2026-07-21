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
 * Compose the REAL governed gateway for a LOCAL live-write demo.
 * @param {{ apiBaseUrl:string, fetch?:Function, run:Function, knownSessionIdsFor:Function, signingKey?:any, signingKeyId?:string }} opts
 *   - apiBaseUrl: the REAL api origin (e.g. https://api.sentinelayer.com) — /auth/me + /human-message target it.
 *   - run: a senti sl-runner for reads / the read-back (real, so the read-back sees the live room).
 *   - knownSessionIdsFor(humanId): membership (the sessions the human may write to).
 *   - signingKey: OPTIONAL dev Ed25519 private key; generated if absent (dev key, labeled — never the prod KMS key).
 * @returns the gateway ({ handle }).
 */
export function createLiveDemoGateway(opts = {}) {
  const { apiBaseUrl, fetch = globalThis.fetch, run, knownSessionIdsFor, signingKey, signingKeyId = 'demo-live-receipt-key', now, reason, brief } = opts;
  if (!apiBaseUrl) throw new Error('createLiveDemoGateway: apiBaseUrl (REAL api origin) is required');
  if (typeof fetch !== 'function') throw new Error('createLiveDemoGateway: fetch is required');
  if (typeof run !== 'function') throw new Error('createLiveDemoGateway: run (sl-runner for reads/read-back) is required');
  if (typeof knownSessionIdsFor !== 'function') throw new Error('createLiveDemoGateway: knownSessionIdsFor is required');
  const key = signingKey || generateSigningKeypair().privateKey; // DEV key: a REAL ed25519 signature, NOT prod KMS

  const gateway = createGateway({
    verifyToken: createSentiSessionVerifier({ fetch, apiBaseUrl }),   // validate the REAL SENTI token via /auth/me (no secret held)
    postHumanMessage: createHumanMessageClient({ fetch, apiBaseUrl }),// post to the REAL /api/v1/sessions/{id}/human-message
    store: createInMemoryStore(),                                     // single-instance idempotency (demo)
    run,                                                              // real reads / read-back against the live room
    knownSessionIdsFor,
    signingKey: key, signingKeyId,
    reason,                                                           // optional Gemma-backed /answer (real Gemma over local Ollama in the demo)
    brief,                                                            // optional Gemma-backed /brief
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
 * @returns {{ server:http.Server }}
 */
export function createLiveDemoServer(opts = {}, { maxBody = MAX_BODY } = {}) {
  const gateway = createLiveDemoGateway(opts);
  const publicKeyB64url = gateway.demoPublicKeyB64url;
  const server = http.createServer((req, res) => {
    req.setTimeout(15_000, () => { try { res.writeHead(408).end('{"error":"request_timeout"}'); } catch { /* */ } req.destroy(); });
    const u = new URL(req.url, 'http://x');
    const send = (status, obj, hdrs) => { if (res.headersSent) return; res.writeHead(status, { 'content-type': 'application/json', ...(hdrs || {}) }); res.end(Buffer.isBuffer(obj) ? obj : JSON.stringify(obj)); };

    // Public (no auth — a pubkey is public): the receipt-signing key so the app can verify ActionReceipt sigs at render.
    if (u.pathname === '/demo-pubkey') return send(200, { publicKeyBase64url: publicKeyB64url, signingKeyId: opts.signingKeyId || 'demo-live-receipt-key', alg: 'Ed25519' });

    // Cheap pre-checks BEFORE buffering: real token validation happens inside gateway.handle (verifyToken → /auth/me).
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
