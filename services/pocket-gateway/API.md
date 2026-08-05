# Pocket Gateway API — contract for the Swift clients

Authoritative wire contract for `services/pocket-gateway` (Relay lane). This is what the phone's `PocketSyncClient`
(read/briefing) and `PocketActionsClient` (Phase-B governed write) call. The gateway is framework-agnostic:
`createGateway(deps).handle({method,path,query,headers,body}) -> {status,headers,body,isBase64Encoded?}`, mounted on
Lambda/API-Gateway (`src/lambda.mjs`) or a local HTTP server (`src/app.mjs` / `scripts/local-server.mjs`).

## Modes
- **Deployed** (product path): every non-health route requires a valid **AIdenID** token (human-bound, audience/
  resource-scoped, DPoP-bound; minted via `/v1/sessions/exchange`). `deps.verifyToken` owns the check (`src/auth.mjs`).
- **LAN demo** (Phase-B on Carter's network): `scripts/local-server.mjs` — loopback by default, `LAN=1` opt-in. Prints a
  pairing token (bearer) + the raw base64url signing pubkey the phone pins. NOTE: LAN is cleartext unless the (c)
  TLS+cert-pinning launcher is used — a stolen bearer on cleartext LAN is arbitrary write authority (demo risk-acceptance).

## Auth boundary (fail-closed)
- No verifier wired, or an invalid/expired/replayed token => **deny** (401 `{error:"authentication required"}`, `www-authenticate: Bearer`).
- The **human identity comes from the token** (`ConsumerAccount.id`), NEVER from the request body.
- **Authorization to write is server-derived**: `knownSessionIdsFor(humanId)` — a client can never name an arbitrary target session.
- **Cross-tenant isolation**: all durable state + the exactly-once lock are namespaced by the FULL principal
  (issuer + aud/resource + site + pairwise sub), not the sub alone.
- **Scopes** (least-privilege): `sessions:read` (sync), `sessions:write` (execute), `pocket:voice` (tts), and
  `pocket:dial` (device binding/ringing). A read+write token must NOT authorize voice or ringing. Missing scope => 403.

## Endpoints

### `GET /health` → 200 `{ok:true}`  (no auth)

### `GET /sync?since=<sequence>` → 200 `{bundles: PocketBundle[]}`  (scope `sessions:read`)
- Returns signed `PocketBundle`s for the caller's principal newer than `since` (0 = all). Tenant-scoped.
- The phone MUST verify each bundle's Ed25519 signature under the pinned pubkey AND `isSemanticallyValid()` before briefing.
- 403 missing scope · 501 sync backend not configured.

### `POST /actions/execute`  (scope `sessions:write`)
Body: `{ proposal: ActionProposal, confirmation: Confirmation }` (frozen shapes in PocketContracts).
- Success → **200 `ActionReceipt`** (`status: posted | pending`), Ed25519-signed, `confirmedProposalHash` non-null.
- **422 `{error:"proposal_rejected", reason}`** — proposal could NOT be bound to a confirmation (never a null-hash "receipt").
- 400 invalid JSON / `proposal.id` required · 403 missing scope · 500 authorization lookup failed.
- **409** — either a prior send outcome is unknown (reconciliation required — do NOT auto-retry blindly) or execution is
  in progress on another instance (safe to retry).
- **Idempotent + exactly-once** per `(principal, proposal.id)`: replaying a terminal `posted` receipt returns it as-is;
  the gateway reserves-before-post and re-verifies by read-back, so a retry NEVER produces a duplicate governed write.
  Clients SHOULD retry with the SAME `proposal.id` on network failure — the gateway reconciles.

### `POST /tts`  (scope `pocket:voice`)
Body: `{ text, voiceId?, modelId?, outputFormat?, tone? }` (`text` 1..8192 UTF-8 bytes).
- 200 → `application/octet-stream` audio; format in `x-senti-audio-format` (default `pcm_s16le_24000`). `isBase64Encoded`
  on API Gateway. The voice-provider key lives ONLY server-side — it never reaches the phone.
- 400 text required · 413 text > 8192 bytes · 501 not configured · 502 backend error.

### `POST /dial/register` — Registry V2 (scope `pocket:dial`)

Membership-gated registration of one installation's current PushKit routing intent. The authenticated principal and
human identity come only from the bearer; neither is accepted in the body.

Deployment remains fail-closed on V1 until the V2 iOS registrar/binding gate is released and the operator explicitly
sets `DEVICE_REGISTRY_CLIENT_V2_READY=1`; the legacy shipping client cannot satisfy this contract.

```json
{
  "registrationVersion": 2,
  "installationId": "<32 random bytes, canonical unpadded base64url>",
  "idempotencyKey": "<UUID>",
  "voipToken": "<opaque PushKit token>",
  "sessionId": "<member session>",
  "platform": "apns",
  "expectedBindingId": "bind_0123456789abcdef0123456789abcdef",
  "expectedBindingRevision": 4,
  "expectedTokenClaimId": "claim_0123456789abcdef0123456789abcdef",
  "expectedTokenClaimRevision": 9
}
```

`expectedBindingId` and `expectedBindingRevision` may be omitted together for a genuinely new installation item or for
an exact same-intent replay/lease renewal. For any changed principal/session/token/platform intent, send the exact last
server binding tuple. Same-intent operations preserve the binding id/revision, even when the idempotency key is new.

The token-claim pair is a separate compare-and-swap fence. Omit it while the requested token is unclaimed or is already
owned by this installation's exact current binding. If the server returns `token-claim-conflict`, retry with the returned
claim tuple only while the same local auth/session/token intent is still current. That explicit retry transfers the
global `(platform, token)` owner atomically with the installation binding and evicts the displaced exact base/directory
member; a delayed old installation cannot win by last physical write.

Success is strict and versioned:

```json
{
  "registered": true,
  "registrationVersion": 2,
  "sessionId": "…",
  "platform": "apns",
  "bindingId": "bind_…",
  "bindingRevision": 5,
  "tokenClaimId": "claim_…",
  "tokenClaimRevision": 10,
  "expiresAt": "2026-08-07T07:00:00.000Z",
  "idempotent": false
}
```

- **409 `binding-conflict`** returns only `currentBinding:{bindingId,bindingRevision,expiresAt}` (or `null`). A client
  may retry with that tuple only while the same local auth/session/token intent is still current. A superseded task must
  not reconcile or retry.
- **409 `token-claim-conflict`** returns only
  `currentTokenClaim:{tokenClaimId,tokenClaimRevision,expiresAt}` (or `null`) for the explicit token-owner CAS above.
  `expiresAt` is the logical route expiry and can already be in the past during reclaim grace; it is not an
  automatic-reuse timestamp, and the returned tuple remains the explicit transfer fence.
- **409 `idempotency-conflict`** means the installation's latest stored idempotency key was reused for different semantic
  intent. Registry V2 retains the latest key, not an unbounded historical key ledger; the binding and token-claim CAS
  fences remain the authority for every state change.
- **409 `target-capacity`** means the authenticated human/session already has 20 active installations. Renewals,
  rotations, and same-target token-owner replacement net their exact removals before this check; no existing member is
  arbitrarily evicted.
- **409 `registration-conflict`** means all 21 bounded serialization attempts lost retryable contention. Retry the same
  idempotency key with client backoff only while the local auth/session/token intent is still current.
- **409 `revision-exhausted`** is permanent for the current V2 namespace. Do not auto-retry; operator intervention and a
  versioned schema migration are required before that Registry V2 record can advance.
- A lease becomes unroutable exactly at `expiresAtEpochSec`. Registry rows remain physically TTL-eligible only after a
  fixed five-minute reclaim grace. During that grace, the same exact owner may renew; another installation must use the
  returned token-claim tuple so the displaced base/directory state moves atomically. Automatic unclaimed-token reuse
  begins only after the grace, when a worker clock up to five minutes behind also considers the old route expired.
- 400 malformed/non-canonical/unknown field · 403 non-member/missing scope · 426 unversioned request · 501 V2 not
  configured · 502 registry failure.
- The raw installation id and token are never returned. The server persists only an HMAC of installation identity;
  the opaque PushKit token necessarily remains protected at rest because APNs cannot route using only a hash.

### `DELETE /dial/register` — exact conditional revoke (scope `pocket:dial`)

Body:

```json
{
  "registrationVersion": 2,
  "installationId": "…",
  "sessionId": "…",
  "bindingId": "bind_…",
  "bindingRevision": 5
}
```

This route intentionally does not require current session membership, so sign-out/access-loss can revoke with the old
bearer before credentials are cleared. It is existence-oblivious: a valid request returns 200 even if already absent.
Deletion occurs only when authenticated target + installation + binding id + revision all still match; a stale A revoke
cannot delete a newer B binding. Registry operations use a schema-bounded 21-attempt serialization budget
(`20 installations + 1`), with bounded jitter between retryable CAS conflicts. If that budget is exhausted while the
exact tuple remains present, the server returns retryable **503 `unregistration-conflict`**; the phone must retain its
local binding and retry.

### Registry V2 ring envelope

A Registry V2 delivery is a version-2 dial payload with the binding fence inside the byte-budgeted core:

```json
{
  "v": 2,
  "binding": {
    "v": 2,
    "id": "bind_…",
    "revision": 5
  },
  "id": "need_…",
  "sessionId": "…",
  "fetch": false
}
```

The phone must require the exact active binding before decoding governed metadata, CallKit presentation, or hydration,
and recheck it before and after hydration. V1 is intentionally not actionable once Registry V2 is enabled. Binding is
included before the deterministic RICH→LEAN size ladder, so the bare DTO remains within the 4,864-byte producer budget
(5,120-byte PushKit cap less envelope reserve). The final `{...dto,aps}` builder also measures the complete serialized
dictionary and refuses any transport extension that exceeds 5,120 bytes.

## Error envelope
JSON `{error: string, reason?: string}` on every non-2xx (except `/tts` binary success). Treat any non-200 on execute as
NOT posted; a `pending` receipt is a real receipt (offline/queued), a 422 is a rejected proposal, a 409 needs reconcile-or-retry.

## Swift client mapping (Phase-B, to author on the Mac)
- `PocketSyncClient.sync(since:) async throws -> [PocketBundle]` → `GET /sync` (verify signature + semantics client-side).
- `PocketActionsClient.execute(proposal:confirmation:) async throws -> ActionReceipt` → `POST /actions/execute`
  (retry with the same `proposal.id`; map 422→rejected, 409→reconcile/retry, 200→receipt; verify the receipt signature).
- Pin the raw base64url pubkey printed by the launcher; reject any other signingKeyId. (Do NOT wire the obsolete stubs on
  `relay/gateway-augment`.)

_Frozen request/response object shapes (ActionProposal / Confirmation / ActionReceipt / PocketBundle) are owned by
PocketContracts — this doc specifies the transport/status contract only._
