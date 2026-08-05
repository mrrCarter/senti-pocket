# Pocket Gateway — Deploy Runbook

The core gateway is a **zero-dependency ESM Lambda**. Its core (`createGateway`) takes a `{method,path,query,headers,body}`
request and returns `{status,headers,body}` — no framework, no ambient I/O. Everything it touches (DynamoDB, the signing
key, `fetch`, the senti runner, the feature backends) is an **injected external** the deploy owns. The production
entrypoint under `deploy/gateway` and private module under `infra/terraform/gateway` package that boundary without
creating public ingress. Registry V2 additionally uses the body-reading service in `operation-admission*.mjs`, a
separate admission table, and the dark Terraform boundary under `infra/terraform/operation-admission`. The core and
admission Lambdas remain separate compute; every network/AWS boundary is explicit and injected.

> **Honesty note:** this documents the deploy *contract*. The core and both isolated Lambda artifacts are tested, and
> the private gateway plus admission IaC are implemented, but none of that is evidence of a live AWS deployment. The
> gateway stays private and APNs-off by default. Registry V2 is not deploy-complete until the prerequisite API and live
> two-instance Dynamo, route/IAM, auth, cutover, APNs, and physical-device evidence are retained; keep V2 disabled. Each
> optional feature backend
> below fails **closed** (a `501` with a typed reason) until its dependency is wired—never a fabricated response.

---

## 1. AWS resources (four core; Registry V2 adds admission compute)

| Resource | Purpose | Notes |
|---|---|---|
| **Lambda** (Node 22, ESM) | runs the locked `deploy/gateway` artifact | immutable numeric versions behind explicit API Gateway routes; no Function URL in Registry V2 |
| **DynamoDB table** | durable state: idempotency/emitted markers + cross-instance locks + proof-jti replay records | single-table, schema below |
| **Secrets Manager secrets** | the Ed25519 **signing key** (receipts/bundles), plus the Registry V2 HMAC key when V2 is enabled | KMS asymmetric does **not** do EdDSA — store the PKCS#8 PEM and independent 32-byte-or-longer HMAC key in separate secrets |
| **API Gateway (HTTP API)** | sole public HTTPS ingress | explicit routes only; no `$default`, Function URL, or public gateway-Lambda integration for either protected POST |
| **Body-reading admission proxy** *(Registry V2 only; additional Lambda/service)* | verifies the caller and atomically admits bounded register/reconcile operation identities before invoking one immutable numeric gateway version | uses a separate encrypted DynamoDB table; an API Gateway/Lambda authorizer alone cannot inspect the JSON body and is insufficient |

### DynamoDB table schema

Single table, composite key, TTL enabled:

- **Partition key** `pk` (String)
- **Sort key** `sk` (String) — the store writes `sk = "record"` (durable state) and `sk = "lock"` (self-healing locks)
- **TTL attribute** `ttl` (Number, epoch-seconds) — **enable DynamoDB TTL on this attribute**. Locks carry a `ttl`
  so a crash-before-release self-heals; DPoP jti replay records carry a `ttl` so they expire. Internal admission
  assertion replay records use `pk=operation-admission-assertion-jti:v1:<jti>`, `sk=record`, and top-level `ttl=exp`.
  Schema records intended to be non-expiring omit `ttl`; other schema-owned rows use their documented bounded TTL.
- **Registry V2 items** (required only for `DEVICE_REGISTRY_MODE=v2`; no GSI):
  - Installation base: `pk=dial:install:v2:<server-HMAC>`, `sk=binding`. It stores `ownerVersion:1` plus the canonical
    opaque `ownerHandle` derived from the verifier-owned principal and human identity.
  - Global token owner: `pk=dial:token:v2:<server-HMAC>`, `sk=claim`. The claim stores a token digest/HMAC, never a
    second raw-token copy, and carries the same owner version/handle as its protected binding.
  - Bounded target directory: `pk=dial:target:v2:<server-HMAC>`, `sk=directory`. It stores a random `directoryId`,
    monotonic revision, schema-fixed capacity 20, and at most 20
    `{installationKey,bindingId,bindingRevision,expiresAtEpochSec}` members—no raw installation id or token.
  - Terminal registration operation: `pk=dial:regop:v2:<server-HMAC>`, `sk=outcome`. Exactly one row exists per
    authenticated-principal + installation + idempotency UUID. It stores only a server-HMAC request fingerprint,
    `ownerVersion:1`, the canonical owner handle, `DENIED|COMMITTED`, timestamps/TTL, and—only when committed—the exact
    binding/claim fences. It never stores a raw principal, installation id, UUID, session id, or token/digest.
  - Registration, rebind, token-owner transfer, renewal, and revoke update every affected base/claim/directory plus the
    operation outcome in one `TransactWrite`. A denial is a conditional terminal write against that same operation key.
    Lookup strongly reads one directory and then at most 20 exact base/claim pairs. An explicit token
    transfer deletes the displaced base and directory member atomically, so active zombie bindings cannot consume
    capacity or remain addressable. `{directoryId,revision}` conditions fence delete/recreate ABA.
  - A full-target lookup makes at most 42 strongly consistent `GetItem` requests in four dependency rounds: directory,
    up to 20 bases in parallel, up to 20 claims in parallel, then the directory stability re-read. Budget Dynamo read
    capacity, connection concurrency, and Lambda timeout for that fixed bound. Batched reads are a future latency
    optimization, not a correctness dependency.
- Billing: on-demand is appropriate only behind the verified-principal unique-operation admission gate below; it is not
  a substitute for a cardinality/rate bound.

### Admission table schema

Use a separate table so the admission role cannot read or mutate registry bindings, claims, directories, outcomes, or
gateway state. It has the same `pk` String / `sk` String key convention and top-level DynamoDB TTL attribute `ttl`:

- `pk=dial:admission:v1:<owner HMAC>`, `sk=record`;
- one exact-schema ledger per verified owner, containing a uint64 CAS revision, at most 256 opaque operation digests and
  expiries, at most 30 new-operation timestamps, and at most 60 total-request timestamps;
- on-demand billing, strongly consistent reads, conditional whole-item puts, SSE-KMS, PITR, TTL on `ttl`, production
  deletion protection, and no scan/query permission for the Lambda role; and
- physical TTL is cleanup only. Runtime pruning enforces operation and strict rolling-window expiry even while DynamoDB
  retains an expired item. The written TTL covers both the latest operation expiry and the final rolling-window tail.

The runtime rejects a ledger over 64 KiB, schema/config drift, unreachable timestamp relationships, revision overflow,
clock rollback, storage errors, or exhausted CAS contention. It never resets corrupt state or converts failure into an
admission.

The gateway's locks tolerate DynamoDB's TTL **deletion lag** (they steal a logically-expired lock via a conditional
put), so no tight TTL sweep is required. Registry V2 also filters `expiresAtEpochSec <= now` synchronously; it never
waits for DynamoDB's asynchronous physical TTL deletion to stop a ring. Registry V2 stores
`ttl = expiresAtEpochSec + 300`: the fixed five-minute physical-deletion/reclaim grace keeps a slow worker from treating
an old route as active after a faster worker has automatically reassigned its token. A base or claim remains protected
from every different owner through `ttl - 1`, even when the caller copied its exact CAS fence; only the same stable owner
may renew/rebind or transfer during grace. Exactly at `ttl`, retained base/claim rows become semantically absent and can
be reclaimed atomically without waiting for DynamoDB's asynchronous physical deletion.

Registry V2 capacity `20` is part of the persisted directory schema, not a per-instance tuning knob. Changing it
requires a versioned schema migration. Keep each Registry V2 table/HMAC namespace scoped to one push-routing domain
(for APNs, one environment + topic; for FCM, one project). The current token-owner HMAC binds `(platform,token)`; sharing
one table across additional provider environments/topics requires adding that routing-domain id to a future schema
beforehand. `DEVICE_REGISTRY_TARGET_INDEX` is obsolete and deliberately fails boot.

Keep every concurrently serving worker's wall clock synchronized within the fixed 300-second reclaim bound relative to
the fastest peer and DynamoDB's service/TTL clock. Monitor platform UTC/clock health and keep an operational margin
below 300 seconds. The route visibility predicate remains exact at logical expiry; the bound controls only when
physical TTL cleanup and automatic token reuse may begin. Registry writes retry only conditional/transaction conflicts,
with a fixed maximum of 21 attempts and bounded jitter; do not add an unbounded outer retry loop at the gateway.

The 300-second grace and terminal-operation protocol are persisted-schema behavior and deployment-immutable for
Registry V2. This code atom assumes the V2 namespace has never been activated: verify all `dial:install:v2:`,
`dial:token:v2:`, `dial:target:v2:`, and `dial:regop:v2:` prefixes are empty before first enablement and retain the
evidence. The proof must use fully paginated base-table reads with `ConsistentRead=true` (never a GSI), continue until
`LastEvaluatedKey` is absent, and retain the per-prefix zero counts, completion time, and request evidence. If any
prerelease V2 worker or row exists, disable all V2 traffic, remove every weighted/old Lambda target,
wait at least the configured maximum Lambda timeout plus ingress/alias propagation time, and verify no old invocation
remains before purging and re-proving all four prefixes empty with the same fully paginated, strongly consistent
base-table procedure. Then deploy a homogeneous fleet in V1 mode, force cold
starts, and only then perform an all-at-once V2 enablement. A pre-outcome V2 worker can commit after a new worker returns definitive 403, so rolling/weighted mixed
V2 fleets are forbidden. Set `DEVICE_REGISTRY_OUTCOME_PROTOCOL_READY=1` only after this quiesced proof. Never roll this
atom beside a worker that writes the older row set or `ttl = expiresAtEpochSec`; either change requires a versioned
namespace migration.

The same empty-prefix proof is the server half of the owner-continuity cutover. The new iOS client intentionally keeps
any ownerless prerelease schema-2 Keychain envelope until an authenticated `GET /dial/register/context` succeeds. It
then durably closes local ring authority before deleting those legacy bytes. Therefore no context-capable V2 fleet may
serve 200 until every old/ownerless V2 worker is quiesced and all four prefixes above have been purged and re-proved
empty. A 501/502 context response leaves legacy bytes untouched. Retain this server proof and the iOS cutover tests
before setting `DEVICE_REGISTRY_OWNER_CONTINUITY_READY=1`; there is no dual-read or mixed-worker migration.

---

## 2. Environment variables

**Required (boot fails without all four):**

| Var | Value |
|---|---|
| `DDB_TABLE` | the DynamoDB table name |
| `SIGNING_KEY_ID` | a stable id string for the signing key (bound into every receipt/bundle signature) |
| `GATEWAY_PUBLIC_URL` | the deploy's public origin (e.g. `https://pocket-api.sentinelayer.com`) — pins the DPoP htu, not a spoofable Host header |
| `SENTI_API_BASE_URL` | the Senti API origin — direct/V1 routes validate sessions there, protected Registry V2 admission validates once there, and governed human writes post there |

**Optional — each lights up a feature; absent ⇒ that route honestly `501`s:**

| Var(s) | Enables |
|---|---|
| `ELEVENLABS_API_KEY` (+ `TTS_VOICE_ID`) | `/tts` + `/deck` narration + `/brief` audio |
| `GEMMA_BASE_URL` (+ `GEMMA_MODEL`, optional `GEMMA_API_KEY`) | `/answer` + `/brief` reasoning (OpenAI-compatible Gemma: local Ollama key-free, or AI Studio) |
| `RESVG_BIN` + `FFMPEG_BIN` + `RESVG_EGRESS_SANDBOXED=1` | `/deck?format=video` (see §4 — the ack is load-bearing) |
| Registry V2 settings below | installation-owned Registry V2; every acknowledgement below is load-bearing |

**Registry V2 gateway boot contract (all required together):**

| Var | Exact contract |
|---|---|
| `DEVICE_REGISTRY_MODE` | `v2` |
| `DEVICE_REGISTRY_HMAC_SECRET_ARN` | exact Secrets Manager ARN shared with admission |
| `DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID` | exact immutable 32–64 character VersionId shared with admission |
| `DEVICE_REGISTRY_HMAC_KEY_B64` | runtime-injected canonical base64 `SecretString`, decoding to 32–1,024 bytes; never a Terraform input |
| `DEVICE_REGISTRY_V1_PURGED` | `1` |
| `DEVICE_REGISTRY_CLIENT_V2_READY` | `1` |
| `DEVICE_REGISTRY_OUTCOME_PROTOCOL_READY` | `1` |
| `DEVICE_REGISTRY_OWNER_CONTINUITY_READY` | `1` |
| `AWS_LAMBDA_FUNCTION_VERSION` | AWS-provided positive numeric published version; `$LATEST` is rejected |

**Operation-admission Lambda environment (exactly seven module-owned variables):**

| Var | Exact contract |
|---|---|
| `DEVICE_REGISTRY_HMAC_SECRET_ARN` | same exact ARN as the gateway |
| `DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID` | same exact immutable VersionId as the gateway |
| `GATEWAY_LAMBDA_VERSION_ARN` | exact positive numeric gateway-version ARN and assertion audience |
| `GATEWAY_LAMBDA_VERSION` | numeric suffix expected in both the ARN and AWS `ExecutedVersion` |
| `OPERATION_ADMISSION_DDB_TABLE` | separate admission-ledger table |
| `REGISTRY_OPERATION_ADMISSION_AUTH_MODE` | `senti_session_reusable_v1` |
| `SENTI_API_BASE_URL` | canonical Senti API HTTPS origin |

With no Registry settings the compatibility mode is V1, and a V2 phone receives an honest 501. Implicit or explicit V1
rejects any of the V2-only gateway settings listed above. Explicit V2 refuses boot when any required V2 value or
acknowledgement is absent.

**Registry migration gate:** historical V1 rows (`pk` beginning `dial:dev:`) are durable and untagged; current V1 rows
(`pk` beginning `dial:v1:dev:`) are exact-principal tagged and expiring. Neither can be safely transformed into
installation-owned rows. Before setting `DEVICE_REGISTRY_V1_PURGED=1`, turn off registration and ring traffic at
ingress, remove old V1 alias/weighted targets, wait at least the maximum Lambda timeout plus propagation time, and
verify no old invocation remains. Only then delete every row under both prefixes, verify both prefixes remain empty
using fully paginated base-table reads with `ConsistentRead=true` through the final absent `LastEvaluatedKey`, retain
the zero-count evidence, and perform the atomic homogeneous V2 cutover. Every public integration and permission is
pinned to a numeric Lambda version; change the public traffic mapping only after both immutable targets satisfy the V2
contract. An in-flight V1 registration after the empty-prefix proof reopens the old route.
There is deliberately no unsafe dual-delivery mode: retaining V1 rows would leave an old A target addressable after B.
Do not set `DEVICE_REGISTRY_CLIENT_V2_READY=1` until the iOS build that persists/reconciles both server fences and gates
V2 pushes is released to the intended devices; the currently shipping legacy registrar receives 426 and cannot operate
against V2. Do not set `DEVICE_REGISTRY_OUTCOME_PROTOCOL_READY=1` until the quiesced homogeneous-fleet/empty-prefix
proof above is retained. Do not set `DEVICE_REGISTRY_OWNER_CONTINUITY_READY=1` until the same quiesced proof covers all
ownerless V2 rows, the stable-handle KAV and same-owner/different-owner/TTL-boundary tests pass, and the context route's
cache/rate controls below are live. These acknowledgements are boot gates, not automatic proof—the
release/purge/cutover checks remain operator-owned.

`GET /dial/register/context` is auth-only and intentionally returns the stable pseudonymous owner handle for the exact
verified principal. Preserve the gateway's `Cache-Control: no-store` and `Pragma: no-cache` headers on every 200/4xx/5xx,
disable CDN/API-Gateway caching for the route, and do not include the bearer or handle in access logs. Put a documented,
shared per-verified-principal request/burst bound ahead of the Lambda; an IP-only or per-process counter is insufficient.
The limiter must fail closed without synthesizing a handle. Before acknowledging owner continuity, prove same-principal
bearer rotation returns the same handle, a different principal returns a different handle, responses are never cached,
and unavailable/corrupt dependencies return generic non-authorizing errors.

The upstream reusable-session verifier is also a public-activation gate: Senti `/api/v1/auth/me` currently permits 30
requests per rolling 60 seconds per client IP, while the admission ledger permits 60 total valid requests per principal
in the same window. Its 20-second positive cache is process-local, so it does not prove fleet or cold-start capacity.
Keep protected public traffic off until a service-authenticated upstream bucket/capacity change or representative
multi-instance egress-burst proof closes this mismatch.

`POST /dial/register/reconcile` and missing-authority registration denial intentionally work for an authenticated
principal with no current dial scope/membership. Without admission, such a caller can submit unlimited valid UUIDs and
create one TTL row each. Before recording `dark_proof_sha256` or enabling the API mapping, deploy and prove a
distributed, verified-principal-aware, body-reading admission proxy ahead of the gateway Lambda. An API Gateway/Lambda
authorizer alone is insufficient because its event does not include the JSON request body needed for this identity. The
proxy must:

- define one operation identity as the canonical length-prefixed tuple of verifier-owned `principal`, verified
  `humanId`, request `installationId`, and request `idempotencyKey`; derive/persist only an opaque keyed digest of that
  tuple, use the identical derivation for `POST /dial/register` and `POST /dial/register/reconcile`, and atomically mark
  the first admission before forwarding it;
- validate `ownerVersion:1` and constant-time compare the canonical request `ownerHandle` with the handle derived from
  that verified principal before allocating an operation slot; mismatch returns only the generic
  `registry-owner-conflict` 409 and must not disclose either handle or any stored fence;
- allow an exact replay of that already admitted identity without consuming another unique-operation slot, regardless
  of the other request fields (the registry remains responsible for rejecting a changed fingerprint as
  `idempotency-conflict`); a replay still consumes the separate total-request lane and refreshes bounded retention;
- cap live unique operation identities to at most **256 per verified principal** over the Registry V2 retention horizon;
- cap new unique identities to at most **30 per principal in a strict rolling 60 seconds**;
- cap all valid register/reconcile requests, including exact replay, to **60 per principal in the same strict rolling
  window**, preventing one admitted tuple from driving unbounded CAS and registry work;
- return typed **429 `operation-rate-limited`** before Lambda/Dynamo mutation when either limit is exceeded;
- share state across every ingress/Lambda instance, fail closed when admission storage is unavailable, and never log or
  persist the raw token, installation id, session id, request body, or bearer.

An IP-only WAF rule, per-instance memory counter, best-effort/fail-open limiter, or API Gateway account-wide throttle is
not sufficient for this gate. If the deploy cannot prove replay-aware per-principal admission, leave the API unmapped
and V2 public traffic off. Hash the retained provisioned-dark evidence bundle as canonical lowercase hexadecimal and
pass that digest as `dark_proof_sha256`; the Terraform module refuses traffic mapping without it.

The current production authentication contract is explicit:
`REGISTRY_OPERATION_ADMISSION_AUTH_MODE=senti_session_reusable_v1`. Admission validates the reusable Senti user-session
bearer exactly once at `/api/v1/auth/me`. After durable owner-ledger admission, it privately invokes the attested numeric
gateway version with the byte-identical bearer/body plus a 10-second HMAC assertion. The assertion is bound to the exact
secret ARN + VersionId, numeric gateway-version ARN, method/path, bearer hash, decoded-body hash, verified identity and
canonical scopes, owner/operation digests, issue/expiry, and a random 256-bit `jti`. The gateway verifies the raw event,
re-derives the owner/operation, atomically consumes that `jti` in shared DynamoDB with TTL=`exp`, and never calls
`/auth/me` again for either protected V2 POST. Missing, malformed, expired, replayed, wrong-version, or store-failed
proofs return the same generic 503 before registry work. A later gateway failure never rolls back the admission marker.
The signer sets `exp = iat + 10`; expiry is exclusive with no grace, and `iat` may be at most two seconds ahead of the
gateway clock.

Do not substitute the AIdenID single-use DPoP verifier without versioning this declared admission auth mode. A future
DPoP deployment must verify the external proof exactly once at admission and preserve its authorization semantics in
the same private, request-bound, single-use assertion contract.

Public routing is exact:

```text
custom domain
  -> explicit POST /dial/register ------------------> published admission version
  -> explicit POST /dial/register/reconcile --------> published admission version
  -> every explicitly declared non-protected route -> attested gateway version
  -> no $default route / Function URL / direct protected gateway integration

admission role -> lambda:InvokeFunction on one immutable numeric gateway version only
```

Disable the default execute-api endpoint when the custom domain is active. Scope API Gateway's gateway permissions by
individual non-protected method/path source ARN; the protected route ARNs must be absent. The admission role alone gets
`lambda:InvokeFunction` on the immutable numeric gateway version ARN, plus strongly consistent `GetItem` and conditional `PutItem` on
the admission table. It gets no registry-table, APNs, signing-key, query/scan, wildcard secret, or wildcard Lambda
permission. The gateway also requires the signed in-band assertion and atomically consumes its `jti`, so a direct
same-account invoke without a fresh proof fails closed. Retain the negative IAM/resource-policy proof as defense in
depth before readiness.
Store the 32-byte-or-longer HMAC key as a separate `SecretString` whose value is canonical standard base64 and decodes
to 32-1024 bytes, never in source, deployed plaintext configuration, or logs. `SecretBinary`, non-canonical base64, and
unbounded material are rejected. Pin an immutable Secrets Manager `VersionId`; do not read only
`AWSCURRENT`, whose movement would silently create a fresh owner/quota namespace. Admission and gateway must receive
the same exact secret ARN and `DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID` in one quiesced deployment and resolve that
exact version. The reference
gateway handler below passes the value only through its process-local env object. The admission artifact has its own
committed entrypoint at `deploy/operation-admission/index.mjs`: it requests the exact `SecretId` + `VersionId`, requires
Secrets Manager to return that same version, and injects the bounded key plus version metadata directly into the
admission app. Neither handler may fall back to `AWSCURRENT`.

Build the admission artifact from `deploy/operation-admission` with Node 22:

```sh
npm ci
npm test
npm run package
```

The locked build emits the deterministic **unsigned source ZIP** `dist/operation-admission.zip`, containing exactly one
bundled root `index.mjs`; the Terraform default handler is therefore `index.handler`. CI proves that unsigned source
artifact is reproducible but does not sign, upload, or deploy it. For every enabled production deployment, including
`provisioned-dark`, sign that exact source through the configured active AWS Signer profile. Retain the signing job id,
exact immutable profile-version ARN, signed destination bucket/key/VersionId, and both source and signed-object digests.
Bind Terraform to the immutable **signed** S3 object and set `admission_package_sha256` to the canonical base64 encoding
of the signed ZIP's raw SHA-256 bytes. The hexadecimal `sha256sum`/`Get-FileHash` representation is retained evidence,
not the Terraform input. Terraform uses the base64 digest as Lambda `source_code_hash` and requires the published
`code_sha256` to match. The S3 VersionId must be nonempty, bounded, and not the literal `null`.

Enabled production requires `admission_signing_profile_name`. The module resolves its exact active
`AWSLambda-SHA384-ECDSA` profile version, creates a code-signing configuration that trusts only that immutable version,
sets `untrusted_artifact_on_deployment = "Enforce"`, and attaches it before the admission Lambda is created. The unsigned
CI ZIP is never a valid production Terraform object. Rebuilding the same source and lock with the same
Node/npm/esbuild versions must reproduce the same unsigned source ZIP; AWS Signer's output is separately identified by
its immutable S3 VersionId and digest. The entrypoint
constructs the strict Senti verifier, separate Dynamo adapter, and synchronous immutable-version invoker once per warm
Lambda environment. The configured numeric version ARN must end in `GATEWAY_LAMBDA_VERSION`, and every successful AWS
response must report that exact `ExecutedVersion`; a named alias is never dereferenced by the private hop. A failed
secret fetch is retried on a later invocation, but it never falls back to a mutable stage;
bootstrap and unexpected app failures return the same identifier-free `operation-admission-unavailable` 503 as the
runtime proxy rather than exposing an SDK/configuration exception through API Gateway.

The admission Lambda accepts only exact `POST /dial/register` and `POST /dial/register/reconcile` events. Every other
method/path fails closed without authenticating, reading the body, allocating ledger state, or invoking the gateway.
This single-purpose behavior prevents a direct Lambda caller from using the admission role as a general gateway proxy.
One invocation-wide deadline is propagated to Senti fetch, DynamoDB, Secrets Manager, and Lambda transports. It is at
most 24 seconds and shrinks to Lambda remaining time minus the two-second response reserve. Deadline expiry aborts
in-flight work and returns the exact generic admission 503. Keep the 28-second Lambda timeout below the 29-second API
integration timeout.

### Operation-admission Terraform activation

`infra/terraform/operation-admission` is dark by default. When enabled, the pinned AWS provider's
`aws_lambda_invocation` data source invokes the configured positive numeric gateway version with the exact non-mutating
control request `{"schema":"senti.gateway.operation-admission-attestation.request.v1"}`. The gateway intercepts that
event before HTTP normalization, authentication, replay storage, or gateway work and returns exactly these 12
lower-snake-case, non-secret fields:

```text
schema, capability, invoked_function_arn, function_version,
registry_mode, v1_purged, client_ready, outcome_ready, owner_ready,
hmac_secret_arn, hmac_secret_version_id, assertion_schema
```

Terraform rejects extra/missing keys and refuses the plan unless the response binds the exact numeric ARN/version,
Registry V2 capability and assertion schema, all remaining gateway boot acknowledgements, and the configured wildcard-
free Secret ARN plus immutable VersionId. It does not accept a runtime self-claim of control-plane `CodeSha256` or a
Lambda description. `gateway_release_artifact_sha256` is independent release evidence supplied by the deployment
process; `gateway_release_manifest` records it alongside a canonical digest of the validated runtime attestation.
Provider credentials are required, but there is no host AWS CLI command or external Terraform provider, and the full
Lambda environment never enters Terraform state. Invocation failure or any response drift fails closed.

Both API integrations and every Lambda resource-policy grant target numeric published versions. The protected routes
invoke the module-published admission version; the 13 direct routes invoke the attested gateway version. No mutable
Lambda alias exists in the ingress path, so an out-of-band `UpdateAlias` cannot redirect reviewed traffic.

Production state uses the partial encrypted S3 backend in `versions.tf`. Initialize it only with an account-owned,
private, versioned bucket using SSE-KMS, TLS-only bucket policy, least-privileged state access, and a dedicated DynamoDB
lock table. The backend CMK must be pre-existing and distinct from the module-managed admission CMK; the role running
`terraform init/plan/apply` needs `kms:Encrypt`, `kms:Decrypt`, and `kms:GenerateDataKey` on that state key. For example:

```sh
terraform init \
  -backend-config="bucket=<private-versioned-state-bucket>" \
  -backend-config="key=senti-pocket/operation-admission/prod.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="kms_key_id=<state-CMK-ARN>" \
  -backend-config="dynamodb_table=<terraform-lock-table>"
```

Tests use `terraform init -backend=false`. The cutover states are deliberately separate: `enabled=false` creates no
module resources; `enabled=true, traffic_enabled=false, publish_dns=false` is `provisioned-dark`; traffic true with DNS
false is `mapped-no-dns` for isolated proof; all three true is `public`. API mapping requires a canonical lowercase
`dark_proof_sha256` over the retained provisioned-dark evidence bundle. DNS publication requires both that digest and a
canonical `mapped_proof_sha256` over the retained mapped-no-DNS evidence bundle; both are echoed in `cutover_contract`.
Use the first two provisioned states for artifact, IAM, two-instance/load, route-negative, telemetry, and rollback proof
before DNS publication. Roll back in dependency order: first set `publish_dns=false`, then set `traffic_enabled=false`
(or apply both false atomically), while preserving `enabled=true`. Never use `enabled=false` as emergency rollback:
retained logs, the admission table, and the KMS key have destruction safeguards, and that change plans resource
destruction.

Treat this HMAC key as **deployment-immutable across every concurrently running Lambda version**. Do not perform a
rolling key change: the current schema has no key id/dual-read migration, so mixed keys create parallel installation,
target, and token namespaces. Until key IDs exist, emergency rotation is stop-the-world only: disable registration and
ring dispatch, purge every `dial:install:v2:`, `dial:token:v2:`, `dial:target:v2:`, and `dial:regop:v2:` row under the old key, replace
the secret across the
whole fleet, force cold starts, and require every phone to register again before rings resume. Do not roll back to the
old key after new registrations without another purge/re-registration cycle. The production-grade non-disruptive path
is an explicit key-id + dual-read/write migration before the first normal rotation.

---

## 3. Production gateway artifact + private dark Terraform

`deploy/gateway` is the reviewed Node 22 executable glue. It snapshots only owned scalar configuration, constructs
one-attempt AWS clients with hard transport deadlines, reads each required `SecretString` by complete ARN plus immutable
`VersionId`, validates Ed25519/P-256 key types, and then hands the resulting `KeyObject`s and Dynamo adapter to
`createLambda`. Secret values never enter the Lambda environment, Terraform, logs, metrics, errors, or CI output.
Bootstrap failures return one identifier-free 503 and a low-cardinality metric; a failed cold start is retryable and a
successful cold start is single-flight cached.

`createProdGateway` constructs the fixed-origin, role-preserving target-membership resolver from
`SENTI_API_BASE_URL + fetch`; production exposes no static/list membership-adapter seam. Registry V2 additionally
requires the exact HMAC pin, all four readiness acknowledgements, and a numeric AWS-owned function version. APNs is
absent/`0` by default: that path does not validate or read the APNs secret and injects no `apnsSend` function.

Build and verify the deterministic unsigned source artifact from the locked directory:

```sh
cd services/pocket-gateway/deploy/gateway
npm ci
npm audit --audit-level=low
npm test
npm run package
```

The output ZIP contains exactly `index.mjs`. CI packages it twice and compares both the bundle and ZIP digests, but has
no AWS OIDC token and does not upload, sign, or deploy. Production must pass `infra/terraform/gateway` one immutable
**signed** S3 object `VersionId` and its canonical base64 SHA-256; mutable stages/objects are not release evidence.

The gateway Terraform module defaults `enabled=false` and `apns_voip_enabled=false`. When explicitly enabled it owns
the encrypted/PITR/TTL Dynamo table, precreated encrypted log group, runtime role, alarms, code-signing policy, Lambda,
and one published numeric version. Production code signing allows exactly one active AWS Signer profile version and
uses `Enforce`. The module deliberately creates no API Gateway resource, Lambda Function URL, Lambda permission,
Lambda alias, DNS record, or mutable traffic target. Its function name, numeric version, qualified ARN, artifact digest,
secret pins, and APNs state are non-secret outputs for the separate operation-admission/cutover evidence.

**IAM:** the runtime role can call only `dynamodb:{GetItem,PutItem,DeleteItem}` on its one table. DynamoDB authorizes
each `TransactWriteItems` sub-operation through the underlying item actions; there is no separate
`dynamodb:TransactWriteItems` IAM action. Secret reads are separate exact-resource statements: receipt signing always,
Registry HMAC only in V2, and APNs `.p8` only when APNs is enabled, each conditioned on its immutable
`secretsmanager:VersionId`. The corresponding KMS decrypt grant is limited to the exact key, Secrets Manager
`ViaService`, and matching `SecretARN` encryption context. The role also has only precreated-log writes, optional X-Ray
emission, and decrypt access to the module-owned Lambda environment key. It has no scan/query or wildcard-secret grant.

The target-membership API route remains a hard release dependency. A private numeric version may be provisioned dark,
but do not create/promote a route until sentinelayer-api PR #783 is merged and deployed, then smoke-prove one exact
known-member 200 and one uniform nonmember 404. A pre-prerequisite 404 fails closed as nonmembership; it is not evidence
the deploy works.

---

## 4. Feature backends + their security

- **Gemma** (`/answer`,`/brief`): set `GEMMA_BASE_URL` (+`GEMMA_MODEL`). Grounding-first + fail-closed — the model may
  cite only ids in the signature-verified bundle; ungrounded ⇒ clarify/unavailable, never fabricated. Absent ⇒ `501`.
- **DIAL** (`/dial`): inject `deps.apnsSend({voipToken,platform,payload}) -> {delivered,...}`. The zero-dependency native
  implementation is `createApnsVoipTransport` in `src/apns-voip-transport.mjs`. It uses Apple provider-token auth and a
  lazy, reusable HTTP/2 session to the fixed development or production APNs host. Deployment owns credential retrieval:
  resolve one exact immutable Secrets Manager version of the Apple `.p8`, parse it with `createPrivateKey`, and pass the
  resulting private P-256 `KeyObject`. Never put PEM/key text in an environment variable, Terraform value/state, log,
  error, metric, or Senti message. The transport itself does not read configuration or secrets and is never enabled
  implicitly; absent `deps.apnsSend` preserves the honest `/dial` `501` while `/dial/register` can still record.

  ```js
  import { createPrivateKey } from 'node:crypto';
  import { createApnsVoipTransport } from './src/apns-voip-transport.mjs';

  // `pinnedP8` came from an exact SecretId + VersionId read owned by deployment bootstrap.
  const apns = createApnsVoipTransport({
    teamId: 'AAAAAAAAAA',
    keyId: 'BBBBBBBBBB',
    privateKey: createPrivateKey(pinnedP8),
    bundleId: 'com.plexaura.sentipocket.app',
    environment: 'development', // explicit; use production only for a production-profile device token
    onResult: emitRedactedApnsMetric,
  });

  export const handler = createLambda(runtimeEnv, {
    // ...baseline deployment dependencies...
    apnsSend: apns.send,
  });
  ```

  The gateway supplies the final dictionary after `buildVoipPushDictionary` enforces the top-level dial shape and the
  serialized 5,120-byte PushKit ceiling. The transport serializes that dictionary once and sends those exact bytes; it
  never wraps it, adds fields, or rebuilds `aps`. It derives topic `<bundle-id>.voip` and sends push type `voip`, priority
  `10`, expiration `0`, and a fresh request UUID. A non-APNs route is rejected before network access.

  Provider JWTs are ES256 (`R || S` IEEE-P1363), single-flight cached for 50 minutes, and rejected on clock rollback.
  Warm workers reuse their HTTP/2 session. A new token-auth connection advertises an initial peer stream limit of one,
  matching Apple's pre-authentication rule until APNs SETTINGS safely replace it; a real HTTP/2 cold-fanout regression
  guards this admission boundary. GOAWAY/error/close retires the session for later calls, and controlled shutdown covers
  both current and already-retired sessions. The request deadline is monotonic and end-to-end from APNs admission across
  provider-token signing, local HTTP/2 queueing, and network response. Authorization and the token-bearing `:path` are
  marked never-indexed in HPACK.

  An explicit Apple `403 ExpiredProviderToken` is the sole one-time replay because that negative acknowledgement
  proves the first request was not accepted. Failure before a stream exists is typed `not-sent`; once a stream may have
  reached Apple, timeout,
  stream/session failure, and connection loss are outcome-ambiguous and are never replayed because a blind replay can
  create a duplicate CallKit ring. Explicit `429`/`5xx` responses are classified for delayed durable follow-up (5xx no
  earlier than 15 minutes even when `Retry-After` is shorter), not retried in-call. `410 Unregistered`, `410 ExpiredToken`,
  `BadDeviceToken`, and `DeviceTokenNotForTopic` are definitive for that request; their redacted metadata does not
  authorize automatic row deletion. A later Registry V2 cleanup worker must compare the APNs timestamp with the
  registration/binding fence. `UnrelatedKeyIdInToken` retires the authenticated connection before later work.

  `onResult` receives only APNs acceptance status, bounded normalized reason, APNs request id, disposition, latency,
  environment, and bounded retry/unregistered metadata. Raw device token, JWT, private key, payload, response body, and
  causes are deliberately absent. Keep each registry namespace scoped to the same APNs environment/topic, use a
  separate environment-scoped provider key operationally, and call `apns.close()` during controlled worker shutdown or
  tests. The committed dark deployment boundary now includes exact-version secret bootstrap, conditional
  KMS/Secrets Manager least-privilege IAM, an explicit APNs enable flag defaulting off, alarms, and a signed-object
  Terraform input. None of those permissions belong on the operation-admission role. This is still unprovisioned:
  actual Apple/AWS pins, signed artifact, dark runtime evidence, rollback evidence, and physical-device proof must be
  retained before APNs or public traffic is enabled.

  The legacy `delivered: true` field means APNs accepted the HTTP/2 request; it never proves handset receipt or CallKit
  presentation. The live APNs smoke gate must assert the exact outbound serialized byte count and a device-side
  `PKPushPayload.dictionaryPayload` decode before enabling Registry V2.
- **Video** (`/deck?format=video`): ship `resvg` + `ffmpeg` (Lambda layer) and set `RESVG_BIN` + `FFMPEG_BIN`. **The
  gateway refuses to enable video unless `RESVG_EGRESS_SANDBOXED=1`** — an explicit deploy assertion that resvg runs
  **network-egress-disabled** (resvg has no self-disable flag, so the SSRF backstop is an OS/container control the
  deploy owns; the gateway can't enforce it from Node, so it fail-safe-refuses without the ack). `safeImageHref`
  (https/data:image only, upstream) + the module's `--resources-dir` scoping are the other LFI/SSRF layers. A
  deploy-injected (pre-sandboxed) `deps.rasterize/encodeVideo` bypasses the env construction.

---

## 5. Verify

- `GET /health` ⇒ `200 {ok:true}` (no auth).
- Direct/V1 routes with no or invalid bearer ⇒ `401` (fail-closed). On either protected V2 POST, malformed JSON,
  non-canonical base64, or an oversized decoded body returns the documented `400`/`413` before auth; a direct gateway
  invoke without a valid private assertion returns the generic admission `503`.
- With a valid senti session bearer: `GET /sync`, `GET /checkpoint?sessionId=…`, `POST /answer`, `POST /brief`,
  `POST /actions/execute`, `POST /tts`, `POST /deck`, `POST /dial`, `POST|DELETE /dial/register`, and authenticated
  `GET /dial/register/context` plus `POST /dial/register/reconcile` per the contract in `API.md`.
- In V2 mode, prove same-installation A→B movement: A stops resolving, B receives a `v:2` push with its exact nested
  binding tuple, stale A unregister/cleanup is a no-op (including a newer same-intent revision), a missing-scope and
  missing-membership 403 each barriers a held original commit, and a logically expired binding is hidden before Dynamo
  TTL cleanup. Verify the four V2 prefixes and terminal outcome TTLs directly.
- Prove one owner across two independently issued bearers receives the same context handle and can finish retained exact
  cleanup/delete. Prove a different owner receives the generic 409 with no handle/fence leak for register, cleanup, and
  delete through `ttl - 1`, then can reclaim a physically retained row exactly at `ttl`. Corrupt stored owner handles
  must fail closed as storage errors rather than being echoed or normalized.
- Concurrently submit the same private assertion and prove exactly one `jti` consume reaches handler entry. Missing,
  expired, replayed, wrong-audience, wrong-key/version, route/body/bearer-tampered proofs and replay-store outage must all
  return the identical generic 503 before any registry mutation.
- Exercise admission with 31 distinct operations inside one rolling window (exactly 30 admitted), 61 exact requests
  inside one rolling window (exactly 60 admitted), 257 retained live identities (256 admitted), an older CAS
  loser/newer-clock winner, two live Lambda instances, TTL deletion lag, and verifier/Dynamo/KMS/gateway outages. Pace
  the 31/61 cases through the production concurrency/burst ceiling, or use a separately isolated load-proof deployment
  with temporarily raised capacity, so edge/concurrency rejection cannot masquerade as a ledger-limit result. Retain
  typed 429/503 responses and prove every failure invokes the gateway zero times except a post-admission gateway
  failure, whose retry is a replay.
- Inspect the deployed API/routes and account-wide Lambda policies: no Function URL, `$default`, obsolete stage/domain,
  protected direct integration, wildcard invoke permission, or unauthorized same-account role may reach the gateway.
  Prove the admission role cannot read/write the registry table. Include this negative evidence in the retained
  provisioned-dark bundle before recording `dark_proof_sha256` or enabling traffic mapping.
- Capture redacted CloudWatch/X-Ray/Dynamo evidence showing no bearer, raw principal/human, installation/session id,
  UUID, token/body, owner handle, or operation digest is emitted to telemetry. Then run register, reconcile, replay,
  downstream-timeout recovery, and revoke from a physical phone through the actual custom domain.
- A route whose feature backend isn't wired returns a **typed `501`** (`no-video-capability`, `dial-not-configured`,
  reasoning-not-configured, …) — confirm these are `501`, not errors: that's the honest "not-configured" signal.

See `API.md` for the full request/response contract and `app.mjs` for the authoritative dep JSDoc.
