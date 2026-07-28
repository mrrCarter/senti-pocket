#!/usr/bin/env node
// live-demo-server.mjs — RUNNABLE entry for the LOCAL live-write demo. DEMO-ONLY (never deployed; prod is app.mjs).
// Forge Mac-hosts this + `cloudflared tunnel --url` exposes it. Honest scope (see live-demo.mjs): runtime LOCAL,
// idempotency in-memory, receipt signed by a DEV ed25519 key (a REAL signature, NOT the prod KMS key).
//
// Usage: SENTI_API_BASE_URL=https://api.sentinelayer.com PORT=8787 SL_BIN=sl DEMO_SESSION_ID=<sid> node src/live-demo-server.mjs
import { execFileSync } from 'node:child_process';
import { createPrivateKey, createHash } from 'node:crypto';
import { readFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { createLiveDemoServer, createDemoBearerGuard, validateDemoConfig } from './live-demo.mjs';
import { createGemmaBackend } from './gemma-backend.mjs';
import { createCartesiaBackend } from './cartesia-backend.mjs';

const apiBaseUrl = process.env.SENTI_API_BASE_URL || 'https://api.sentinelayer.com';
const port = Number(process.env.PORT || 8787);
const slBin = process.env.SL_BIN || 'sl';
const demoSession = process.env.DEMO_SESSION_ID || '6cf7e861-546a-4b9f-b937-39182a5bd395';

const run = (args) => {
  try { return execFileSync(slBin, args, { encoding: 'utf8', timeout: 15_000, maxBuffer: 8 * 1024 * 1024 }); }
  catch (e) { return (e && typeof e.stdout === 'string' && e.stdout) ? e.stdout : '{}'; }
};
const knownSessionIdsFor = async () => [demoSession];

let signingKey;
try {
  if (process.env.DEMO_SIGNING_KEY_PATH) signingKey = createPrivateKey(readFileSync(process.env.DEMO_SIGNING_KEY_PATH));
  else if (process.env.DEMO_SIGNING_JWK) signingKey = createPrivateKey({ key: JSON.parse(process.env.DEMO_SIGNING_JWK), format: 'jwk' });
} catch (e) { process.stderr.write(`[live-demo] FAILED to load fixed signing key (${(e && e.message) || e}) — falling back to a per-boot key\n`); signingKey = undefined; }
const keyMode = signingKey ? 'FIXED (stable pin across restarts)' : 'per-boot (pubkey changes each restart — app must re-pin)';

const gemmaBaseUrl = process.env.GEMMA_BASE_URL || '';
const gemma = gemmaBaseUrl ? createGemmaBackend({ baseUrl: gemmaBaseUrl, model: process.env.GEMMA_MODEL || 'gemma3', apiKey: process.env.GEMMA_API_KEY, fetch: globalThis.fetch }) : undefined;
const ttsBackend = process.env.CARTESIA_API_KEY ? createCartesiaBackend({ apiKey: process.env.CARTESIA_API_KEY, voiceId: process.env.TTS_VOICE_ID }) : undefined;

// PUBLIC demo-capability BOUNDS. The login-free bearer ships inside a sideloaded .ipa ⇒ EXTRACTABLE ⇒ server-bounded.
// verifyToken(live-demo.mjs) scopes it to pocket:voice ONLY. createDemoBearerGuard.reserveTts (injected into handleTts,
// after validation, before the provider) adds: absolute expiry(401) + per-60s anti-abuse rate(429) + a crash-safe,
// cross-process, fail-closed PERSISTENT lifetime call+BYTE budget(429/503). Config is BOOT-VALIDATED to strict positive
// safe integers within hard ceilings — INVALID config ⇒ the capability is REFUSED (bearer disabled, → 401), never
// coerced. Budget = maxCalls × perCall≤8192 bytes, bounded by lifetimeMaxBytes. Set from a small explicit demo ceiling.
const rawBearer = process.env.POCKET_DEMO_BEARER || '';
const cfg = rawBearer ? validateDemoConfig({
  expiresUnixSec: Number(process.env.POCKET_DEMO_BEARER_EXPIRES_UNIX),
  maxPerMin: Number(process.env.POCKET_DEMO_BEARER_MAX_PER_MIN),
  maxCalls: Number(process.env.POCKET_DEMO_BEARER_MAX_CALLS),
  maxBytes: Number(process.env.POCKET_DEMO_BEARER_MAX_BYTES),
  nowSec: Math.floor(Date.now() / 1000),
}) : { valid: false, reason: 'no bearer set' };

let demoBearer = '';
let demoGuard;
let demoFingerprint = '';
if (rawBearer && cfg.valid) {
  demoBearer = rawBearer;
  demoFingerprint = createHash('sha256').update(rawBearer).digest('hex').slice(0, 16);
  const usageDir = process.env.POCKET_DEMO_USAGE_DIR || join(process.env.HOME || '.', '.pocket-demo-usage');
  try { mkdirSync(usageDir, { recursive: true, mode: 0o700 }); } catch { /* the guard fails closed if the dir is unusable */ }
  demoGuard = createDemoBearerGuard({ expiresUnixSec: cfg.expiresUnixSec, maxPerMin: cfg.maxPerMin, maxCalls: cfg.maxCalls, maxBytes: cfg.maxBytes, fingerprint: demoFingerprint, persistDir: usageDir });
} else if (rawBearer && !cfg.valid) {
  process.stderr.write(`[live-demo] REFUSING demo capability — invalid config: ${cfg.reason}. Bearer DISABLED (fail-closed).\n`);
}

const { server, publicKeyB64url } = createLiveDemoServer({ apiBaseUrl, fetch: globalThis.fetch, run, knownSessionIdsFor, signingKey, reason: gemma && gemma.reason, brief: gemma && gemma.brief, ttsBackend, demoBearer, demoGuard });
server.listen(port, () => {
  process.stdout.write(`[live-demo] gateway :${port} -> api ${apiBaseUrl} | room ${demoSession} | sl=${slBin}\n`);
  process.stdout.write(`[live-demo] LOCAL runtime · in-memory idempotency · DEV ed25519 receipt key [${keyMode}] (real sig, NOT prod KMS)\n`);
  process.stdout.write(`[live-demo] receipt PUBKEY (Ed25519 x, base64url) = ${publicKeyB64url}\n`);
  if (demoBearer) {
    const st = demoGuard.stats();
    process.stdout.write(`[live-demo] PUBLIC demo capability BOUNDED (fp ${demoFingerprint}): scope=pocket:voice-ONLY · expiry=${new Date(st.expSec * 1000).toISOString()} · rate/min=${st.perMin} · maxCalls=${st.totCalls} · lifetimeMaxBytes=${st.totBytes} (perCall≤8192) · used={calls:${st.used.calls},bytes:${st.used.bytes}} · persisted=${st.persisted}\n`);
  } else {
    process.stdout.write(`[live-demo] demo capability DISABLED (${rawBearer ? 'invalid config -> fail-closed' : 'no POCKET_DEMO_BEARER'})\n`);
  }
  process.stdout.write(gemma ? `[live-demo] Gemma reasoning WIRED -> ${gemmaBaseUrl} (model ${gemma.model})\n` : '[live-demo] Gemma NOT wired\n');
  process.stdout.write(ttsBackend ? '[live-demo] Cartesia TTS WIRED (voice ' + String(process.env.TTS_VOICE_ID || '').slice(0, 8) + ') -> /tts live\n' : '[live-demo] Cartesia TTS NOT wired\n');
});
