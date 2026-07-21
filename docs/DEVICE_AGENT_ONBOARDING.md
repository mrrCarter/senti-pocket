# Senti Pocket — Device-Build Agent Onboarding (Mac holder)

You are joining a live Sunday build with **zero prior repo context**. Read this top-to-bottom; it is the
authoritative brief for the backend/contracts/wiring. Your job is the **physical-iPhone build** — the one thing the
rest of the squad cannot do (nobody else has a Mac). Everything behind the screen is done and proven.

## 1. What Senti Pocket is
An offline-first iOS app: **"answer the call from your work."** The loop:
1. A Senti checkpoint (a durable summary of a multi-agent work session) is turned into a **signed PocketBundle**.
2. The phone **rings** ("Senti is calling"), then **speaks a briefing** from the bundle.
3. You can **barge in** with a spoken question, answered from the cached bundle.
4. You **dictate a decision** → **confirm** → it is **written back** to the Senti thread → you get a **signed receipt**.

Wedge = a cryptographically-verifiable briefing + a governed, human-confirmed, signed voice write-back.

## 2. Carter's target for TONIGHT (device evidence over everything)
An exact-SHA Swift build on a **physical iPhone** demonstrating, in one recording:
incoming-call screen → briefing plays **out loud** → **one barge-in** interrupt answered from cache →
**one dictated decision → confirm → write-back**. Carter would rather ship an immaculate **80%** loop that actually
rings and speaks than a perfect core with an unproven UI. **Prioritize the screen recording of the call + briefing.**

## 3. Repo map (`mrrCarter/senti-pocket`, cloned at `H:\senti-pocket` on Windows boxes; clone fresh on the Mac)
- `packages/PocketContracts/Sources/PocketContracts/PocketContracts.swift` — **FROZEN** Swift Codable contracts
  (v0.1.8). The single source of truth for every wire shape. Do not edit; mirror.
- `services/pocket-gateway/` — the backend (Node ESM, **zero external deps**, `node:test`). **DONE + proven.** Owner:
  claude-pocket-relay. Runs + tests fully on Windows or Mac with Node ≥ 20.
- `apps/` — the iOS app + Swift UI (Pulse/Atlas lanes: `PocketUI`, `PocketCallMachine`, call screen, briefing player).
- Branches: gateway work is on `relay/pocket-gateway` (PR #3). UI is on Pulse's branch (ask in the room for the exact
  SHA — Pulse pinned it clean/frozen). Contracts frozen at PocketContracts v0.1.8 `@7e1cfbe`.

## 4. The frozen contracts you consume (PocketContracts v0.1.8)
- **PocketBundle**: `{ contractsVersion, checkpointId, sessionId, sequenceStart, sequenceEnd, summary, evidence[],
  createdAt, signature, signingKeyId }`. `signature` = Ed25519 over the canonical bundle bytes (bundle minus the
  `signature` field, deterministic sorted-key JSON). **Verify it before briefing** (fail closed).
- **CheckpointSummary**: `{ checkpointId, headline, summaryBaselineSchema, grade?, perAgent[], risks[], blockers[] }`.
- **AgentSummary**: `{ agentId, summary, evidence[] }`.
- **EvidenceRef**: `{ id, sessionId, sequence, agentId, snippet, ts }` — every spoken claim cites these.
- **ActionProposal**: `{ id, kind (threadedReply|opinionRequest), targetSessionId, targetSequence, renderedPreview,
  requiresConfirmation:true, createdAt, sourceQuestionId? }`. `renderedPreview` = the EXACT bytes shown + posted.
- **ActionReceipt**: `{ id, proposalId, status (posted|pendingConnectivity|failed), result (ActionResultRef|null),
  targetSessionId, confirmedProposalHash, confirmedByHumanAt, executedAt?, failureReason?, signature, signingKeyId }`.
  A signed receipt exists ONLY for a real `posted` write. `pendingConnectivity`/`failed` are NEVER shown as sent.

## 5. The backend (PHASE B only — under re-audit; the ROOM/warden clearance wins)
> The demo backend/launcher is **NO-GO for real write-back until warden posts "launcher CLEARED"** (Echo #233248).
> Phase A needs NO backend. Treat this section as the intended wire shape; do not run/integrate the launcher for a
> real write-back until cleared. For Phase A, brief from the frozen `canonical_checkpoint.json` fixture.

Run the local demo gateway on the Mac (from the repo):
```
# briefing-only (loopback):
node scripts/local-server.mjs
# real write-back over LAN (once cleared) — disposable session must be re-confirmed; sl entrypoint must be absolute:
LAN=1 DEMO_SESSION=<disposable-id> DEMO_SESSION_DISPOSABLE_CONFIRM=<same-id> \
  SL_CLI_JS=<abs path to sentinelayer-cli.js> node scripts/local-server.mjs
```
It prints: the **LAN URL**; a **RANDOM per-run pairing token** (ephemeral — type into the phone, do NOT log/commit);
the **raw base64url Ed25519 verify key** (keyId `demo-bundle-key`/`demo-receipt-key`); and the committed KAV pointer.
Defaults to **loopback** (`LAN=1` is explicit opt-in; LAN is cleartext HTTP — trusted LAN only).

Endpoints (send `Authorization: Bearer <printed pairing token>`; exact `application/json` MIME for POST):
- `GET  /sync` → one **real Ed25519-signed** PocketBundle to brief from.
- `POST /actions/execute` `{ proposal, confirmation }` → with a **confirmed disposable** session, a **real** governed
  write-back (shell-free `sl`) → **real sequence + signed receipt**. A proposal that cannot be bound to a confirmation
  returns a **typed `422 { error:"proposal_rejected" }` envelope** — never a null-hash "receipt", never a fake `posted`.
- `POST /tts` `{ text, voiceId }` → PCM (needs the `pocket:voice` scope; the real voice path is on-device/Echo).
- **KAV**: `test/fixtures/pocket_kav_v1.json` — verify the bundle + receipt with the raw base64url key in Swift too.

Product-truth rules you MUST honor in the UI (Pulse enforces fail-closed):
- **Verify the bundle signature** (raw base64url Ed25519) before speaking a briefing. If it fails, do not brief.
- **Never render a non-`posted` receipt as sent.** Only a `posted` + signature-verifying receipt = "written back".
- The pairing token/keys are local-demo only; do not present them as AIdenID / production trust.

## 6. What is DONE vs what is YOURS
DONE (do not rebuild): the whole gateway — checkpoint extract → grounded summary → strict-egress signed bundle →
governed exactly-once write-back → signed receipt; real AIdenID JWT/DPoP verifier (byte-exact KAV-verified);
Lambda/TTS/DynamoDB adapters; the local demo server. 130/130 hermetic tests, live-proven. **The governed-write core
is frozen-final and byte-locked — do not touch it.**

YOURS (the device build, Swift, needs the Mac):
1. Incoming-call screen ("Senti is calling") + accept.
2. Fetch `GET /sync`, **verify the bundle signature**, cache it.
3. Speak the briefing (headline + per-agent summaries) via on-device TTS.
4. One **barge-in**: pause playback, take a spoken question, answer from the **cached** bundle/evidence.
5. One **dictated decision** → render an `ActionProposal.renderedPreview` → show it → **confirm** →
   `POST /actions/execute` → verify the returned `ActionReceipt` (signature + `status:posted`) → show "written back."
6. **Record the screen** (call + briefing + write-back) — that recording is the deliverable.

Coordinate the Swift app internals (`PocketCallMachine`, `VerifiedBundle.verify()`, UI states) with **claude-pocket-atlas**
and **codex-pocket-pulse** in the room (session `6cf7e861-546a-4b9f-b937-39182a5bd395`). Ask them for the exact UI SHA.

## 7. How to work here
- Post status + questions in the Senti room (session `6cf7e861-...`); ack Carter first; keep a tight cadence.
- Nothing merges to the demo branch without the warden gate + a second distinct-role sign-off (batch-8 rule).
- Backend/contract questions → **claude-pocket-relay** (gateway owner). I will support you live.
