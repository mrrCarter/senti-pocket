# Atlas Shell — Step-2 Auth-State Composition (DESIGN)

**Owner:** claude-pocket-atlas · **Status:** DESIGN (pre-code). **Lane:** app shell only (§7).
**Consumes:** the ratified auth+fetch contract **V10 `a0a9114c`** (warden #241245) — the SOLE authority for every type named here. This doc **redefines nothing** and **adds no presentation**; it specifies only how the *bare shell* composes screens from the `AuthState` the auth machine produces.
**Base:** `atlas/pocket-contracts-v0.1 6f019594` (FF-ready). **Code is NOT written here** — the shell's auth composition lands only once Relay's `AuthProviding` ships as code; authoring Swift against the Markdown surface would be building-ahead (a standing lesson). This is the *plan* that lets that wiring land in one pass, and it surfaces two impl-shaping questions to Relay **while he builds** (below).

---

## 1. Where the gate sits (the seam — please confirm, §7)

The auth machine (**Relay**) *produces* `AuthState`. The screens (**Pulse**) are *presentation*. The **shell** (Atlas) is the thin composition between them: it subscribes to the state and mounts either the signed-in tab structure or exactly one Pulse-injected non-tab screen. That composition — the `switch AuthState { … }` plus the subscription — is "bare app shell," so it is Atlas's, the same way the `TabView` composition already is (`AppShell.swift`). It **defines no view-models, copy, badges, or fallbacks** (those are Pulse's) and **no auth logic** (that is Relay's); it only *routes*.

> **Q-seam (→ Relay/warden):** confirm the state→screen gate is Atlas-shell (consumer of `AuthProviding`), not part of the auth machine. If you'd rather own the gate inside the machine, say so — I'll consume whatever root View you vend instead. My assumption below is the former.

The gate is a new root above the existing `AppShell`. `SentiPocketApp.@main` mounts the gate; the gate mounts `AppShell(sessions:{…}, activity:{…})` **only** in `.signedIn`.

---

## 2. `AuthState` → composition (all SIX ratified cases)

From V10 §4, verbatim surface:
```swift
public enum AuthState { case signedOut, authenticating, signedIn(expiresAt: Date), reauthenticationRequired, wipePending, error(AuthError) }
```

| `AuthState` | Shell composition | Tabs? | Cached session content? |
|---|---|---|---|
| `.signedOut` | Pulse-injected **sign-in** screen | ✗ | ✗ (nothing to show pre-auth) |
| `.authenticating` | Pulse-injected **authenticating** screen | ✗ | ✗ |
| `.signedIn(expiresAt:)` | **`AppShell`** (Sessions / Pocket / Activity) | ✓ | ✓ — repository-backed, freshness per snapshot (§3) |
| `.reauthenticationRequired` | Pulse-injected **re-auth** screen | ✗ | **✗ — fail-closed.** 401 suppressed the subject cache (§3/§4b R4'); the gate shows the re-auth screen *instead of* tabs, never tabs-with-stale-content |
| `.wipePending` | Pulse-injected **wipe-pending** screen | ✗ | ✗ — tombstone blocks reads+network; credential unusable until both wipes clear (§4b) |
| `.error(AuthError)` | Pulse-injected **auth-error** screen, given the `AuthError` | ✗ | ✗ |

Non-obvious, load-bearing points:
- **`.wipePending` is a distinct gate screen**, not a spinner over the tabs — per §4b the credential is unusable and reads are disabled until both deletions succeed, so tabs must not be mounted.
- **`.reauthenticationRequired` shows NO cached content.** This is the whole point of the 401 fail-closed redline: a server 401 is indistinguishable from revoked, so cache is suppressed. The gate must not fall back to `AppShell` with a stale snapshot here.
- **`.error(.wipeFailed(keychain:cache:))`** is a serious degraded state (sign-out could not fully wipe). The gate routes it to Pulse's error screen with the exact per-half flags; Pulse decides the copy. Reads stay disabled.

---

## 3. Signed-in freshness is NOT a gate concern

The gate switches on `AuthState` only. Per-fetch staleness — `Source` / `AuthStatus{live,authExpired,offline}` / `Completeness` on `RepositorySnapshot` (§4b table) — lives **inside** the tabs and is rendered by **Pulse** off the snapshot (e.g. an "offline · cached 10:36" badge). The gate does not read `AuthStatus`. Concretely: `client-detected pre-network expiry → .authExpired cached` is a *snapshot row Pulse renders inside a tab*, **not** a gate transition to a re-auth screen. Only a server **401** (which arrives as `AuthState.reauthenticationRequired` via the machine) pulls the whole app out of the tabs. Keeping this split is what prevents a benign local-clock expiry from nuking the UI while still fail-closing a real server rejection.

---

## 4. Subscription shape (the one wiring question)

V10 §4 vends both:
```swift
func currentState() async -> AuthState
func stateUpdates() async -> AsyncStream<AuthState>
```
The gate holds `@State private var state: AuthState` and drives it from a `.task`:
```
// SHAPE ONLY — not compilable against Markdown; lands with Relay's impl.
.task {
    // ← Q-stream decides whether this first line is needed
    // state = await provider.currentState()
    for await s in await provider.stateUpdates() { state = s }
}
```

> **Q-stream (→ Relay):** does `stateUpdates()` **replay the current state synchronously on subscribe** (BehaviorSubject-style)? If yes, the gate needs *only* the `for await` loop — no separate `currentState()` read, and **no race** between the one-shot read and the stream. If `stateUpdates()` does **not** replay, the gate must seed with `currentState()` first and then subscribe, which opens a lost-update window (a transition landing between the read and the subscription). **Strong consumer preference: replay-on-subscribe**, so the gate is a single loop and `currentState()` stays a convenience for non-gate one-shot reads. This is cheap to build in now and painful to retrofit — hence surfacing it before the impl sets.

---

## 5. Injection seam (Pulse owns all five non-tab visuals)

The gate injects the five non-tab screens exactly as `AppShell` already injects Sessions/Activity — `@ViewBuilder` seams, never Atlas-authored copy. Atlas provides the *routing*; Pulse provides every pixel of: sign-in, authenticating, re-auth, wipe-pending, auth-error. The signed-in branch is the existing `AppShell` (Pulse's Sessions/Activity + the fail-closed Pocket briefing). No new presentation type originates in this layer (§7: "This layer defines no presentation types").

> **Note (→ Pulse):** five injected screens land on your side for step-2b. The gate will expose them as builder params (or a single `AuthScreens` provider struct of five `@ViewBuilder`s — your preference; I'll shape the seam to whatever is cleanest for your factory). No rush — this is post-impl.

---

## 6. What this does and does NOT commit

- **Does:** fix the shell's state→screen routing for all six cases against the exact ratified surface; keep 401 fail-closed and the gate/snapshot split explicit; enumerate the injection seam.
- **Does NOT:** write any Swift (no symbols against unwritten `AuthProviding`); define any presentation; touch the auth machine, the wire, or `VerifiedBundle`. Code lands only after Relay's `AuthProviding` impl, reviewed distinct-role against V10 at that head, re-keyed per exact SHA (no key carries), with build-green deferred to forge.

**Blocking on:** Relay's fixture `AuthProviding`/`SessionRepository` impl branch. **Answers wanted (non-blocking, impl-shaping):** Q-seam, Q-stream.
