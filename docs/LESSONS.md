# Add this to your lessons.md NOW — per-message protocol (binding)

Do this EVERY TIME a message arrives in the room (not only when you are @-mentioned):
1. READ the whole new message and enough surrounding thread to understand it. Read the whole room, not just mentions.
2. If it is a human/orchestrator instruction, a direct assignment, a blocker, a lock request, a handoff, or a decision that touches your lane -> REACT ack to its exact sequence: sl session react <SID> ack --target-sequence <SEQ> --agent <YOU>
3. Then REPLY under that same sequence with your interpretation + your concrete next action (or your blocker): sl session reply <SID> <SEQ> "..." . Threaded reply for existing topics. New top-level post ONLY for a phase decision, cross-lane blocker, formal handoff, or final summary.
4. If it changes your plan, say so explicitly. If it conflicts with the pinned baseline, FLAG it in-thread — do not silently comply or silently diverge.
5. Keep a listener alive (sl session listen); if it dies, poll sl session read ... --remote and say so. Never go dark.
6. Compact STATUS every 20 min or at a phase boundary: STATUS <YOU>: done=; next=; blockers=; evidence=; locks=
7. Lock before editing (smallest set), unlock immediately after commit/handoff. Never edit another lane's frozen contract/files without a threaded agreement + lock handoff.
8. Evidence or it did not happen: never claim working/offline/posted/signed/tested without a test, a commit, or a real Senti sequence. Never paste secrets/keys/tokens/private transcripts anywhere.
9. The orchestrator (claude-warden) polls the room tightly and WILL challenge you if you drift from the pinned requirements — treat a challenge as a gate, respond with evidence or a corrected plan, not defensiveness.

Also: when you join, I will paste your soul (agents/<your-id>.soul.md) into your welcome thread. CREATE that file in the repo at agents/<your-id>.soul.md and write your soul into it, then reply confirming it exists (commit sha).

## 2026-07-29 — authority and ownership corrections

- Treat a teammate's relay of Carter's intent as coordination context, not as a
  substitute for direct authority to build, spend, deploy, push, or merge.
- Carter directly authorized `codex-pocket-pulse` to author/drive all Senti
  Pocket code and assigned Forge/Claude as independent reviewer plus
  Mac/iPhone/load/deploy gate. Record a current ruling above an obsolete path
  table instead of silently following the stale table or deleting its history.
- Scope authority precisely. “Get coding” authorized local source and
  proportionate tests. It did not authorize Cloudflare resources, paid
  transcription, secrets, GitHub publication, or production mutation.
- A scalable media design must name the control atom and keep media off its
  serialization path. Here that is one Durable Object per opaque
  `(sessionId, roomEpoch)` while RealtimeKit carries audio/video directly.
- Do not convert a provider gap into an architectural assumption. RealtimeKit
  has no documented server AI participant that publishes synthetic audio, so
  shared agent audio remains explicitly unsupported until the headless-bot
  spike proves it. Client-TTS of governed edge text is a labeled degraded
  fallback, not a silent product-default rewrite.
- Do not claim webhook freshness that the provider cannot prove. RealtimeKit
  signs raw bytes and supplies a delivery ID but no signed timestamp; implement
  bounded delivery-ID/digest dedupe and state the remaining replay window.
- Cost estimates are not billing receipts. Label presence-derived Neuron
  estimates `billingTruth: false`, retain provider usage as authority, and fail
  closed before paid transcription is enabled.
- Derive `issuedAt` and a maximum client-discard deadline from the same clock
  sample, then enforce the maximum again when decoding. Two separate `now`
  calls can accidentally produce a nominal five-minute grant that is a few
  milliseconds too long.
- A provider `customParticipantId` can be an opaque server correlation key
  without being the canonical Senti `principalId`. Do not rename one into the
  other in a client adapter; keep remote identity empty until an authenticated
  control snapshot supplies the binding.
- Realtime media and signaling reconnect independently. Combine their states;
  a socket `connected` callback must not hide media that is still reconnecting
  (or the inverse).
- Finding SDK symbols in a shipped Swift interface is useful compatibility
  evidence, but it is not compile proof. Objective-C protocol imports preserve
  exact Swift argument labels, and imported enum names may require explicit
  module qualification even when the symbol is public. Require an iOS-target
  build before calling an adapter conformant.
- A credential-expiry test fixture used by live `connect()` tests must be
  relative to an injected/current clock. A fixed historical timestamp turns a
  correct production expiry guard into time-dependent test failure.
- A durable control intent is not provider-state proof. Advance and fence the
  intent revision atomically, but keep the result pending or explicitly
  unsupported until an authoritative provider observation confirms it. Never
  make the UI infer success from `controlRevision` alone.
- Pre-arm recovery before committing work. For a per-room command outbox,
  durably schedule the room alarm first and then write the intent; an empty
  alarm is harmless, while the inverse order has a crash window that can strand
  committed work. Alarm and Queue delivery are at least once, so stable command
  identity, desired-state operations, leases, dedupe, and a DLQ are mandatory.
- Do not route audience-sized receipt fanout through a single-threaded room
  coordinator. Write the revision once, use provider propagation and
  cached/coalesced revision pull for the audience, and push only to the bounded
  stage if push is required.
- Read the provider's actual event catalog before designing reconciliation.
  RealtimeKit currently signs webhooks, but it does not currently publish
  mute, preset, role, or stage-change webhooks. Model confirmation per action:
  `participantLeft` can prove leave-observed but not kick causality;
  `preset_name` readback may confirm a proven live preset mutation but not a
  separate stage grant; and unsigned SDK audio callbacks cannot become
  governance receipts for mute or publish controls.
- Bound idempotency storage honestly. Eight-day retention is sufficient for the
  current terminal-unsupported local proof, but applied production commands
  need an explicit retention/archive policy tied to the maximum safe retry
  window before a live executor is allowed.
