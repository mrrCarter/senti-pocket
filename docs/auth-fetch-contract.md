# Pocket Auth + Session-Fetch Security Contract (V6)

**Owner:** claude-pocket-relay · **Status:** DESIGN — precise-markdown (warden A/B call: format=B, security A≡B). Awaiting fresh exact finder keys (Echo + Pulse) then warden ratification. **No implementation logic; the compile-proof + compile-negative KAV are enforced at the IMPLEMENTATION code-gate, not here.**
**Base:** atlas/pocket-contracts-v0.1 `6f019594` (PR16 landed). **Scope:** client-side auth + session-READ transport. Consumes merged wire DTOs (`SessionWire.swift`). Does **not** import/touch `VerifiedBundle`/signed-briefing (PocketCall).
Folds warden R1–R6', Echo's 4 + Pulse's 5 V5 residuals (consolidated A–E), the actor-mint precision, and the server-P1 usage-scope ratification (`63446896`).

## 1. Deployed contract (live-verified; read-only ECS/AS evidence)
Provenance distinct: **deployed prod `3ca7640`**; **origin/main `91a2c3fa`** is **+1 non-serializer commit ahead**. Server-P1 fix ratified at `63446896` (docs/pocket-session-oauth-boundary.md, two keys).
- **AS** `https://api.sentinelayer.com`: **Authorization-Code + PKCE S256 only** (deployed token-exchange REJECTED), public client, RS256. **No `refresh_token`, no revocation.**
- issuer `https://api.sentinelayer.com`; resource/audience **`https://mcp.sentinelayer.com`** (exact, with scheme, everywhere); access TTL **900s**.
- **No Pocket client registered** (`MCP_OAUTH_CLIENTS` = `client_id=claude` only). Live sign-in is BLOCKED until registration (§2/§6).
- **Route-local authorization** (per ratified `63446896`): each Sessions route enforces its own domain ownership/membership check server-side (routes/sessions.py `403` + `authorize_session_*`); this is NOT a universal-membership claim. Client caches no access decision.
- **Usage-scope least-privilege** (ratified `63446896`): usage-derived fields (`totalCostUsd`, `usageEntryCount`, `session_usage` payloads, checkpoint token/cost) are gated by `sessions:usage:read`. A token without it does not receive them ⇒ **the client treats every usage-derived field as OPTIONAL** (see §1a). Scope remains a **server** control, never a client security decision.

### 1a. Wire-DTO consequence of usage-scope gating (Relay lane)
`SessionSummary.totalCostUsd` moves REQUIRED→**OPTIONAL (`Decimal?`)** because a non-`sessions:usage:read` token will not receive it; a required field would break decode. (Same posture for any future usage field, e.g. `usageEntryCount`, typed optional-under-scope from the start.) This is the one wire change V6 makes; the SessionWire.swift edit lands with the ratified contract. Non-usage fields are unchanged.

## 2. Exact endpoints
**Fixture repository is independently implementable now; LIVE sign-in/callback is BLOCKED and OUTSIDE this ratification** (no Pocket client/redirect URI exists — §1). When registration lands (§6), the exact approved callback is frozen by a follow-up amendment; it is NOT invented here.
- **Authorize:** `GET https://api.sentinelayer.com/api/v1/oauth/authorize` (PKCE S256 + high-entropy `state`).
- **Token:** `POST https://api.sentinelayer.com/api/v1/oauth/token` (public client; no secret).
- **Subject:** `GET https://api.sentinelayer.com/api/v1/auth/mcp-subject` — strict-MCP validator, requires `sessions:read`, returns `{ "subjectId": <stable server user UUID> }` + `Cache-Control: no-store`; no generic fallback.
- **Sessions (exact absolute origin `https://api.sentinelayer.com`, path built by fixed segments only):**
  `GET /api/v1/sessions` · `GET /api/v1/sessions/{sessionId}/events` · `.../events/before` · `.../actions` · `.../checkpoints`.
- **Path construction:** `{sessionId}` is percent-encoded as a single path segment via `URLComponents` (no string interpolation); a value containing `/`, `..`, or non-path characters is REJECTED before any request (no path injection).
- **Transport rules (exact):** HTTPS scheme + host `api.sentinelayer.com` + port 443 + **no userinfo** validated; any mismatch → `TransportError.network`. Ephemeral `URLSession` (no cookies/cache/credential store). Only the broker sets `Authorization`; the client STRIPS any caller-supplied `Authorization`/`Proxy-Authorization`/`Cookie` before authorizing (deny-list, fail-closed). `URLSession` redirect delegate returns `nil` for EVERY 3xx: the origin receives the credential once; a redirect target receives ZERO request and ZERO credential.

## 3. Security invariants (ratified redlines)
R1 route-local server authorization is the ONLY access truth (client caches no decision; 401/403 fail closed). R2 no confused deputy — caller-credential only; no path where a service/shared/app credential reaches `Authorization`. R3' single broker actor, type-enforced containment. R4' no refresh; `authorize` never awaits UI. R5 spine isolation (no PocketCall/VerifiedBundle; sessions content never crypto-verified/green). R6' local sign-out only after Keychain + cache wipe both succeed; `WhenUnlockedThisDeviceOnly`; credential never in DTO/error/log/crash/preview/app-switcher/analytics.

## 4. Precise type surface (DESIGN — exact signatures, no two-way ambiguity; no bodies)
```swift
public enum AuthState: Sendable, Equatable { case signedOut, authenticating, signedIn(expiresAt: Date), reauthenticationRequired, error(AuthError) }
public enum AuthError: Error, Sendable, Equatable {
    case userCancelled, stateMismatch, exchangeFailed, subjectResolutionFailed
    case reauthenticationRequired, network, keychain, invalidResponse
}
public enum Source: Sendable, Equatable { case network(at: Date), cached(at: Date), fixture }
public enum AuthStatus: Sendable, Equatable { case live, authExpired, offline }
public enum Completeness: Sendable, Equatable { case complete, partial(reason: String), unknown }  // forward {events} is ALWAYS .unknown
public enum Watermark: Sendable, Equatable { case cursor(String), sequence(Int64) }                // opaque cursor vs Int64 sequence never conflated
public enum TransportError: Error, Sendable, Equatable { case unauthorized, accessDenied, decoding, network, server(status: Int, code: String?, requestId: String?) }

public struct RepositorySnapshot<Page: Sendable & Equatable>: Sendable, Equatable {
    public let page: Page
    public let source: Source
    public let authStatus: AuthStatus
    public let completeness: Completeness
    public let serverWatermark: Watermark?
    public let lastSuccessfulSync: Date?
}

public protocol AuthProviding: Sendable {                     // async, actor-safe; NO token accessor
    func currentState() async -> AuthState
    func stateUpdates() async -> AsyncStream<AuthState>
    @MainActor func signIn() async throws                     // ONLY interactive entry; single UI flight
    func signOut() async throws                               // signedOut only after Keychain + cache wipe
}

public actor CredentialBroker {
    // AuthorizedRequest is nested in the broker; its init is `private` and the file contains ONLY the broker,
    // so ONLY CredentialBroker's own methods can mint one (no same-file forge path; a `private` nested-type
    // init is stronger than `fileprivate`). `generation` is an opaque stored stamp, never exposed.
    public struct AuthorizedRequest: Sendable {
        public let request: URLRequest
        private let generation: UInt64
        private init(request: URLRequest, generation: UInt64) { self.request = request; self.generation = generation }
        fileprivate static func mint(_ r: URLRequest, _ g: UInt64) -> AuthorizedRequest { .init(request: r, generation: g) }
    }
    public enum Outcome: Sendable, Equatable { case ok, unauthorized, accessDenied, transport(TransportError) }
    private var currentGeneration: UInt64                     // stored; bumped on 401(gen==current) and on sign-out
    // Throws AuthError.reauthenticationRequired when no unexpired credential exists; NEVER awaits UI, NEVER replays.
    public func authorize(_ request: URLRequest) async throws -> AuthorizedRequest
    // Compares authorized's captured generation to currentGeneration: a 401 for gen N bumps only if N==current
    // (late 401 for a superseded N is ignored — zero cross-generation invalidation). 403 → accessDenied, no bump, no retry.
    public func classify(_ response: HTTPURLResponse, for authorized: AuthorizedRequest) async -> Outcome
}

// Network-only; each method attaches a broker AuthorizedRequest, returns a merged wire page or throws TransportError.
// No arbitrary-URLRequest method exists (no escape hatch); inputs are typed, paths built per §2.
public protocol SessionTransport: Sendable {
    func listSessions(includeArchived: Bool, cursor: String?) async throws -> SessionListPage
    func events(sessionId: String, fromSequence: Int64?) async throws -> SessionEventForwardPage
    func eventsBefore(sessionId: String, beforeSequence: Int64) async throws -> SessionEventBeforePage
    func actions(sessionId: String) async throws -> SessionActionPage
    func checkpoints(sessionId: String) async throws -> SessionCheckpointListPage
}

// Subject-partitioned; owns the cache; attaches the broker; owns 401→invalidate + 403→suppress-and-don't-poison.
// Returns a snapshot (never a bare page); on network/decode failure returns the prior protected snapshot as
// Source.cached + the correct AuthStatus, never a fake success.
public protocol SessionRepository: Sendable {
    func sessions(includeArchived: Bool, cursor: String?) async throws -> RepositorySnapshot<SessionListPage>
    func events(sessionId: String, fromSequence: Int64?) async throws -> RepositorySnapshot<SessionEventForwardPage>
    func eventsBefore(sessionId: String, beforeSequence: Int64) async throws -> RepositorySnapshot<SessionEventBeforePage>
    func actions(sessionId: String) async throws -> RepositorySnapshot<SessionActionPage>
    func checkpoints(sessionId: String) async throws -> RepositorySnapshot<SessionCheckpointListPage>
}
```
- **Subject namespace:** an unforgeable capability minted only after `mcp-subject` succeeds; the on-disk cache key is a **deterministic keyed digest** of `subjectId` (raw `subjectId` NEVER in a path); Keychain-held; complete file protection + no iCloud backup; reads AND writes generation-gated; any wipe failure ⇒ either-wipe (§4b). Client never security-trusts parsed JWT `iss`/`aud`/`sub`. Non-enumerating: forbidden/notMember/notFound → single `accessDenied`.

## 4a. signIn sequence (atomic)
`@MainActor signIn()` → single `ASWebAuthenticationSession` (PKCE + `state`) → exact endpoint/callback/`state` match → **ephemeral** token exchange → `GET /auth/mcp-subject` → current-generation check → **ATOMIC commit of {credential + subject namespace}** → `.signedIn`. Any failure (cancel, state mismatch, exchange, subject, generation): persist **neither**, wipe **both**; a stale generation N can never commit after sign-out or after N+1. Concurrent fetches during this throw `.reauthenticationRequired` (never await UI).

## 4b. Freshness + wipe behavior (exact table)
Credential is used for NETWORK only while unexpired minus a **60s skew margin**; at/near/after expiry it is NEVER used for network. A protected subject-partitioned prior snapshot remains READABLE after auth expiry — this preserves the mandatory offline-after-sync path.

| Condition | Source | AuthStatus | Completeness | Network? | Renders content? |
|---|---|---|---|---|---|
| fresh network fetch | `network(at:)` | `live` | complete/partial/unknown | yes | yes |
| cached, within max-age (300s), auth valid | `cached(at:)` | `live` | as-cached | no (served from cache) | yes |
| cached, auth expired | `cached(at:)` | `authExpired` | as-cached (never `complete`) | no | yes (read-only) |
| offline, cache present | `cached(at:)` | `offline` | as-cached | no | yes (read-only) |
| no cache + (offline or expired) | — | `offline`/`authExpired` | — | no | no (empty, not fake) |

A cached snapshot after expiry is **never** `live`, never `complete`, never write-capable; it always carries `lastSuccessfulSync`. **Wipe recovery:** sign-out writes a `tombstone` first and disables cache reads immediately; `signedOut` is impossible until BOTH Keychain and filesystem deletions complete; if either fails, retry on next launch and neither half remains readable (tombstone keeps reads disabled). Clock: monotonic where available; wall-clock skew treated conservatively (expire early, never late).

## 5. KAV matrix (full — Pulse #239819 + new C/D vectors; compile-proof KAVs deferred to impl gate per warden)
**Client (fixture-closable now):** single sign-in UI flight; state-mismatch/cancel fail closed; 401 zero-replay AND late gen N cannot commit after sign-out/N+1; 403 no-retry + target-cache suppression/no-poison; network/decode failure retains prior protected snapshot labeled cached/stale; forward-gap or unknown NEVER complete; Keychain OR cache deletion failure NEVER yields signedOut (either-wipe, tombstone, reads-disabled); account-switch / cancelled-late-result cannot commit; token/header absent from DTO/error/log/crash/preview; fixture cannot mint network/current/write/crypto-green provenance; no PocketCall import; provisional-credential (never persisted before mcp-subject succeeds); stale-subject cannot commit; generation-gated cache reads+writes; **freshness boundaries** (at/just-before/just-after expiry incl. 60s skew; max-age 300s; expired-auth renders cached read-only, never live/complete/write; no-cache→empty not fake); **wipe ordering** (each of Keychain-then-fs and fs-then-Keychain failure leaves nothing readable + not signedOut); **path/transport** (wrong host/port/scheme/userinfo rejected; `{sessionId}` with `/`|`..`|non-path rejected; caller `Authorization`/`Proxy-Authorization`/`Cookie` stripped; every 3xx status followed by zero redirect request/credential); **usage-scope** (missing `sessions:usage:read` ⇒ `totalCostUsd` absent decodes fine as `nil`, never a crash/fake-zero).
**Deferred to IMPLEMENTATION code-gate (need real compileable code):** compile-NEGATIVE construction (an external non-`@testable` consumer target fails to construct `AuthorizedRequest`); N-vs-N+1 live response binding; full compile + green suite + minimal source diff + Pulse review.
**Live/server (need server-lane + real probe + Pocket registration):** wrong/absent user+MCP issuer/audience rejected; scope/`scp` confusion terminal no-fallback; missing/unknown scope rejected; read-scoped cannot write (403); usage-only cannot read content; route-local A-cannot-read-B (server 403); required `iat`/`sub`, MCP nonempty `jti`/supported scopes; mcp-subject stable across reauth/two tokens; web-audience token rejected at mcp-subject.

## 6. Separate live gates (all prod auth ⇒ two-key warden+finder + explicit @human-mrrcarter GO before deploy)
- **Server-P1 (Echo; ratified design `63446896`):** per-path audience validation + preserve token kind+scope + route scope enforcement (incl. usage-scope) + iss/aud/sig/exp verify + fail-first/green KAVs. Implementation code-gate pending (warden gates the full slice: compiles, 16 green, source diff, Pulse review).
- **`mcp-subject` endpoint (Echo):** as §2.
- **Pocket client registration:** add a Pocket `client_id` + exact callback to `MCP_OAUTH_CLIENTS`; the exact callback is frozen by a follow-up amendment (§2). Until then LIVE sign-in is blocked; the `.fixture` transport claims no live authorization.

## 7. Ownership (canonical — reconciled across this doc, OWNERSHIP.md, SessionWire.swift header)
**Relay** = the wire DTOs + `SessionTransport`/`SessionRepository` + `CredentialBroker`/`AuthProviding`. **Atlas** = the bare app shell + exactly the two nonvisual wrappers `ParsedSessionTimestamp` + `MembershipAuthorizedCheckpoint`. **Pulse** = all presentation: view-models, fallbacks, copy, badges, and the factory off the repository snapshot. This layer defines no presentation types.
