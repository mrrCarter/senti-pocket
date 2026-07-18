// local-server.mjs — LOCAL demo gateway for the on-device stage loop. Serves a REAL Ed25519-signed PocketBundle
// (GET /sync) and runs the REAL governed writeback (POST /actions/execute) — NO mock. Point the iPhone build at
// http://<this-Mac-LAN-ip>:8787.
//   node scripts/local-server.mjs                         -> briefing works; writeback HONESTLY REFUSES (no throwaway session)
//   DEMO_SESSION=<throwaway-session-id> node scripts/local-server.mjs   -> real write-back to that DISPOSABLE session
//
// PRODUCT-TRUTH (Pulse P0): /actions/execute posts to a REAL Senti thread and returns the REAL sequence + a signed
// receipt, OR it returns an honest non-posted status. It NEVER signs `posted` for something that was not posted.
// Use a DISPOSABLE DEMO_SESSION (never the stage room) so the write-back is real without polluting a live room.
//
// SECURITY: the printed bearer token + keys are LOCAL-DEMO credentials, NOT production trust. Never deploy this file;
// production is app.mjs (real AIdenID JWT/DPoP + DynamoDB + KMS). Requires `sl` on PATH + authed to DEMO_SESSION.
import http from 'node:http';
import { execFileSync } from 'node:child_process';
import { networkInterfaces } from 'node:os';
import { createGateway } from '../src/handlers.mjs';
import { createInMemoryStore } from '../src/store.mjs';
import { buildRawCheckpoint } from '../src/extract.mjs';
import { summarize } from '../src/summarize.mjs';
import { buildSignedBundle, generateSigningKeypair } from '../src/bundle.mjs';

const PORT = Number(process.env.PORT || 8787);
const DEV_TOKEN = 'demo-pocket-token';
const DEMO_SESSION = process.env.DEMO_SESSION || null; // a DISPOSABLE session for the real write-back demo
const BRIEF_SESSION = DEMO_SESSION || '00000000-0000-4000-8000-000000000000'; // bundle session (demo target if set)

// REAL sl runner (cross-platform): on Windows resolve the sl.cmd shim via cmd; elsewhere call sl directly.
const isWin = process.platform === 'win32';
const realRun = (args) => execFileSync(isWin ? 'cmd' : 'sl', isWin ? ['/c', 'sl', ...args] : args, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });

// ---- a realistic demo checkpoint of today's Senti Pocket build (illustrative briefing content) ----
const EXPORT = {
  session: { id: BRIEF_SESSION, title: 'Senti Pocket — Sunday build' },
  events: [
    { sequenceId: 100, event: 'session_message', agent: { id: 'claude-pocket-relay' }, payload: { text: 'Governed writeback frozen-final: snapshot-bound, exactly-once, idempotency-key reconciled. 130/130.' }, ts: '2026-07-18T17:00:00Z' },
    { sequenceId: 101, event: 'session_message', agent: { id: 'codex-pocket-echo' }, payload: { text: 'Byte-exact AIdenID KAV verified: real EdDSA token + ES256 DPoP accepted; replay/tamper/wrong-site rejected.' }, ts: '2026-07-18T17:05:00Z' },
    { sequenceId: 102, event: 'session_message', agent: { id: 'claude-pocket-atlas' }, payload: { text: 'PocketContracts v0.1.8 frozen; VerifiedBundle wired for the device build.' }, ts: '2026-07-18T17:20:00Z' },
    { sequenceId: 103, event: 'session_message', agent: { id: 'codex-pocket-pulse' }, payload: { text: 'Incoming-call screen + briefing playout + barge-in interrupt ready for the physical iPhone.' }, ts: '2026-07-18T17:40:00Z' },
  ],
};
const CKPT = { checkpointId: 'cp_pocket_demo_001', sessionId: BRIEF_SESSION, startSequence: 100, endSequence: 103, title: 'Senti Pocket — Sunday build', summarySections: { window: { eventCount: 4 }, headline: 'Senti Pocket: governed writeback + real-token auth done; device loop ready to ring.' } };

const { publicKey, privateKey } = generateSigningKeypair();
const { rawCheckpoint } = buildRawCheckpoint(CKPT, EXPORT);
const SUMMARY = summarize(rawCheckpoint, CKPT);
const BUNDLE = buildSignedBundle(rawCheckpoint, SUMMARY, privateKey, { signingKeyId: 'demo-bundle-key', createdAt: '2026-07-18T18:00:00Z' });

const gateway = createGateway({
  verifyToken: async (h) => ((h.authorization || h.Authorization) === 'Bearer ' + DEV_TOKEN
    ? { humanId: 'pairwise-demo', principal: 'demo:site_sentinelayer:pairwise-demo', site: 'site_sentinelayer', scopes: ['pocket:read', 'pocket:write', 'pocket:voice'] } : null),
  store: createInMemoryStore(),
  run: realRun,                                              // REAL governed sender — no mock
  signingKey: privateKey,
  signingKeyId: 'demo-receipt-key',
  // writeback is authorized ONLY for the disposable DEMO_SESSION; unset => executeAction returns an honest non-posted
  // failure ("not a known session"), never a fabricated `posted`.
  knownSessionIdsFor: async () => (DEMO_SESSION ? [DEMO_SESSION] : []),
  bundleStore: { listForHuman: async () => [BUNDLE] },
  ttsBackend: async (text) => ({ audio: Buffer.from('DEMO-PCM:' + text.slice(0, 32)), format: 'pcm_s16le_24000' }),
  agent: 'claude-pocket-relay',
});

function readBody(req) {
  return new Promise((resolve) => { let b = ''; req.on('data', (c) => { b += c; }); req.on('end', () => resolve(b)); });
}
const server = http.createServer(async (req, res) => {
  const u = new URL(req.url, 'http://x');
  const query = Object.fromEntries(u.searchParams.entries());
  const headers = {}; for (const [k, v] of Object.entries(req.headers)) headers[k.toLowerCase()] = v;
  headers['x-http-method'] = req.method; headers['x-http-url'] = 'http://x' + u.pathname;
  const body = (req.method === 'POST') ? await readBody(req) : undefined;
  const out = await gateway.handle({ method: req.method, path: u.pathname, query, headers, body });
  const isBuf = Buffer.isBuffer(out.body);
  res.writeHead(out.status, out.headers || {});
  res.end(isBuf ? out.body : (typeof out.body === 'string' ? out.body : JSON.stringify(out.body)));
});

function lanIp() {
  for (const ifs of Object.values(networkInterfaces())) for (const i of ifs || []) if (i.family === 'IPv4' && !i.internal) return i.address;
  return '127.0.0.1';
}
server.listen(PORT, '0.0.0.0', () => {
  console.log('=== Senti Pocket LOCAL demo gateway (LOCAL-DEMO credentials, NOT production trust) ===');
  console.log('URL for the iPhone build : http://' + lanIp() + ':' + PORT);
  console.log('Dev bearer token (demo)  : ' + DEV_TOKEN + '   (local-demo only; NOT AIdenID / not prod trust)');
  console.log('GET  /sync               : one REAL signed PocketBundle (' + BUNDLE.evidence.length + ' evidence refs) to brief from');
  if (DEMO_SESSION) {
    console.log('POST /actions/execute    : REAL governed write-back to disposable session ' + DEMO_SESSION + ' -> real sequence + signed receipt');
  } else {
    console.log('POST /actions/execute    : HONESTLY REFUSES (no throwaway session). Set DEMO_SESSION=<disposable-id> for a real write-back.');
    console.log('                           (never returns a fabricated posted receipt — Pulse P0 product-truth.)');
  }
  console.log('Bundle signing PUBLIC key (pin in the app to verify bundles):');
  console.log(publicKey.export({ type: 'spki', format: 'pem' }).trim());
});
