#!/usr/bin/env node
// emit-senti-token.mjs — emit the host's stored SENTI USER-SESSION bearer to stdout (transient use only).
//
// `sl auth token` does NOT exist (verified: 0.39.2 auth subcommands = login/status/sessions/revoke/logout). This imports
// the CLI's OWN exported `readStoredSession` (session-store.js:584 — the real keyring/Keychain decrypt path, NOT a
// re-implementation) and prints the resolved session token. Run ON A HOST whose `sl` is logged in (the demo Mac = mrrCarter).
//
// The token goes to STDOUT ONLY — pipe it straight into an env var; this script logs nothing else, writes no file.
//   SENTI_TOKEN=$(node services/pocket-gateway/scripts/emit-senti-token.mjs) && [ -n "$SENTI_TOKEN" ] && \
//     GATEWAY_URL=http://localhost:8787 ROOM=6cf7e861-... SL_BIN=sl node services/pocket-gateway/scripts/warden-live-verify.mjs
//
// Yields the USER-SESSION token (resolveAuth source:"session" = auth_method=bearer = what /human-message accepts — NOT a
// scoped agent token). Exits non-zero with an empty stdout if there is no usable session (then `sl auth login` first, or
// Carter supplies the bearer transiently). NEVER log/print/commit the emitted value.
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const require = createRequire(import.meta.url);

// Resolve the CLI's session-store.js robustly — the Mac's `sl` is likely npm-GLOBAL, which require.resolve won't find
// from a local dir. Order: explicit SL_PKG_DIR env → local dep → `npm root -g` → the `sl` binary's real target dir.
function resolveSessionStore() {
  const rel = 'src/auth/session-store.js';
  const candidates = [];
  if (process.env.SL_PKG_DIR) candidates.push(path.join(process.env.SL_PKG_DIR, rel));
  try { candidates.push(require.resolve('sentinelayer-cli/' + rel)); } catch { /* not a local dep */ }
  try {
    const gRoot = execFileSync('npm', ['root', '-g'], { encoding: 'utf8' }).trim();
    if (gRoot) candidates.push(path.join(gRoot, 'sentinelayer-cli', rel));
  } catch { /* npm not on PATH */ }
  try {
    const slBin = execFileSync(process.platform === 'win32' ? 'where' : 'which', [process.env.SL_BIN || 'sl'], { encoding: 'utf8' }).split(/\r?\n/)[0].trim();
    const real = fs.realpathSync(slBin);              // resolve the symlink to the actual bin script
    candidates.push(path.join(real, '..', '..', rel)); // <pkg>/bin/*.js -> <pkg>/src/auth/session-store.js
  } catch { /* sl not on PATH */ }
  return candidates.find((p) => { try { return fs.existsSync(p); } catch { return false; } }) || null;
}

const sessionStorePath = resolveSessionStore();
if (!sessionStorePath) {
  process.stderr.write('emit-senti-token: could not locate sentinelayer-cli session-store.js. Set SL_PKG_DIR=<npm root -g>/sentinelayer-cli and retry.\n');
  process.exit(2);
}

const { readStoredSession } = await import(sessionStorePath);
let s = null;
try {
  s = await readStoredSession({});
} catch (e) {
  process.stderr.write('emit-senti-token: readStoredSession threw (keytar unavailable?) — `sl auth login`, or supply the bearer\n');
  process.exit(3);
}

const token = s && typeof s.token === 'string' ? s.token.trim() : '';
if (!token) {
  process.stderr.write('emit-senti-token: no usable stored session — run `sl auth login` first, or provide the bearer transiently\n');
  process.exit(4);
}
process.stdout.write(token); // STDOUT ONLY — pipe to SENTI_TOKEN; never logged/committed
