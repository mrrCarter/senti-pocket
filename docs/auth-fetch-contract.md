# Pocket Auth + Session-Fetch Security Contract (V7)

**Owner:** claude-pocket-relay · **Status:** DESIGN — precise-markdown (warden A/B=B). Awaiting fresh exact finder keys (Echo + Pulse) then warden ratification. **No implementation logic; compile-proof + compile-negative + N-vs-N+1 KAVs enforced at the IMPLEMENTATION code-gate.**
**Base:** atlas/pocket-contracts-v0.1 `6f019594` (FF-ready). **Scope:** client-side auth + session-READ transport. Consumes merged wire DTOs (`SessionWire.swift`, **unchanged**). Does **not** import/touch `VerifiedBundle`/signed-briefing (PocketCall).
Folds warden R1–R6', consolidated V6 residuals P1-1..P2-5, Pulse guards #240856/#240883 + 3 final precision points, and Echo's full A-E verdict. Server-P1 ratified `63446896`.

## 1. Deployed contract (live-verified; read-only ECS/AS evidence)
Provenance distinct: **deployed prod `3ca7640`**; **origin/main `91a2c3fa`** is **+1 non-serializer commit ahead**.
- **AS** `https://api.sentinelayer.com`: **Authorization-Code + PKCE S256 only** (deployed token-exchange REJECTED), public client, RS256. **No `refresh_token`, no revocation.**
- issuer `https://api.sentinelayer.com`; resource/audience **`https://mcp.sentinelayer.com`** (exact, with scheme, everywhere); access TTL **900s**.
- **No Pocket client registered** (`MCP_OAUTH_CLIENTS` = `client_id=claude` only). LIVE sign-in BLOCKED until registration (§2/§6).
- **Route-local authorization** (ratified `63446896`): each route enforces its own domain ownership/membership check server-side (`403` + `authorize_session_*`); NOT a universal-membership claim. Client caches no access decision.
- **Usage-scope (ratified `63446896`, all-of model, NO redaction):** `sessions` list/get require **all-of `sessions:read`+`sessions:usage:read`**; a strict subset gets **`403`** (route-level, not field redaction). A `200` therefore ALWAYS carries the usage-derived fields. `totalCostUsd` stays **required `Decimal`** in the wire DTO — unchanged. Scope is a server control, never a client security decision.

## 2. Endpoints (exact; execution is broker-owned per §4)
**Fixture repository is independently implementable now; LIVE sign-in/callback is BLOCKED and OUTSIDE this ratification** (no Pocket client/redirect URI — §1). The exact approved callback is frozen by a follow-up amendment at registration; NOT invented here.
- **Authorize:** `GET https://api.sentinelayer.com/api/v1/oauth/authorize` (PKCE S256 + high-entropy `state`).
- **Token:** `POST https://api.sentinelayer.com/api/v1/oauth/token` (public client; no secret).
- **Subject:** `GET https://api.sentinelayer.com/api/v1/auth/mcp-subject` — strict-MCP validator, requires `sessions:read`, returns EXACTLY `{ "subjectId": <string> }` (no credential/extra identity fields) + BOTH `Cache-Control: no-store` AND `Pragma: no-cache`.
- **Sessions (fixed origin `https://api.sentinelayer.com`, port 443, method GET):**
  `/api/v1/sessions` · `/api/v1/sessions/{id}/events` · `.../events/before` · `.../actions` · `.../checkpoints`.
- **SessionID grammar (frozen; NOT assumed UUID):** `SessionID` is an opaque validated token matching `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$` (covers observed UUID `6cf7e861-…` and short-hex `954233b7` forms), always a SINGLE path segment. Empty / `/` / `..` / control / space / `%` → REJECTED (`AuthError.invalidResponse` at construction, before any broker execution). Tightened to the server's durable-ID contract if it publishes a stricter one.

## 3. Security invariants (ratified redlines)
R1 route-local server authorization is the ONLY access truth (client caches no decision; 401/403 fail closed). R2 no confused deputy — caller-credential only; **no credential-bearing URLRequest is ever a public/internal return value** (§4). R3' single broker actor owns credential + execution. R4' no refresh; auth never awaits UI from a fetch path. R5 spine isolation (no PocketCall/VerifiedBundle; sessions content never crypto-verified/green). R6' local sign-out only after Keychain + cache wipe both succeed (tombstone-gated, §4b); `WhenUnlockedThisDeviceOnly`; credential never in DTO/error/log/crash/preview/app-switcher/analytics.

## 4. Precise type surface (DESIGN — exact signatures, no two-way ambiguity; no bodies)
No `AuthorizedRequest` and no credential-bearing `URLRequest` exist anywhere in the public OR internal return surface (P1-1 escape hatch eliminated). The broker owns validation→attachment→execution→classification end-to-end; callers name a typed operation, never a URL/method/header.
```swift
public struct SessionID: Sendable, Equatable { public init?(_ raw: String) /* validates §2 grammar; nil → rejected */ }

public enum AuthState: Sendable, Equatable { case signedOut, authenticating, signedIn(expiresAt: Date), reauthenticationRequired, wipePending, error(AuthError) }
public enum AuthError: Error, Sendable, Equatable {
    case userCancelled, stateMismatch, exchangeFailed, subjectResolutionFailed
    case reauthenticationRequired, network, keychain, invalidResponse
}
public enum TransportError: Error, Sendable, Equatable {
    case unauthorized, accessDenied, decoding, network, offlineNoCache        // offlineNoCache distinct from network
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
enum SessionRequestSpec: Sendable {
    case listSessions(includeArchived: Bool, cursor: String?)               // fixed limit; see §5 query freeze
    case events(sessionId: SessionID, fromSequence: Int64?)
    case eventsBefore(sessionId: SessionID, beforeSequence: Int64)
    case actions(sessionId: SessionID)
    case checkpoints(sessionId: SessionID)
}
// INTERNAL, not public. Maps each spec case → fixed HTTPS origin/method/path/query, attaches credential, executes,
// classifies privately. Credential + generation are private actor state; neither ever leaves the actor.
actor CredentialBroker {
    func perform(_ spec: SessionRequestSpec) async throws -> (Data, HTTPURLResponse)   // throws AuthError.reauthenticationRequired if no unexpired credential; NEVER awaits UI; 401(gen==current) invalidates only, no replay; 403 → no invalidation/retry
}

public protocol AuthProviding: Sendable {                     // async, actor-safe; NO token accessor
    func currentState() async -> AuthState
    func stateUpdates() async -> AsyncStream<AuthState>
    @MainActor func signIn() async throws                     // ONLY interactive entry; single UI flight
    func signOut() async throws                               // tombstone-gated; signedOut only after both wipes (§4b)
}

// Public surface is ONLY these typed methods (no arbitrary-request API). Each decodes a merged wire page.
public protocol SessionTransport: Sendable {
    func listSessions(includeArchived: Bool, cursor: String?) async throws -> SessionListPage
    func events(sessionId: SessionID, fromSequence: Int64?) async throws -> SessionEventForwardPage
    func eventsBefore(sessionId: SessionID, beforeSequence: Int64) async throws -> SessionEventBeforePage
    func actions(sessionId: SessionID) async throws -> SessionActionPage
    func checkpoints(sessionId: SessionID) async throws -> SessionCheckpointListPage
}
// ONE contract: async throws -> Snapshot with exact thrown cases (§4b). Subject-partitioned; owns cache; owns
// 401→invalidate + 403→suppress-and-render-nothing. Snapshot returned ONLY when a page (network|cached) exists.
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
`@MainActor signIn()` → single `ASWebAuthenticationSession` (PKCE + `state`) → exact endpoint/callback/`state` match → **ephemeral** token exchange → `GET /auth/mcp-subject` → current-generation check → **ATOMIC commit {credential + subject namespace}** → `.signedIn`. Any failure (cancel, state mismatch, exchange, subject, generation): persist **neither**, wipe **both**; a stale generation N can never commit after sign-out or after N+1. Concurrent fetches during this throw `.reauthenticationRequired`.

## 4b. Freshness + wipe (exact; one `async throws -> Snapshot` contract)
Credential used for NETWORK only while unexpired minus **60s skew**; at/near/after expiry NEVER used for network. `max-age` = **300s**. Any cached fallback sets completeness **away from `.complete`** (→ `.partial(reason:)` or `.unknown`). Precedence when conditions overlap: **auth-expired outranks offline**.

| Condition | Result |
|---|---|
| fresh network fetch | `Snapshot(source:.network, authStatus:.live, completeness:as-decoded)` |
| cached ≤300s, auth valid | `Snapshot(source:.cached, authStatus:.live, completeness:≤.partial)` |
| cached >300s (stale) + network failure | `Snapshot(source:.cached, authStatus:.offline, completeness:.partial("stale"))` |
| cached + decode failure of fresh fetch | `Snapshot(source:.cached, authStatus:.offline, completeness:.partial("decode-fallback"))` |
| cached, auth expired (± offline) | `Snapshot(source:.cached, authStatus:.authExpired, completeness:.partial("expired"))` |
| 403 on target | THROW `TransportError.accessDenied` — suppress+don't-poison target cache, render NO cached protected content |
| no cache + offline | THROW `TransportError.offlineNoCache` |
| no cache + auth expired | THROW `AuthError.reauthenticationRequired` |

**Wipe:** `signOut` writes a `tombstone` FIRST → immediately blocks BOTH cache reads AND any broker credential/network use → deletes Keychain + filesystem. `signedOut` is impossible until BOTH deletions complete; if either fails, state is `.wipePending` (NOT signedOut, credential unusable), retried before any later `authorize`; neither half is ever readable. Clock: monotonic where available; wall-clock skew conservative (expire early, never late).

## 5. KAV matrix (Pulse #239819 + Echo/Pulse V6; compile-proof KAVs deferred to impl gate)
**Query freeze (exact per method):** listSessions → `limit` fixed server default, `cursor` = opaque `next_cursor` only, `include_archived` bool, NO `displayOnly`; events → `after`/`from_sequence` = Int64 only; eventsBefore → `before_sequence` Int64 only; actions → no client filters (server default projection); checkpoints → no `checkpointId` (list only). **Completeness:** forward events, actions, AND checkpoints are `.unknown` absent wire-proven exhaustion (default-capped, no `hasMore`); only a page whose wire proves exhaustion may be `.complete`.
**Client (fixture-closable now):** single sign-in UI flight; state-mismatch/cancel fail closed; 401 zero-replay + late gen N cannot commit after sign-out/N+1; 403 → accessDenied, no-retry, cache suppressed, no cached content rendered; each freshness-table row returns/throws EXACTLY its cell; offline-no-cache→offlineNoCache, expired-no-cache→reauthenticationRequired, expired+offline→expired; cached fallback never `.complete`; token/header absent from DTO/error/log/crash/preview; fixture cannot mint network/current/write/green; no PocketCall import; provisional-credential never persisted before mcp-subject; stale-subject cannot commit; generation-gated cache r/w; freshness boundaries (±60s skew, 300s max-age); wipe (tombstone blocks reads+network immediately; either-order deletion failure → `.wipePending`, nothing readable, retry-before-authorize); SessionID grammar (UUID + short-hex accepted; `/`,`..`,control,`%`,empty rejected pre-execution); no caller can name a URL/method/header (only SessionRequestSpec cases); usage-scope (read-only→403; read+usage→200 with required `totalCostUsd`; missing key→decode-fail).
**Deferred to IMPL code-gate (need real code):** compile-NEGATIVE (no external/same-module construction of a credential-bearing request; broker has no internal/fileprivate factory escape) + N-vs-N+1 live-response binding + full compile/green/minimal-diff/Pulse review.
**Live/server (need server-lane + probe + registration):** wrong/absent user+MCP issuer/audience rejected; scope/`scp` confusion terminal no-fallback; read-scoped cannot write (403); route-local A-cannot-read-B (403); required `iat`/`sub`, MCP nonempty `jti`; mcp-subject stable across reauth/two tokens + both cache headers + subject-only body; web-audience token rejected at mcp-subject.

## 6. Separate live gates (all prod auth ⇒ two-key warden+finder + explicit @human-mrrcarter GO before deploy)
- **Server-P1 (Echo; ratified design `63446896`):** per-path audience + token kind+scope preserve + route scope (incl. usage all-of) + iss/aud/sig/exp verify + fail-first/green KAVs. Implementation code-gate pending (warden gates full slice).
- **`mcp-subject` endpoint (Echo):** as §2 (both cache headers, subject-only body).
- **Pocket client registration:** add a Pocket `client_id` + exact callback to `MCP_OAUTH_CLIENTS`, requesting **all-of `sessions:read`+`sessions:usage:read`**; exact callback frozen by follow-up amendment. **Absent/blocked today** — no live claim; `.fixture` transport asserts no live authorization.

## 7. Ownership (canonical — reconciled across this doc, OWNERSHIP.md, SessionWire.swift header)
**Relay** = wire DTOs + `SessionTransport`/`SessionRepository` + `CredentialBroker`/`AuthProviding`/`SessionRequestSpec`/`SessionID`. **Atlas** = bare app shell + exactly the two nonvisual wrappers `ParsedSessionTimestamp` + `MembershipAuthorizedCheckpoint`. **Pulse** = all presentation: view-models, fallbacks, copy, badges, factory off the snapshot. This layer defines no presentation types.
