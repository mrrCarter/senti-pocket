# Demo Guide — Senti Pocket + ENGRAM (Atlas's sections)

_Part of the unified "demo everything in the stack" walkthrough. One story: a team + its agents working as one organization, steered by humans, remembered as one graph._

---

## Senti Pocket — the human-in-the-loop, on your phone

**What it is (1 line):** long-running agent sessions reach you the way a teammate would — your phone *rings*; you hear the decision, talk it through, and your answer posts back into the same live session, as you, signed.

**Why it matters:** multiplayer AI isn't only agents watching each other — it's the *human* staying in the loop without sitting at a terminal. An agent hits a point where it genuinely needs a person; Senti Pocket is how the person shows up — from anywhere, by voice.

**The demo (the DIALS flow — ~90 seconds):**
1. **Ring.** An agent in the live session commands `call user` with the decision it needs (or a checkpoint fires). Your phone rings a real CallKit call: *"Senti · claude-atlas needs your decision."* (You see WHO's asking, on the lock screen.)
2. **Answer → briefing.** You pick up; the phone speaks who's calling and the decision + the options aloud (on-device TTS).
3. **Barge-in Q&A.** Ask grounded follow-ups by voice ("what's the blast radius?"). Answered from the session's evidence — *never* posts anything. Questions and answers can never be mistaken for authorizing a write.
4. **Dictate + confirm.** Say *"my reply is rotate the token and hold the deploy."* The phone reads it back verbatim and asks you to say **confirm**. Only an explicit dictated reply **and** an explicit confirm authorize a write — voice-GO === tap-GO.
5. **It posts as you.** Your decision lands as a governed `humanMessage` in the **same** session the ring was about — authored as you (human-mrrcarter), hash-bound, ed25519-signed receipt, read-back-verified. On-screen invariant: `ring.sessionId === writeback.sessionId`.

> **Readiness — Track-A (now) vs Track-B (~30 min infra):** Steps 1-3 plus the governed-write invariant (`ring.sessionId === writeback.sessionId`, real ed25519, idempotent by `(principal, proposal.id)`, non-member → 403) demo **hermetically today** — the sim rings and *speaks* the brief; with no side-loaded Whisper model, capture is nil so it briefs-and-**declines** (nothing posts). The **live voice capture** in steps 4-5 (dictate → confirm → post from the phone) runs only on **Track-B** (Whisper model side-load + APNs VoIP cert + api#753 Deploy-to-ECS). See the operator runbook (**#118**) for the authoritative Track-A / Track-B demarcation so the story and the readiness stay in sync.

**What to look for (the honesty spine — this is the moat, not the voice):**
- Nothing posts without your explicit dictated reply + confirm; decline / hang-up / unclear → **nothing** posted or queued.
- The write is the SAME governed path a human tap uses — real crypto, no faked wedge; a retry never double-posts (idempotent by `(principal, proposal.id)`); a non-member target → 403.
- Offline → the confirmed intent is durably queued and shown as **pending**, never "sent"; "sent" renders only on a pin-verified signature.
- The decision content is delivered over an **authed** channel (hydrated), never trusted from the unauthenticated push — the doorbell announces, it doesn't carry the governed content.

**The multiplayer line:** any agent — coding or otherwise — can reach the right human for a decision, and the decision returns into the shared session everyone (humans + agents) is working in. The session is the shared surface; the phone is how a human steps in from anywhere.

---

## ENGRAM — one memory graph for the whole organization  _(secret-sauce-GUARDED)_

> Scope guard: this section shows the WHAT and the VISUAL only. The engine internals stay out of anything public — how memory is stored, consolidated, or recalled is not demoed or documented here. Carter approves the final public line before it ships.

**What it is (safe framing):** everything the org produces — PRs, commits, agent messages, checkpoints, decisions, receipts — isn't a pile of separate logs. It's one connected **graph**: every artifact is a node, every relationship an edge. ENGRAM is the substrate that holds that graph and keeps it coherent as it grows.

**The visual (Carter's brief — a story, not a hairball):** a 3D node-space. Nodes = the artifacts (a PR, a commit, an agent's message, a checkpoint decision, a signed receipt). Edges = the real relationships (*this commit closed that PR* · *this decision came from that checkpoint* · *this agent-message triggered that dial* · *this receipt recorded that governed write*). As you pull back, the threads **converge**: many scattered activities resolve into a single shape — the organization working as one system. It should read as one story arriving at one ending, never a distorted tangle.

**The demo (navigate the convergence):**
1. Start on a single **PR** node.
2. Trace its edges: the **commits** under it → the **agent messages** that reasoned about it → the **checkpoint** where a human steered it (via Senti Pocket!) → the **receipt** of that governed decision.
3. Pull back: that one thread is one of many, and they all connect into the same org graph — the buffet of activity becoming one coherent picture.

**What to look for:** it's not that we log everything — it's that everything is *connected and navigable* as one graph, so the whole organization's work (human + agent) is one queryable, living memory.

**Ties into the story:** Senti Pocket is where a human *steers* a moment; ENGRAM is where every such moment — and every commit, message, and PR around it — is *remembered as one connected whole*. Same org, one graph.

---

_Draft (Atlas). Content-ready for the web lane to render; ENGRAM public line pending Carter's approval. Pairs with the crew's devTestBot / 13-persona-audit / multiplayer-AI guide entries → one converging walkthrough._
