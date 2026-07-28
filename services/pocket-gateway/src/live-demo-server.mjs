#!/usr/bin/env node
// live-demo-server.mjs — RUNNABLE entry for the LOCAL live-write demo. DEMO-ONLY (never deployed; prod is app.mjs).
// Forge Mac-hosts this + `cloudflared tunnel --url` exposes it. Honest scope: runtime LOCAL, idempotency in-memory,
// receipt signed by a DEV ed25519 key (a REAL signature, NOT the prod KMS key).
import { execFileSync } from 'node:child_process';
import { createPrivateKey, createHash } from 'node:crypto';
import { readFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { createLiveDemoServer, createDemoBearerGuard, validateDemoConfig } from './live-demo.mjs';
import { createReservationLedger } from './demo-ledger.mjs';
import { createGemmaBackend } from './gemma-backend.mjs';
import { createCartesiaBackend } from './cartesia-backend.mjs';

const apiBaseUrl = process.env.SENTI_API_BASE_URL || 'https://api.sentinelayer.com';
const port = Number(process.env.PORT || 8787);
const slBin = process.env.SL_BIN || 'sl';
const demoSession = process.env.DEMO_SESSION_ID || '6cf7e861-546a-4b9f-b937-39182a5bd395';

const run = (args) => { try { return execFileSync(slBin, args, { encoding: 'utf8', timeout: 15_000, maxBuffer: 8 * 1024 * 1024 }); } catch (e) { return (e && typeof e.stdout === 'string' && e.stdout) ? e.stdout : '{}'; } };
const knownSessionIdsFor = async () => [demoSession];

let signingKey;
try {
  if (process.env.DEMO_SIGNING_KEY_PATH) signingKey = createPrivateKey(readFileSync(process.env.DEMO_SIGNING_KEY_PATH));
  else if (process.env.DEMO_SIGNING_JWK) signingKey = createPrivateKey({ key: JSON.parse(process.env.DEMO_SIGNING_JWK), format: 'jwk' });
} catch (e) { process.stderr.write(`[live-demo] FAILED to load fixed signing key (${(e && e.message) || e}) — per-boot key\n`); signingKey = undefined; }
const keyMode = signingKey ? 'FIXED (stable pin)' : 'per-boot (app must re-pin)';

const gemmaBaseUrl = process.env.GEMMA_BASE_URL || '';
const gemma = gemmaBaseUrl ? createGemmaBackend({ baseUrl: gemmaBaseUrl, model: process.env.GEMMA_MODEL || 'gemma3', apiKey: process.env.GEMMA_API_KEY, fetch: globalThis.fetch }) : undefined;
const ttsBackend = process.env.CARTESIA_API_KEY ? createCartesiaBackend({ apiKey: process.env.CARTESIA_API_KEY, voiceId: process.env.TTS_VOICE_ID }) : undefined;

// PUBLIC demo-capability bounds. Config is BOOT-VALIDATED to strict positive safe integers within ceilings; INVALID =>
// the capability is REFUSED (bearer disabled -> 401), never coerced. Identity = FULL sha256(bearer) (capId); fp16 is
// display-only. The reservation ledger is PRE-PROVISIONED at boot (zero-spend) with owner/mode/no-link dir checks and a
// stale-lock clear (operator recovery); a provision failure REFUSES the capability. maxBytes = UTF-8 bytes, a
// conservative upper bound on Cartesia billable characters (bytes >= chars). The true cost anchor is a Cartesia
// account-level cap (operator action) — this in-host ledger is crash/restart/concurrency-safe, NOT rollback-proof.
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
let capId16 = '';
let disableReason = rawBearer ? (cfg.valid ? '' : cfg.reason) : 'no POCKET_DEMO_BEARER';
if (rawBearer && cfg.valid) {
  const capId = createHash('sha256').update(rawBearer).digest('hex');
  capId16 = capId.slice(0, 16);
  const usageDir = process.env.POCKET_DEMO_USAGE_DIR || join(process.env.HOME || '.', '.pocket-demo-usage');
  try {
    mkdirSync(usageDir, { recursive: true, mode: 0o700 });
    const ledger = createReservationLedger({ dir: usageDir, capId, maxCalls: cfg.maxCalls, maxBytes: cfg.maxBytes });
    ledger.provision(); // owner/mode/no-link checks + stale-lock clear + zero-spend provision (throws => refuse)
    demoGuard = createDemoBearerGuard({ expiresUnixSec: cfg.expiresUnixSec, maxPerMin: cfg.maxPerMin, ledger });
    demoBearer = rawBearer;
  } catch (e) { disableReason = 'ledger provision failed: ' + ((e && e.message) || e); }
}
if (rawBearer && !demoBearer) process.stderr.write(`[live-demo] REFUSING demo capability (fail-closed): ${disableReason}\n`);

const { server, publicKeyB64url } = createLiveDemoServer({ apiBaseUrl, fetch: globalThis.fetch, run, knownSessionIdsFor, signingKey, reason: gemma && gemma.reason, brief: gemma && gemma.brief, ttsBackend, demoBearer, demoGuard });
server.listen(port, () => {
  process.stdout.write(`[live-demo] gateway :${port} -> api ${apiBaseUrl} | room ${demoSession} | sl=${slBin}\n`);
  process.stdout.write(`[live-demo] LOCAL runtime · in-memory idempotency · DEV ed25519 receipt key [${keyMode}]\n`);
  process.stdout.write(`[live-demo] receipt PUBKEY (Ed25519 x, base64url) = ${publicKeyB64url}\n`);
  if (demoBearer) {
    const st = demoGuard.stats();
    process.stdout.write(`[live-demo] PUBLIC demo capability BOUNDED (capId16 ${capId16}): scope=pocket:voice-ONLY · expiry=${new Date(st.expSec * 1000).toISOString()} · rate/min=${st.perMin} · maxCalls=${cfg.maxCalls} · lifetimeMaxBytes=${cfg.maxBytes} (perCall≤8192, bytes≥billable-chars) · used={calls:${st.used.calls},bytes:${st.used.bytes}} · provisioned=${st.used.provisioned}\n`);
  } else {
    process.stdout.write(`[live-demo] demo capability DISABLED (${disableReason})\n`);
  }
  process.stdout.write(gemma ? `[live-demo] Gemma WIRED -> ${gemmaBaseUrl}\n` : '[live-demo] Gemma NOT wired\n');
  process.stdout.write(ttsBackend ? '[live-demo] Cartesia TTS WIRED -> /tts live\n' : '[live-demo] Cartesia TTS NOT wired\n');
});
