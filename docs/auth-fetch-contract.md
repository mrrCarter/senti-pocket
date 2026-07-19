# Pocket Auth + Session-Fetch Security Contract (V12)

**Owner:** claude-pocket-relay · **Status:** CANDIDATE (V12 §4c(A) dual-clock amendment + §4d reauth-cause-channel/cache-targeting representability model; Warden binding ruling 2026-07-19) — this is the immutable CONTENT candidate; fresh keys (Echo + Pulse finder, Atlas consumer, Warden §4c/§4d re-ratify) cite THIS content SHA. A header-only descendant commit (S) records RATIFIED + this content SHA + exact key sequences with ZERO body-byte change. **No implementation logic; compile-proof + compile-negative + N-vs-N+1 KAVs enforced at the IMPLEMENTATION code-gate.**
**Base:** atlas/pocket-contracts-v0.1 `6f019594` (FF-ready). **Scope:** client-side auth + session-READ transport. Consumes merged wire DTOs (`SessionWire.swift`, **unchanged**). Does **not** import/touch `VerifiedBundle`/signed-briefing (PocketCall).
Folds warden R1–R6', consolidated V6 P1-1..P2-5 + Pulse guards, both full A-E verdicts + V7 a–g, V8 residuals 1–5 (401 suppresses subject cache per warden R4', structured `wipeFailed`, exact query limits, `.unauthorized` removed, decode-no-cache), V9 consistency fixes (stale SessionRepository 401 comment, normalized-status wording at every surface, literal query omissions, exact `/api/v1/auth/mcp-subject`), V11 precision amendment (§4c stale-generation terminal + §5a fixture A/B seams; distinguishing signal = PRIVATE atomic authority not presentation, tombstone+generation-advance-before-wipe-await, crossover KAV, §6 server-P1 e16bbc37 status truth), and V12 §4c(A) dual-clock NARROW REDLINE (Warden binding ruling 2026-07-19): the stale-generation branch REQUIRES ONE clock-driven mutation — clearing a newer authority the broker's own dual-clock independently finds DEAD (usable iff BOTH bounds; DEAD when EITHER fails; terminal, no resurrection) before `reauthenticationRequired`; seal never opened, valid N+1/cache/AuthState untouched. V12 changes vs 15c83561: this title (V11→V12), the Status line (CANDIDATE), this history line, the §4 type-surface intro (internal `(Data, CacheWriteGrant)` note) + CredentialBroker L61 comment + `perform` signature (§4d cause channel + ownership correction), the §4b clock sentence (dual-clock both-bounds + either-bound terminal), the §4c heading + §4c(A) stale-branch clause/cause-ladder/KAVs + §4d link, the ENTIRE NEW §4d section (reauth-cause channel + generation/target-epoch cache targeting), and the §5 client KAV row; R1–R6' (§3), the rest of the §4/§4a type surface, the §4b freshness table + wipe sentence, §5a, §6, and §7 are BYTE-IDENTICAL to V11. Server-P1 ratified `63446896`.

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
No `AuthorizedRequest`, no credential-bearing `URLRequest`, and no raw `HTTPURLResponse`/headers/status object ever appears in the public OR internal return surface (a NORMALIZED status Int in `.server(status:)` excepted). The broker owns validation→attachment→execution→status-classification→typed-error mapping end-to-end; its INTERNAL `perform` returns `(Data, CacheWriteGrant)` on success (§4d), while the PUBLIC surface returns only pages (`SessionTransport`) / snapshots (`SessionRepository`) — no grant/auth ever escapes to a public caller.
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
// classifies status PRIVATELY, then CLASSIFIES + EMITS an internal cause/grant and owns NO cache (V12 §4d; the
// Repository is the SOLE cache owner — corrects the old broker-suppresses wording, §4d/L83): 2xx→(Data, CacheWriteGrant);
// 401→advance generation + emit BrokerFailure.reauthServerUnauthorized(ns) — the REPOSITORY suppresses, not the
// broker; 403→TransportError.accessDenied + synchronous targetEpoch suppression (§4d); other→TransportError.server.
// Credential/generation/UnavailableReason/epochs are private actor state; neither they nor any HTTPURLResponse ever leave the actor.
actor CredentialBroker {
    func perform(_ spec: SessionRequestSpec, suppress: @Sendable (CacheNamespaceCapability, SuppressTarget) -> Void) async throws -> (Data, CacheWriteGrant)   // §4d: broker invokes `suppress` SYNCHRONOUSLY on 401(.namespace)/403(.target) BEFORE actor release; INTERNAL return +opaque write grant; reauth throws BrokerFailure (§4d); NEVER awaits UI; no replay; §4c stale terminal
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

**Wipe:** `signOut` writes a `tombstone` AND advances (increments) the current generation FIRST — both BEFORE awaiting either deletion — so any in-flight request under the old generation N compares unequal at classification and returns no Data during the wipe window; this immediately blocks BOTH cache reads AND any broker credential/network use → then deletes Keychain + filesystem. `signedOut` is impossible until BOTH complete. Per-half failure: `signOut` throws exactly one `AuthError.wipeFailed(keychain:, cache:)` with the failed halves flagged (both true ⇒ both deletions failed); AuthState stays `.wipePending` (credential unusable, reads disabled) until BOTH deletions succeed, retried before any later `perform`/`signIn`; neither half is ever readable. Clock (dual-clock, V12 §4c(A)): at commit the broker samples ONE wall instant + ONE CONTINUOUS-monotonic instant (`ContinuousClock`, which advances through device sleep — NOT a suspending/uptime clock) and derives `wallDeadline = expiresAt - 60s` and `monotonicDeadline = M0 + (expiresAt - W0 - 60s)`. An authority is USABLE iff BOTH `wallNow < wallDeadline` AND `monotonicNow < monotonicDeadline`; it is DEAD when EITHER bound fails. Once either bound is observed failed the authority is TERMINALLY dead — the broker advances the generation + clears it, so no later wall rollback below the deadline (while monotonic is still under its own deadline) can resurrect it (expire early, never late).

## 4c. Stale-generation terminal (V11 precision amendment; V12 §4c(A) dual-clock narrow redline — Warden binding ruling)
When a response returns for a request under captured generation N: the broker compares the captured generation against the private committed-pair/tombstone authority BEFORE observing, reading, or classifying the response status OR body. On mismatch it takes the terminal below with ZERO status/body observation — a stale 401 is NEVER classified, so the unread stale status/body can never CAUSE any invalidation or suppression and a VALID current generation is never touched by the response (the only stale-branch mutation is the response-INDEPENDENT clock-driven clear of a dual-clock-DEAD authority — §4c(A) below, driven by the broker's own clocks, not the 401). ONLY on generation EQUALITY may the status/body then be observed and classified (§4b 2xx/401/403 handling). On mismatch, terminate that caller by CAUSE:
- **Superseded by a newer VALID signed-in generation** (re-auth produced an N+1 usable under BOTH bounds): throw `CancellationError()` — the request was semantically cancelled, not auth-failed; the caller may retry under N+1, which is NEVER mutated. (`reauthenticationRequired` would be untruthful while validly signed-in.)
- **Superseded by a committed-but-DEAD newer generation** (a pair WAS committed at the current generation but the broker's own dual-clock finds it DEAD — EITHER bound failed per §4b): throw `AuthError.reauthenticationRequired` AND the broker MUST clock-drivenly advance the generation + clear THAT dead authority (terminal anti-resurrection). Distinct from a valid N+1 (untouched) and from sign-out (a committed pair existed here).
- **Superseded by SIGN-OUT or an already-cleared no-authority state** (tombstone / `.wipePending`, OR `authority=nil` with NO tombstone — a completed sign-out or a prior dead-clear, AuthState unchanged): throw `AuthError.reauthenticationRequired`; NOT a benign cancel; no N+1 to retry; NO clock-driven mutation (nothing to clear). Cache/network permission DIFFERS by sub-state and is governed by §4d: a TOMBSTONE (sign-out) blocks reads AND network via the R6' wipe (`.signedOut`); an already-cleared `authority=nil`/no-tombstone state leaves ONLY network unavailable, with cache/AuthState §4b/§4d-governed (a benign client-expiry cached `.authExpired` may still serve via the §4d dispatch) — NOT a blanket block.
Distinguishing signal is the PRIVATE atomic authority at classification — NOT the public `.signedIn` presentation state, resolved in THREE mutually-exclusive cases: (i) a committed credential+namespace at the SAME current generation, USABLE under BOTH bounds, with NO tombstone ⇒ valid N+1 ⇒ `CancellationError()` (retryable; N+1 untouched); (ii) a committed pair at the current generation that the dual-clock finds DEAD (EITHER bound failed) ⇒ `AuthError.reauthenticationRequired` + the broker MUST clock-drivenly advance the generation + clear that dead authority (terminal); (iii) a tombstone is present (sign-out), OR there is no committed credential+namespace pair at the current generation (a completed sign-out OR an already-cleared `authority=nil`/no-tombstone state from a prior dead-clear) ⇒ `AuthError.reauthenticationRequired` (no clock-driven mutation — nothing left to clear). (`.signedIn` presentation alone can never authorize the cancel/retry path.) All three branches, for BOTH a stale 2xx AND a stale 401: zero Data returned, zero decode, zero cache read-or-write, no transparent replay; the unread stale RESPONSE (data/decode/cache/outcome) is terminal to ONLY the stale caller. The response-INDEPENDENT clock-driven dead-clear (case ii) is a SEPARATE broker-GLOBAL authority transition — it advances the generation + clears the dead authority, which future callers observe as re-auth — NOT a stale-caller-scoped effect. **§4c(A) dual-clock amendment (Warden binding ruling — narrow redline; cause emission + ALL cache serve/suppress/target/write governed by §4d):** §4c(A) is the dual-clock CLASSIFICATION that selects which internal cause is emitted (§4d maps cause→cache under the generation/target-epoch linearizable transaction). On a stale-generation branch the seal is opened ZERO times (status/body never observed), so the stale response's unread content influences nothing, and the broker performs ZERO response-CAUSED mutation of a VALID current-generation credential/namespace/cache/AuthState. The SOLE permitted mutation is CLOCK-DRIVEN and response-INDEPENDENT: when the broker's own dual-clock finds the newer authority DEAD (EITHER bound failed per §4b — terminal, no resurrection after either observed failed), the broker MUST advance the generation and clear THAT dead authority before throwing `reauthenticationRequired`. A valid N+1 (usable under BOTH bounds), its subject namespace, the cache, and AuthState are NEVER mutated on a stale branch; because the seal is never opened, no stale status/body can trigger or influence this invalidation. KAVs: (a) superseded-by-valid-N+1 (a usable-under-BOTH-bounds committed pair at a newer generation) → `CancellationError` + N+1 state untouched + caller may retry; (b) superseded-by-DEAD-newer (a committed pair the dual-clock finds dead, EITHER bound) → `reauthenticationRequired` + the broker MUST advance the generation + clear that dead authority (clock-driven, seal never opened, valid state untouched); (b2) superseded-by-sign-out-or-already-cleared (tombstone present, OR no committed pair — a completed sign-out or an already-cleared `authority=nil`/no-tombstone state) → `reauthenticationRequired`, NO further clock-driven mutation (nothing to clear); (c) CROSSOVER: sign-out → a NEW successfully-committed generation → a late OLD 2xx/401 ⇒ `CancellationError` (zero stale Data/mutation); a current tombstone / no-pair ⇒ `reauthenticationRequired`; (d) FORWARD-THEN-BACK wall: a 10m-usable credential, at M+1 the wall jumps past `wallDeadline` ⇒ DEAD + MUST terminally clear + generation advanced, at M+2 the wall rolls back below `wallDeadline` while monotonic is STILL < `monotonicDeadline` ⇒ STILL dead (`reauthenticationRequired`) — NOT resurrected; (e) MONOTONIC-ONLY expiry: real elapsed (ContinuousClock, incl. sleep) ≥ `monotonicDeadline` while `wallNow < wallDeadline` ⇒ DEAD + MUST terminally clear + generation advanced; (f) BOTH-BOUNDS-FAILED: `wallNow ≥ wallDeadline` AND `monotonicNow ≥ monotonicDeadline` ⇒ DEAD + MUST terminally clear + generation advanced; (g) BOTH-bounds-live ⇒ usable + `CancellationError` retry path intact + no mutation; (h) on any dead-clear: `sealed.open()` invoked ZERO times + cache/AuthState unchanged.

## 4d. Reauth-cause channel + generation/target-epoch cache targeting (V12 representability model — Warden binding)
**Ownership (corrects L61 vs L83):** the Repository is the SOLE owner of cache store + suppression policy. The broker CLASSIFIES the cause and CARRIES it + an opaque cache capability/grant; it holds NO cache and applies NO cache policy. (L61's "broker suppresses subject cache" is corrected to "broker emits `.serverUnauthorized`; the Repository suppresses.")

**Internal cause channel (all package-INTERNAL; PUBLIC surface FROZEN — callers still see only `AuthError.reauthenticationRequired` / `TransportError` / `RepositorySnapshot`):**
```swift
// Opaque, broker-DERIVED capabilities (type-opaque — never a raw String/subjectId):
struct CacheNamespaceCapability: Sendable { /* opaque §93 digest-keyed namespace */ }
struct CacheTarget: Sendable { /* opaque broker-derived target id; NOT a raw String */ }
struct CacheReadAuth: Sendable  { /* opaque; broker-MINTED at the CURRENT epoch: {generation, namespace, target, targetEpoch} */ }
struct CacheWriteGrant: Sendable { /* opaque; captured at 2xx classify: {generation, namespace, target, targetEpoch} */ }
enum SuppressTarget: Sendable { case namespace; case target(CacheTarget) }
// Invalid states UNREPRESENTABLE — the namespace causes carry a NON-optional capability; signedOut carries none:
enum BrokerFailure: Error {
    case reauthClientExpiry(CacheReadAuth)                    // benign request-start expiry; carries the current-epoch READ auth (may-serve §4b)
    case reauthDeadClear(CacheNamespaceCapability)            // §4c stale caller; no-serve, cache preserved
    case reauthServerUnauthorized(CacheNamespaceCapability)   // 401; Repository suppresses THIS namespace (R4')
    case reauthSignedOut                                      // tombstone; global wipe (R6'); NO namespace
    case transport(TransportError)
}
// ONE private product/sum — Authority/reason/namespace/epoch valid BY CONSTRUCTION (authority=nil + .available UNREPRESENTABLE):
enum BrokerAvailability: Sendable {
    case signedOut
    case available(Authority)                                 // usable committed pair (credential+namespace+generation+deadlines)
    case unavailable(UnavailableReason)                       // the reason CARRIES the namespace (+ epoch); no bare nil+available
}
// Write-ahead CRASH-DURABLE suppression — the RESULT/ERROR path proves fail-closed (NOT a Void callback):
struct SuppressionObligation: Sendable { /* opaque; epoch-bearing: {namespace|target, generation, targetEpoch} */ }
enum DurableCommit: Sendable { case committed; case failed /* fail-CLOSED: caller MUST NOT proceed to serve/propagate */ }
// Broker-issued, actor-isolated, ZERO-await SIGNATURES (impl bodies + the concrete durable store defer to the code-gate):
//   authorizeRead(_ ns: CacheNamespaceCapability, _ t: CacheTarget) -> CacheReadAuth?   // EVERY read (live/authExpired/cached/offline/decode); nil ⇒ no read; Repository NEVER self-mints
//   beginPending(_ s: SuppressTarget) throws -> SuppressionObligation                   // write-ahead DURABLE guard BEFORE any network that could 401/403
//   commitSuppression(_ o: SuppressionObligation) -> DurableCommit                      // atomically converts the pending guard ⇒ suppression; denial propagates ONLY on .committed
//   commitCacheRead(_ a: CacheReadAuth, _ read: @Sendable () -> P?) -> P?               // §4d linearizable; all-4-field revalidation
//   commitCacheWrite(_ g: CacheWriteGrant, _ apply: @Sendable () -> Void)               // §4d linearizable
```

**Internal transport (no public expansion):** `CacheReadAuth` and `CacheWriteGrant` flow ONLY on the INTERNAL Repository↔broker path — the Repository holds an internal broker reference and calls `perform` directly (getting `(Data, CacheWriteGrant)`), and a `BrokerFailure.reauthClientExpiry` carries a broker-MINTED `CacheReadAuth`. The PUBLIC page-only `SessionTransport` NEVER carries a grant/auth. The Repository presents the grant/auth back to `commitCacheWrite`/`commitCacheRead`.

**Persistent `UnavailableReason` (closes the concurrent-401 TOCTOU):** broker-private `enum UnavailableReason { case available; case clientExpired(CacheNamespaceCapability); case serverUnauthorized(CacheNamespaceCapability); case signedOut }` — the reason CARRIES the opaque namespace (invalid states unrepresentable, mirroring BrokerFailure), so AFTER `authority=nil` the sticky dispatch still targets the CORRECT namespace (a payload-free reason could not). Carried THROUGH `authority=nil` and DISPATCHED — NEVER inferred from nil. Set on EVERY transition: successful commit ⇒ `.available` (RESET — a fresh sign-in clears a prior `.serverUnauthorized`); request-start dual-clock expiry AND §4c dead-clear ⇒ `.clientExpired`; equal-gen 401 ⇒ `.serverUnauthorized`; sign-out ⇒ `.signedOut`. Actor-atomic (reason + authority + epochs transition together, no read-tears). `.serverUnauthorized` is STICKY until a successful commit resets it, so any concurrent/subsequent request in the 401 window maps to SUPPRESS. `authority=nil` DISPATCHES the stored reason on BOTH request-start and §4c-stale paths (never blanket). INVARIANT: `authority=nil` + `reason=.available` is UNREACHABLE.

**Emitted cause by phase (request-start §4b vs §4c stale):** request-start (expiry OR nil) dispatches the stored reason to a `BrokerFailure` ⇒ `.reauthClientExpiry(readAuth)` (may-serve, §4b) / `.reauthServerUnauthorized(ns)` (suppress) / `.reauthSignedOut` (block). §4c stale-completion (dead OR nil) dispatches ⇒ `.reauthDeadClear(ns)` (NO-serve for the CURRENT stale caller, cache PRESERVED) / `.reauthServerUnauthorized(ns)` (suppress) / `.reauthSignedOut` (block). Cache-eligibility is realized ONLY when a LATER request-start dispatches `.reauthClientExpiry`.

**Revocation epochs (every-invalidation generation + per-target epoch):** broker-private per-`{namespace}` generation advanced on EVERY authority invalidation (client/dual-clock expiry, §4c dead-clear, 401, sign-out — so an old write grant can NEVER validate after expiry) AND per-`{namespace,target}` `targetEpoch` (incremented + suppressed by an equal-gen 403 — because a 403 does NOT advance the generation). EVERY cache I/O authorization — READ (`CacheReadAuth`) AND WRITE (`CacheWriteGrant`) — captures the tuple `{generation N, namespace, target, targetEpoch}`. (A namespace-wide cache-authorization epoch bumped on any 403 is an acceptable bounded-conservative equivalent, while the store still suppresses only the denied target T.)

**Synchronous logical suppression BEFORE broker release:** `perform` carries a Repository-supplied `suppress: @Sendable (CacheNamespaceCapability, SuppressTarget) -> Void` closure (ZERO-await, non-suspending). On an equal-gen 401 the broker calls `suppress(ns, .namespace)`; on a 403 `suppress(ns, .target(T))` — SYNCHRONOUSLY, inside the actor, BEFORE it releases/propagates the reauth/denial — so no concurrent commit can interleave fresh cache into the suppression window. The closure performs the Repository's LOGICAL suppression (tombstone/index mutation — NOT physical deletion; the broker owns no cache). Delayed PHYSICAL cleanup is permitted but may delete ONLY bytes it still matches (old gen/epoch); it can NEVER delete fresh bytes.

**Linearizable broker-isolated cache transaction (no TOCTOU):** the Repository owns bytes + policy and PREPARES the transaction async (decode the page / locate bytes), then supplies a SYNCHRONOUS, NON-SUSPENDING final closure. The broker runs it UNDER actor isolation AFTER atomically re-validating ALL FOUR fields `{generation, namespace, target, targetEpoch}` against current broker state, with NO await between validation and the closure ⇒ no invalidation can interleave.
```swift
// broker, actor-isolated; the closure is @Sendable + NON-SUSPENDING (no await). No @unchecked Sendable escape of actor state.
func commitCacheWrite(_ grant: CacheWriteGrant, _ apply: @Sendable () -> Void)              // runs apply() iff all 4 fields current; else ZERO write
func commitCacheRead<P: Sendable>(_ auth: CacheReadAuth, _ read: @Sendable () -> P?) -> P?   // runs read() iff all 4 fields current; else nil
```
ORDERING: commit-before-invalidation LANDS (a later sign-out then wipes); invalidation-before-commit REJECTS. Swift-6: closures are `@Sendable` + non-suspending; the broker validates + invokes without a suspension point and without `@unchecked Sendable` escape.

**Persistence boundary (crash / reboot — Warden C6 binding):**
- **MONOTONIC-ANCHOR RESTORE (most critical):** the `ContinuousClock` monotonic anchor is process/boot-local and CANNOT be reconstructed across relaunch/reboot. On ANY anchor loss (relaunch / reboot / anchor-unavailable), a persisted credential is restored as TERMINAL `.clientExpired` / DEAD — ZERO network authority; the broker NEVER recomputes `monotonicDeadline` wall-only (`expiresAt - wallNow`) after anchor loss (a wall rollback would otherwise EXTEND authority). Cache MAY still serve `.authExpired` via a later request-start `.clientExpiry` dispatch (§4d). This is §4c(A) "expire early, never late" extended to persistence: no anchor ⇒ dead. This transition is atomic and happens BEFORE any startup network/read exposure.
- **CRASH-DURABLE SUPPRESSION (write-ahead pending/classification guard):** an in-memory-only failure result is NOT fail-closed across a subsequent crash, so suppression is a WRITE-AHEAD durable protocol: BEFORE any network request that could 401/403, the broker durably records a `SuppressionObligation` (`beginPending` — the epoch-bearing pending guard); on the response, classification ATOMICALLY converts the guard to the 401-namespace / 403-target suppression (`commitSuppression -> DurableCommit`), and the denial propagates ONLY on `.committed` (`.failed` ⇒ fail-CLOSED, caller must not proceed). On restart, any pending / unknown / corrupt guard SUPPRESSES before ANY cache read or network (fail-closed until re-proven). A crash at any point — before the network, between network and marker, or mid-commit — can therefore NEVER lose a suppression and serve revoked (401) / denied (403) cache: R4' holds across crash. The epoch-bearing obligation also keeps delayed physical cleanup off fresh (new-gen/new-epoch) bytes. (Concrete durable store type/fields/fsync + bodies defer to the impl code-gate; the RESULT/ERROR signature + ordering are the normative boundary.)
- **ALL-READ-AUTH:** EVERY cache READ path — cached-valid, offline fallback, decode fallback, `.authExpired` — obtains a broker-MINTED current-epoch `CacheReadAuth` and commits through `commitCacheRead` with FULL `{generation, namespace, target, targetEpoch}` re-validation; NO read bypasses the epoch/generation check; the Repository NEVER self-mints an auth.

**§4d persistence/crash KAVs (C7):** (p1) relaunch/reboot/anchor-loss + wall rollback ⇒ ZERO network / no resurrection (restored TERMINAL `.clientExpired`, cache may serve `.authExpired`); (p2) crash BEFORE the durable 401/403 mark but with the pending guard present ⇒ restart SUPPRESSES before any read/network; (p3) crash AFTER `commitSuppression` ⇒ suppression persists, denied bytes never served; (p4) durable-write FAILURE (`DurableCommit.failed`) ⇒ fail-CLOSED, denial not propagated as served; (p5) corrupt/unknown restore state ⇒ suppressed before any read/network; (p6) EACH cached-valid / offline / decode / `.authExpired` read ⇒ broker-minted `CacheReadAuth` + `commitCacheRead` full-tuple revalidation (no self-mint, no bypass); (p7) delayed old cleanup after a fresh generation/targetEpoch ⇒ fresh bytes UNTOUCHED (epoch-bearing obligation); (p8) `BrokerAvailability` makes `authority=nil` + `.available` unrepresentable (compile-negative).

**FRESH-BYTES invariant (security crux):** because the commit matches CURRENT `{N, targetEpoch}`, a stale grant (old N OR old targetEpoch) can NEITHER read NOR write that target, and a stale/delayed suppression targets ONLY old-epoch bytes — fresh bytes (new gen or new targetEpoch) are structurally untouchable. A real 401/403 can NEVER serve or repopulate protected cache; a stale suppression can NEVER erase fresh authorized data.

**Repository cause→policy mapping (Repository owns it):** `.reauthClientExpiry(readAuth)` ⇒ cache-ELIGIBLE — a later request-start MAY serve `.cached/.authExpired` via `commitCacheRead(readAuth)` (§4b/L107); `.reauthDeadClear(ns)` ⇒ no-serve for the CURRENT stale caller, cache PRESERVED; `.reauthServerUnauthorized(ns)` ⇒ synchronous LOGICAL suppress of ns + fail-closed, renders nothing (R4'); `.reauthSignedOut` ⇒ global wipe/block (R6', no namespace); 403 target T ⇒ synchronous targetEpoch suppress of T + `TransportError.accessDenied`.

**KAVs (§4d):** (a) paused old-2xx `CacheWriteGrant` after an equal-gen 403 target-suppress ⇒ `commitCacheWrite` REFUSED (denied T not repopulated); (b) paused old `CacheReadAuth` after equal-gen 403 ⇒ `commitCacheRead` REFUSED (denied cached T not exposed); (c) 401 A-suppress vs concurrent N+2 fresh commit ⇒ stale suppression does NOT erase fresh N+2 bytes AND revoked-N cache IS suppressed; (d) `commit*` re-validates all four fields atomically, ZERO await; (e) Swift-6 strict-concurrency build clean, no `@unchecked Sendable`; (f) concurrent request after a 401 dispatches persisted `.serverUnauthorized` ⇒ cache SUPPRESSED even mid-suppression; (g) successful commit after `.serverUnauthorized` resets `.available` so a legitimate later expiry serves; (h) reason NEVER inferred from `authority==nil`; (i) `authority=nil` + `reason=.available` unreachable.

## 5. KAV matrix (exact query freeze with server-proven limits; compile-proof KAVs deferred to impl gate)
**Query freeze (literal names + exact fixed values OR explicit omission — server-route-verified limits):**
- `listSessions` → `include_archived=<bool>`, `cursor=<opaque next_cursor>` (OMIT when nil), `limit=50`. Omit `after`/`display_only`.
- `events` → `from_sequence=<Int64 ≥0>` (OMIT when nil), `limit=50`. OMIT the opaque `after` cursor entirely (this client pages by sequence).
- `eventsBefore` → `before_sequence=<Int64 ≥0>`, `limit=50`. OMIT `display_only`/`displayOnly`.
- `actions` → `limit=200`. OMIT `targetSequenceId`/`targetActionId` filters and any projection override.
- `checkpoints` → `limit=100`. OMIT `checkpointId` (list only).
Negative `fromSequence`/`beforeSequence` rejected pre-execution (`AuthError.invalidResponse`). **Completeness:** forward events, actions, AND checkpoints are `.unknown` absent wire-proven exhaustion (default-capped, no `hasMore`); only a page whose wire proves exhaustion may be `.complete`.
**Client (fixture-closable now):** single sign-in UI flight; state-mismatch/cancel fail closed; 401 invalidates generation + SUPPRESSES subject cache + throws reauthenticationRequired (never serves cache — may be revoked/invalid; AS has no revocation endpoint) + zero-replay + late gen N cannot commit after sign-out/N+1; ONLY client-detected pre-network expiry serves `.authExpired` cache; 403→accessDenied, no-retry, cache suppressed, renders nothing; fresh-2xx-decode-fail WITH cache→`.partial("decode-fallback")` `.live`, with NO cache→`TransportError.decoding`; each freshness row returns/throws EXACTLY its cell; offline-no-cache→offlineNoCache, expired-no-cache→reauthenticationRequired, expired+offline→expired; cached fallback never `.complete`; raw response/headers/token absent from DTO/error/log/crash/preview while a NORMALIZED status Int in `.server(status:)` IS permitted; broker's internal perform returns (Data, CacheWriteGrant), no HTTPURLResponse escapes (the grant is package-internal, §4d); fixture cannot mint network/current/write/green; no PocketCall import; provisional-credential never persisted before mcp-subject; stale-subject cannot commit; generation-gated cache r/w; freshness boundaries (±60s skew, 300s max-age); wipe (tombstone blocks reads+network immediately; `AuthError.wipeFailed(keychain:,cache:)` exact flags, `.wipePending` until both clear, nothing readable, retry before perform/signIn); SessionID init throws on grammar violation pre-execution; negative sequence rejected; no caller can name a URL/method/header (only SessionRequestSpec); usage-scope (read-only→403; read+usage→200 required `totalCostUsd`; missing key→decode-fail); dual-clock usability (V12 §4c(A)): usable iff BOTH wall+monotonic bounds pass, DEAD when EITHER fails, TERMINAL (wall-only forward-then-back does NOT resurrect; monotonic-only expiry kills + terminal-clears; BOTH-BOUNDS-FAILED kills + terminal-clears; both-bounds-live stays usable), and a stale-branch dead-clear advances the generation + clears ONLY the dead authority (a broker-GLOBAL transition) with `sealed.open()` invoked ZERO times and cache/AuthState unchanged.
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
