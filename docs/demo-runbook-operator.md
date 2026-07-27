# Senti Pocket — Operator Runbook & Wake-Up Checklist

_The operator's companion to [`demo-guide-pocket-engram.md`](./demo-guide-pocket-engram.md) (the narrative) and the web `/demos` surface (the rendered experience). This is **how you actually run and show each demo beat**._

**State:** master `c7173ef` — all 7 demo PRs (#110–#116) merged; full stack green: gateway **501/0** + Swift union **111/0** = **612/0**, zero cross-PR regression.

---

## Two tracks

- **Track A — demoable the moment you wake, ~0 setup.** Hermetic proofs + the app in the iOS simulator + the gateway wire, all on master. No infrastructure.
- **Track B — ~30-min wake-up infra (your hand).** The steps that flip Track A into the full **live** phone-call + external-join demo.

---

## The 5 beats

### Beat 1 · MCP servers on npm → ChatGPT + Claude join a live session + post
- **Track A (now):** show the MCP server + tools in-repo; a local MCP client connects to the gateway. api + create-sentinelayer scan/merge cleanly.
- **Track B (infra):** publish the MCP servers to npm (headless `id_rsa`+OIDC) + the token re-mint → then ChatGPT/Claude connectors join a **real** senti room. Needs your publish/token hand.

### Beat 2 · Multiplayer cross-GitHub join ("a different gh couldn't join")
- **Track A (now):** walk the invite→accept flow and the exact failure that was root-caused — accept requires the invitee's GitHub-login email to equal the invited email; a private/`noreply` gh email silently mismatches (`"belongs to a different email"`), and there is **no public self-join**.
- **Track B (config, fast, no code):**
  1. Confirm `RESEND_API_KEY` is set in the api prod env — else invite emails silently don't send (the invite token ships **only** by email).
  2. Invite the second player's **exact** gh-login email (or their `NNNN+user@users.noreply.github.com`); they `sl auth login` + accept → they post.

### Beat 3 · Phone rings about a checkpoint → you speak back → it posts to the SAME session
- **Track A (now, hermetic):**
  ```
  node --test services/pocket-gateway/test/dial-roundtrip-demo.test.mjs
  ```
  Proves ring → answer → same-session governed write, **real ed25519**, the invariant `ring.sessionId === writeback.sessionId`, idempotent (no double-post), non-member → 403. Plus the iOS **simulator** renders the "Senti is calling" UI and **speaks the brief** (the caller-open + the options aloud). Note: voice **capture** is NOT in Track A — with no side-loaded model, `WhisperModelLocator.resolve()`=nil → `listen()`="" → the sim briefs but declines (graceful degrade, nothing posts); the capture→writeback half is Track B (needs the side-load). Narrative: the demo-guide.
- **Track B (infra, for a live phone / live capture):** APNs VoIP cert · api#753 Deploy-to-ECS (writeback endpoint live) · Apple code-signing (app on your real phone) · one-time Whisper side-load (`<AppSupport>/PocketModels/ggml-base.en.bin`, sha256 `a03779…`) — **this is what turns on voice capture → dictate+confirm → governed writeback** on sim/device · the deploy `apnsSend` delivers `buildVoipPushDictionary(payload)` top-level.

### Beat 4 · Senti CLI "call user \<msg>" → Pocket rings: "this is \<caller>" + the decision
- **Track A (now):** the `#113` BEAT-4 cases prove the ring carries caller + decision + options + sessionId and is confused-deputy-safe (targets the **verified** human, not the request body); the spoken open (`#115`) says _"Senti · claude-atlas needs your decision"_ off the **authed** `callerName`.
- **Track B:** same APNs infra as beat 3 for the physical ring.

### Beat 5 · The multiplayer pitch, word-for-word, demonstrable
- **Track A (now):** the demo-guide + web `/demos` render the pitch; each claim maps to a real artifact (the demos above).
- **Track B:** the polished on-site guided surface. _ENGRAM's public line stays approval-gated — not shipped without your sign-off._

---

## Wake-up infra checklist (Track B — your hand, ~30 min, ordered)

1. Token re-mint + publish MCP → npm (beat 1).
2. Confirm `RESEND_API_KEY` in api prod (beat 2 invite emails).
3. api#753 Deploy-to-ECS (beat 3 writeback endpoint live).
4. APNs VoIP cert wired (beat 3/4 ring).
5. Apple code-signing (app on your phone).
6. One-time Whisper model side-load.
7. Deploy `apnsSend` → `buildVoipPushDictionary` (top-level envelope).

---

## Honesty invariants (hold in every demo)

- No governed write posts without an explicit dictated reply **and** an explicit confirm — decline / hang-up / unclear posts **nothing**.
- The write uses the **same** governed path a human tap uses — real crypto, no faked wedge; idempotent by `(principal, proposal.id)`; non-member target → 403.
- Offline → the confirmed intent is durably queued and shown as **pending**, never "sent"; "sent" renders only on a pin-verified signature.
- The decision content arrives over an **authed** (hydrated) channel — the unauthenticated push is a doorbell that announces, never carries the governed content.
- Everything green on master is real; nothing depicted exceeds what the real path does.
