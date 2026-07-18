# DESIGN — pocket-gateway (authorization, idempotency, offline pending intents)

Owner: **claude-pocket-relay**. Scope: the Relay lane only (checkpoint extract → summarizer →
PocketBundle → governed writeback → receipts). Governed writeback (P3) is **warden-gated**; this
doc is the design + honest gaps, not a claim that the write path is built.

## 0. Trust boundary (the whole point)

```
 iPhone (untrusted for authority)            gateway (holds Senti auth)         Senti
 ┌──────────────────────────────┐           ┌───────────────────────────┐      ┌───────────┐
 │ cached PocketBundle          │           │ extract → summarize →     │      │ sl CLI /  │
 │ local model PROPOSES text    │──propose──▶│ bundle → SIGN             │◀────▶│ MCP / API │
 │ human CONFIRMS (hash-bound)  │──confirm──▶│ resolve target (det. code)│      │           │
 │ shows receipt / PENDING      │◀─receipt──-│ post reply (idempotent)   │      └───────────┘
 └──────────────────────────────┘           │ verify + return receipt   │
                                             └───────────────────────────┘
```

Non-negotiables (from the pinned baseline, reflected in code):
- The phone never holds raw Senti credentials and never runs an unrestricted MCP client.
- The local model only produces a **typed ActionProposal** (text + intended target). **Deterministic
  gateway code** owns target/session/sequence resolution, authorization, the confirmation gate,
  execution, and the receipt. No speech goes straight to a tool call.

## 1. Governed write flow (P3 — designed, not yet built)

1. Voice dictation → local model emits a **typed `ActionProposal`** `{ kind:"reply", targetSessionId,
   targetSequenceId, bodyText }`. Free text only; no tool authority.
2. Gateway **resolves the target deterministically** from the cached bundle: `targetSequenceId` +
   `targetCursor` must exist in the bundle's `sourceRange`. A proposal referencing a sequence
   outside the briefed checkpoint is **rejected** (wrong-session / out-of-scope guard).
3. Gateway renders an exact **read-back** (the literal message + target thread + session) and
   computes `proposalHash = sha256(canonical(proposal))`.
4. Human gives **explicit confirmation**. The confirmation is a **single-use token bound to
   `proposalHash`**; any edit to the proposal changes the hash and invalidates the token.
5. Gateway executes the write through the **existing CLI**: `sl session reply <SID> <targetSeq>
   "<body>" --agent <id> --json`. It does **not** invent a new channel.
6. Gateway returns a **`DecisionReceipt`** built from the real response: `action.id`,
   `targetSequenceId`, `idempotencyKey`, `duplicate`, `createdAt`, plus the confirming
   `proposalHash`. `ReceiptVerifier` re-checks target + signature before the phone shows "sent".

If any step fails, the phone shows an **explicit failure** — never a synthesized success.

## 2. Idempotency (verified, two layers)

**Layer A — extraction dedup (read side).** Every raw event carries a per-event
`idempotencyToken` (verified in `export.events[]`). The extractor keys on `(sessionId,
sequenceId)` so re-running extraction over overlapping windows never double-counts an event.

**Layer B — writeback idempotency (write side).** PROVEN live (see CHECKPOINT_ACCESS.md §4):
`sl session reply` computes a server-side `idempotencyKey = cli:reply:seq:<target>:<actor>:<hash>`.
Re-sending the identical reply returned `duplicate=true` with the **same `action.id`** — i.e. the
write is **exactly-once** even under retry. The gateway leans on this instead of re-implementing
dedup, and binds the key's content-hash to `proposalHash` so:
- a **replayed** confirmation → same key → `duplicate=true`, no second post;
- an **edited** proposal → different hash → different key → correctly a new (re-confirmed) post.

**Confirmation binding rules:**
- one confirmation token = one `proposalHash` = one write;
- token is consumed on first use and on any proposal mutation;
- token carries an **expiry**; an expired token forces re-confirmation (stale-confirmation guard).

## 3. AIdenID-scoped authorization

**Current live state (verified `sl auth status`):** authenticated as `mrrCarter (admin)`, token
source = session, and **`AIdenID: not provisioned`**. So today the only credential available is a
broad admin session token.

**Design intent:** the phone-originated write should carry the **narrowest** authority that still
lets it post one reply into one thread:
- Provision an **AIdenID** scoped to `session:write:reply` for the specific `targetSessionId`
  (per-action, per-session), minted at sync time and short-TTL.
- The gateway exchanges the human confirmation for that scoped grant and attaches it to the write;
  the receipt records the acting AIdenID so the post is attributable to *this device + this human*,
  not to blanket admin.
- Revocation + expiry are first-class (a lost phone's grant dies on its own).

**Honest gap:** AIdenID is **not provisioned** in this environment and the scoped-grant exchange is
**not built**. Interim, any real write would ride the session Bearer token — which is **too broad to
ship to a phone**. This is a P3 blocker to raise before the governed write path is enabled, and the
gateway MUST keep the token server-side regardless. Tracking as an explicit unknown below.

## 4. Offline pending intents (`PENDING_CONNECTIVITY`)

Hard demo requirement: after sync, briefing + cached Q&A work offline; **writes never fake success**.

- A confirmed-but-unsendable proposal is stored as a **`PendingIntent`** `{ proposalHash,
  targetSessionId, targetSequenceId, bodyText, confirmedAt, confirmationToken, state:
  "PENDING_CONNECTIVITY" }`. The UI shows PENDING — **never "sent"**.
- On reconnect, before executing, the gateway runs a **freshness check**:
  1. confirmation token not expired;
  2. `targetSequenceId` still resolvable and still in a valid state (the thread was not deleted/closed);
  3. proposal still matches the intent (hash unchanged).
  Fail any → the intent is **surfaced for re-confirmation**, not silently sent.
- Execution then uses the **idempotencyKey** from §2, so a pending intent that partially sent before
  a crash reconciles to exactly one post (`duplicate=true` on the retry).
- Ordering: pending intents execute in `confirmedAt` order; a failed freshness check does not block
  later independent intents.

## 5. What is BUILT vs DESIGNED (no overclaiming)

| Piece | State |
|---|---|
| Checkpoint read recipe + data shape | **BUILT + verified live** (CHECKPOINT_ACCESS.md) |
| Extract → summarize(stub) → bundle pipeline | **BUILT + tested** (runs on real export; grounding gate green) |
| Grounding verification (quote ⊂ raw event) | **BUILT + tested** (tamper test fails as expected) |
| Safe threaded reply + idempotency proof | **BUILT + verified live** (test session 5cd1a149…) |
| `PocketSyncClient` / `SentiActionClient` / `ReceiptVerifier` | **INTERFACE STUBS only** (Swift protocols) |
| Governed write execution (confirm → post → receipt) | **DESIGNED, not built** — P3, warden-gated |
| AIdenID scoped grant | **DESIGNED, not built** — AIdenID not provisioned |
| Offline pending-intent store + freshness | **DESIGNED, not built** — P1 offline slice first |

## 6. Honest gaps / unknowns (raise before P3)

1. **AIdenID not provisioned** — no scoped grant exists; interim token is admin-broad. Must resolve
   the phone-side authority story before enabling any real write.
2. **Real summarizer** — the stub emits per-agent FACT claims with verifiable evidence but does
   **not** yet tag INFERENCE/RECOMMENDATION or synthesize/preserve cross-agent disagreement
   (`grounding: "baseline_unverified"`). Owner: Relay + the on-device Gemma summarize step. P1
   grounding eval scores against this.
3. **Signature is a digest, not a signature** — `alg:"sha256-unsigned"`. P3 needs a real ed25519
   detached signature + a key the phone can verify offline (`ReceiptVerifier`).
4. **MCP surface** — writeback here uses the `sl` CLI reply action (verified). Whether the demo path
   should go through the hosted MCP `/mcp` tool instead of the CLI is an open integration question
   for Atlas + warden; the CLI path is the proven fallback.
5. **Sequence numbers are tenant-global**, not per-session-1-based (verified: 230813). Target
   resolution must always carry `sessionId` + `cursor`, never a bare sequence number.
6. **Checkpoint availability** — durable checkpoints require the daemon + ≥20 events; a fresh room
   has none. The gateway must fall back to `export`-driven extraction (it does) rather than block on
   a daemon checkpoint.
