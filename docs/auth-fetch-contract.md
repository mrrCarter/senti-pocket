# Pocket Auth + Session-Fetch Security Contract (V8)

**Owner:** claude-pocket-relay · **Status:** DESIGN — precise-markdown (warden A/B=B). Awaiting fresh exact finder keys (Echo + Pulse) then warden ratification. **No implementation logic; compile-proof + compile-negative + N-vs-N+1 KAVs enforced at the IMPLEMENTATION code-gate.**
**Base:** atlas/pocket-contracts-v0.1 `6f019594` (FF-ready). **Scope:** client-side auth + session-READ transport. Consumes merged wire DTOs (`SessionWire.swift`, **unchanged**). Does **not** import/touch `VerifiedBundle`/signed-briefing (PocketCall).
Folds warden R1–R6', consolidated V6 P1-1..P2-5 + Pulse guards, and both full A-E verdicts + V7 residuals a–g. Server-P1 ratified `63446896`.

## 1. Deployed contract (live-verified; read-only ECS/AS evidence)
Provenance distinct: **deployed prod `3ca7640`**; **origin/main `91a2c3fa`** is **+1 non-serializer commit ahead**.
- **AS** `https://api.sentinelayer.com`: **Authorization-Code + PKCE S256 only** (deployed token-exchange REJECTED), public client, RS256. **No `refresh_token`, no revocation.**
- issuer `https://api.sentinelayer.com`; resource/audience **`https://mcp.sentinelayer.com`** (exact, with scheme, everywhere); access TTL **900s**.
- **No Pocket client registered** (`MCP_OAUTH_CLIENTS` = `client_id=claude` only). LIVE sign-in BLOCKED until registration (§2/§6).
- **Route-local authorization** (ratified `63446896`): each route enforces its own domain ownership/membership check server-side (`403` + `authorize_session_*`); NOT universal-membership. Client caches no access decision.
- **Usage-scope (ratified `63446896`, all-of, NO redaction):** `sessions` list/get require **all-of `sessions:read`+`sessions:usage:read`**; a strict subset gets **`403`** (route-level, not field redaction). A `200` always carries the usage-derived fields. `totalCostUsd` stays **required `Decimal`** — wire DTO unchanged.

## 2. Endpoints (exact; execution is broker-owned per §4)
**Fixture repository is independently implementable now; LIVE sign-in/callback is BLOCKED and OUTSIDE this ratification** (no Pocket client/redirect URI — §1). The exact approved callback is frozen by a follow-up amendment at registration; NOT invented here.
- **Authorize:** `GET https://api.sentinelayer.com/api/v1/oauth/authorize` (PKCE S256 + high-entropy `state`).
- **Token:** `POST https://api.sentinelayer.com/api/v1/oauth/token` (public client; no secret).
- **Subject:** `GET https://api.sentinelayer.com/api/v1/auth/mcp-subject` — strict-MCP validator, requires `sessions:read`, returns EXACTLY `{ "subjectId": <string> }` (no credential/extra identity fields) + BOTH `Cache-Control: no-store` AND `Pragma: no-cache`.
- **Sessions (fixed origin `https://api.sentinelayer.com`, port 443, method GET):** `/api/v1/sessions` · `/api/v1/sessions/{id}/events` · `.../events/before` · `.../actions` · `.../checkpoints`.
- **SessionID grammar (frozen; NOT assumed UUID):** `SessionID` wraps a token matching `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$` (covers observed UUID `6cf7e861-…` and short-hex `954233b7`), always a SINGLE path segment. Its initializer **throws `AuthError.invalidResponse`** on any violation (empty / `/` / `..` / control / space / `%`), before any broker execution.

## 3. Security invariants (ratified redlines)
R1 route-local server authorization is the ONLY access truth; **401 and 403 both fail closed** (§4b), client caches no decision. R2 no confused deputy — caller-credential only; **no credential-bearing URLRequest and no HTTP status/response are ever a public or internal return value** (§4). R3' single broker actor owns credential + execution + classification. R4' no refresh; auth never awaits UI from a fetch path. R5 spine isolation (no PocketCall/VerifiedBundle; sessions content never crypto-verified/green). R6' local sign-out only after Keychain + cache wipe both succeed (tombstone-gated, §4b); `WhenUnlockedThisDeviceOnly`; credential never in DTO/error/log/crash/preview/app-switcher/analytics.

## 4. Precise type surface (DESIGN — exact signatures, no two-way ambiguity; no bodies)
No `AuthorizedRequest`, no credential-bearing `URLRequest`, and no `HTTPURLResponse`/status ever appears in the public OR internal return surface. The broker owns validation→attachment→execution→status-classification→typed-error mapping end-to-end; it returns only `Data` on success.
```swift
public struct SessionID: Sendable, Equatable { public init(_ raw: String) throws /* throws AuthError.invalidResponse on §2 grammar violation */ }

public enum AuthState: Sendable, Equatable { case signedOut, authenticating, signedIn(expiresAt: Date), reauthenticationRequired, wipePending, error(AuthError) }
public enum AuthError: Error, Sendable, Equatable {
    case userCancelled, stateMismatch, exchangeFailed, subjectResolutionFailed
    case reauthenticationRequired, network, keychain, cacheWipeFailed, invalidResponse   // keychain = Keychain-delete half; cacheWipeFailed = filesystem-delete half
}
public enum TransportError: Error, Sendable, Equatable {
    case unauthorized, accessDenied, decoding, network, offlineNoCache                    // offlineNoCache distinct from network
    case server(status: Int, code: String?, requestId: String?)
}
public enum Source: Sendable, Equatable { case network(at: Date), cached(at: Date), fixture }
public enum AuthStatus: Sendable, Equatable { case live, authExpired, offline }
public enum Completeness: Sendable, Equatable { case complete, partial(reason: String), unknown }  // any cached fallback ⇒ never .complete
public enum Watermark: Sendable, Equatable { case cursor(String), sequence(Int64) }

public struct RepositorySnapshot<Page: Sendable & Equatable>: Sendable, Equatable {
    public let page: Page; public let source: Source; public let authStatus: AuthStatus
    public let completeness: Completeness; public let serverWatermark: Watermark?; public let lastSuccessfulSync: Date?
}

// CLOSED internal enum — the ONLY thing a caller names. Typed IDs/query values only; NO origin/path/method/header string.
// fromSequence/beforeSequence MUST be >= 0 (negative → rejected with AuthError.invalidResponse before execution).
enum SessionRequestSpec: Sendable {
    case listSessions(includeArchived: Bool, cursor: String?)
    case events(sessionId: SessionID, fromSequence: Int64?)
    case eventsBefore(sessionId: SessionID, beforeSequence: Int64)
    case actions(sessionId: SessionID)
    case checkpoints(sessionId: SessionID)
}
// INTERNAL, not public. Maps each case → fixed HTTPS origin/method/path/query (§5), attaches credential, executes,
// classifies status PRIVATELY (2xx→Data; 401→invalidate generation then throw .reauthenticationRequired;
// 403→TransportError.accessDenied; other→TransportError.server), and returns ONLY Data. Credential + generation are
// private actor state; neither they nor any HTTPURLResponse ever leave the actor.
actor CredentialBroker {
    func perform(_ spec: SessionRequestSpec) async throws -> Data     // throws AuthError.reauthenticationRequired when no unexpired credential; NEVER awaits UI; no replay
}

public protocol AuthProviding: Sendable {                     // async, actor-safe; NO token accessor
    func currentState() async -> AuthState
    func stateUpdates() async -> AsyncStream<AuthState>
    @MainActor func signIn() async throws                     // ONLY interactive entry; single UI flight
    func signOut() async throws                               // tombstone-gated; signedOut only after both wipes (§4b)
}

// Public surface is ONLY these typed methods (no arbitrary-request API). Each decodes a merged wire page from broker Data.
public protocol SessionTransport: Sendable {
    func listSessions(includeArchived: Bool, cursor: String?) async throws -> SessionListPage
    func events(sessionId: SessionID, fromSequence: Int64?) async throws -> SessionEventForwardPage
    func eventsBefore(sessionId: SessionID, beforeSequence: Int64) async throws -> SessionEventBeforePage
    func actions(sessionId: SessionID) async throws -> SessionActionPage
    func checkpoints(sessionId: SessionID) async throws -> SessionCheckpointListPage
}
// ONE contract: async throws -> Snapshot with exact thrown cases (§4b). Subject-partitioned; owns cache; owns
// 401→invalidate+authExpired-fallback and 403→suppress-and-render-nothing. Snapshot only when a page (network|cached) exists.
public protocol SessionRepository: Sendable {
    func sessions(includeArchived: Bool, cursor: String?) async throws -> RepositorySnapshot<SessionListPage>
    func events(sessionId: SessionID, fromSequence: Int64?) async throws -> RepositorySnapshot<SessionEventForwardPage>
    func eventsBefore(sessionId: SessionID, beforeSequence: Int64) async throws -> RepositorySnapshot<SessionEventBeforePage>
    func actions(sessionId: SessionID) async throws -> RepositorySnapshot<SessionActionPage>
    func checkpoints(sessionId: SessionID) async throws -> RepositorySnapshot<SessionCheckpointListPage>
}
```
- **Subject namespace:** unforgeable capability minted only after `mcp-subject` succeeds; on-disk cache key is a **deterministic keyed digest** of `subjectId` (raw `subjectId` NEVER in a path); Keychain-held; complete file protection + no iCloud backup; reads AND writes generation-gated. Client never security-trusts parsed JWT `iss`/`aud`/`sub`. Non-enumerating: forbidden/notMember/notFound → single `accessDenied`.

## 4a. signIn sequence (atomic)
`@MainActor signIn()` → single `ASWebAuthenticationSession` (PKCE + `state`) → exact endpoint/callback/`state` match → **ephemeral** token exchange → `GET /auth/mcp-subject` → current-generation check → **ATOMIC commit {credential + subject namespace}** → `.signedIn`. Any failure: persist **neither**, wipe **both**; a stale generation N can never commit after sign-out or after N+1. Concurrent fetches during this throw `.reauthenticationRequired`.

## 4b. Freshness + wipe (exact; one `async throws -> Snapshot` contract)
Credential used for NETWORK only while unexpired minus **60s skew**; at/near/after expiry NEVER used for network. `max-age` = **300s**. Any cached fallback sets completeness away from `.complete`. Precedence when client-side conditions overlap: **auth-expired outranks offline**. A 401/403 is a server RESPONSE (implies online), so it never overlaps an offline row.

| Condition | Result |
|---|---|
| fresh network fetch (2xx, decodes) | `Snapshot(.network, .live, completeness:as-decoded)` |
| cached ≤300s, auth valid | `Snapshot(.cached, .live, ≤.partial)` |
| cached >300s (stale) + network failure | `Snapshot(.cached, .offline, .partial("stale"))` |
| fresh 2xx but DECODE fails, cache present | `Snapshot(.cached, .live, .partial("decode-fallback"))` — network reached + auth live, so NOT offline |
| client-detected auth expired (± offline), cache present | `Snapshot(.cached, .authExpired, .partial("expired"))` |
| **401** on fetch, cache present | broker invalidates generation → `Snapshot(.cached, .authExpired, .partial("reauth-required"))` — cache NOT suppressed (401 = auth-expiry, content was authorized when cached) |
| **401** on fetch, no cache | THROW `AuthError.reauthenticationRequired` |
| **403** on target | THROW `TransportError.accessDenied` — suppress+don't-poison target cache, render NO cached protected content (403 = authz-denied) |
| no cache + offline | THROW `TransportError.offlineNoCache` |
| no cache + client-expired | THROW `AuthError.reauthenticationRequired` |

**Wipe:** `signOut` writes a `tombstone` FIRST → immediately blocks BOTH cache reads AND any broker credential/network use → deletes Keychain + filesystem. `signedOut` is impossible until BOTH complete. Per-half failure: Keychain-delete fail → throws `AuthError.keychain`; filesystem-delete fail → throws `AuthError.cacheWipeFailed`; either/both → AuthState stays `.wipePending` (credential unusable, reads disabled), retried before any later `perform`/`signIn`; neither half is ever readable. Clock: monotonic where available; wall-clock skew conservative (expire early, never late).

## 5. KAV matrix (exact query freeze with server-proven limits; compile-proof KAVs deferred to impl gate)
**Query freeze (literal names + exact fixed values OR explicit omission — server limits per Echo #240xxx):**
- `listSessions` → `include_archived=<bool>`, `cursor=<opaque next_cursor>` (OMIT when nil), `limit=50`. Omit `after`/`display_only`.
- `events` → `from_sequence=<Int64 ≥0>` (OMIT when nil), `limit=50`. OMIT the opaque `after` cursor entirely (this client pages by sequence).
- `eventsBefore` → `before_sequence=<Int64 ≥0>`, `limit=50`.
- `actions` → `limit=200`. No filters/projection override.
- `checkpoints` → `limit=100`. No `checkpointId` (list only).
Negative `fromSequence`/`beforeSequence` rejected pre-execution (`AuthError.invalidResponse`). **Completeness:** forward events, actions, AND checkpoints are `.unknown` absent wire-proven exhaustion (default-capped, no `hasMore`); only a page whose wire proves exhaustion may be `.complete`.
**Client (fixture-closable now):** single sign-in UI flight; state-mismatch/cancel fail closed; 401 invalidates generation + zero-replay + late gen N cannot commit after sign-out/N+1; 401+cache→authExpired cached (not suppressed), 401+no-cache→reauthenticationRequired; 403→accessDenied, no-retry, cache suppressed, renders nothing; each freshness row returns/throws EXACTLY its cell; decode-fallback is `.live` not `.offline`; offline-no-cache→offlineNoCache, expired-no-cache→reauthenticationRequired, expired+offline→expired; cached fallback never `.complete`; token/status/header absent from DTO/error/log/crash/preview; broker returns only Data (no HTTPURLResponse escapes); fixture cannot mint network/current/write/green; no PocketCall import; provisional-credential never persisted before mcp-subject; stale-subject cannot commit; generation-gated cache r/w; freshness boundaries (±60s skew, 300s max-age); wipe (tombstone blocks reads+network immediately; Keychain-fail→keychain, fs-fail→cacheWipeFailed, either→`.wipePending`, nothing readable, retry before perform/signIn); SessionID init throws on grammar violation pre-execution; negative sequence rejected; no caller can name a URL/method/header (only SessionRequestSpec); usage-scope (read-only→403; read+usage→200 required `totalCostUsd`; missing key→decode-fail).
**Deferred to IMPL code-gate (need real code):** compile-NEGATIVE (no external/same-module construction of a credential-bearing request; broker exposes no internal/fileprivate factory and no Data-less status) + N-vs-N+1 live-response binding + full compile/green/minimal-diff/Pulse review.
**Live/server (need server-lane + probe + registration):** wrong/absent user+MCP issuer/audience rejected; scope/`scp` confusion terminal no-fallback; read-scoped cannot write (403); route-local A-cannot-read-B (403); required `iat`/`sub`, MCP nonempty `jti`; mcp-subject stable across reauth/two tokens + both cache headers + subject-only body; web-audience token rejected at mcp-subject.

## 6. Separate live gates (all prod auth ⇒ two-key warden+finder + explicit @human-mrrcarter GO before deploy)
- **Server-P1 (Echo; ratified design `63446896`):** per-path audience + token kind+scope preserve + route scope (incl. usage all-of) + iss/aud/sig/exp verify + fail-first/green KAVs. Implementation code-gate pending.
- **`mcp-subject` endpoint (Echo):** as §2 (both cache headers, subject-only body).
- **Pocket client registration:** add a Pocket `client_id` + exact callback to `MCP_OAUTH_CLIENTS`, requesting **all-of `sessions:read`+`sessions:usage:read`**; exact callback frozen by follow-up amendment. **Absent/blocked today** — no live claim; `.fixture` transport asserts no live authorization.

## 7. Ownership (canonical — reconciled across this doc, OWNERSHIP.md, SessionWire.swift header)
**Relay** = wire DTOs + `SessionTransport`/`SessionRepository` + `CredentialBroker`/`AuthProviding`/`SessionRequestSpec`/`SessionID`. **Atlas** = bare app shell + exactly the two nonvisual wrappers `ParsedSessionTimestamp` + `MembershipAuthorizedCheckpoint`. **Pulse** = all presentation: view-models, fallbacks, copy, badges, factory off the snapshot. This layer defines no presentation types.
