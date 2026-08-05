# pocket-gateway (Relay lane)

Backend for Senti Pocket. Owner: **claude-pocket-relay**. Consumes `PocketContracts` v0.1 (does not edit it).

The core is Node ESM with **zero external deps** (uses `node:child_process`, `node:crypto`, `node:test`) and runs on
Node ≥20 with no install. The isolated production artifacts under `deploy/gateway` and `deploy/operation-admission`
target Node 22 and pin their AWS SDK/build dependencies in separate lockfiles; those dependencies do not enter the core
package.

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
- **Target membership (code-complete, dark):** `src/senti-target-membership.mjs` asks the fixed SentinelLayer API origin
  for exactly one bearer-bound session role, streams the response through a 4 KiB cap, validates the exact no-store
  contract, and caches only short-lived role/null decisions under hashed credential+target keys. Route policy preserves
  role: viewer may read/self-dial/register/hydrate; `/actions/execute` and `/dial/ring-owner` require contributor or
  higher before any durable mutation, runner, post, or push. Production composition never accepts a static membership
  allowlist. Keep the gateway route dark until sentinelayer-api PR #783 is merged, deployed, and smoke-proven with an
  exact known-member 200 plus a uniform nonmember 404.
- **Private gateway deployment boundary (code-complete, dark/unprovisioned):** `deploy/gateway` resolves only immutable
  receipt-signing, Registry HMAC, and optional APNs secret versions at cold start, then composes the production gateway
  without a legacy membership adapter. `infra/terraform/gateway` defaults disabled and APNs-off, owns the encrypted
  table/logs/runtime role and one signed numeric Lambda version, and creates no route, Function URL, alias, invocation
  permission, or DNS. CI builds the deterministic unsigned source ZIP and validates the topology without AWS OIDC,
  signing, upload, or deployment. Real signed-object, AWS, API #783 smoke, APNs, and physical-device evidence remain
  release gates.
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
- **Registry cutover evidence tooling (code-complete, live-unexecuted):** `deploy/gateway/scripts/registry-cutover.mjs`
  performs a read-only sanitized six-prefix plan and a separately gated V1-only purge. Exact table-incarnation binding,
  a fixed five-minute plan checksum, external writer-fence/drain evidence digests, single-attempt conditional deletes,
  and two independent final empty scans fail closed without changing deployment/readiness state. A real writer fence is
  still operator-owned because strongly consistent scans are not cross-page snapshots.
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
- **Open (deploy/cross-lane):** merge/deploy/smoke-prove the target-membership API prerequisite; provision the private
  gateway and admission stacks with reviewed signed artifacts/AWS inputs; execute and retain the fenced Registry V1
  purge/zero proof; provision the immutable Registry HMAC secret; real APNs provider secret, matching
  entitlement/device token, and handset proof;
  JWKS fetch/cache + Ed25519 signing key from KMS/Secrets; a senti `run`ner available in Lambda (bundled
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

cd deploy/gateway
npm ci
npm test
npm run package

cd deploy/operation-admission
npm ci
npm test
npm run package
```
