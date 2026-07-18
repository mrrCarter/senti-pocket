// local-server.mjs — LOCAL demo gateway for the on-device stage loop. HARDENED per Echo #233114.
//   node scripts/local-server.mjs                                   -> loopback only, briefing-only (writeback refuses)
//   LAN=1 DEMO_SESSION=<disposable-id> SL_CLI_JS=<path> node scripts/local-server.mjs   -> LAN + real write-back
//
// SECURITY (Echo #233114): shell-FREE sl dispatch (no cmd/injection); loopback default + explicit LAN opt-in; a
// RANDOM per-run bearer token; auth + bounds BEFORE buffering; validation failures return an ERROR ENVELOPE (never a
// null-hash, non-Swift-decodable receipt); the receipt/bundle verify key is published as RAW base64url Ed25519 keyed
// by signingKeyId (+ a Node->Swift vector); DEMO_SESSION must be a DISPOSABLE session (protected rooms are denied).
// This file is DEMO-ONLY and must never be deployed; production is app.mjs (AIdenID + DynamoDB + KMS).
import http from 'node:http';
import { randomBytes } from 'node:crypto';
import { networkInterfaces } from 'node:os';
import { createGateway } from '../src/handlers.mjs';
import { createInMemoryStore } from '../src/store.mjs';
import { buildRawCheckpoint } from '../src/extract.mjs';
import { summarize } from '../src/summarize.mjs';
import { buildSignedBundle, generateSigningKeypair, canonicalBundleBytes } from '../src/bundle.mjs';
import { makeSlRunner } from '../src/sl-runner.mjs';

const PORT = Number(process.env.PORT || 8787);
const BIND = process.env.LAN === '1' ? '0.0.0.0' : '127.0.0.1'; // loopback by default; LAN is explicit opt-in
const DEV_TOKEN = 'demo-' + randomBytes(24).toString('base64url'); // random per run, not a fixed/logged constant
const MAX_BODY = 256 * 1024;

// DEMO_SESSION must be a DISPOSABLE session, never a protected/live room.
const PROTECTED = new Set(['6cf7e861-546a-4b9f-b937-39182a5bd395', '954233b7-1822-42bc-9cfe-1eb95eb0357a']);
const DEMO_SESSION = process.env.DEMO_SESSION || null;
if (DEMO_SESSION && PROTECTED.has(DEMO_SESSION)) { console.error('FATAL: DEMO_SESSION must be a DISPOSABLE session, not a protected/live room.'); process.exit(1); }
const BRIEF_SESSION = DEMO_SESSION || '00000000-0000-4000-8000-000000000000';

const realRun = makeSlRunner(); // shell-free (node + SL_CLI_JS); refuses on Windows without SL_CLI_JS

// ---- illustrative demo checkpoint of today's Senti Pocket build ----
const EXPORT = {
  session: { id: BRIEF_SESSION, title: 'Senti Pocket — Sunday build' },
  events: [
    { sequenceId: 100, event: 'session_message', agent: { id: 'claude-pocket-relay' }, payload: { text: 'Governed writeback frozen-final: snapshot-bound, exactly-once, idempotency-key reconciled.' }, ts: '2026-07-18T17:00:00Z' },
    { sequenceId: 101, event: 'session_message', agent: { id: 'codex-pocket-echo' }, payload: { text: 'Byte-exact AIdenID KAV verified; adversarial audits closed.' }, ts: '2026-07-18T17:05:00Z' },
    { sequenceId: 102, event: 'session_message', agent: { id: 'claude-pocket-atlas' }, payload: { text: 'PocketContracts v0.1.8 frozen; VerifiedBundle wired for the device.' }, ts: '2026-07-18T17:20:00Z' },
    { sequenceId: 103, event: 'session_message', agent: { id: 'codex-pocket-pulse' }, payload: { text: 'Call screen + briefing playout + barge-in ready for the iPhone.' }, ts: '2026-07-18T17:40:00Z' },
  ],
};
const CKPT = { checkpointId: 'cp_pocket_demo_001', sessionId: BRIEF_SESSION, startSequence: 100, endSequence: 103, title: 'Senti Pocket — Sunday build', summarySections: { window: { eventCount: 4 }, headline: 'Senti Pocket: governed writeback + real-token auth done; device loop ready to ring.' } };

const { publicKey, privateKey } = generateSigningKeypair();
const { rawCheckpoint } = buildRawCheckpoint(CKPT, EXPORT);
const SUMMARY = summarize(rawCheckpoint, CKPT);
const BUNDLE = buildSignedBundle(rawCheckpoint, SUMMARY, privateKey, { signingKeyId: 'demo-bundle-key', createdAt: '2026-07-18T18:00:00Z' });
const RAW_PUB_B64URL = publicKey.export({ format: 'jwk' }).x; // raw Ed25519 public key, base64url (PocketUI key form)

const gateway = createGateway({
  verifyToken: async (h) => ((h.authorization || h.Authorization) === 'Bearer ' + DEV_TOKEN
    ? { humanId: 'pairwise-demo', principal: 'demo:site_sentinelayer:pairwise-demo', site: 'site_sentinelayer', scopes: ['pocket:read', 'pocket:write', 'pocket:voice'] } : null),
  store: createInMemoryStore(),
  run: realRun,                                              // REAL, shell-free governed sender
  signingKey: privateKey,
  signingKeyId: 'demo-receipt-key',
  knownSessionIdsFor: async () => (DEMO_SESSION ? [DEMO_SESSION] : []), // no disposable session => writeback refuses (no fake posted)
  bundleStore: { listForHuman: async () => [BUNDLE] },
  ttsBackend: async (text) => ({ audio: Buffer.from('DEMO-PCM:' + text.slice(0, 32)), format: 'pcm_s16le_24000' }),
  agent: 'claude-pocket-relay',
});

const server = http.createServer((req, res) => {
  req.setTimeout(10_000, () => { res.writeHead(408).end('{"error":"request_timeout"}'); req.destroy(); });
  const u = new URL(req.url, 'http://x');
  const send = (status, obj, hdrs) => { res.writeHead(status, { 'content-type': 'application/json', ...(hdrs || {}) }); res.end(Buffer.isBuffer(obj) ? obj : JSON.stringify(obj)); };

  // AUTH + bounds BEFORE buffering a body (an unauthenticated request never gets to allocate).
  const auth = req.headers.authorization;
  if (u.pathname !== '/health' && auth !== 'Bearer ' + DEV_TOKEN) return send(401, { error: 'unauthorized' }, { 'www-authenticate': 'Bearer' });
  if (req.method === 'POST') {
    if (!String(req.headers['content-type'] || '').includes('application/json')) return send(415, { error: 'unsupported_media_type' });
    if (Number(req.headers['content-length'] || 0) > MAX_BODY) return send(413, { error: 'payload_too_large' });
  }

  let body = '';
  let over = false;
  req.on('data', (c) => { body += c; if (body.length > MAX_BODY) { over = true; req.destroy(); } });
  req.on('end', async () => {
    if (over) return send(413, { error: 'payload_too_large' });
    const headers = {}; for (const [k, v] of Object.entries(req.headers)) headers[k.toLowerCase()] = v;
    headers['x-http-method'] = req.method; headers['x-http-url'] = 'http://x' + u.pathname; // trusted (this server sets it)
    const query = Object.fromEntries(u.searchParams.entries());
    const out = await gateway.handle({ method: req.method, path: u.pathname, query, headers, body: req.method === 'POST' ? body : undefined });
    // ERROR ENVELOPE: a pre-confirmation validation failure carries confirmedProposalHash:null and is NOT a
    // frozen-Swift-decodable ActionReceipt. Return an explicit error instead of a malformed receipt (Echo #233114).
    const b = out.body;
    if (u.pathname === '/actions/execute' && b && typeof b === 'object' && b.status === 'failed' && b.confirmedProposalHash == null) {
      return send(422, { error: 'proposal_rejected', reason: b.failureReason || 'invalid proposal' });
    }
    send(out.status, out.body, out.headers);
  });
  req.on('error', () => { try { res.writeHead(400).end('{"error":"bad_request"}'); } catch { /* ignore */ } });
});

function lanIp() {
  for (const ifs of Object.values(networkInterfaces())) for (const i of ifs || []) if (i.family === 'IPv4' && !i.internal) return i.address;
  return '127.0.0.1';
}
server.listen(PORT, BIND, () => {
  const host = BIND === '0.0.0.0' ? lanIp() : '127.0.0.1';
  console.log('=== Senti Pocket LOCAL demo gateway (DEMO-ONLY; not production trust) ===');
  console.log('Bind                     : ' + BIND + (BIND === '0.0.0.0' ? '  (LAN opt-in)' : '  (loopback; set LAN=1 for device access)'));
  console.log('URL                      : http://' + host + ':' + PORT);
  console.log('Bearer token (random)    : ' + DEV_TOKEN);
  console.log('Verify key (raw base64url Ed25519, keyId demo-bundle-key AND demo-receipt-key): ' + RAW_PUB_B64URL);
  console.log('GET  /sync               : one real signed PocketBundle to brief from');
  if (DEMO_SESSION) console.log('POST /actions/execute    : REAL write-back to disposable ' + DEMO_SESSION + ' (needs SL_CLI_JS set + sl authed)');
  else console.log('POST /actions/execute    : refuses honestly (no disposable session); pre-confirm bad input -> 422 error envelope, never a fake receipt');
  // Node->Swift vector: verify Ed25519(rawPub, canonicalBundleBytes(BUNDLE)) == base64-decoded BUNDLE.signature
  console.log('Node->Swift vector       : bundle.signature(base64)=' + BUNDLE.signature.slice(0, 24) + '...  over canonicalBundleBytes len=' + canonicalBundleBytes(BUNDLE).length);
});
