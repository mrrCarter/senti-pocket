#!/usr/bin/env node
// live-demo-server.mjs — RUNNABLE entry for the LOCAL live-write demo. DEMO-ONLY (never deployed; prod is app.mjs).
// Forge Mac-hosts this + `cloudflared tunnel --url` exposes it; Warden's script-verify + Atlas's app POST to /actions/execute.
//
// Wires createLiveDemoServer to:
//   - the REAL api (SENTI_API_BASE_URL) — verifyToken=/auth/me + postHumanMessage=/human-message,
//   - the host's `sl` binary as the read-back `run` — reads the room AS the host's authed MEMBER (Forge's Mac = mrrCarter),
//     so verifyHumanMessageLanded can actually see the landed event (uncertainty #2, solved by hosting on a member's box).
// Honest scope (see live-demo.mjs): runtime LOCAL, idempotency in-memory, receipt signed by a DEV ed25519 key (a REAL
// signature, NOT the prod KMS key). The /execute BEARER is supplied by the CALLER (script/app) in the request — this
// server validates + forwards it; it never sources or holds Carter's token.
//
// Usage: SENTI_API_BASE_URL=https://api.sentinelayer.com PORT=8787 SL_BIN=sl DEMO_SESSION_ID=<sid> node src/live-demo-server.mjs
import { execFileSync } from 'node:child_process';
import { createPrivateKey, createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { createLiveDemoServer, createDemoBearerGuard } from './live-demo.mjs';
import { createGemmaBackend } from './gemma-backend.mjs';
import { createCartesiaBackend } from './cartesia-backend.mjs';

const apiBaseUrl = process.env.SENTI_API_BASE_URL || 'https://api.sentinelayer.com';
const port = Number(process.env.PORT || 8787);
const slBin = process.env.SL_BIN || 'sl';               // the host's authed sl (must be a MEMBER of the demo room)
const demoSession = process.env.DEMO_SESSION_ID || '6cf7e861-546a-4b9f-b937-39182a5bd395';

// The read-back `run`: execute the host's `sl` synchronously (the gateway calls run() sync) + return stdout. The parse
// layers (parseHumanMessageResult / JSON.parse) are null-safe, so a non-JSON/failed invocation degrades to NOT-landed
// (fail-closed) rather than throwing. No token is ever passed here — sl reads its own keychain; args carry no secret.
const run = (args) => {
  try {
    return execFileSync(slBin, args, { encoding: 'utf8', timeout: 15_000, maxBuffer: 8 * 1024 * 1024 });
  } catch (e) {
    return (e && typeof e.stdout === 'string' && e.stdout) ? e.stdout : '{}';
  }
};

// Membership: the authed member may write to the demo room. (A prod deploy derives this from the api under the user's
// token; for the single-room demo the target is fixed + the api re-checks membership on the /human-message write anyway.)
const knownSessionIdsFor = async () => [demoSession];

// FIXED dev signing key (STABLE pubkey the app PINS out-of-band = trust-anchored, Warden #2): DEMO_SIGNING_KEY_PATH (a
// PEM private-key file) or DEMO_SIGNING_JWK (a JWK string). Absent => generated per-boot (pubkey CHANGES each restart —
// only safe if the app RE-pins; a stable pin is the honest closure). Private key NEVER committed/printed.
let signingKey; // undefined => createLiveDemoGateway generates per-boot
try {
  if (process.env.DEMO_SIGNING_KEY_PATH) signingKey = createPrivateKey(readFileSync(process.env.DEMO_SIGNING_KEY_PATH));
  else if (process.env.DEMO_SIGNING_JWK) signingKey = createPrivateKey({ key: JSON.parse(process.env.DEMO_SIGNING_JWK), format: 'jwk' });
} catch (e) {
  process.stderr.write(`[live-demo] FAILED to load fixed signing key (${(e && e.message) || e}) — falling back to a per-boot key\n`);
  signingKey = undefined;
}
const keyMode = signingKey ? 'FIXED (stable pin across restarts)' : 'per-boot (pubkey changes each restart — app must re-pin)';

// Gemma reasoning (Carter: "make sure Gemma is used"): set GEMMA_BASE_URL to a local key-free Ollama
// (http://localhost:11434/v1, GEMMA_MODEL=gemma3) or the AI Studio OpenAI-compat URL (+ GEMMA_API_KEY) to light up
// /answer + /brief with REAL Gemma. Absent => those routes stay 501 (reasoning not configured).
const gemmaBaseUrl = process.env.GEMMA_BASE_URL || '';
const gemma = gemmaBaseUrl
  ? createGemmaBackend({ baseUrl: gemmaBaseUrl, model: process.env.GEMMA_MODEL || 'gemma3', apiKey: process.env.GEMMA_API_KEY, fetch: globalThis.fetch })
  : undefined;

// Cartesia TTS (real online voice for the login-free demo): CARTESIA_API_KEY (+ TTS_VOICE_ID) lights up /tts with a real
// voice. Absent => /tts stays 501 (tts backend not configured). The key lives ONLY here (server-side), never on the phone.
const ttsBackend = process.env.CARTESIA_API_KEY
  ? createCartesiaBackend({ apiKey: process.env.CARTESIA_API_KEY, voiceId: process.env.TTS_VOICE_ID })
  : undefined;

// PUBLIC demo-capability BOUNDS. The login-free bearer ships inside a sideloaded .ipa ⇒ EXTRACTABLE ⇒ server-bounded,
// independent of client honesty. verifyToken(live-demo.mjs) scopes it to pocket:voice ONLY (only /tts; every other route
// 403 at the scope-check before upstream). createDemoBearerGuard adds the QUANTITATIVE bounds:
//   POCKET_DEMO_BEARER               the rotated capability (also matched by verifyToken)
//   POCKET_DEMO_BEARER_EXPIRES_UNIX  absolute wall-clock deadline (unix sec)   — REQUIRED, finite>0, else 401
//   POCKET_DEMO_BEARER_MAX_PER_MIN   per-60s ANTI-ABUSE rate cap               — REQUIRED, finite>0, else 429
//   POCKET_DEMO_BEARER_MAX_CALLS     lifetime /tts CALL budget (restart-safe)  — REQUIRED, finite>0, else 429
//   POCKET_DEMO_BEARER_MAX_CHARS     lifetime /tts CHARACTER budget            — REQUIRED, finite>0, else 429
// The call+char budget is persisted per capability fingerprint under POCKET_DEMO_USAGE_DIR (default ~/.pocket-demo-usage)
// so it survives restart and is NOT reset by relaunch. A new bearer (new fingerprint) starts fresh.
const demoBearer = process.env.POCKET_DEMO_BEARER || '';
const demoFingerprint = demoBearer ? createHash('sha256').update(demoBearer).digest('hex').slice(0, 16) : '';
const usageDir = process.env.POCKET_DEMO_USAGE_DIR || join(process.env.HOME || '.', '.pocket-demo-usage');
if (demoBearer) { try { mkdirSync(usageDir, { recursive: true, mode: 0o700 }); } catch { /* best-effort */ } }
const demoExpiresUnix = Number(process.env.POCKET_DEMO_BEARER_EXPIRES_UNIX || 0);
const demoMaxPerMin = Number(process.env.POCKET_DEMO_BEARER_MAX_PER_MIN || 0);
const demoMaxCalls = Number(process.env.POCKET_DEMO_BEARER_MAX_CALLS || 0);
const demoMaxChars = Number(process.env.POCKET_DEMO_BEARER_MAX_CHARS || 0);
const demoGuard = demoBearer
  ? createDemoBearerGuard({ expiresUnixSec: demoExpiresUnix, maxPerMin: demoMaxPerMin, maxTotalCalls: demoMaxCalls, maxTotalChars: demoMaxChars, fingerprint: demoFingerprint, persistDir: usageDir })
  : undefined;

// DEPLOYMENT BINDING: a content digest of the RUNNING containment source, so a receipt can prove the live process is
// exactly the reviewed commit's bytes (not a divergent/patched process). sha256 over the two containment files as loaded.
const srcDir = dirname(fileURLToPath(import.meta.url));
let srcDigest = 'unknown';
try {
  srcDigest = createHash('sha256')
    .update(readFileSync(join(srcDir, 'live-demo.mjs')))
    .update(readFileSync(join(srcDir, 'live-demo-server.mjs')))
    .digest('hex').slice(0, 16);
} catch { /* */ }

const { server, publicKeyB64url } = createLiveDemoServer({ apiBaseUrl, fetch: globalThis.fetch, run, knownSessionIdsFor, signingKey, reason: gemma && gemma.reason, brief: gemma && gemma.brief, ttsBackend, demoBearer, demoGuard });
server.listen(port, () => {
  // Startup lines only — no secrets (apiBaseUrl / port / session / bin path / PUBLIC key); the gateway logs nothing per-request.
  process.stdout.write(`[live-demo] gateway :${port} -> api ${apiBaseUrl} | room ${demoSession} | sl=${slBin}\n`);
  process.stdout.write(`[live-demo] LOCAL runtime · in-memory idempotency · DEV ed25519 receipt key [${keyMode}] (real sig, NOT prod KMS)\n`);
  process.stdout.write(`[live-demo] receipt PUBKEY (Ed25519 x, base64url) = ${publicKeyB64url}\n`);
  process.stdout.write(`[live-demo] RUNNING containment src sha256[:16] = ${srcDigest}  (deployment binding: must match the reviewed commit)\n`);
  process.stdout.write('[live-demo] POST /actions/execute with the caller\'s SENTI user-session bearer to author as human-<you>\n');
  // Redacted capability-bounds line (NO bearer value — fingerprint + enforced numbers only) for the deployment receipt.
  if (demoBearer) {
    const st = demoGuard.stats();
    process.stdout.write(`[live-demo] PUBLIC demo capability BOUNDED (fp ${demoFingerprint}): scope=pocket:voice-ONLY · expiry=${st.expSec ? new Date(st.expSec * 1000).toISOString() : 'INVALID->fail-closed(401)'} · rate/min=${st.perMin || 'INVALID->fail-closed(429)'} · maxCalls=${st.totCalls || 'INVALID->fail-closed(429)'} · maxChars=${st.totChars || 'INVALID->fail-closed(429)'} · used={calls:${st.used.calls},chars:${st.used.chars}} persisted=${st.usagePath}\n`);
  } else {
    process.stdout.write('[live-demo] no POCKET_DEMO_BEARER set (login-free demo capability disabled)\n');
  }
  process.stdout.write(gemma
    ? `[live-demo] Gemma reasoning WIRED -> ${gemmaBaseUrl} (model ${gemma.model}) -> /answer + /brief live\n`
    : '[live-demo] Gemma NOT wired (set GEMMA_BASE_URL=http://localhost:11434/v1 GEMMA_MODEL=gemma3 for real Gemma /answer + /brief)\n');
  process.stdout.write(ttsBackend
    ? '[live-demo] Cartesia TTS WIRED (voice ' + String(process.env.TTS_VOICE_ID || '').slice(0, 8) + ') -> /tts live\n'
    : '[live-demo] Cartesia TTS NOT wired (set CARTESIA_API_KEY + TTS_VOICE_ID for real /tts)\n');
});
