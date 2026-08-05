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

### `GET /dial/register/context` — Registry V2 owner bootstrap (authenticated)

This auth-only read resolves the stable registry owner for the exact bearer being used by the phone. It requires neither
`pocket:dial` scope nor session membership, accepts no request body, and grants no binding or ring authority.

```json
{
  "registrationVersion": 2,
  "ownerVersion": 1,
  "ownerHandle": "<canonical 43-character unpadded base64url>",
  "serverTime": "2026-08-04T22:00:00.000Z"
}
```

`ownerHandle` is a versioned, domain-separated server HMAC over the verifier-owned principal and human identity. It is
stable across bearer refresh for the same authenticated owner and changes for a different owner. It is pseudonymous
correlation data—not authority: every mutation still requires a valid bearer, and the server recomputes and compares
the handle. Clients must bind any cached context to the exact bearer digest and local auth generation, then recheck both
after the response. All success and error responses carry `Cache-Control: no-store` and `Pragma: no-cache`; deployments
must also enforce a shared, verified-principal-aware rate bound for this route. 401 means the bearer is absent/invalid,
501 means Registry V2 is disabled, and malformed adapter output or context failure returns a generic 502.

### `POST /dial/register` — Registry V2 (scope `pocket:dial` for new writes)

Membership-gated registration of one installation's current PushKit routing intent. The authenticated principal and
human identity come only from the bearer; neither is accepted in the body.

Deployment remains fail-closed on V1 until the V2 iOS registrar/binding gate is released and the operator explicitly
sets every migration/outcome/admission/owner-continuity acknowledgement documented in `DEPLOY.md`; the legacy shipping client cannot
satisfy this contract.

```json
{
  "registrationVersion": 2,
  "ownerVersion": 1,
  "ownerHandle": "<value returned for this exact authenticated owner>",
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

`ownerVersion` and `ownerHandle` are required on every Registry V2 mutation and are included unchanged in every
successful, recovery, denied-before-commit, binding-conflict, and token-claim-conflict receipt. The server derives the
expected handle again from the authenticated principal. A mismatch against either that derivation or a protected stored
base/claim/outcome row returns exact **409**
`{"error":"registry owner does not match authenticated principal","reason":"registry-owner-conflict"}`. That generic
body intentionally exposes no current handle or fence. A freshly issued bearer for the same principal resolves the same
handle and may resume exact cleanup; a different account cannot use copied local installation/fence values.

`expectedBindingId` and `expectedBindingRevision` may be omitted together only for a genuinely new installation item or
an exact retry of the same idempotency operation. Every distinct operation against an existing installation must send
the exact last server binding tuple, even when principal/session/token/platform intent is unchanged. A distinct
same-intent operation preserves the stable binding id but advances the binding revision and token-claim generation;
an exact same-operation retry alone preserves the revision. This makes each operation's cleanup fence unique and stops
a delayed operation with a stale fence from superseding a newer grant.

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
  "ownerVersion": 1,
  "ownerHandle": "<exact request owner handle>",
  "sessionId": "…",
  "platform": "apns",
  "bindingId": "bind_…",
  "bindingRevision": 5,
  "tokenClaimId": "claim_…",
  "tokenClaimRevision": 10,
  "expiresAt": "2026-08-07T07:00:00.000Z",
  "serverTime": "2026-07-31T07:00:00.000Z",
  "idempotent": false
}
```

`serverTime` is generated after the registry operation from the same injected server clock. Clients must derive the
lease duration from `expiresAt - serverTime`, conservatively subtract request round-trip time, and count the remainder
down with a sleep-inclusive monotonic clock. Device wall time is not lease authority.

An exact retry (same authenticated owner, installation, idempotency key, and semantic request fingerprint) is first
reconciled with strong reads and never renews or mutates registry state. It receives the normal 200 receipt only while
the caller still has both `pocket:dial` and session membership. If either authority disappeared after the write
committed, the exact retry receives strict **409 `registration-committed-but-unauthorized`** instead:

```json
{
  "registered": false,
  "committed": true,
  "authorized": false,
  "revocationRequired": true,
  "reason": "registration-committed-but-unauthorized",
  "error": "registration committed but current authorization is missing",
  "registrationVersion": 2,
  "ownerVersion": 1,
  "ownerHandle": "<exact request owner handle>",
  "sessionId": "…",
  "platform": "apns",
  "bindingId": "bind_…",
  "bindingRevision": 5,
  "tokenClaimId": "claim_…",
  "tokenClaimRevision": 10,
  "expiresAt": "2026-08-07T07:00:00.000Z",
  "serverTime": "2026-07-31T07:00:00.000Z",
  "idempotent": true
}
```

This is a revocation receipt, not lease authority: clients must persist the fences only long enough to call DELETE and
must not make the route eligible for rings. An exact physically retained replay at or after logical expiry has the same
strict body fields with **410 `registration-expired`** and `error: "registration lease expired"`. Changed, absent,
invalid, and non-V2 requests cannot use this recovery path; without scope they remain the ordinary 403. A reconcile
read/corruption failure is generic retryable 502 so the client retains its pending request rather than treating it as a
definitive miss.

- **409 `binding-conflict`** returns exactly `ownerVersion`, `ownerHandle`, and
  `currentBinding:{bindingId,bindingRevision,expiresAt}` (or `null`). A client
  may retry with that tuple only while the same local auth/session/token intent is still current. A superseded task must
  not reconcile or retry.
- **409 `token-claim-conflict`** returns exactly `ownerVersion`, `ownerHandle`, and
  `currentTokenClaim:{tokenClaimId,tokenClaimRevision,expiresAt}` (or `null`) for the explicit token-owner CAS above.
  `expiresAt` is the logical route expiry and can already be in the past during reclaim grace; it is not an
  automatic-reuse timestamp, and the returned tuple remains the explicit transfer fence.
- **409 `idempotency-conflict`** means the same principal + installation + operation UUID was reused for different
  semantic intent. Each operation has one HMAC-addressed terminal outcome row retained for a bounded lease/retry
  horizon; raw principal, installation, session, token, and UUID are not stored in that row. Production V2 cannot boot
  until distributed unique-operation admission is independently verified, so arbitrary UUIDs cannot create unbounded
  journal cardinality.
- **409 `target-capacity`** means the authenticated human/session already has 20 active installations. Renewals,
  rotations, and same-target token-owner replacement net their exact removals before this check; no existing member is
  arbitrarily evicted.
- **409 `registration-conflict`** means all 21 bounded serialization attempts lost retryable contention. Retry the same
  idempotency key with client backoff only while the local auth/session/token intent is still current.
- **409 `revision-exhausted`** is permanent for the current V2 namespace. Do not auto-retry; operator intervention and a
  versioned schema migration are required before that Registry V2 record can advance.
- A lease becomes unroutable exactly at `expiresAtEpochSec`. Registry rows remain physically TTL-eligible only after a
  fixed five-minute reclaim grace. Through that physical TTL, only the same owner may renew/rebind or transfer a
  protected base/claim with its exact CAS fence; a different owner receives the generic owner conflict even if it copied
  every identifier. At or after physical TTL, a still-retained base/claim is treated as reclaimable without waiting for
  DynamoDB's asynchronous deletion. Same-owner token movement during grace still requires the returned claim tuple so
  displaced base/directory state moves atomically.
- 400 malformed/non-canonical/unknown field · 403 non-member/missing scope · 410 exact committed lease expired · 426
  unversioned request · 429 `operation-rate-limited` at the required admission boundary · 501 V2 not configured · 502
  registry failure.
- The raw installation id and token are never returned. The server persists only an HMAC of installation identity;
  the opaque PushKit token necessarily remains protected at rest because APNs cannot route using only a hash.

A missing scope or membership response is definitive 403 only after the server has durably written a `DENIED` outcome
for that exact operation. The original registration transaction and the denial contend on the same operation row. If
denial wins, any held/late original write returns 409 `registration-denied-before-commit` with no authority fences. If
commit wins, the unauthorized retry returns the strict 409/410 revocation receipt above, never a false 403. Storage,
corruption, or exhausted-contention failures are retryable 5xx and the phone retains its pending operation.

Both the definitive 403 and a late writer's 409 return the exact no-authority terminal envelope below. The 403 preserves
its authorization error (`missing scope pocket:dial` or `not a known session for this user`); the 409 uses the generic
error shown in the example. A different-fingerprint request that reuses an operation UUID is not exact terminal proof:
without authorization it remains the ordinary generic 403 and never receives stored outcome, owner, or authority fields.

The denied-before-commit body is exact:

```json
{
  "registered": false,
  "committed": false,
  "authorized": false,
  "revocationRequired": false,
  "reason": "registration-denied-before-commit",
  "error": "registration operation was denied before commit",
  "registrationVersion": 2,
  "ownerVersion": 1,
  "ownerHandle": "<exact request owner handle>",
  "sessionId": "…",
  "platform": "apns",
  "idempotent": true
}
```

It is terminal proof that this exact UUID created no binding. The phone may clear only the matching pending operation
and, if the same authorized intent is still current, mint a new UUID; it must not treat this response as lease authority.

### `POST /dial/register/reconcile` — authenticated digest-only cleanup

This endpoint is deliberately subtractive and requires a valid bearer but neither current `pocket:dial` scope nor
session membership. It exists for sign-out/access-loss recovery when iOS retained a pending operation but PushKit has
already invalidated and erased the raw token.

The request has exactly these eight fields:

```json
{
  "registrationVersion": 2,
  "ownerVersion": 1,
  "ownerHandle": "<value returned for this exact authenticated owner>",
  "installationId": "<32 random bytes, canonical unpadded base64url>",
  "idempotencyKey": "<UUID>",
  "tokenDigest": "<canonical unpadded base64url SHA-256>",
  "sessionId": "…",
  "platform": "apns"
}
```

`tokenDigest` is exactly `base64url-unpadded(SHA-256(UTF-8(voipToken)))`, where `voipToken` is the same wire string sent
to `POST /dial/register`; it is not a hash of decoded hex/token bytes. Raw `voipToken`, binding/claim fences, unknown
fields, padded/noncanonical digests, and non-version-2 bodies are rejected before storage.

The server derives the same HMAC operation key/fingerprint as the original request. An absent operation becomes a
durable `DENIED` barrier. A committed operation is compare-deleted using only its stored exact binding revision. A
newer operation—including a same-intent renewal—has a newer revision and cannot be erased by stale cleanup. Replays are
existence-oblivious and never grant lease authority.

The only successful body is exact:

```json
{
  "registrationVersion": 2,
  "ownerVersion": 1,
  "ownerHandle": "<exact request owner handle>",
  "idempotencyKey": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  "sessionId": "…",
  "platform": "apns",
  "registered": false,
  "authorized": false,
  "cleanupComplete": true,
  "serverTime": "2026-08-04T22:00:00.000Z"
}
```

- 200 means the exact operation is durably denied or its exact committed binding is absent/deleted. It contains no
  binding id/revision, token-claim fence, expiry, renewal, or `idempotent` field.
- 409 `idempotency-conflict` means that UUID already names different registration bytes; retain local state and do not
  treat it as cleanup success.
- 409 `registry-owner-conflict` means the authenticated owner differs from the requested or protected stored owner;
  retain local state, expose no handle/fence from the server response, and require the correct account.
- 503 `registration-cleanup-conflict` means the barrier/delete could not serialize; retry the identical request.
- 400 malformed/noncanonical/unknown field · 401 invalid bearer · 429 `operation-rate-limited` at the required admission
  boundary · 501 V2 unavailable · 502 storage/corruption/adapter failure. Every non-200 retains the pending operation on
  the phone.

For both registration endpoints, the external admission boundary's 429 response is exact JSON
`{"error":"registration operation rate limited","reason":"operation-rate-limited"}` with a positive integer
`Retry-After` header in seconds. It keys the shared quota by the verifier-owned principal/human plus installation and
idempotency UUID—not by IP, mutable request fingerprint, or UUID alone—and returns before any registry mutation.

### `DELETE /dial/register` — authenticated exact conditional revoke

Body:

```json
{
  "registrationVersion": 2,
  "ownerVersion": 1,
  "ownerHandle": "<exact authenticated owner handle>",
  "installationId": "…",
  "sessionId": "…",
  "bindingId": "bind_…",
  "bindingRevision": 5
}
```

The only 200 body is exact:

```json
{
  "unregistered": true,
  "registrationVersion": 2,
  "ownerVersion": 1,
  "ownerHandle": "<exact request owner handle>",
  "sessionId": "…"
}
```

This route intentionally requires neither current `pocket:dial` scope nor session membership, so sign-out/access-loss
can revoke with the still-authenticated bearer before credentials are cleared. It is existence-oblivious: a valid
request returns 200 even if already absent. Deletion occurs only when authenticated target + installation + binding id
+ revision + owner all still match; a stale A revoke cannot delete a newer B binding, and another account cannot delete
the protected row even with a copied exact fence. Owner mismatch returns the same generic 409 body documented above.
Registry operations use a schema-bounded 21-attempt serialization budget
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

Immediately before transport, the gateway performs one second bounded target lookup after any hydration write and
retains only routes whose exact `(platform, token, binding.id, binding.revision)` tuple is still present. A failed second
snapshot sends nothing and surfaces `registry-revalidation-failed`; zero survivors sends nothing and surfaces
`stale-device-binding`. Surviving routes fan out concurrently within the fixed 20-installation admission bound. V1 uses
the same two-snapshot rule with exact `(platform, token)` matching inside its exact-principal compatibility namespace.

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
