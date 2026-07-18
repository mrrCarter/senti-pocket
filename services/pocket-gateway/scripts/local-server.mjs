// local-server.mjs — DEMO-ONLY local gateway for the on-device stage loop (NO AWS, NO real AIdenID).
// Serves a REAL Ed25519-signed PocketBundle over GET /sync and accepts POST /actions/execute (mock writeback ->
// real signed receipt) + POST /tts (stub). Point the iPhone build at http://<this-Mac-LAN-ip>:8787.
// Run:  node scripts/local-server.mjs        (prints the dev token, LAN URL, and the bundle-signing public key)
//
// SECURITY NOTE: auth here is a fixed DEV bearer token — this file is for the physical-device DEMO ONLY and must
// never be deployed. The production path is app.mjs (real AIdenID JWT/DPoP verifier + DynamoDB + KMS).
import http from 'node:http';
import { networkInterfaces } from 'node:os';
import { createGateway } from '../src/handlers.mjs';
import { createInMemoryStore } from '../src/store.mjs';
import { buildRawCheckpoint } from '../src/extract.mjs';
import { summarize } from '../src/summarize.mjs';
import { buildSignedBundle, generateSigningKeypair } from '../src/bundle.mjs';

const PORT = Number(process.env.PORT || 8787);
const DEV_TOKEN = 'demo-pocket-token';
const DEV_PRINCIPAL = 'demo:site_sentinelayer:pairwise-demo';

// ---- a realistic demo checkpoint of today's Senti Pocket build ----
const SESSION = '6cf7e861-546a-4b9f-b937-39182a5bd395';
const EXPORT = {
  session: { id: SESSION, title: 'Senti Pocket — Sunday build' },
  events: [
    { sequenceId: 100, event: 'session_message', agent: { id: 'claude-pocket-relay' }, payload: { text: 'Governed writeback frozen-final: snapshot-bound, exactly-once, idempotency-key reconciled. 130/130.' }, ts: '2026-07-18T17:00:00Z' },
    { sequenceId: 101, event: 'session_message', agent: { id: 'codex-pocket-echo' }, payload: { text: 'Byte-exact AIdenID KAV verified: real EdDSA token + ES256 DPoP accepted; replay/tamper/wrong-site rejected.' }, ts: '2026-07-18T17:05:00Z' },
    { sequenceId: 102, event: 'session_message', agent: { id: 'claude-pocket-atlas' }, payload: { text: 'PocketContracts v0.1.8 frozen; VerifiedBundle wired for the device build.' }, ts: '2026-07-18T17:20:00Z' },
    { sequenceId: 103, event: 'session_message', agent: { id: 'codex-pocket-pulse' }, payload: { text: 'Incoming-call screen + briefing playout + barge-in interrupt ready for the physical iPhone.' }, ts: '2026-07-18T17:40:00Z' },
  ],
};
const CKPT = { checkpointId: 'cp_pocket_demo_001', sessionId: SESSION, startSequence: 100, endSequence: 103, title: 'Senti Pocket — Sunday build', summarySections: { window: { eventCount: 4 }, headline: 'Senti Pocket: governed writeback + real-token auth done; device loop ready to ring.' } };

const { publicKey, privateKey } = generateSigningKeypair();
const { rawCheckpoint } = buildRawCheckpoint(CKPT, EXPORT);
const SUMMARY = summarize(rawCheckpoint, CKPT);
const BUNDLE = buildSignedBundle(rawCheckpoint, SUMMARY, privateKey, { signingKeyId: 'demo-bundle-key', createdAt: '2026-07-18T18:00:00Z' });

// mock sl runner: a governed writeback that "lands" + read-back-confirms, so the full signed-receipt loop completes.
let actionSeq = 0;
function demoRun(args) {
  if (args[1] === 'reply') { actionSeq += 1; return JSON.stringify({ action: { id: 'demo_act_' + actionSeq, targetSequenceId: Number(args[3]), targetCursor: 'cur_' + actionSeq } }); }
  if (args[1] === 'read') return JSON.stringify({ events: [{ eventId: 'session-action-demo_act_' + actionSeq, agent: { id: 'claude-pocket-relay' }, payload: { targetSequenceId: 103 } }] });
  return '{}';
}

const gateway = createGateway({
  verifyToken: async (h) => ((h.authorization || h.Authorization) === 'Bearer ' + DEV_TOKEN
    ? { humanId: 'pairwise-demo', principal: DEV_PRINCIPAL, site: 'site_sentinelayer', scopes: ['pocket:read', 'pocket:write', 'pocket:voice'] } : null),
  store: createInMemoryStore(),
  run: demoRun,
  signingKey: privateKey,
  signingKeyId: 'demo-receipt-key',
  knownSessionIdsFor: async () => [SESSION],
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
  headers['x-http-method'] = req.method; headers['x-http-url'] = 'http://x' + u.pathname; // demo binding
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
  const pub = publicKey.export({ type: 'spki', format: 'pem' });
  console.log('=== Senti Pocket DEMO gateway (LOCAL, no AWS) ===');
  console.log('URL for the iPhone build : http://' + lanIp() + ':' + PORT);
  console.log('Dev bearer token         : ' + DEV_TOKEN);
  console.log('GET  /sync               : returns 1 signed PocketBundle (' + BUNDLE.evidence.length + ' evidence refs)');
  console.log('POST /actions/execute    : { proposal, confirmation } -> signed ActionReceipt (mock writeback)');
  console.log('POST /tts                : { text, voiceId } -> stub pcm (needs pocket:voice)');
  console.log('Bundle signing PUBLIC key (pin in the app to verify bundles):');
  console.log(pub.trim());
});
