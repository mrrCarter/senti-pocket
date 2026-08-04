# Pocket Gateway — Deploy Runbook

The core gateway is a **zero-dependency ESM Lambda**. Its core (`createGateway`) takes a `{method,path,query,headers,body}`
request and returns `{status,headers,body}` — no framework, no ambient I/O. Everything it touches (DynamoDB, the signing
key, `fetch`, the senti runner, the feature backends) is an **injected external** the deploy owns. V1 needs the four core
AWS resources below. Registry V2 additionally requires a body-reading admission service with shared state; it may reuse
the DynamoDB table but it is separate compute and is not implemented by `createLambda`. Nothing here reaches the network
on its own; every boundary is explicit.

> **Honesty note:** this documents the deploy *contract*. The core gateway is tested (`node --test`), but it is **not
> live** until this runbook is executed against a real AWS account. Registry V2 is not deploy-complete until the separate
> admission proxy/IaC atom is implemented and its evidence retained; keep V2 disabled. Each optional feature backend
> below fails **closed** (a `501` with a typed reason) until its dependency is wired—never a fabricated response.

---

## 1. AWS resources (four core; Registry V2 adds admission compute)

| Resource | Purpose | Notes |
|---|---|---|
| **Lambda** (Node 20+, ESM) | runs `createLambda(process.env, deps)` | behind a Function URL or API Gateway (HTTP API) |
| **DynamoDB table** | durable state: idempotency/emitted markers + cross-instance locks + DPoP jti | single-table, schema below |
| **Secrets Manager secrets** | the Ed25519 **signing key** (receipts/bundles), plus the Registry V2 HMAC key when V2 is enabled | KMS asymmetric does **not** do EdDSA — store the PKCS#8 PEM and independent 32-byte-or-longer HMAC key in separate secrets |
| **API Gateway (HTTP API)** *(or Lambda Function URL behind the admission proxy)* | public HTTPS ingress | its origin URL is `GATEWAY_PUBLIC_URL` (DPoP htu pinning); V2 must not use a bare Function URL |
| **Body-reading admission proxy** *(Registry V2 only; additional Lambda/service)* | verifies the caller and atomically admits bounded register/reconcile operation identities before invoking the gateway | uses distributed state (the table may be reused); an API Gateway/Lambda authorizer alone cannot inspect the JSON body and is insufficient; this component/IaC is a separate required atom |

### DynamoDB table schema

Single table, composite key, TTL enabled:

- **Partition key** `pk` (String)
- **Sort key** `sk` (String) — the store writes `sk = "record"` (durable state) and `sk = "lock"` (self-healing locks)
- **TTL attribute** `ttl` (Number, epoch-seconds) — **enable DynamoDB TTL on this attribute**. Locks carry a `ttl`
  so a crash-before-release self-heals; DPoP jti replay records carry a `ttl` so they expire. Durable records have no
  `ttl` and never expire.
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
| `SENTI_API_BASE_URL` | the senti API origin — the gateway validates the caller's session at `GET {SENTI_API_BASE_URL}/api/v1/auth/me` **and** posts the human write there |

**Optional — each lights up a feature; absent ⇒ that route honestly `501`s:**

| Var(s) | Enables |
|---|---|
| `ELEVENLABS_API_KEY` (+ `TTS_VOICE_ID`) | `/tts` + `/deck` narration + `/brief` audio |
| `GEMMA_BASE_URL` (+ `GEMMA_MODEL`, optional `GEMMA_API_KEY`) | `/answer` + `/brief` reasoning (OpenAI-compatible Gemma: local Ollama key-free, or AI Studio) |
| `RESVG_BIN` + `FFMPEG_BIN` + `RESVG_EGRESS_SANDBOXED=1` | `/deck?format=video` (see §4 — the ack is load-bearing) |
| `DEVICE_REGISTRY_MODE=v2` + `DEVICE_REGISTRY_HMAC_SECRET_ARN` + `DEVICE_REGISTRY_V1_PURGED=1` + `DEVICE_REGISTRY_CLIENT_V2_READY=1` + `DEVICE_REGISTRY_OUTCOME_PROTOCOL_READY=1` + `DEVICE_REGISTRY_OPERATION_ADMISSION_READY=1` + `DEVICE_REGISTRY_OWNER_CONTINUITY_READY=1` | installation-owned Registry V2; every acknowledgement below is load-bearing, and the reference handler resolves the secret to the process-local `DEVICE_REGISTRY_HMAC_KEY_B64` expected by the gateway |

With no Registry settings the compatibility mode is V1, and a V2 phone receives an honest 501. Do not place V2
settings beside implicit/V1 mode: partial or mixed configuration fails boot.

**Registry migration gate:** V1 rows (`pk` beginning `dial:dev:`) are durable, unversioned, and cannot be safely
transformed into installation-owned rows. Before setting `DEVICE_REGISTRY_V1_PURGED=1`, turn off registration and ring
traffic at ingress, remove old V1 alias/weighted targets, wait at least the maximum Lambda timeout plus propagation time,
and verify no old invocation remains. Only then delete every legacy row, verify the prefix is still empty using a fully
paginated base-table read with `ConsistentRead=true` through the final absent `LastEvaluatedKey`, retain the zero-count
evidence, and perform the atomic homogeneous V2 alias flip. An in-flight V1 registration after the empty-prefix proof
reopens the old route.
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

`POST /dial/register/reconcile` and missing-authority registration denial intentionally work for an authenticated
principal with no current dial scope/membership. Without admission, such a caller can submit unlimited valid UUIDs and
create one TTL row each. Before setting `DEVICE_REGISTRY_OPERATION_ADMISSION_READY=1`, deploy and prove a distributed,
  verified-principal-aware, body-reading admission proxy ahead of the gateway Lambda. An API Gateway/Lambda authorizer
  alone is insufficient because its event does not include the JSON request body needed for this identity. The proxy must:

- define one operation identity as the canonical length-prefixed tuple of verifier-owned `principal`, verified
  `humanId`, request `installationId`, and request `idempotencyKey`; derive/persist only an opaque keyed digest of that
  tuple, use the identical derivation for `POST /dial/register` and `POST /dial/register/reconcile`, and atomically mark
  the first admission before forwarding it;
- validate `ownerVersion:1` and constant-time compare the canonical request `ownerHandle` with the handle derived from
  that verified principal before allocating an operation slot; mismatch returns only the generic
  `registry-owner-conflict` 409 and must not disclose either handle or any stored fence;
- allow an exact replay of that already admitted identity without consuming another unique-operation slot, regardless
  of the other request fields (the registry remains responsible for rejecting a changed fingerprint as
  `idempotency-conflict`);
- cap live unique operation identities to at most **256 per verified principal** over the Registry V2 retention horizon;
- cap new unique identities to at most **30 per principal per minute**, with a documented bounded burst;
- return typed **429 `operation-rate-limited`** before Lambda/Dynamo mutation when either limit is exceeded;
- share state across every ingress/Lambda instance, fail closed when admission storage is unavailable, and never log or
  persist the raw token, installation id, session id, request body, or bearer.

An IP-only WAF rule, per-instance memory counter, best-effort/fail-open limiter, or API Gateway account-wide throttle is
not sufficient for this acknowledgement. If the deploy cannot prove replay-aware per-principal admission, leave V2
off. The source flag asserts the external control; it does not implement it.
Store the 32-byte-or-longer HMAC key as a separate secret whose value is canonical standard base64, never in source,
deployed plaintext configuration, or logs. The reference handler below resolves `DEVICE_REGISTRY_HMAC_SECRET_ARN` and
passes the secret only through its process-local env object. A different handler may inject
`DEVICE_REGISTRY_HMAC_KEY_B64` by an equivalent secret-to-runtime mechanism.

Treat this HMAC key as **deployment-immutable across every concurrently running Lambda version**. Do not perform a
rolling key change: the current schema has no key id/dual-read migration, so mixed keys create parallel installation,
target, and token namespaces. Until key IDs exist, emergency rotation is stop-the-world only: disable registration and
ring dispatch, purge every `dial:install:v2:`, `dial:token:v2:`, `dial:target:v2:`, and `dial:regop:v2:` row under the old key, replace
the secret across the
whole fleet, force cold starts, and require every phone to register again before rings resume. Do not roll back to the
old key after new registrations without another purge/re-registration cycle. The production-grade non-disruptive path
is an explicit key-id + dual-read/write migration before the first normal rotation.

---

## 3. The handler (reference `index.mjs`)

This is the only glue the deploy writes. It resolves the real externals and hands them to `createLambda`:

```js
import { createLambda } from './src/app.mjs';
import { createDynamoClientAdapter } from './src/store.mjs';
import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import {
  DynamoDBDocumentClient,
  GetCommand,
  PutCommand,
  DeleteCommand,
  TransactWriteCommand,
} from '@aws-sdk/lib-dynamodb';
import { SecretsManagerClient, GetSecretValueCommand } from '@aws-sdk/client-secrets-manager';
import { createPrivateKey } from 'node:crypto';

// DynamoDB v3 -> the base store plus Registry V2 transaction surface.
const doc = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const dynamoClient = createDynamoClientAdapter(doc, {
  GetCommand,
  PutCommand,
  DeleteCommand,
  TransactWriteCommand,
});

// Ed25519 signing key (PKCS#8 PEM) from Secrets Manager.
const sm = new SecretsManagerClient({});
const pem = (await sm.send(new GetSecretValueCommand({ SecretId: process.env.SIGNING_KEY_SECRET_ARN }))).SecretString;
const signingKey = createPrivateKey(pem);

// Registry V2's HMAC key is resolved at cold start and passed only to createLambda; it is not written back to the
// Lambda environment, source, or logs. V1 does not retrieve or require this optional secret.
let runtimeEnv = process.env;
if (process.env.DEVICE_REGISTRY_MODE === 'v2') {
  if (!process.env.DEVICE_REGISTRY_HMAC_SECRET_ARN) {
    throw new Error('DEVICE_REGISTRY_HMAC_SECRET_ARN is required for Registry V2');
  }
  const hmacKey = (await sm.send(new GetSecretValueCommand({
    SecretId: process.env.DEVICE_REGISTRY_HMAC_SECRET_ARN,
  }))).SecretString;
  if (!hmacKey) throw new Error('Registry V2 HMAC secret is empty');
  runtimeEnv = { ...process.env, DEVICE_REGISTRY_HMAC_KEY_B64: hmacKey };
}

export const handler = createLambda(runtimeEnv, {
  dynamoClient,
  signingKey,
  fetch,                                   // Node 20+ global; validates sessions + posts the human write
  run: /* senti writeback runner */,       // shells the bundled `sl` or a senti API client (POST /actions/execute)
  knownSessionIdsFor: /* (humanId) => Promise<string[]> */,   // the sessions a human may write to (server-derived authz)
  bundleStore: /* { listForHuman(humanId, since) } */,        // signed bundles for GET /sync
  // optional feature deps (see §4):
  // apnsSend, rasterize, encodeVideo,
});
```

`createProdGateway` **fails boot** if any of `dynamoClient / signingKey / knownSessionIdsFor / fetch` (or the four
required env vars) is missing — so a misconfigured deploy never starts half-wired.

**IAM:** the Lambda role needs `dynamodb:{GetItem,PutItem,DeleteItem}` on the table. DynamoDB authorizes each
`TransactWriteItems` sub-operation through its underlying `PutItem` / `DeleteItem` permission (there is no separate
`dynamodb:TransactWriteItems` policy action). Also grant
`secretsmanager:GetSecretValue` on the signing-key secret and, when V2 is enabled, the separate HMAC-key secret.

---

## 4. Feature backends + their security

- **Gemma** (`/answer`,`/brief`): set `GEMMA_BASE_URL` (+`GEMMA_MODEL`). Grounding-first + fail-closed — the model may
  cite only ids in the signature-verified bundle; ungrounded ⇒ clarify/unavailable, never fabricated. Absent ⇒ `501`.
- **DIAL** (`/dial`): inject `deps.apnsSend({voipToken,platform,payload}) -> {delivered}` — the APNs VoIP push transport
  (needs a **VoIP credential** from the Apple Developer account). The gateway supplies the final dictionary after
  `buildVoipPushDictionary` enforces the top-level shape and serialized 5,120-byte PushKit ceiling. The transport must
  serialize that dictionary verbatim: do not wrap it, add fields, or rebuild `aps`. Send `apns-push-type: voip` and topic
  `<bundle-id>.voip`. Treat the raw token as routing secret material at rest/in logs. Absent ⇒ `/dial` `501`s while
  `/dial/register` can still record. The live APNs smoke gate must assert the exact outbound serialized byte count and
  a device-side `PKPushPayload.dictionaryPayload` decode before enabling Registry V2.
- **Video** (`/deck?format=video`): ship `resvg` + `ffmpeg` (Lambda layer) and set `RESVG_BIN` + `FFMPEG_BIN`. **The
  gateway refuses to enable video unless `RESVG_EGRESS_SANDBOXED=1`** — an explicit deploy assertion that resvg runs
  **network-egress-disabled** (resvg has no self-disable flag, so the SSRF backstop is an OS/container control the
  deploy owns; the gateway can't enforce it from Node, so it fail-safe-refuses without the ack). `safeImageHref`
  (https/data:image only, upstream) + the module's `--resources-dir` scoping are the other LFI/SSRF layers. A
  deploy-injected (pre-sandboxed) `deps.rasterize/encodeVideo` bypasses the env construction.

---

## 5. Verify

- `GET /health` ⇒ `200 {ok:true}` (no auth).
- Any other route with no/invalid bearer ⇒ `401` (fail-closed).
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
- Exercise the admission boundary with exact replay, 257 unique live identities, the per-minute threshold, two
  concurrent Lambda/ingress instances, and an unavailable admission store. Retain the 200/replay, typed 429, and
  fail-closed evidence before setting `DEVICE_REGISTRY_OPERATION_ADMISSION_READY=1`.
- A route whose feature backend isn't wired returns a **typed `501`** (`no-video-capability`, `dial-not-configured`,
  reasoning-not-configured, …) — confirm these are `501`, not errors: that's the honest "not-configured" signal.

See `API.md` for the full request/response contract and `app.mjs` for the authoritative dep JSDoc.
