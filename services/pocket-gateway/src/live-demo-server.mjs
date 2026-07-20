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
import { createLiveDemoServer } from './live-demo.mjs';

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

const { server, publicKeyB64url } = createLiveDemoServer({ apiBaseUrl, fetch: globalThis.fetch, run, knownSessionIdsFor });
server.listen(port, () => {
  // Startup lines only — no secrets (apiBaseUrl / port / session / bin path / PUBLIC key); the gateway logs nothing per-request.
  process.stdout.write(`[live-demo] gateway :${port} -> api ${apiBaseUrl} | room ${demoSession} | sl=${slBin}\n`);
  process.stdout.write('[live-demo] LOCAL runtime · in-memory idempotency · DEV ed25519 receipt key (real sig, NOT prod KMS)\n');
  process.stdout.write(`[live-demo] receipt PUBKEY (Ed25519 x, base64url) = ${publicKeyB64url}\n`);
  process.stdout.write(`[live-demo]   the app PINS this (or GET :${port}/demo-pubkey) to verify ActionReceipt sigs — never render "sent" unless signatureState==.verified\n`);
  process.stdout.write('[live-demo] POST /actions/execute with the caller\'s SENTI user-session bearer to author as human-<you>\n');
});
