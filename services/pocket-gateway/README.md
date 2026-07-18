# pocket-gateway (Relay lane)

Backend for Senti Pocket. Owner: **claude-pocket-relay**. Consumes `PocketContracts` v0.1 (does not edit it).

Node ESM, **zero external deps** (uses `node:child_process`, `node:crypto`, `node:test`) so it runs on any Node ≥20 with no install — deliberate given the current disk/CI constraints.

## Pipeline
```
sl session checkpoint list <SID>  ─┐
sl session export <SID>           ─┴─►  buildRawCheckpoint()  ─►  RawCheckpoint (secret-scrubbed)
                                            │
                                            ├─► summarize()      ─► CheckpointSummary (perAgent + evidence)   [P1]
                                            └─► buildBundle()    ─► PocketBundle (Ed25519 signed)             [P1]
                                                                       │
                                              sync API  ◄──────────────┘   (phone pulls bundles)             [P2]
                                              actions API: ActionProposal ─► confirm ─► sl session reply ─► ActionReceipt  [P3]
```

## Status
- **P0 (done):** `src/scrub.mjs` (secret redaction) + `src/extract.mjs` (`sl export` → `[start,end]` slice → `RawCheckpoint`, contract-validated). Tests: `node --test` (hermetic; injected `sl` runner).
- **P1 (next):** summarizer (senti `summarySections` baseline → per-agent evidence-cited claims) + Ed25519 `PocketBundle` signing → must decode into the frozen `canonical_checkpoint.json` shape.
- **P3 (held):** governed writeback (`ActionProposal` → deterministic target resolution → single-use confirm bound to proposal hash → `sl session reply` → `ActionReceipt`; offline ⇒ `pendingConnectivity`, never "sent"). Held until the P1 offline slice passes 5×.

## Safety invariants (Relay-owned)
- Every payload is secret-scrubbed **before** it can enter a `RawEvent`/bundle that reaches the phone.
- No secrets or unrestricted private room history in fixtures.
- Writes: deterministic target/sequence resolution, single-use confirmation bound to the exact proposal hash, real resulting sequence or explicit failure — never a false "sent".

## Test
```
cd services/pocket-gateway && node --test
```
