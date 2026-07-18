# CHECKPOINT_ACCESS — how a REAL Senti checkpoint is obtained today

Owner: **claude-pocket-relay**. Status: **VERIFIED LIVE** on 2026-07-18 as `mrrCarter (admin)`
against `https://api.sentinelayer.com`, CLI `sentinelayer-cli v0.39.2`, Node 22.15.0.

> This is the data-ingress contract for the gateway. Every command below was run against a
> real session; the shapes are copied from live output and from the CLI source
> (`src/session/checkpoints.js`, `src/commands/session.js`). No invented fields.
>
> Run the CLI with Node 22 (default node crashes it):
> ```
> N22="/c/Users/carter/AppData/Roaming/nvm/v22.15.0/node.exe"
> CLI="/c/Users/carter/AppData/Roaming/npm/node_modules/sentinelayer-cli/bin/sentinelayer-cli.js"
> "$N22" "$CLI" <args>          # equivalently: sl <args>
> ```

## TL;DR — the recipe

There are **two** real ingress surfaces. Relay uses both:

| # | Command | Mutating? | What you get |
|---|---------|-----------|--------------|
| 1 | `sl session export <SID> --json` | no | **RAW** — full transcript + agents + actions + tasks + totals. The event source. |
| 2 | `sl session checkpoint list <SID> --json` | no | **Durable summarized checkpoints** the Senti daemon already minted (`kind=auto_summary`), with grounded `summarySections` + completeness grade. |
| 3 | `sl session checkpoint generate <SID> [--min-events 20 --max-events 80] [--catch-up]` | yes | Mint a checkpoint from the next uncheckpointed window (what the daemon does automatically). |
| 4 | `sl session checkpoint create <SID> --start-sequence N --end-sequence M --title T --summary S` | yes | Manually anchor a checkpoint to an explicit sequence range. |
| 5 | `sl session recap now <SID> --remote --json` | no | Lightweight deterministic recap (current owners, locks, task ownership) — cheaper than a checkpoint. |

**Pipeline decision:** the gateway ingests `export` as the RAW source of truth (surface #1) and
uses `checkpoint list` (surface #2) as an *optional pre-summarized baseline*. Relay's own
summarizer pass (see `DESIGN.md`) re-grounds the raw slice into the per-agent, FACT/INFERENCE/
RECOMMENDATION-tagged, evidence-cited `CheckpointSummary` the demo requires — the Senti
`auto_summary` alone does **not** satisfy the differentiator (see "Gap" below).

---

## 1. RAW source — `sl session export`

Verified live (`sl session export 6cf7e861-… --json`, 122 KB, exit 0):

```
TOP KEYS: command, exportedAt, session, agents, participants, actions,
          actionProjection, actionEvents, events, tasks, remote, counts,
          includeControlEvents, totals
counts:  { agents:5, participants:5, derivedAgents:5, registeredAgents:3,
           events:24, rawEvents:34, hiddenControlEvents:10, actions:0,
           actionEvents:0, tasks:0 }
totals:  { tokenTotal:6791, inputTokens:0, outputTokens:6791,
           costTotalUsd:0, usageEntries:8, priceBookVersions:["2026-05-24"] }
```

### Event shape (`events[]`) — verified live
```jsonc
{
  "stream": "sl_event",
  "event": "session_message",          // session_message | session_reply | agent_join | context_briefing | session_action | ...
  "agent": { "id": "senti", "model": "senti", "role": "coder", "displayName": "…", "clientKind": "cli" },
  "payload": { "to": ["mention"], "channel": "session", "message": "…", "mentions": [...], "firstMessage": true },
  "sessionId": "6cf7e861-…",
  "idempotencyToken": "…",             // per-event; Relay uses this to DEDUP EXTRACTION (not writeback)
  "cursor": "0000000230731:0003854b",  // canonical ordered cursor (seq:hash)
  "sequenceId": 230731,                // GLOBAL canonical sequence (tenant-wide, NOT per-session-1-based)
  "ts": "2026-07-18T11:45:26.487Z",
  "timestamp": "…"
}
```

### Agents shape (`agents[]` / `participants[]`) — verified live
```jsonc
{ "schemaVersion":"1.0.0", "sessionId":"6cf7e861-…", "agentId":"claude-pocket-relay",
  "model":"claude", "displayName":"Claude", "provider":"anthropic",
  "clientKind":"cli", "role":"coder", ... }
```

### Actions (`actions[]` / `actionProjection`)
The acks / replies / reactions / receipts channel (threaded activity). Empty on a fresh room;
populated shape verified via the reply proof below (`action.id`, `targetSequenceId`,
`targetCursor`, `actionType`, `idempotencyKey`, `note`, `createdAt`).

---

## 2. Durable checkpoint shape — `sl session checkpoint list`

Live call on the current room returns `{ ok:true, count:0, checkpoints:[] }` (new room, <20
events, daemon has not minted one yet — expected). The **shape** of each checkpoint (from
`src/session/checkpoints.js` + `formatCheckpointLine` in `src/commands/session.js`, and observed
on populated rooms) is:

```jsonc
{
  "checkpointId": "cp_cli_<24hex>",     // stable hash of range/body, or daemon id
  "kind": "auto_summary",               // summary | handoff | milestone | billing | auto_summary
  "title": "…",
  "summary": "…",                        // freeform prose
  "createdByAgentId": "senti",           // daemon-minted checkpoints are createdBy=senti
  "startSequence": 230731,               // canonical event-sequence range (anchors EvidenceRefs)
  "endSequence": 230799,
  "tokenRange": { "start": 0, "end": 6791 } | null,

  // completeness grade (checkpoint_grade_v1):
  "grade": "A".."F", "gradeScore": 0..100, "gradeReasons": [{ "message"|"code": "…" }],

  // GROUNDED structured sections (schema: checkpoint_summary_sections_v1):
  "summarySections": {
    "workCompleted":       ["…"],
    "agentContributions":  [{ "agentId": "…", "summary": "…" }],   // per-agent — preserved
    "evidence":            [{ "label": "…", "value": "…" }],
    "risks":               ["…"],
    "nextSteps":           ["…"]
  },
  "cursor": "…", "createdAt": "…"
}
```

Under the hood (from source): `GET  /api/v1/sessions/{id}/checkpoints?limit=N`,
`POST /api/v1/sessions/{id}/checkpoints/generate`, `POST /api/v1/sessions/{id}/checkpoints`.
Auth: `Authorization: Bearer <token>` from `sl auth login` (token source=session, verified).

---

## 3. RawCheckpoint → PocketBundle mapping (what Relay extracts)

| PocketBundle / RawCheckpoint field (Atlas contract) | Source (verified) |
|---|---|
| source sequence range `[startSequence, endSequence]` | `export.events[].sequenceId` window, or checkpoint `start/endSequence` |
| participating agents | `export.agents[]` / `export.participants[]` |
| raw messages / evidence bodies | `export.events[].payload.message` (+ `cursor`/`sequenceId` for EvidenceRef anchor) |
| acks / replies / receipts | `export.actions[]` + `export.actionProjection` |
| per-agent baseline summary | checkpoint `summarySections.agentContributions[]` |
| risks / next steps baseline | checkpoint `summarySections.risks` / `nextSteps` |
| token/cost accounting | `export.totals` |
| extraction dedup key | `export.events[].idempotencyToken` (per event) |

`EvidenceRef` = `{ sequenceId, cursor, quote }` — every claim in the summary must cite one, and
the `quote` must be substring-verifiable against `events[sequenceId].payload.message`.

---

## 4. Writeback ingress — one SAFE threaded reply (PROVEN)

A decision posts back into the checkpoint thread as a **threaded reply**, which is a Senti
**action** (not a new top-level message). Proven live in a throwaway test session
`5cd1a149-6413-4b81-abc6-067af7952f63` (created with `--no-daemon`, TTL auto-expires):

- Anchor message posted → **sequenceId 230813** (`remoteConfirmation.confirmed=true`, `source=forward_cursor`).
- `sl session reply <TID> 230813 "…" --agent relay-selftest --json` →
  ```jsonc
  action: {
    "id": "ad888498-d681-4b1d-ba68-71e1fc6e8609",   // durable action identity
    "targetSequenceId": 230813,                      // deterministic target binding
    "targetCursor": "0000000230813:0003859d",
    "actionType": "reply",
    "actorId": "relay-selftest",
    "idempotencyKey": "cli:reply:seq:230813:relay-selftest:5e16504c…",
    "createdAt": "2026-07-18T12:13:02Z"
  }
  duplicate: false
  event: { "event": "session_reply", "payload": { "targetSequenceId": 230813, "message": "reply #230813: …" } }
  ```
- **Idempotency proven:** re-sending the identical reply returned `duplicate=true` with the
  **same** `action.id` and **same** `idempotencyKey` — i.e. a retried/replayed confirm posts
  **exactly once**. This is the writeback safety primitive.
- Reply is visible in-room: `session_reply targetSeq=230813`.

**Governed-write takeaway:** deterministic code owns `targetSequenceId` + `targetCursor`
resolution and the `idempotencyKey`; the model only proposes text. The CLI already enforces
idempotency server-side. See `DESIGN.md`.

---

## Gap Relay owns (do not paper over)

The Senti daemon `auto_summary` / `summarySections` is a usable **baseline**, but:
- it is **not tagged** FACT vs INFERENCE vs RECOMMENDATION;
- `agentContributions` is per-agent but the daemon can still flatten a disagreement into one
  line — the summarizer must **preserve disagreement** explicitly;
- it does not attach a verifiable `EvidenceRef{sequenceId,quote}` to every claim.

Relay's summarizer pass (gateway `src/summarize.ts`) adds those. Until it lands, the gateway
emits the baseline **clearly labeled** `grounding: "baseline_unverified"` — never as if it were
grounded. That is the honest state and the P1 grounding eval scores against it.
