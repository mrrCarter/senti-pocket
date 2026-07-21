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
- **P0 (done):** `src/scrub.mjs` (best-effort redaction) + `src/extract.mjs` (`sl export` → durable+contained `[start,end]` slice → `RawCheckpoint`, eventCount-complete, bounded, contract-validated). Tests: `node --test` (hermetic; injected `sl` runner).
- **P1 (done):** `src/summarize.mjs` (deterministic grounded baseline: senti `summarySections` passthrough + per-agent evidence anchored to real event sequences) → `src/bundle.mjs` Ed25519 `PocketBundle` signing with strict frozen-schema egress projection. Full pipeline `extract → summarize → buildSignedBundle → verifyBundle` is tested end-to-end.
- **API (done):** `src/handlers.mjs` (`GET /health`, `GET /sync`, `POST /actions/execute`, `POST /tts`). Fail-closed auth; per-human namespaced idempotency; cross-instance exactly-once writeback (durable in-flight reservation + content-based crash recovery).
- **Auth (done):** `src/auth.mjs` — REAL AIdenID bearer verification: JWT signature against a JWKS, `iss/aud/exp/nbf`, RFC 8707 resource indicator, and DPoP proof-of-possession (RFC 9449 — thumbprint binding + `htm/htu/ath/iat` + single-use `jti` replay defense). Not a stub; JWKS/issuer/audience/resource are deploy config.
- **Store (done):** `src/store.mjs` — async store: in-memory (dev/tests) + `createDynamoStore` (real conditional-put, OWNER-FENCED lock + `putIfAbsent` + TTL; deploy injects the `@aws-sdk/lib-dynamodb` client → package stays zero-dep) + `createStoreReplayGuard` (cross-instance DPoP jti single-use).
- **Backends/adapters (done):** `src/lambda.mjs` (API Gateway HTTP API v2 ⇄ gateway, base64 binary, DPoP url/method), `src/tts.mjs` (ElevenLabs backend; key server-side only, `fetch` injected), `src/app.mjs` (deploy composition → `createLambda(env, deps)`).
- **Writeback (done):** governed writeback (snapshot-frozen deterministic target → single-use confirm bound to proposal hash → server-time freshness → reserve-before-post exactly-once → `sl session reply` → read-back verify → signed `ActionReceipt`; offline ⇒ `pendingConnectivity`). Live-proven twice.
- **Open (deploy/cross-lane):** DynamoDB table + IAM + AWS creds; JWKS fetch/cache + Ed25519 signing key from KMS/Secrets; a senti `run`ner available in Lambda (bundled `sl` or senti API client); bind checkpoint provenance/`contentTrust` into the SIGNED bundle canonical (Atlas's contract); LLM-enriched summary prose (same grounded evidence); Swift client packages (need a Mac).

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
