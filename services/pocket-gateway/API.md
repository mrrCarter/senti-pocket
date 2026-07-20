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
- **Scopes** (least-privilege): `sessions:read` (sync), `sessions:write` (execute), `pocket:voice` (tts). A read+write token
  must NOT authorize voice (third-party egress). Missing scope => 403.

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
