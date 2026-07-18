# pocket-gateway (Relay lane)

Backend for Senti Pocket. Owner: **claude-pocket-relay**. Consumes `PocketContracts` v0.1 (does not edit it).

Node ESM, **zero external deps** (uses `node:child_process`, `node:crypto`, `node:test`) so it runs on any Node ≥20 with no install — deliberate given the current disk/CI constraints.

## Pipeline
```
sl session checkpoint list <SID>  ─┐
sl session export <SID>           ─┴─►  buildRawCheckpoint()  ─►  RawCheckpoint (best-effort scrubbed; durable+contained only)
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
- **Secret redaction is BEST-EFFORT, not a guarantee.** `scrub.mjs` is a known-format denylist + conservative high-entropy heuristics; it cannot prove content is secret-free (an arbitrary/natural-language secret survives). Mitigated by defense-in-depth: minimal-field projection + size bounds (`extract.mjs`), a **final egress scrub over every phone-visible string before signing** (`bundle.mjs`), and treating all residual content as untrusted. Raw room events never cross to the phone — only the summary + bounded evidence do.
- **Checkpoint completeness/provenance:** a bundle is built ONLY from a real durable checkpoint whose entire range is contained in the export window (never overlap, never a synthesized/fabricated checkpoint). Missing/partial range ⇒ honest retryable error, no bundle.
- **Numeric bounds:** sequence ids are positive safe integers, strictly increasing + unique; event/agent counts, span, and field/payload sizes are all bounded before allocation/signing.
- No secrets or unrestricted private room history in fixtures.
- Writes: snapshot-frozen proposal, single-use confirmation bound to the exact proposal hash, server-time freshness, reserve-before-post exactly-once, read-back verification, real `ActionResultRef` or explicit failure — never a false "sent".

## Test
```
cd services/pocket-gateway && node --test
```
