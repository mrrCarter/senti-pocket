# iOS UI/UX Backlog — SentiPocketApp (living)

**Purpose (Carter, 2026-09-01):** the web session UI (`sentinelayer-web`) is the **reference UX**. Whenever something is said or fixed in the Senti Pocket room (or the web session viewer), forge captures the **iOS implication** here so the phone app tracks the web pattern instead of drifting. This is a *living* list — append, don't rewrite; check items off as they land in `apps/SentiPocketApp`.

Conventions: each item = **what** · **web reference** (component in sentinelayer-web) · **iOS target** (file/area in apps/SentiPocketApp) · **status** (`backlog` / `in-progress` / `done`) · source (Pocket-room seq or PR).

---

## A. In-flight (named by Carter)

- **A1 · Listen-to-message voice** — a speaker button in each message/reply action row that reads the post aloud; free voice, markdown→speech, natural pauses, one-at-a-time. · web: `ListenButton` + `useSpeech` (PR #493). · iOS: new `MessageListenControl` backed by `AVSpeechSynthesizer` (reuse the web's sentence/paragraph chunking for pauses); wire into the message row. · **status: backlog** (web shipped; iOS port pending). src: sentinelayer-web#493
- **A2 · Chat on the phone (session feed + compose)** — a real session message list the user can read and post/reply into, mirroring the web feed. · web: `SessionLiveView` / `SessionStreamVirtualized` / `SessionComposer`. · iOS: today the app is call/briefing-centric (`PocketPhoneView`, RootView still placeholder); needs a feed screen. Governed-write discipline stays (typed proposal → read-back → confirm → receipt). · **status: backlog**
- **A3 · Call-on-checkpoint affordance** — when a checkpoint lands, surface a "call" action. · web: `SessionCheckpointRail`. · iOS: CALL-ME PushKit path already built (`SentiCallKit`/`DialHost`); wire checkpoint → ring trigger (see call-me contract `docs/CALL_ME_AND_VOICE_CONTRACT.md`). · **status: backlog** (blocked on gateway/.p8 deploy for live ring)

## B. Web → iOS parity backlog (the web is the reference)

- **B1 · Message action row** — Copy · Listen · Ack · Working · Reply · Like · Dislike · Disregard · Pin, with counts + active state. · web: `SessionMessageActionBar` in `SessionMessage.tsx`. · iOS: message-row view (new). · **status: backlog**
- **B2 · Reply threads** — nested replies, "View all N comments" expand/collapse, reply-to-reply. · web: `SessionReplyNote`. · iOS: new. · **status: backlog**
- **B3 · Actor attribution** — "Ack: a, b, c +N more" with an expandable popover listing everyone. · web: `ActorNameList` / `ActionActorAttribution`. · iOS: new. · **status: backlog**
- **B4 · Agent avatars** — stable per-agent colored initials. · web: `AgentAvatar` / `agentAvatarTone`. · iOS: new. · **status: backlog**
- **B5 · Lock/unlock chips** — mechanical lock coordination posts render as a compact chip, not a full bubble (noise reduction). · web: `parseLockMessage` in `SessionMessage`. · iOS: new. · **status: backlog**
- **B6 · Finding cards** — severity badge + colored left rail (P0/P1 rose, P2 amber, else emerald). · web: `findingAccent` / finding branch of `SessionMessage`. · iOS: new. · **status: backlog**
- **B7 · Human vs agent bubble styling** — human posts right-aligned with send-status (sending/confirming/failed); agent posts left with avatar. · web: `SessionMessage` isHuman branch. · iOS: new. · **status: backlog**
- **B8 · Recap / context-briefing** — italic muted rendering, distinct from normal messages. · web: `isRecap` branch. · iOS: `PocketPhoneView` briefing already speaks a brief; align the visual. · **status: backlog**
- **B9 · Attachments** — attachment cards inline. · web: `SessionAttachmentCard`. · iOS: new. · **status: backlog**
- **B10 · Checkpoint rail** — checkpoint list/generate UI. · web: `SessionCheckpointRail`. · iOS: new (feeds A3). · **status: backlog**
- **B11 · Theme + accessibility** — light/dark parity; VoiceOver labels equivalent to the web's aria-labels (e.g. "Listen to message #N" / "Stop reading …"). · web: theme tokens + aria-* throughout. · iOS: Dynamic Type + VoiceOver pass. · **status: backlog**

## C. Captured from the Pocket room (append as things are said/fixed)

_(empty — new items land here with their room seq / PR as they come up)_
