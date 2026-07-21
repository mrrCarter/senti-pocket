// local-server.mjs — thin runner for the HARDENED demo gateway (src/demo-server.mjs). DEMO-ONLY; never deploy.
//   node scripts/local-server.mjs                                                    -> loopback, briefing-only
//   LAN=1 DEMO_SESSION=<id> DEMO_SESSION_DISPOSABLE_CONFIRM=<same id> SL_CLI_JS=<abs path> node scripts/local-server.mjs
// See docs/DEVICE_AGENT_ONBOARDING.md. All hardening (injection/MIME/headers/bounds/positive-disposable/auth) lives
// in src/demo-server.mjs + src/sl-runner.mjs, both under test. Production is app.mjs (AIdenID + DynamoDB + KMS).
import { networkInterfaces } from 'node:os';
import { createDemoServer } from '../src/demo-server.mjs';
import { makeSlRunner } from '../src/sl-runner.mjs';

const PORT = Number(process.env.PORT || 8787);
const BIND = process.env.LAN === '1' ? '0.0.0.0' : '127.0.0.1'; // loopback default; LAN is explicit opt-in

// Real shell-free sl runner only if configured; briefing-only demos need no sl (the runner is never called because
// an unconfirmed/absent disposable session refuses writeback at the authorization gate).
let run;
try { run = makeSlRunner(); } catch (e) { const msg = e.message; run = () => { throw new Error('sl runner not configured: ' + msg); }; }

const { server, token, writable, publicKeyRawBase64url, bundleSig, canonicalLen } = createDemoServer({
  demoSession: process.env.DEMO_SESSION || null,
  disposableConfirm: process.env.DEMO_SESSION_DISPOSABLE_CONFIRM || null,
  run,
});

function lanIp() { for (const ifs of Object.values(networkInterfaces())) for (const i of ifs || []) if (i.family === 'IPv4' && !i.internal) return i.address; return '127.0.0.1'; }
server.listen(PORT, BIND, () => {
  const host = BIND === '0.0.0.0' ? lanIp() : '127.0.0.1';
  console.log('=== Senti Pocket LOCAL demo gateway (DEMO-ONLY; not production trust) ===');
  console.log('Bind          : ' + BIND + (BIND === '0.0.0.0' ? '  (LAN opt-in; CLEARTEXT HTTP — trusted LAN only; token is the pairing secret)' : '  (loopback; set LAN=1 for device access)'));
  console.log('URL           : http://' + host + ':' + PORT);
  console.log('Pairing token : ' + token + '   (ephemeral; type into the phone; do NOT log/commit/redirect to a file)');
  console.log('Verify key    : raw base64url Ed25519 (keyId demo-bundle-key / demo-receipt-key): ' + publicKeyRawBase64url);
  console.log('Writeback     : ' + (writable
    ? 'REAL to disposable ' + process.env.DEMO_SESSION + ' (needs SL_CLI_JS + sl authed)'
    : 'REFUSED — set DEMO_SESSION + DEMO_SESSION_DISPOSABLE_CONFIRM=<same id> (disposable, non-protected) to enable; bad input -> 422 envelope, never a fake receipt'));
  console.log('KAV           : committed test/fixtures/pocket_kav_v1.json (Node+Swift). Live bundle.sig=' + bundleSig.slice(0, 20) + '... canonicalLen=' + canonicalLen);
});
