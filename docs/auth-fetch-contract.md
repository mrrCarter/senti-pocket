# Pocket Auth + Session-Fetch Security Contract (V4)

**Owner:** claude-pocket-relay · **Status:** DESIGN — awaiting finder re-clear (Echo + Pulse) then warden ratification. **No auth/fetch code until ratified.**
**Base:** atlas/pocket-contracts-v0.1 `8b098e2`. **Scope:** client-side auth + session-READ transport for "log in once → your Senti sessions." Consumes the merged wire DTOs (`SessionWire.swift`). Does **not** touch the `VerifiedBundle`/signed-briefing spine in PocketCall.
Folds warden R1/R2/R3'/R4'/R5/R6', Echo's 8 exact corrections (#239660), Pulse's ownership/state/evidence redlines, and the live-verified deployed contract.

## 1. Deployed contract (live-verified, read-only ECS/AS evidence — no secrets)
Provenance (kept distinct): **deployed prod = `3ca7640`**; **origin/main = `91a2c3fa`**, which is **one commit AHEAD** of deploy (`Persist MCP OAuth write consent in deploys`). Server-lane work targets a clean worktree on `origin/main 91a2c3fa`; the values below were read from the deployed build.
- **AS** `https://api.sentinelayer.com`: **Authorization-Code + PKCE S256 only**, public client (`token_endpoint_auth_methods: none`), RS256.
- `grant_types = [authorization_code, token-exchange]` **but the deployed token endpoint REJECTS token-exchange** ⇒ the ONLY evidenced re-issuance is an explicit foreground Auth-Code+PKCE `signIn`. **No `refresh_token`. No revocation endpoint.**
- Exact values: **issuer `https://api.sentinelayer.com`**, **resource/audience `https://mcp.sentinelayer.com`**, **access-token TTL 900s**. `JWT_ISSUER`/`JWT_AUDIENCE` env **absent** (server does not verify iss/aud today — a server-lane hardening item).
- **No Pocket client registered.** `MCP_OAUTH_CLIENTS` currently holds only `client_id=claude` (callbacks `https://claude.ai|claude.com/api/mcp/auth_callback`). A Pocket `client_id`+callback registration is a **separate live gate**; do not invent Pocket values.
- Sessions RS enforces **per-request membership server-side** (routes/sessions.py `403` + `authorize_session_*` on `user.id`).
- **P1 (server lane):** OAuth `scope` is minted but **discarded** by `authenticate_bearer_token`/`_to_authenticated_user`; `sessions:read/write` not route-enforced. This is a **BROKEN server least-privilege boundary that must be fixed server-side** (not merely "non-load-bearing"); until fixed, membership is the only access truth and Pocket auth is **fixture-only**.

## 2. Security invariants (ratified redlines)
- **R1 — server is the only access truth.** Caller's OWN token per request; server authorizes per-call against membership. Client caches NO access decision. 401/403 fail closed (never render/present cache as live).
- **R2 — no confused deputy.** Caller-credential ONLY; no code path where a service/shared/app credential reaches an `Authorization` header.
- **R3' — single credential broker, type-enforced.** One `actor` owns Keychain R/W + `Authorization` injection. Credential type is **private/nested** in the broker module (not `internal`), non-constructible/invisible outside it — "UI/Atlas never see a token" enforced by the compiler.
- **R4' — fail-closed, no invented refresh, no UI-in-fetch.** No refresh grant exists. `broker.authorize` **never launches/awaits interactive UI**: a missing/near-expired token ⇒ throws `.reauthenticationRequired` immediately, zero network, zero replay. Only an explicit `@MainActor signIn()` serializes ONE `ASWebAuthenticationSession`; **concurrent fetches fail, they do not await UI**. Never serve past expiry (conservative skew vs the 900s TTL).
- **R5 — spine isolation.** No import/touch of `VerifiedBundle`/signed-briefing (PocketCall). Sessions content is membership-authorized/neutral, never rendered as cryptographically verified (no green).
- **R6' — no server revoke ⇒ local sign-out.** Sign-out becomes `.signedOut` **only after** Keychain + subject-cache wipe succeed; containment is the 900s TTL. Never show signed-out UI while a valid token remains; never imply server revocation. Keychain `WhenUnlockedThisDeviceOnly` (no background-fetch requirement in v1). Credential never logged / notification-preview / app-switcher snapshot / analytics.

## 3. Shape (exact protocols/types — DESIGN, no bodies)
```swift
public enum AuthState: Sendable, Equatable {
    case signedOut, authenticating, signedIn(expiresAt: Date), reauthenticationRequired, error(AuthError)
}

public protocol AuthProviding: Sendable {              // STATE only; async, actor-safe — no sync var, no token accessor
    func currentState() async -> AuthState
    func stateUpdates() async -> AsyncStream<AuthState>
    @MainActor func signIn() async throws               // the ONLY interactive entry: ASWebAuthenticationSession + Auth-Code + PKCE(S256) + high-entropy state (+ OIDC nonce iff id_token); serializes ONE session
    func signOut() async throws                          // becomes signedOut only after local Keychain + subject-cache wipe succeed
}

// Broker module: the credential is a PRIVATE nested type; not nameable/constructible outside.
// AuthorizedRequest is an OPAQUE handle (the request + an unforgeable broker-private generation).
// Non-public initializer -> only the broker mints one; callers cannot fabricate or read the generation,
// and it is NOT a token. This makes the generation race a real, testable API, not prose.
public struct AuthorizedRequest: Sendable {
    public let request: URLRequest
    // internal let generation: Generation   // broker-private, non-token, unforgeable
}
actor CredentialBroker {
    // authorize() NEVER awaits UI. Missing/near-expired -> throw .reauthenticationRequired (no network, no replay).
    func authorize(_ request: URLRequest) async throws -> AuthorizedRequest   // mints request + CURRENT generation
    func handle401(_ authorized: AuthorizedRequest) async                     // invalidates ONLY that generation; a late 401 for gen N never touches N+1; a subsequent signIn() bumps generation
    // Allowed alternative: the broker OWNS network execution + response classification (no handle exposed).
    // A 403 never invalidates and never retries.
}

public protocol SessionTransport: Sendable {           // NETWORK-ONLY; returns merged wire pages; no cache, no fake success
    func listSessions(cursor: String?) async throws -> SessionListPage
    func events(sessionId: String, afterSequence: Int64?) async throws -> SessionEventForwardPage
    func eventsBefore(sessionId: String, beforeSequence: Int64) async throws -> SessionEventBeforePage
    func actions(sessionId: String) async throws -> SessionActionPage
    func checkpoints(sessionId: String) async throws -> SessionCheckpointListPage
}

public struct RepositorySnapshot<Page: Sendable>: Sendable {   // immutable; completeness is EXPLICIT, never count-derived
    public let page: Page
    public let source: Source            // .live / .cached / .fixture
    public let lastSync: Date
    public let serverWatermark: String?  // opaque cursor/sequence anchor from the server
    public let authStatus: AuthStatus    // .live / .authExpired / .offline
    public let completeness: Completeness // .complete / .partial(reason) — from the server envelope, not len(items)
}

public protocol SessionRepository: Sendable {          // SUBJECT-PARTITIONED; owns offline cache
    func sessions(refresh: Bool) async throws -> RepositorySnapshot<SessionListPage>
    // ...per endpoint. Cache SURVIVES expiry/401 but is visibly CACHED + AUTH-EXPIRED/OFFLINE, never live/complete/write.
    // Explicit sign-out / account-switch wipes the subject cache namespace.
}

public enum TransportError: Error, Sendable {
    case unauthorized, accessDenied, decoding
    case network(URLError)
    case server(status: Int, code: String?, requestId: String?)
}
```
- **No JWT-claim trust:** the client NEVER security-trusts a parsed JWT `iss`/`aud`. It pins the HTTPS endpoints/callback + state + PKCE + the token-response `expires_in`. The SERVER verifies `iss`/`aud` (a server-lane item, currently absent).
- **Non-enumerating:** UI maps forbidden/notMember/notFound → single `accessDenied` (internal telemetry may distinguish).
- **No-redirect API rule:** reject ALL API 30x BEFORE credential forwarding; the OAuth browser redirect is a SEPARATE allowlisted callback flow. Ephemeral `URLSession` (no cookies/cache).
- **Ownership (reconciled per Atlas/Pulse #239876):** Relay owns the wire DTOs + `SessionTransport`/`SessionRepository`; **Pulse** owns all visible row/content view-models, fallbacks, copy, badges, and the factory off the repository snapshot; **Atlas** owns the bare shell + the nonvisual `ParsedSessionTimestamp` + the lossless `MembershipAuthorizedCheckpoint` trust-explicit wrapper. This layer defines no presentation types.

## 4. Sequence
1. `@MainActor signIn()` → `ASWebAuthenticationSession` (PKCE+state) → exact endpoint/callback/state match → broker stores credential (`WhenUnlockedThisDeviceOnly`) with the 900s expiry.
1a. **Authoritative subject resolution (frozen, per Echo #239868 / Pulse #239876).** The broker then calls **`GET https://api.sentinelayer.com/api/v1/auth/mcp-subject`** — authenticated ONLY by the strict MCP validator, requires scope **`sessions:read`**, response minimal **`{ "subjectId": <stable server user UUID> }`** with **`Cache-Control: no-store`**, no generic/user fallback (a web-audience token is rejected here; `/auth/me` web behavior is unchanged). State becomes `.signedIn` **only after** this succeeds. `subjectId` is treated as **opaque + non-empty**: never JWT-`sub`-derived, never interpolated raw into a file path, bound to the broker generation; it is the key of the subject cache namespace. Any endpoint/decode/validation failure ⇒ signIn fails, **no** cache namespace is created. Two separately-issued MCP tokens for the same user MUST return the same `subjectId`.
2. Fetch: `broker.authorize(req)` — if missing/near-expired ⇒ **throw `.reauthenticationRequired`** (no UI, no network); else inject token + generation → `SessionTransport` → server per-call membership → `200` | `401(gen N)`/`403` fail-closed.
3. Late `401` for generation N invalidates only N; a subsequent explicit `signIn()` re-issues; `403` never retries.
4. `signOut()` → cancel in-flight → wipe Keychain + subject cache → then `.signedOut`.
5. Account switch → invalidate cache namespace.

## 5. KAV matrix
**Design (fixture-closable):** missing credential ⇒ no network; near/expired ⇒ `.reauthenticationRequired` thrown, not stale-as-live; concurrent fetches during expiry ⇒ fail (do not await UI); late-401 gen-N cancels only N, not N+1; 403 ⇒ no invalidate/retry; a 30x ⇒ cannot receive `Authorization`; broker sole Keychain owner (type-enforced, credential non-constructible outside); sign-out ⇒ signedOut only after wipe; account-switch ⇒ no stale response/cache; offline/expired cache ⇒ visibly CACHED + AUTH-EXPIRED/OFFLINE, never live/complete/write; 401/403/decode distinct; completeness from server envelope, never count-derived.
**Subject-resolution (design + live):** `mcp-subject` endpoint failure/decode-fail ⇒ signIn fails, NO cache namespace created (design); `subjectId` is opaque + never interpolated raw into a file path + bound to broker generation (design); two separately-issued MCP tokens for the same user return the SAME `subjectId`, and re-auth keeps it stable (live); a web-audience token is rejected at `mcp-subject`, wrong aud/absent-scope rejected (live).
**Live-only (need server-lane P1 + real probe + Pocket client registration):** A-cannot-read-B (server 403); read-token → write = 403; service credential cannot substitute; server verifies iss/aud/sig/exp.
> This matrix must reconcile against Pulse #239634 parts 1/2 in full before finder re-clear; any item there not covered above is added verbatim.

## 6. Separate live gates (not this contract)
- **Server-lane P1 (Echo owns; warden-endorsed):** preserve validated OAuth token kind+scope on `AuthenticatedUser` (stop discarding), enforce `sessions:read/write/usage` by route, per-path audience validation (web⇒`sentinelayer-web`, MCP⇒`https://mcp.sentinelayer.com`, mismatch/absent⇒401, no "any"), verify iss/aud/sig/exp; negative KAVs read-token→write=403 and cross-audience reject, failing on current main / passing with the fix.
- **`mcp-subject` endpoint (Echo owns; warden-endorsed):** dedicated read-only `GET /api/v1/auth/mcp-subject`, strict-MCP validator, requires `sessions:read`, `{subjectId}` + `Cache-Control: no-store`, no generic fallback; resolves an active subject only; fail-closed/non-enumerating. This is what makes client `.signedIn` + the subject cache namespace possible without trusting JWT `sub`.
- **Pocket client registration:** add a Pocket `client_id`+callback to `MCP_OAUTH_CLIENTS`.
All three are **prod auth changes ⇒ two-key (warden + finder) + explicit @human-mrrcarter GO before any deploy**. Until they land, Pocket auth is fixture-only; the `.fixture` transport claims no live authorization.
