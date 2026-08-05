# pocket-gateway (Relay lane)

Backend for Senti Pocket. Owner: **claude-pocket-relay**. Consumes `PocketContracts` v0.1 (does not edit it).

The core is Node ESM with **zero external deps** (uses `node:child_process`, `node:crypto`, `node:test`) and runs on
Node ≥20 with no install. The isolated production admission artifact under `deploy/operation-admission` targets Node 22
and pins its AWS SDK/build dependencies in a separate lockfile; those dependencies do not enter the core package.

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
- **Auth (done):** `src/senti-session-verifier.mjs` is the deployed reusable-session path: bounded `GET /auth/me`,
  positive-only process-local cache, deeply frozen identity, and strict invalid-vs-upstream-outage handling. `src/auth.mjs`
  remains the supported AIdenID alternative: JWT/JWKS verification plus RFC 8707 resource and RFC 9449 DPoP binding.
- **Store (done):** `src/store.mjs` — async store: in-memory (dev/tests) + `createDynamoStore` (real conditional-put,
  OWNER-FENCED lock + `putIfAbsent` + TTL; deploy injects the `@aws-sdk/lib-dynamodb` client → package stays zero-dep)
  + `createStoreReplayGuard` (cross-instance single-use for DPoP and internal admission-assertion JTIs).
- **Device Registry V2 (code-complete, deploy-unverified):** `src/device-registry-v2.mjs` — server-HMAC-keyed
  installation, token-owner, and bounded target-directory authority moves atomically in DynamoDB without a GSI
  correctness dependency. Stable owner handles, durable operation outcomes, exact binding/token-claim CAS fences,
  displaced-owner eviction, ABA-safe directories, hard 20-installation admission, exact revoke, logical leases,
  reclaim grace, stable-read fencing, and bounded serialization are covered hermetically. Pushes carry the server's
  nested `v:2` binding fence and perform one bounded exact-route snapshot immediately before concurrent APNs fanout.
  The V1 migration lane is exact-principal scoped, expiring, and ignores historical untagged rows. Registry V2 remains
  disabled until the explicit backend/iOS/purge acknowledgements in `API.md` and `DEPLOY.md` are satisfied.
- **Registry V2 operation admission (code-complete, dark/deploy-unverified):** `src/operation-admission*.mjs` plus
  `deploy/operation-admission` enforce one cross-instance opaque CAS ledger per authenticated owner (256 live, 30 new
  per rolling minute, 60 total requests per rolling minute), exact replay handling, reusable-Senti-only auth, pinned
  HMAC Secret ARN + `VersionId`, exact-route rejection, and a private invocation pinned pre-execution to an attested
  numeric gateway version (with a matching `ExecutedVersion` response assertion). Admission validates `/auth/me` once;
  the private gateway then requires a 10-second request-bound assertion and atomically consumes its signed 256-bit
  `jti`, preserving the verifier's canonical scopes without a second external-auth call. The Terraform stack in
  `infra/terraform/operation-admission` performs provider-native exact-version runtime attestation, records the gateway
  artifact digest as separate release evidence, and pins both public integrations to numeric Lambda versions rather
  than mutable aliases. Enabled production creates a module-owned AWS Signer configuration with one immutable publisher
  and `Enforce`; CI proves only the reproducible unsigned source ZIP, while production requires the immutable signed S3
  object. Provisioning, proof-digest-gated route mapping, and proof-digest-gated DNS publication remain separate. Public
  activation is still blocked on the distributed context limiter and proof that the upstream 30-request/IP `/auth/me`
  bucket supports the protected lane's 60-request contract across cold/multi-instance egress.
- **Backends/adapters (done):** `src/lambda.mjs` (API Gateway HTTP API v2 ⇄ gateway, base64 binary, DPoP url/method), `src/tts.mjs` (ElevenLabs backend; key server-side only, `fetch` injected), `src/app.mjs` (deploy composition → `createLambda(env, deps)`).
- **Writeback (done):** governed writeback (snapshot-frozen deterministic target → single-use confirm bound to proposal hash → server-time freshness → reserve-before-post exactly-once → `sl session reply` → read-back verify → signed `ActionReceipt`; offline ⇒ `pendingConnectivity`). Live-proven twice.
- **Open (deploy/cross-lane):** DynamoDB table/TTL + IAM + AWS creds; Registry V1 row purge + HMAC secret; real APNs
  VoIP transport; JWKS fetch/cache + Ed25519 signing key from KMS/Secrets; a senti `run`ner available in Lambda (bundled
  `sl` or senti API client); bind checkpoint provenance/`contentTrust` into the SIGNED bundle canonical (Atlas's
  contract); LLM-enriched summary prose (same grounded evidence); Swift/Xcode build, simulator, device, and signing
  validation on a Mac.

## Safety invariants (Relay-owned)
- **Secret redaction is BEST-EFFORT, not a guarantee.** `scrub.mjs` is a known-format denylist + conservative high-entropy heuristics; it cannot prove content is secret-free (an arbitrary/natural-language secret survives). Mitigated by defense-in-depth: minimal-field projection + size bounds (`extract.mjs`), a **final egress scrub over every phone-visible string before signing** (`bundle.mjs`), and treating all residual content as untrusted. Raw room events never cross to the phone — only the summary + bounded evidence do.
- **Checkpoint completeness/provenance:** a bundle is built ONLY from a real durable checkpoint whose entire range is contained in the export window (never overlap, never a synthesized/fabricated checkpoint). Missing/partial range ⇒ honest retryable error, no bundle.
- **Numeric bounds:** sequence ids are positive safe integers, strictly increasing + unique; event/agent counts, span, and field/payload sizes are all bounded before allocation/signing.
- No secrets or unrestricted private room history in fixtures.
- Writes: snapshot-frozen proposal, single-use confirmation bound to the exact proposal hash, server-time freshness, reserve-before-post exactly-once, read-back verification, real `ActionResultRef` or explicit failure — never a false "sent".

## Test
```
cd services/pocket-gateway && node --test

cd deploy/operation-admission
npm ci
npm test
npm run package
```
