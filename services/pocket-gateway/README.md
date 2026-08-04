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
- **Device Registry V2 (done in source):** installation-global monotonic generation heads use Dynamo conditional
  writes; targets use the verifier's full principal namespace while membership remains human-ID based. Bounded
  target-slot reservations and one global, topic/environment-scoped APNs token claim are acquired before a head can
  change, so a cap/duplicate-token loser cannot strand its prior binding; a synchronous token-claim loser also
  conditionally releases its exact earlier target reservation without erasing a same-generation sibling retry.
  Installation/target/token values are
  HMAC-derived, while the raw APNs token is confined to its generation-specific expiring lease. Unregister advances to
  a durable tombstone and conditionally releases only the exact token owner. Lookup and pre-send revalidation require
  index, head, lease, and token claim to agree. A durable token claim also prevents a migrated token from resurfacing
  through V1. New V1 compatibility rows are tagged and keyed by the same full principal; historical untagged rows fail
  closed rather than becoming cross-site authority. Distinct scoped legacy devices can remain during the grace window.
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

## Registry V2 rollout

Set `DIAL_REGISTRY_HMAC_KEY` to independent high-entropy secret material of at least 32 bytes. Set the non-secret
`DIAL_REGISTRY_TOKEN_SCOPE` to the exact APNs topic/environment namespace, for example
`com.plexaura.sentipocket.app:development`; production refuses to enable V2 without it. Rotate either only with an
explicit registry migration because changing them changes derived ownership keys. During rollout, V1 registration and
lookup remain enabled by default, but only for new exact-principal-tagged V1 rows; historical human-only rows are not
accepted because their originating site cannot be proven. Once supported iOS builds have renewed onto V2, set:

```text
DIAL_REGISTRY_V2_REQUIRED=1
DIAL_REGISTRY_TOKEN_SCOPE=com.plexaura.sentipocket.app:development
DIAL_REGISTRY_ALLOW_V1=0
DIAL_REGISTRY_READ_V1=0
```

`DIAL_REGISTRY_V2_REQUIRED=1` makes a missing HMAC key a boot error; any configured HMAC key makes a missing token
scope a boot error. Durable V2 installation heads, token migration claims, and CAS records must not receive a Dynamo
TTL. Leases and short reservations enforce logical expiry even while physical records remain. The table role needs the
existing Get/Put/Delete actions plus permission for conditional `PutItem`.
