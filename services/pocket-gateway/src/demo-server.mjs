// demo-server.mjs — HARDENED local demo gateway factory (Echo #233248). DEMO-ONLY (never deployed; prod is app.mjs).
// Fixes: exact JSON MIME (no substring), singleton Authorization/Content-Type, Buffer BYTE cap with deterministic
// 413+drain, POSITIVE disposable-session authorization (not a fail-open denylist), per-run random pairing token,
// auth+bounds BEFORE buffering, request timeout. Injectable `run`/`now` for tests.
import http from 'node:http';
import { randomBytes } from 'node:crypto';
import { createGateway } from './handlers.mjs';
import { createInMemoryStore } from './store.mjs';
import { buildRawCheckpoint } from './extract.mjs';
import { summarize } from './summarize.mjs';
import { buildSignedBundle, generateSigningKeypair, canonicalBundleBytes } from './bundle.mjs';

const PROTECTED = new Set(['6cf7e861-546a-4b9f-b937-39182a5bd395', '954233b7-1822-42bc-9cfe-1eb95eb0357a']); // live rooms
const MAX_BODY = 256 * 1024;

/** Exact JSON media type (rejects substrings like "text/plain; x=application/json" and duplicate joined headers). */
function isJsonContentType(v) {
  if (typeof v !== 'string') return false;             // array (duplicate header) => not a single JSON type
  const media = v.split(';')[0].trim().toLowerCase();
  return media === 'application/json';
}
const singleBearer = (v, token) => typeof v === 'string' && v === 'Bearer ' + token; // array/duplicate => false

/**
 * @param {{ demoSession?:string, disposableConfirm?:string, run?:Function, now?:()=>string, maxBody?:number }} opts
 *   POSITIVE disposable authorization: writes are enabled ONLY if demoSession is set, is NOT a protected/live room,
 *   AND disposableConfirm === demoSession (the operator re-asserts disposability). Otherwise writes are refused.
 * @returns {{ server:http.Server, token:string, publicKeyRawBase64url:string, bundleSig:string, writable:boolean }}
 */
export function createDemoServer(opts = {}) {
  const maxBody = opts.maxBody || MAX_BODY;
  const token = 'demo-' + randomBytes(24).toString('base64url'); // random pairing secret per run
  const demoSession = opts.demoSession || null;
  if (demoSession && PROTECTED.has(demoSession)) throw new Error('DEMO_SESSION must be a DISPOSABLE session, not a protected/live room');
  const writable = !!(demoSession && !PROTECTED.has(demoSession) && opts.disposableConfirm && opts.disposableConfirm === demoSession);
  const briefSession = demoSession || '00000000-0000-4000-8000-000000000000';

  const { publicKey, privateKey } = generateSigningKeypair();
  const EXPORT = { session: { id: briefSession, title: 'Senti Pocket — Sunday build' }, events: [
    { sequenceId: 100, event: 'session_message', agent: { id: 'claude-pocket-relay' }, payload: { text: 'Governed writeback frozen-final; exactly-once, idempotency-key reconciled.' }, ts: '2026-07-18T17:00:00Z' },
    { sequenceId: 101, event: 'session_message', agent: { id: 'codex-pocket-echo' }, payload: { text: 'Byte-exact AIdenID KAV verified; audits closed.' }, ts: '2026-07-18T17:05:00Z' },
    { sequenceId: 102, event: 'session_message', agent: { id: 'claude-pocket-atlas' }, payload: { text: 'PocketContracts v0.1.8 frozen; VerifiedBundle wired.' }, ts: '2026-07-18T17:20:00Z' },
    { sequenceId: 103, event: 'session_message', agent: { id: 'codex-pocket-pulse' }, payload: { text: 'Call screen + briefing + barge-in ready for device.' }, ts: '2026-07-18T17:40:00Z' },
  ] };
  const CKPT = { checkpointId: 'cp_pocket_demo_001', sessionId: briefSession, startSequence: 100, endSequence: 103, summarySections: { window: { eventCount: 4 }, headline: 'Senti Pocket: governed writeback + real-token auth done; device loop ready to ring.' } };
  const { rawCheckpoint } = buildRawCheckpoint(CKPT, EXPORT, { capturedAt: '2026-07-18T18:00:00Z' });
  const BUNDLE = buildSignedBundle(rawCheckpoint, summarize(rawCheckpoint, CKPT), privateKey, { signingKeyId: 'demo-bundle-key', createdAt: '2026-07-18T18:00:00Z' });

  const gateway = createGateway({
    verifyToken: async (h) => (singleBearer(h.authorization, token) ? { humanId: 'pairwise-demo', principal: 'demo:site_sentinelayer:pairwise-demo', site: 'site_sentinelayer', scopes: ['pocket:read', 'pocket:write', 'pocket:voice'] } : null),
    store: createInMemoryStore(),
    run: opts.run, // injected (real shell-free sl-runner in prod-of-demo; mock in tests)
    signingKey: privateKey, signingKeyId: 'demo-receipt-key',
    knownSessionIdsFor: async () => (writable ? [demoSession] : []), // POSITIVE gate: no confirmed disposable => no writable target
    bundleStore: { listForHuman: async () => [BUNDLE] },
    ttsBackend: async (text) => ({ audio: Buffer.from('DEMO-PCM:' + text.slice(0, 32)), format: 'pcm_s16le_24000' }),
    agent: 'claude-pocket-relay',
    now: opts.now,
  });

  const server = http.createServer((req, res) => {
    req.setTimeout(10_000, () => { try { res.writeHead(408).end('{"error":"request_timeout"}'); } catch { /* */ } req.destroy(); });
    const u = new URL(req.url, 'http://x');
    const send = (status, obj, hdrs) => { if (res.headersSent) return; res.writeHead(status, { 'content-type': 'application/json', ...(hdrs || {}) }); res.end(Buffer.isBuffer(obj) ? obj : JSON.stringify(obj)); };

    // AUTH + bounds BEFORE buffering (exact singleton header/MIME; unauthenticated requests never allocate a body).
    if (u.pathname !== '/health' && !singleBearer(req.headers.authorization, token)) return send(401, { error: 'unauthorized' }, { 'www-authenticate': 'Bearer' });
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
      headers['x-http-method'] = req.method; headers['x-http-url'] = 'http://x' + u.pathname;
      const query = Object.fromEntries(u.searchParams.entries());
      try {
        const out = await gateway.handle({ method: req.method, path: u.pathname, query, headers, body: req.method === 'POST' ? body : undefined });
        send(out.status, out.body, out.headers);
      } catch { send(500, { error: 'internal' }); }
    });
  });

  return { server, token, writable, publicKeyRawBase64url: publicKey.export({ format: 'jwk' }).x, bundleSig: BUNDLE.signature, canonicalLen: canonicalBundleBytes(BUNDLE).length };
}
