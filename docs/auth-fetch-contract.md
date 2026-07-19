# Pocket Auth + Session-Fetch Security Contract (V5)

**Owner:** claude-pocket-relay · **Status:** DESIGN — awaiting fresh exact finder keys (Echo + Pulse) then warden ratification. **No auth/fetch code, no TODOs.**
**Base:** atlas/pocket-contracts-v0.1 `8b098e2`. **Scope:** client-side auth + session-READ transport. Consumes the merged wire DTOs (`SessionWire.swift`). Does **not** import/touch `VerifiedBundle`/signed-briefing (PocketCall).
Folds warden R1–R6', Echo's 7 exact blockers (#239905) + the actor-mint precision, Pulse's full KAV matrix (#239819), and the cross-contract subject resolution.

## 1. Deployed contract (live-verified; read-only ECS/AS evidence)
Provenance kept distinct: **deployed prod `3ca7640`**; **origin/main `91a2c3fa`** is **one commit AHEAD** (`Persist MCP OAuth write consent in deploys`). Server-lane work targets a clean worktree on `91a2c3fa`.
- **AS** `https://api.sentinelayer.com`: **Authorization-Code + PKCE S256 only** (deployed token-exchange is REJECTED), public client, RS256. **No `refresh_token`, no revocation.**
- issuer `https://api.sentinelayer.com`; resource/audience `https://mcp.sentinelayer.com`; access TTL **900s**. `JWT_ISSUER`/`JWT_AUDIENCE` env absent (server doesn't verify iss/aud today — a server-lane item).
- **No Pocket client registered** (`MCP_OAUTH_CLIENTS` holds only `client_id=claude`). Separate live gate.
- Sessions RS enforces per-request membership server-side (routes/sessions.py `403` + `authorize_session_*`).
- **P1 (server lane, Echo owns, warden-endorsed):** OAuth `scope` minted then discarded ⇒ `sessions:read/write` not route-enforced = broken least-privilege. Plus JWT audience confusion (user `sentinelayer-web` vs MCP audience not segregated). Client treats scope as **broken boundary**, never a client-side security control.

## 2. Exact endpoints (frozen)
- **Authorize:** `GET https://api.sentinelayer.com/api/v1/oauth/authorize` (PKCE S256 + high-entropy `state`).
- **Token:** `POST https://api.sentinelayer.com/api/v1/oauth/token` (public client; no secret).
- **Callback:** a registered Pocket Universal Link (server-lane registration gate) — the OAuth redirect is the ONLY allowlisted redirect flow.
- **Subject:** `GET https://api.sentinelayer.com/api/v1/auth/mcp-subject` — strict-MCP validator, requires `sessions:read`, returns `{ "subjectId": <stable server user UUID> }` + `Cache-Control: no-store`, no generic fallback.
- **Sessions:** `GET /api/v1/sessions`, `/api/v1/sessions/{id}/events`, `/events/before`, `/actions`, `/checkpoints`.
- **Transport rules:** HTTPS scheme + exact host + port validated; **no userinfo** in URL; ephemeral `URLSession` (no cookies/cache); credential injected **only** on the request origin, **once**; **reject ALL API 30x before credential forwarding** — a redirect target receives ZERO request and ZERO credential; hostile/injected request headers are stripped/rejected; only the broker may set `Authorization`.

## 3. Security invariants (ratified redlines)
R1 server-only access truth (client caches no access decision; 401/403 fail closed). R2 no confused deputy — caller-credential only; no path where a service/shared/app credential reaches `Authorization`. R3' single broker actor. R4' no refresh, `authorize` never awaits UI. R5 spine isolation (no PocketCall/VerifiedBundle; sessions content never crypto-verified/green). R6' local sign-out only after Keychain + cache wipe; `WhenUnlockedThisDeviceOnly`; credential never in DTO/error/log/crash/preview/app-switcher/analytics.

## 4. Shape (exact types — DESIGN, no bodies)
```swift
public enum AuthState: Sendable, Equatable { case signedOut, authenticating, signedIn(expiresAt: Date), reauthenticationRequired, error(AuthError) }
public enum AuthError: Error, Sendable, Equatable { case userCancelled, stateMismatch, exchangeFailed, subjectResolutionFailed, network, keychain, invalidResponse }

public protocol AuthProviding: Sendable {                 // async, actor-safe; no token accessor
    func currentState() async -> AuthState
    func stateUpdates() async -> AsyncStream<AuthState>
    @MainActor func signIn() async throws                  // ONLY interactive entry; single UI flight
    func signOut() async throws                            // signedOut only after Keychain + cache wipe succeed
}

// CredentialBroker: the credential AND the generation are broker-private nested types with NO accessible
// initializer (not even same-file). Nothing outside the broker's own methods can construct or forge an
// AuthorizedRequest or its generation (fileprivate is insufficient — actor-scoped private-mint is the guarantee).
actor CredentialBroker {
    public struct AuthorizedRequest: Sendable { public let request: URLRequest /* opaque broker-minted generation, no public init */ }
    func authorize(_ request: URLRequest) async throws -> AuthorizedRequest   // NEVER awaits UI; missing/near-expired -> throw .reauthenticationRequired (no network, no replay)
    func classify(_ response: HTTPURLResponse, for authorized: AuthorizedRequest) async -> Outcome
    // 401(gen N): invalidate ONLY generation N; a late 401 for N never touches N+1; zero replay. 403: never invalidate, never retry.
}

public enum Source: Sendable { case network(at: Date), cached(at: Date), fixture }   // fixture/cached NEVER masquerade as network/live/verified
public enum AuthStatus: Sendable { case live, authExpired, offline }
public enum Completeness: Sendable { case complete, partial(reason: String), unknown }  // forward {events} is ALWAYS .unknown, never inferred from len(items)
public struct RepositorySnapshot<Page: Sendable>: Sendable {
    public let page: Page; public let source: Source; public let authStatus: AuthStatus
    public let completeness: Completeness; public let serverWatermark: Watermark?; public let lastSuccessfulSync: Date?
}
public enum Watermark: Sendable { case cursor(String), sequence(Int64) }   // typed; opaque cursor vs Int64 sequence never conflated

public protocol SessionTransport: Sendable { /* network-only; returns merged wire pages; no cache/fake-success */ }
public protocol SessionRepository: Sendable { /* subject-partitioned; owns cache; returns RepositorySnapshot */ }
public enum TransportError: Error, Sendable { case unauthorized, accessDenied, decoding, network(URLError), server(status: Int, code: String?, requestId: String?) }
```
- **Subject namespace:** an unforgeable capability minted only after `mcp-subject` succeeds; the on-disk cache key is a **deterministic keyed digest** of `subjectId` (raw `subjectId` NEVER in a path); Keychain-held; complete file protection + no iCloud backup; reads AND writes are **generation-gated**; any wipe failure ⇒ either-wipe (never a half state).
- **No client JWT-claim trust:** the client never security-trusts parsed `iss`/`aud`/`sub`; the server verifies them. `subjectId` is opaque + non-empty.
- **Non-enumerating:** forbidden/notMember/notFound → single `accessDenied`.

## 4a. signIn sequence (atomic; frozen per Echo #239905)
`@MainActor signIn()` → single `ASWebAuthenticationSession` (PKCE + `state`) → exact endpoint/callback/`state` match → **ephemeral** token exchange → `GET /api/v1/auth/mcp-subject` → current-generation check → **ATOMIC commit of {credential + subject namespace}** → `.signedIn`. On ANY failure (cancel, state mismatch, exchange, subject, generation): persist **neither**, wipe **both**; a stale generation N can never commit after sign-out or after N+1. Concurrent fetches during this never await UI — they throw `.reauthenticationRequired`.

## 5. KAV matrix (full; no TODO — Pulse #239819 + Echo #239905, verbatim)
**Client (design, fixture-closable):** single sign-in UI flight; state-mismatch/cancel fail closed; 401 zero-replay AND late generation N cannot commit after sign-out/N+1; 403 no-retry + target-cache suppression/no-poison; network/decode failure retains the prior protected snapshot **labeled cached/stale**; forward-gap or unknown NEVER complete; Keychain OR cache deletion failure NEVER yields signedOut (either-wipe); account-switch / cancelled-late-result cannot commit; token/header absent from DTO/error/log/crash/preview; fixture cannot mint network/current/write/crypto-green provenance; no PocketCall import; **forged-handle** (a non-broker-minted AuthorizedRequest is unconstructible/rejected); **provisional-credential** (credential never persisted before mcp-subject); **stale-subject** (a prior-generation subject cannot commit); **generation-gated cache reads+writes**; **freshness/clock boundaries** (skew-conservative expiry; never serve past expiry).
**Live/server (need server-lane + real probe + Pocket registration):** wrong/absent user+MCP issuer/audience rejected; scope/`scp` confusion terminal no-fallback; missing/unknown scope rejected; read-scoped cannot write (403); usage-only cannot read content; ordinary user/API/agent behavior unchanged; required `iat`/`sub` present and MCP nonempty `jti`/supported scopes; A-cannot-read-B (server 403); mcp-subject stable across reauth/two tokens; web-audience token rejected at mcp-subject.

## 6. Separate live gates (all prod auth ⇒ two-key warden+finder + explicit @human-mrrcarter GO before deploy)
- **Server-lane P1 (Echo owns; PR #752):** per-path audience validation (web⇒`sentinelayer-web`, MCP⇒`mcp.sentinelayer.com`, mismatch/absent⇒401, no "any") + preserve token kind+scope + route scope enforcement + iss/aud/sig/exp verify + the live KAVs (fail on main / pass on fix).
- **`mcp-subject` endpoint (Echo owns):** as in §2.
- **Pocket client registration:** add a Pocket `client_id`+callback to `MCP_OAUTH_CLIENTS`.
Until all land, Pocket auth is fixture-only; the `.fixture` transport claims no live authorization.

## 7. Ownership (canonical — reconciled across all three files: this doc, OWNERSHIP.md, SessionWire.swift header)
**Relay** = the wire DTOs + `SessionTransport`/`SessionRepository` + `CredentialBroker`/`AuthProviding`. **Atlas** = the bare app shell + exactly the two nonvisual wrappers `ParsedSessionTimestamp` + `MembershipAuthorizedCheckpoint`. **Pulse** = all presentation: view-models, fallbacks, copy, badges, and the factory off the repository snapshot. This layer defines no presentation types. (OWNERSHIP.md and SessionWire.swift:3-6 corrected to match in the same commit.)
