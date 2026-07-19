# Pocket Auth + Session-Fetch Security Contract (V11)

**Owner:** claude-pocket-relay · **Status:** DESIGN — precise-markdown (warden A/B=B). Awaiting fresh exact finder keys (Echo + Pulse) then warden ratification. **No implementation logic; compile-proof + compile-negative + N-vs-N+1 KAVs enforced at the IMPLEMENTATION code-gate.**
**Base:** atlas/pocket-contracts-v0.1 `6f019594` (FF-ready). **Scope:** client-side auth + session-READ transport. Consumes merged wire DTOs (`SessionWire.swift`, **unchanged**). Does **not** import/touch `VerifiedBundle`/signed-briefing (PocketCall).
Folds warden R1–R6', consolidated V6 P1-1..P2-5 + Pulse guards, both full A-E verdicts + V7 a–g, V8 residuals 1–5 (401 suppresses subject cache per warden R4', structured `wipeFailed`, exact query limits, `.unauthorized` removed, decode-no-cache), V9 consistency fixes (stale SessionRepository 401 comment, normalized-status wording at every surface, literal query omissions, exact `/api/v1/auth/mcp-subject`), and V11 precision amendment (§4c stale-generation terminal + §5a fixture A/B seams — NO redline change; distinguishing signal = PRIVATE atomic authority not presentation, tombstone+generation-advance-before-wipe-await, crossover KAV, §6 server-P1 e16bbc37 status truth). Server-P1 ratified `63446896`.

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
R1 route-local server authorization is the ONLY access truth; **401 and 403 both fail closed** (§4b) — a server 401 (indistinguishable expiry/invalid/revoked; the deployed AS has NO revocation endpoint, so a 401 is the only invalidation signal) SUPPRESSES the subject cache and forces re-auth (R4'); client caches no decision. R2 no confused deputy — caller-credential only; **no credential-bearing URLRequest and no raw HTTP response/headers/status object are ever a return value** — a NORMALIZED status Int in `.server(status:)` is the only status form permitted (§4). R3' single broker actor owns credential + execution + classification. R4' no refresh; auth never awaits UI from a fetch path. R5 spine isolation (no PocketCall/VerifiedBundle; sessions content never crypto-verified/green). R6' local sign-out only after Keychain + cache wipe both succeed (tombstone-gated, §4b); `WhenUnlockedThisDeviceOnly`; credential never in DTO/error/log/crash/preview/app-switcher/analytics.

## 4. Precise type surface (DESIGN — exact signatures, no two-way ambiguity; no bodies)
No `AuthorizedRequest`, no credential-bearing `URLRequest`, and no raw `HTTPURLResponse`/headers/status object ever appears in the public OR internal return surface (a NORMALIZED status Int in `.server(status:)` excepted). The broker owns validation→attachment→execution→status-classification→typed-error mapping end-to-end; it returns only `Data` on success.
```swift
public struct SessionID: Sendable, Equatable { public init(_ raw: String) throws /* throws AuthError.invalidResponse on §2 grammar violation */ }

public enum AuthState: Sendable, Equatable { case signedOut, authenticating, signedIn(expiresAt: Date), reauthenticationRequired, wipePending, error(AuthError) }
public enum AuthError: Error, Sendable, Equatable {
    case userCancelled, stateMismatch, exchangeFailed, subjectResolutionFailed
    case reauthenticationRequired, network, keychain, invalidResponse       // keychain = non-wipe Keychain op failure
    case wipeFailed(keychain: Bool, cache: Bool)                            // sign-out wipe: exact per-half flags (both true ⇒ both deletions failed)
}
public enum TransportError: Error, Sendable, Equatable {
    case accessDenied, decoding, network, offlineNoCache                                  // offlineNoCache distinct from network; NO .unauthorized (401 ⇒ AuthError.reauthenticationRequired)
    case server(status: Int, code: String?, requestId: String?)                          // a NORMALIZED status Int is permitted in errors; raw HTTPURLResponse/headers/token FORBIDDEN
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
// classifies status PRIVATELY (2xx→Data; 401→invalidate generation + suppress subject cache then throw
// .reauthenticationRequired; 403→TransportError.accessDenied; other→TransportError.server), returns ONLY Data. Credential + generation are
// private actor state; neither they nor any HTTPURLResponse ever leave the actor.
actor CredentialBroker {
    func perform(_ spec: SessionRequestSpec) async throws -> Data     // throws AuthError.reauthenticationRequired when no unexpired credential; NEVER awaits UI; no replay; stale-generation supersession terminal per §4c
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
// 401→invalidate+suppress-subject-cache+throw-reauthenticationRequired and 403→suppress-target-cache+throw-accessDenied. Snapshot only when a page (network|cached) exists.
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
`@MainActor signIn()` → single `ASWebAuthenticationSession` (PKCE + `state`) → exact endpoint/callback/`state` match → **ephemeral** token exchange → `GET /api/v1/auth/mcp-subject` → current-generation check → **ATOMIC commit {credential + subject namespace}** → `.signedIn`. Any failure: persist **neither**, wipe **both**; a stale generation N can never commit after sign-out or after N+1. Concurrent fetches during this throw `.reauthenticationRequired`.

## 4b. Freshness + wipe (exact; one `async throws -> Snapshot` contract)
Credential used for NETWORK only while unexpired minus **60s skew**; at/near/after expiry NEVER used for network. `max-age` = **300s**. Any cached fallback sets completeness away from `.complete`. Precedence when client-side conditions overlap: **auth-expired outranks offline**. A 401/403 is a server RESPONSE (implies online), so it never overlaps an offline row.

| Condition | Result |
|---|---|
| fresh network fetch (2xx, decodes) | `Snapshot(.network, .live, completeness:as-decoded)` |
| cached ≤300s, auth valid | `Snapshot(.cached, .live, ≤.partial)` |
| cached >300s (stale) + network failure | `Snapshot(.cached, .offline, .partial("stale"))` |
| fresh 2xx but DECODE fails, cache present | `Snapshot(.cached, .live, .partial("decode-fallback"))` — network reached + auth live, so NOT offline |
| client-detected auth expired PRE-network, cache present | `Snapshot(.cached, .authExpired, .partial("expired"))` — benign local expiry (no server rejection); cache readable |
| **401** on fetch (server; indistinguishable expiry/invalid/revoked) | broker invalidates generation + SUPPRESSES subject cache → THROW `AuthError.reauthenticationRequired` — cache NOT served until successful reauth (R4' fail-closed) |
| **403** on target | THROW `TransportError.accessDenied` — suppress+don't-poison target cache, render NO cached protected content (403 = authz-denied) |
| fresh 2xx but DECODE fails, NO cache | THROW `TransportError.decoding` |
| no cache + offline | THROW `TransportError.offlineNoCache` |
| no cache + client-expired PRE-network | THROW `AuthError.reauthenticationRequired` |

**Wipe:** `signOut` writes a `tombstone` AND advances (increments) the current generation FIRST — both BEFORE awaiting either deletion — so any in-flight request under the old generation N compares unequal at classification and returns no Data during the wipe window; this immediately blocks BOTH cache reads AND any broker credential/network use → then deletes Keychain + filesystem. `signedOut` is impossible until BOTH complete. Per-half failure: `signOut` throws exactly one `AuthError.wipeFailed(keychain:, cache:)` with the failed halves flagged (both true ⇒ both deletions failed); AuthState stays `.wipePending` (credential unusable, reads disabled) until BOTH deletions succeed, retried before any later `perform`/`signIn`; neither half is ever readable. Clock: monotonic where available; wall-clock skew conservative (expire early, never late).

## 4c. Stale-generation terminal (V11 precision amendment — no redline change)
When a response returns for a request under captured generation N: the broker compares the captured generation against the private committed-pair/tombstone authority BEFORE observing, reading, or classifying the response status OR body. On mismatch it takes the terminal below with ZERO status/body observation — a stale 401 is NEVER classified and can never invalidate/suppress the current generation. ONLY on generation EQUALITY may the status/body then be observed and classified (§4b 2xx/401/403 handling). On mismatch, terminate that caller by CAUSE:
- **Superseded by a newer SIGNED-IN generation** (re-auth produced a valid N+1): throw `CancellationError()` — the request was semantically cancelled, not auth-failed; the caller may retry under N+1. (`reauthenticationRequired` would be untruthful while signed-in.)
- **Superseded by SIGN-OUT** (tombstone / `.wipePending`; no valid current credential): throw `AuthError.reauthenticationRequired` via the R6' tombstone path — NOT a benign cancel; there is no N+1 to retry and reads+network are already blocked.
Distinguishing signal is the PRIVATE atomic authority at classification — NOT the public `.signedIn` presentation state: a usable committed credential AND subject namespace bound to the SAME current generation, with NO tombstone ⇒ a valid N+1 exists ⇒ `CancellationError()` (retryable). Otherwise — a tombstone is present, OR there is no committed credential+namespace pair at the current generation ⇒ `AuthError.reauthenticationRequired`. (`.signedIn` presentation alone can never authorize the cancel/retry path.) Both branches, for BOTH a stale 2xx AND a stale 401: zero Data returned, zero decode, zero cache read-or-write, zero mutation of current-generation credential/namespace/cache/AuthState, no transparent replay; terminal to ONLY the stale caller. KAVs: (a) superseded-by-N+1 (committed pair at a newer generation) → `CancellationError` + N+1 state untouched + caller may retry; (b) superseded-by-sign-out (tombstone / no committed pair) → `reauthenticationRequired`; (c) CROSSOVER: sign-out → a NEW successfully-committed generation → a late OLD 2xx/401 ⇒ `CancellationError` (zero stale Data/mutation); a current tombstone / no-pair ⇒ `reauthenticationRequired`.

## 5. KAV matrix (exact query freeze with server-proven limits; compile-proof KAVs deferred to impl gate)
**Query freeze (literal names + exact fixed values OR explicit omission — server-route-verified limits):**
- `listSessions` → `include_archived=<bool>`, `cursor=<opaque next_cursor>` (OMIT when nil), `limit=50`. Omit `after`/`display_only`.
- `events` → `from_sequence=<Int64 ≥0>` (OMIT when nil), `limit=50`. OMIT the opaque `after` cursor entirely (this client pages by sequence).
- `eventsBefore` → `before_sequence=<Int64 ≥0>`, `limit=50`. OMIT `display_only`/`displayOnly`.
- `actions` → `limit=200`. OMIT `targetSequenceId`/`targetActionId` filters and any projection override.
- `checkpoints` → `limit=100`. OMIT `checkpointId` (list only).
Negative `fromSequence`/`beforeSequence` rejected pre-execution (`AuthError.invalidResponse`). **Completeness:** forward events, actions, AND checkpoints are `.unknown` absent wire-proven exhaustion (default-capped, no `hasMore`); only a page whose wire proves exhaustion may be `.complete`.
**Client (fixture-closable now):** single sign-in UI flight; state-mismatch/cancel fail closed; 401 invalidates generation + SUPPRESSES subject cache + throws reauthenticationRequired (never serves cache — may be revoked/invalid; AS has no revocation endpoint) + zero-replay + late gen N cannot commit after sign-out/N+1; ONLY client-detected pre-network expiry serves `.authExpired` cache; 403→accessDenied, no-retry, cache suppressed, renders nothing; fresh-2xx-decode-fail WITH cache→`.partial("decode-fallback")` `.live`, with NO cache→`TransportError.decoding`; each freshness row returns/throws EXACTLY its cell; offline-no-cache→offlineNoCache, expired-no-cache→reauthenticationRequired, expired+offline→expired; cached fallback never `.complete`; raw response/headers/token absent from DTO/error/log/crash/preview while a NORMALIZED status Int in `.server(status:)` IS permitted; broker returns only Data (no HTTPURLResponse escapes); fixture cannot mint network/current/write/green; no PocketCall import; provisional-credential never persisted before mcp-subject; stale-subject cannot commit; generation-gated cache r/w; freshness boundaries (±60s skew, 300s max-age); wipe (tombstone blocks reads+network immediately; `AuthError.wipeFailed(keychain:,cache:)` exact flags, `.wipePending` until both clear, nothing readable, retry before perform/signIn); SessionID init throws on grammar violation pre-execution; negative sequence rejected; no caller can name a URL/method/header (only SessionRequestSpec); usage-scope (read-only→403; read+usage→200 required `totalCostUsd`; missing key→decode-fail).
**Deferred to IMPL code-gate (need real code):** compile-NEGATIVE (no external/same-module construction of a credential-bearing request; broker exposes no internal/fileprivate factory and no Data-less status) + N-vs-N+1 live-response binding + full compile/green/minimal-diff/Pulse review.
**Live/server (need server-lane + probe + registration):** wrong/absent user+MCP issuer/audience rejected; scope/`scp` confusion terminal no-fallback; read-scoped cannot write (403); route-local A-cannot-read-B (403); required `iat`/`sub`, MCP nonempty `jti`; mcp-subject stable across reauth/two tokens + both cache headers + subject-only body; web-audience token rejected at mcp-subject.

## 5a. Fixture seams (V11 precision amendment — no redline change)
Two distinct seams, never conflated:
- **(A) Deterministic executor (KAV-only):** a private `SessionExecuting` seam injected into the REAL broker/repository path. Test executors simulate every §4b/§4c response — HTTP status, races, decode failures, including simulated `.network`/`.live` — because they drive the REAL `perform` construction + classification + repository code under test. UNREACHABLE from any public/demo initializer.
- **(B) Shipping `FixtureSessionRepository`:** the app/demo-consumed repository. It ALWAYS vends exactly `RepositorySnapshot(source: .fixture, authStatus: .offline, completeness: .unknown, serverWatermark: nil, lastSuccessfulSync: nil)` and NEVER `.network`/`.live`/`.complete` (upholds §5 fixture-cannot-mint). Replay fixtures may drive all `AuthState` cases for routing tests without claiming a live credential.
- **Item 9:** (A) drives the same `perform` path as live; (B) cannot select (A) nor bypass into live provenance. Negative KAVs: no external/demo consumer can reach (A); (B) never emits `.network`/`.live`/`.complete`.

## 6. Separate live gates (all prod auth ⇒ two-key warden+finder + explicit @human-mrrcarter GO before deploy)
- **Server-P1 (Echo; ratified design `63446896`):** per-path audience + token kind+scope preserve + route scope (incl. usage all-of) + iss/aud/sig/exp verify + fail-first/green KAVs. Implementation two-key SOURCE code-gate COMPLETE at PR #752 `e16bbc37` (warden + finder); UNMERGED / UNDEPLOYED pending @human-mrrcarter GO; no live probes yet.
- **`mcp-subject` endpoint (Echo):** as §2 (both cache headers, subject-only body).
- **Pocket client registration:** add a Pocket `client_id` + exact callback to `MCP_OAUTH_CLIENTS`, requesting **all-of `sessions:read`+`sessions:usage:read`**; exact callback frozen by follow-up amendment. **Absent/blocked today** — no live claim; `.fixture` transport asserts no live authorization.

## 7. Ownership (canonical — reconciled across this doc, OWNERSHIP.md, SessionWire.swift header)
**Relay** = wire DTOs + `SessionTransport`/`SessionRepository` + `CredentialBroker`/`AuthProviding`/`SessionRequestSpec`/`SessionID`. **Atlas** = bare app shell + exactly the two nonvisual wrappers `ParsedSessionTimestamp` + `MembershipAuthorizedCheckpoint`. **Pulse** = all presentation: view-models, fallbacks, copy, badges, factory off the snapshot. This layer defines no presentation types.
