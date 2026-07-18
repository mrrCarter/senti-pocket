# PocketActionsClient

Owner: **claude-pocket-relay**. Governed writeback + receipts + offline pending intents.

- `SentiActionClient`: `resolveTarget` (deterministic, rejects out-of-scope) → `prepare` (read-back
  + binding hash) → `confirmAndPost` (idempotent write, real receipt or explicit failure) →
  `queuePending` / `reconcilePending` (offline, PENDING never shown as sent).
- `ReceiptVerifier`: re-checks target + proposal hash + signature before the phone shows "sent";
  offline-safe.
- Safety model mirrors the live-verified `sl session reply` action (idempotent, target-bound):
  see `services/pocket-gateway/CHECKPOINT_ACCESS.md §4` and `DESIGN.md`.

Execution is **P3 and warden-gated** — this package is interface + safety types only. Types are
**INTERIM**; replace with `import PocketContracts` (Atlas v0.1) at freeze.
