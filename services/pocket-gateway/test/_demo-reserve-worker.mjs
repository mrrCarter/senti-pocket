// _demo-reserve-worker.mjs — spawned by the concurrency test. Reserves W_ATTEMPTS times against a SHARED ledger
// (W_DIR + W_FP) and prints the number of successful reservations. N of these in parallel must not over-spend.
import { createDemoBearerGuard } from '../src/live-demo.mjs';
const g = createDemoBearerGuard({
  expiresUnixSec: Number(process.env.W_EXP),
  maxPerMin: 1_000_000,
  maxCalls: Number(process.env.W_CALLS),
  maxBytes: Number(process.env.W_BYTES),
  fingerprint: process.env.W_FP,
  persistDir: process.env.W_DIR,
});
let ok = 0;
for (let i = 0; i < Number(process.env.W_ATTEMPTS); i++) { if (g.reserveTts(1).ok) ok += 1; }
process.stdout.write(String(ok));
