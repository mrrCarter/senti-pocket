# Senti Pocket Sunday Build — Mandatory Operating Order

We are building **Senti Pocket** for the Sunday hackathon. This room is the source of truth for scope, ownership, decisions, blockers, handoffs, and proof.

## 1. The product we are shipping

By the final demo, this exact loop must work:

1. Senti creates or exposes a real checkpoint.
2. Pocket receives a bounded checkpoint bundle containing the summary, agents, evidence, risks, blockers, and source sequence range.
3. The iPhone shows a local notification or in-app incoming screen: **“Senti is calling.”**
4. The user answers and hears a short briefing.
5. The user interrupts the briefing and asks a question.
6. Pocket answers from checkpoint evidence and shows the supporting receipt/card.
7. The user says an instruction such as: “Tell them to rotate the token but do not deploy until Omar Gate is green.”
8. Pocket converts that speech into a typed `ActionProposal`, shows and reads back the exact proposed message, target session, and target sequence.
9. Pocket executes nothing until the user explicitly confirms.
10. When online, Pocket posts through the existing Senti API/MCP surface into the original checkpoint thread and returns the resulting sequence plus an action receipt.
11. When offline, briefing and cached Q&A continue working; write actions become `PENDING_CONNECTIVITY` and must never be represented as sent.

The pitch line is:

> **Your agents work while you are gone. Answer the call.**

## 2. Sunday scope

### Required

- Native iPhone app in SwiftUI.
- One real Senti session and one real checkpoint flow.
- Local checkpoint storage and evidence cards.
- Incoming-briefing notification/in-app ring; no phone number or carrier dependency.
- Local spoken briefing.
- Barge-in: user speech stops or ducks narration immediately.
- Local follow-up Q&A over the cached checkpoint.
- Draft → read-back → explicit confirmation → Senti threaded reply.
- Receipt showing the resulting Senti sequence or a clear failure state.
- Airplane-mode demonstration after the checkpoint bundle has synced.

### Explicitly out of scope until the vertical slice passes

- Gmail, Calendar, Zoom, PSTN, custom voice cloning, multiple personas, multiple repositories, App Store billing, generic MCP marketplace, team administration, or autonomous destructive actions.

## 3. Locked initial technology choices

- App: SwiftUI.
- Local reasoning: **Gemma 4 E2B Instruct through LiteRT-LM**. Echo benchmarks the actual target phone before depending on it.
- Local speech recognition: **whisper.cpp `base.en`**, upgraded only if measured command accuracy requires it.
- Speech output: **AVSpeechSynthesizer** for the hackathon build.
- Retrieval: local SQLite/FTS or the simplest equivalent already in the repo.
- Ringing: local notification plus an in-app incoming briefing screen; no fake PSTN implementation.
- Senti writes: existing API/MCP primitives only. Pocket must not invent a second chat system.
- Safety: the model may propose an action, but deterministic code owns target resolution, authorization, confirmation, execution, and receipts.

If the target phone cannot sustain Gemma 4 E2B, Atlas may approve a clearly labeled local-LAN fallback running the same model on the Mac. Do not silently switch to cloud inference and continue calling the demo offline.

## 4. Four-agent team

### `claude-pocket-atlas` — Lead, contracts, integration, and release

Own the architecture, repository inventory, shared data contracts, fixture checkpoint, path/lock map, app skeleton, integration branch, end-to-end state machine, final merge, demo runbook, and release call. Atlas codes; Atlas is not a passive project manager.

### `codex-pocket-pulse` — iOS product and SwiftUI

Own the checkpoint inbox, incoming briefing screen, Answer/Listen Later/Snooze, conversation screen, playback controls, evidence cards, offline/pending states, proposal preview, confirmation UX, accessibility, and device-level UI tests.

### `codex-pocket-echo` — Offline model, speech, and interruption

Own Gemma/LiteRT-LM integration, model download/verification, whisper.cpp integration, microphone and `AVAudioSession`, TTS, VAD/barge-in, cancellation, latency/thermal instrumentation, and the local question-answer execution path.

### `claude-pocket-relay` — Senti checkpoint, MCP, writeback, and receipts

Own checkpoint discovery/export, bounded `CheckpointBundle` creation, sync to the phone, Senti API/MCP adapter, threaded replies, opinion requests, AIdenID-scoped authorization where available, idempotency, pending offline intents, and action receipts.

## 5. Immediate join protocol — every agent

Before touching code, run the local help and treat it as source of truth:

```powershell
sl --help
sl session actions
sl mcp list --json
```

Then join and hydrate:

```powershell
sl session join <SESSION_ID> --name <AGENT_ID>
sl session read <SESSION_ID> --remote --agent <AGENT_ID> --json
sl session pins <SESSION_ID> --json
sl session locks <SESSION_ID> --json
```

Find the sequence number of this message, ACK it explicitly, then reply underneath it:

```powershell
sl session react <SESSION_ID> ack --target-sequence <FIRST_MESSAGE_SEQ>
sl session reply <SESSION_ID> <FIRST_MESSAGE_SEQ> "ACK <AGENT_ID>: role=<role>; first_action=<next concrete action>; intended_paths=<paths or inventory first>"
```

Start the room listener in a separate terminal and keep it alive while assigned work is active:

```powershell
sl session listen --session <SESSION_ID> --agent <AGENT_ID>
```

If the listener fails, poll with `sl session read ... --remote --agent ...` and report the failure. Do not go dark.

## 6. Room behavior and commentary rules

1. Read the whole room, not only direct mentions.
2. ACK every new human/orchestrator instruction, direct assignment, blocker, lock request, handoff, or decision that affects your lane.
3. After ACKing an actionable message, reply under that same sequence with your interpretation, action, or blocker.
4. Use `sl session reply` / `comment` for existing topics. Create a new top-level post only for a new phase decision, cross-lane blocker, formal handoff, or final summary.
5. Keep commentary low-noise. Do not post “still working” every few minutes.
6. Post a compact status every 20 minutes or at a phase boundary:

```text
STATUS <AGENT_ID>: done=<facts>; next=<one action>; blockers=<none|exact blocker>; evidence=<tests/commit/PR>; locks=<paths>
```

7. Before editing, inspect locks and claim the smallest practical path set:

```powershell
sl session locks <SESSION_ID> --json
sl session lock <SESSION_ID> <files...> --intent "<specific purpose>"
```

8. Release locks immediately after committing, handing off, or abandoning the patch:

```powershell
sl session unlock <SESSION_ID> <files...>
```

9. If uncertain how to comment, react, reply, lock, or transition work, run `sl --help` and `sl session actions`; do not guess old syntax.
10. Never paste secrets, API keys, signing keys, tokens, or full private transcripts into Senti, commits, logs, screenshots, or demo fixtures.
11. Never claim “working,” “offline,” “posted,” “signed,” or “tested” without evidence.
12. No agent may change another lane’s frozen contract or files without a threaded agreement and lock handoff.

## 7. How the agents interact

Atlas freezes these shared contracts first:

- `CheckpointBundle`
- `EvidenceRef`
- `BriefingPlan`
- `QuestionAnswer`
- `ActionProposal`
- `ActionReceipt`

Pulse builds UI against Atlas’s fixture and contracts without waiting for Relay.

Echo exposes narrow interfaces to Atlas and Pulse:

- `LocalInferenceEngine`
- `SpeechRecognizer`
- `SpeechSynthesizer`
- `BargeInController`

Relay exposes narrow interfaces to Atlas and Pulse:

- `PocketSyncClient`
- `SentiActionClient`
- `ReceiptVerifier`

Only Atlas edits the Xcode project/workspace and shared composition files after the initial path map. Feature agents work in their owned modules/worktrees and hand commits to Atlas.

Every handoff uses:

```text
HANDOFF <FROM> -> <TO>: contract=<version>; commit=<sha>; tests=<proof>; integration=<steps>; limits=<known limits>
```

## 8. Build phases

### Phase 0 — Reality check and contracts

- Atlas inventories the repo and posts the path/lock map.
- Relay proves how current checkpoints are obtained and how a threaded Senti reply is executed today.
- Echo benchmarks Gemma 4 E2B and whisper.cpp on the target hardware.
- Pulse starts against one canonical fixture.

No lane may wait idle for another lane; use the fixture and interfaces.

### Phase 1 — Offline fixture vertical slice

Must work five consecutive times:

```text
fixture checkpoint → saved locally → Senti is calling → Answer → spoken briefing → user interrupts → local answer → evidence card
```

Do not add real writeback until this passes.

### Phase 2 — Real checkpoint sync

Replace the fixture with one real Senti checkpoint while preserving offline playback after sync.

### Phase 3 — Governed writeback

```text
voice instruction → typed proposal → exact read-back → explicit confirmation → threaded Senti reply → resulting sequence → receipt
```

No direct speech-to-tool execution.

### Phase 4 — Hardening and demo

- Airplane mode after sync.
- Wrong-session and stale-confirmation tests.
- Prompt/tool-injection fixture.
- Five complete demo runs.
- `sl review scan --path . --json`.
- `sl /omargate deep --path . --json` or the current local equivalent from `sl --help`.

P0/P1 findings block the demo build.

## 9. First actions by agent

- **Atlas:** inventory repos; post architecture, contracts, owned paths, worktrees, and the canonical fixture.
- **Pulse:** after Atlas posts contracts, lock the UI module and build the incoming briefing + conversation screens with fixture data.
- **Echo:** run the smallest real device harness proving model load, transcription, TTS, and interruption; post measured latency and memory, not estimates.
- **Relay:** locate the current checkpoint and MCP/API implementation; prove one read and one safe threaded reply in a test session; document exact scopes and gaps.

## 10. Definition of done for Sunday

The build is done only when Carter or the human hacker can perform this from a physical phone:

1. Receive a real checkpoint.
2. Answer the Senti briefing.
3. Interrupt it.
4. Ask a question and inspect the cited evidence.
5. Dictate a decision.
6. Review the exact proposed Senti message and target.
7. Confirm it.
8. See the reply in the original checkpoint thread and verify the returned sequence/receipt.
9. Repeat briefing and cached Q&A in airplane mode after sync.

Start now: ACK this post, state your lane, run your listener, and take the first action above.
