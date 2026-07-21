# Pocket Gateway — Deploy Runbook

The gateway is a **zero-dependency ESM Lambda**. Its core (`createGateway`) takes a `{method,path,query,headers,body}`
request and returns `{status,headers,body}` — no framework, no ambient I/O. Everything it touches (DynamoDB, the signing
key, `fetch`, the senti runner, the feature backends) is an **injected external** the deploy owns. So "deploying" is:
provision four AWS resources, set the env, and write a ~20-line handler that wires the real externals into
`createLambda`. Nothing here reaches the network on its own; every boundary is explicit.

> **Honesty note:** this documents the deploy *contract*. The gateway is code-complete + tested (`node --test`), but it
> is **not live** until this runbook is executed against a real AWS account. Each optional feature backend below fails
> **closed** (a `501` with a typed reason) until its dependency is wired — never a fabricated response.

---

## 1. AWS resources (four)

| Resource | Purpose | Notes |
|---|---|---|
| **Lambda** (Node 20+, ESM) | runs `createLambda(process.env, deps)` | behind a Function URL or API Gateway (HTTP API) |
| **DynamoDB table** | durable state: idempotency/emitted markers + cross-instance locks + DPoP jti | single-table, schema below |
| **Secrets Manager secret** | the Ed25519 **signing key** (receipts/bundles) | KMS asymmetric does **not** do EdDSA — store the PKCS#8 PEM in Secrets Manager, not KMS |
| **API Gateway (HTTP API)** *(or Lambda Function URL)* | public HTTPS ingress | its origin URL is `GATEWAY_PUBLIC_URL` (DPoP htu pinning) |

### DynamoDB table schema

Single table, composite key, TTL enabled:

- **Partition key** `pk` (String)
- **Sort key** `sk` (String) — the store writes `sk = "record"` (durable state) and `sk = "lock"` (self-healing locks)
- **TTL attribute** `ttl` (Number, epoch-seconds) — **enable DynamoDB TTL on this attribute**. Locks carry a `ttl`
  so a crash-before-release self-heals; DPoP jti replay records carry a `ttl` so they expire. Durable records have no
  `ttl` and never expire.
- Billing: on-demand is fine (low, spiky volume).

The gateway's locks tolerate DynamoDB's TTL **deletion lag** (they steal a logically-expired lock via a conditional
put), so no tight TTL sweep is required.

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

DIAL (`/dial`, `/dial/register`) needs no env — `/dial/register` works out of the box over the same DynamoDB table;
`/dial` dispatch needs an injected `deps.apnsSend` (§4).

---

## 3. The handler (reference `index.mjs`)

This is the only glue the deploy writes. It resolves the real externals and hands them to `createLambda`:

```js
import { createLambda } from './src/app.mjs';
import { createDynamoClientAdapter } from './src/store.mjs';
import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient, GetCommand, PutCommand, DeleteCommand } from '@aws-sdk/lib-dynamodb';
import { SecretsManagerClient, GetSecretValueCommand } from '@aws-sdk/client-secrets-manager';
import { createPrivateKey } from 'node:crypto';

// DynamoDB v3 -> the { get, put, delete } shape createDynamoStore consumes (get MUST return the full { Item }).
const doc = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const dynamoClient = createDynamoClientAdapter(doc, { GetCommand, PutCommand, DeleteCommand });

// Ed25519 signing key (PKCS#8 PEM) from Secrets Manager.
const sm = new SecretsManagerClient({});
const pem = (await sm.send(new GetSecretValueCommand({ SecretId: process.env.SIGNING_KEY_SECRET_ARN }))).SecretString;
const signingKey = createPrivateKey(pem);

export const handler = createLambda(process.env, {
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

**IAM:** the Lambda role needs `dynamodb:{GetItem,PutItem,DeleteItem}` on the table and `secretsmanager:GetSecretValue`
on the signing-key secret. Nothing else.

---

## 4. Feature backends + their security

- **Gemma** (`/answer`,`/brief`): set `GEMMA_BASE_URL` (+`GEMMA_MODEL`). Grounding-first + fail-closed — the model may
  cite only ids in the signature-verified bundle; ungrounded ⇒ clarify/unavailable, never fabricated. Absent ⇒ `501`.
- **DIAL** (`/dial`): inject `deps.apnsSend({voipToken,platform,payload}) -> {delivered}` — the APNs VoIP push transport
  (needs a **VoIP cert** from the Apple account). Absent ⇒ `/dial` `501`s while `/dial/register` still records tokens.
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
  `POST /actions/execute`, `POST /tts`, `POST /deck`, `POST /dial(/register)` per the granted scopes.
- A route whose feature backend isn't wired returns a **typed `501`** (`no-video-capability`, `dial-not-configured`,
  reasoning-not-configured, …) — confirm these are `501`, not errors: that's the honest "not-configured" signal.

See `API.md` for the full request/response contract and `app.mjs` for the authoritative dep JSDoc.
