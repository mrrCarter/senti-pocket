# pocket-gateway

Senti Pocket gateway — owner **claude-pocket-relay**.

Pipeline: **RAW Senti export → bounded RawCheckpoint → grounded CheckpointSummary → signed
PocketBundle → (P3) governed writeback → receipts**. Deterministic and side-effect free through
the bundle stage (no network, no writeback).

- **`CHECKPOINT_ACCESS.md`** — how a real Senti checkpoint is obtained today (live-verified commands + data shapes). Read this first.
- **`DESIGN.md`** — authorization (AIdenID scope), idempotency, offline pending intents, and honest gaps.
- **`src/`** — the pipeline (TypeScript, erasable-syntax; runs under Node 22 `--experimental-strip-types`).

## Run it (Node 20/22, no install needed)

```sh
# smoke on the committed synthetic fixture (no real transcript)
node --experimental-strip-types src/cli.ts fixtures/raw_export.sample.json

# emit the full bundle JSON
POCKET_EMIT_BUNDLE=1 node --experimental-strip-types src/cli.ts fixtures/raw_export.sample.json

# on a REAL room (never commit the output — it holds private transcript):
sl session export <SID> --json > /tmp/room.export.json
node --experimental-strip-types src/cli.ts /tmp/room.export.json

# tests
node --experimental-strip-types --test "test/**/*.test.ts"
```

The CLI exits **non-zero** if any cited quote fails verification against the raw transcript — a
miniature of the P1 grounding gate.

## Status

BUILT + tested: read recipe, extract→summarize(stub)→bundle, grounding verification, idempotent
reply proof. DESIGNED (not built): governed write execution, AIdenID scoped grant, offline
pending-intent store — all P3/warden-gated. See `DESIGN.md` §5.

## Contract alignment

`src/contracts.interim.ts` mirrors **live-verified** Senti shapes (facts) and defines **interim**
Pocket contracts shaped to the pinned baseline. Replace the Pocket types with an import of Atlas's
`packages/PocketContracts` v0.1 at freeze — alignment is a re-type, not a redesign.
