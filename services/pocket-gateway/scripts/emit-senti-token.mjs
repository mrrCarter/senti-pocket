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

const require = createRequire(import.meta.url);
let sessionStorePath;
try {
  sessionStorePath = require.resolve('sentinelayer-cli/src/auth/session-store.js');
} catch {
  process.stderr.write('emit-senti-token: sentinelayer-cli not resolvable here — run where `sl` is installed (the demo Mac)\n');
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
