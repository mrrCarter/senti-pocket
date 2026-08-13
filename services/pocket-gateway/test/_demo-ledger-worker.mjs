// _demo-ledger-worker.mjs — spawned by the contention gate. Reserves W_ATTEMPTS times against a SHARED pre-provisioned
// ledger and prints the count of successful reservations. N in parallel must never exceed maxCalls (no over-spend).
import { createReservationLedger } from '../src/demo-ledger.mjs';
// This is a SPAWNED helper, not a standalone test. `node --test` auto-discovers files in test/, so exit cleanly when
// invoked without the spawn env (no work, no crash) — the contention test in demo-ledger.test.mjs runs it with env.
if (!process.env.W_CAPID || !process.env.W_DIR) process.exit(0);
const L = createReservationLedger({ dir: process.env.W_DIR, capId: process.env.W_CAPID, maxCalls: Number(process.env.W_CALLS), maxBytes: Number(process.env.W_BYTES) });
let ok = 0;
for (let i = 0; i < Number(process.env.W_ATTEMPTS); i++) { if (L.reserve(1).ok) ok += 1; }
process.stdout.write(String(ok));
