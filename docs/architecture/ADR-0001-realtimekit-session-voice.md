# ADR-0001: RealtimeKit for Senti session voice

- Status: Proposed for independent review
- Decision status: RealtimeKit selected for the launch spike; production approval remains conditional
- Date: 2026-07-29
- Product owner: Carter
- Author: Pocket-Pulse
- Independent reviewer / physical-device gate: Pocket-Forge
- Source base: `origin/master@410286c8e2e8f6616b4b6c07cfb20099c339ea25`
- Normative contract: [`../contracts/session-voice-room-v1.md`](../contracts/session-voice-room-v1.md)
- Machine-readable wire schema: [`../contracts/session-voice-room-v1.schema.json`](../contracts/session-voice-room-v1.schema.json)

## 1. Decision

Use Cloudflare RealtimeKit as the first media-room provider for Senti session
voice. Put every provider-specific API and SDK behind the provider-neutral
ports in the v1 contract. RealtimeKit owns ephemeral media and media presence;
Senti remains the durable authority for membership, governance, semantic
history, transcripts, checkpoints, search, downloadable evidence, and
governed write receipts.

The provider decision is final for the spike. Production approval is not. Two
capabilities must be proven rather than inferred from marketing or SDK shape:

1. A true server-side agent participant can receive attributed live room audio,
   apply overlap and barge-in policy, and publish one agent audio track back.
2. The selected RealtimeKit plan and quota can sustain the required listener
   fan-out, publisher stage, roster, active-speaker, transcript, and recovery
   envelope with measured headroom.

If the first capability cannot be implemented without turning every human
client into an STT/TTS relay, the predefined provider fallback is LiveKit. A
client-side "edge text" mode may remain as an explicitly degraded feature, but
it does not satisfy the true-agent acceptance gate.

At acceptance, this ADR authorized design and local contract work only.
Carter's subsequent build-go authorized implementation and a feature-branch
handoff for independent review. Neither ruling authorizes Cloudflare account
creation, credentials, a paid plan, DNS, production mutation, deployment,
spend, a pull request to the protected branch, merge, or release.

## 2. Why this is a separate product plane

Senti Pocket's existing checkpoint briefing and governed-write loop remains
the product spine. Session voice extends that spine; it does not replace it or
turn speech directly into tool authority.

The design has three independently operable planes:

| Plane | Authority | Durable data | Explicit exclusions |
|---|---|---|---|
| Media | RealtimeKit | Provider-required operational records only | No Senti governance authority; no governed-write authority |
| Room control | Join broker plus bounded RoomGovernor | Lifecycle, role decisions, dedupe cursors, agent-turn lease, correlations | No media, full roster graph, raw audio, or full transcript |
| Evidence | Senti plus async transcript/ENGRAM pipeline | Final utterances, checkpoints, indexes, receipts, archive manifests | Never blocks live media; never grants room or write authority |

This split prevents a hot room from serializing listener joins through one
Durable Object, keeps transcript growth out of room control state, and
preserves the existing confirmation and receipt boundary.

## 3. Identity and room model

A voice call is one epoch within one Senti session:

```text
tenantId + sentiSessionId + voiceRoomEpochId
```

One Senti session may have many voice room epochs. Reopening a call creates a
new epoch; it never reuses an eternal media room. Every control command,
transcript event, usage record, trace, and receipt carries that identity.

The server join broker:

1. authenticates the current Senti principal;
2. verifies active Senti membership and tenant ownership;
3. loads a server-owned `VoiceEntitlement`;
4. derives the room role and capabilities on the server;
5. creates or reuses the provider participant for exactly one room epoch;
6. returns a short-lived, single-room provider credential.

Clients never select their own tenant, session role, moderator grant, speaker
grant, or speaker identity. RealtimeKit API credentials never reach browsers or
iOS. Join credentials are secrets: they are not persisted in analytics,
transcripts, logs, traces, errors, screenshots, or Senti events.

## 4. Roles, stage, and moderation

The provider-neutral roles are `owner`, `moderator`, `speaker`, `listener`, and
`agent`. The server maps them to RealtimeKit presets. Policy records, not client
branches, decide which capabilities each role receives.

The audience may be large, but microphone publishing is always bounded by a
stage cap. Listener joins and heartbeats do not pass through a single
RoomGovernor. Provider observations feed a sharded, paginated roster read
model. Only bounded mutations are serialized:

- room lifecycle transitions;
- stage promotion and demotion;
- mute, remove, and deny-publish commands;
- one fenced agent-turn lease per room epoch;
- webhook deduplication and reconciliation cursors;
- governed-write correlations and outbox cursors.

Moderators may mute, demote, or remove another participant. Remote unmute is
forbidden. A participant must affirmatively re-enable their own microphone
after a mute. No provider adapter may emulate unmute by silently replacing a
participant, reminting broader grants, or changing a preset.

### 4.1 Durable command ledger and scalable execution plane

The room Durable Object owns only the smallest serialized control atom. For one
moderation request it:

1. verifies the exact tenant/session/epoch/room identity;
2. accepts only a freshly authenticated Senti owner/admin who also has an active
   moderator admission;
3. binds the target canonical principal to the active opaque participant key
   and provider participant ID; a `remove` also pins the exact signed
   RealtimeKit provider-session ID and connection-specific peer ID;
4. fences `commandId`, the owner-scoped idempotency fingerprint, payload
   fingerprint, and `expectedRevision`;
5. pre-arms recovery and appends one durable command intent, one outbox row,
   and the next `controlRevision` in one SQLite-backed Durable Object
   transaction; and
6. returns the pending command without making a provider call or pushing to
   listeners.

The raw idempotency key and caller bearer are never stored. Two concurrent
commands at one expected revision serialize: one may reserve the next revision
and the other receives `VOICE_CONTROL_CONFLICT` plus the current revision.
An exact retry returns the original command record; a reused command or key
with different ownership or content conflicts.

The local implementation now includes the offline-safe alarm/outbox, Queue
consumer, execution lease, DLQ terminalizer, terminal watchdog, and a
provider-neutral `remove` execution/observation kernel. Production composition
still selects only `UnavailableVoiceControlExecutor`, which runs outside the
room coordinator, performs zero provider I/O, finalizes
`providerMutationApplied=false`, and returns `VOICE_PROVIDER_UNAVAILABLE`. The
new kernel is exercised only through hostile test adapters; adding its source
does not enable a RealtimeKit mutation. Therefore the current revision is an
ordered intent-ledger revision, not proof that RealtimeKit state changed. A
client must not render an applied moderation result from the revision alone.

The target live path is asynchronous:

```text
authenticated command
        |
        v
RoomGovernor: intent + revision + lease
        |
        v
pre-armed alarm/outbox dispatcher
        |
        v
at-least-once control Queue -> leased per-action kernel -> provider port
        |                                                  |
        +--------------- retry / DLQ / reconcile <---------+
                             |
                             v
action-specific observation + signed Senti receipt -> bounded read projection
```

Before accepting a command, the object durably pre-arms its alarm and commits
the command row, outbox row, and revision CAS in the same SQLite-backed Durable
Object transaction. A workerd rollback proof sets the alarm, writes SQL, throws,
and observes that neither survives. The alarm publishes an exact four-field,
secret-free envelope—schema version, opaque room ID, command ID, and result
revision—and marks it dispatched only after Queue acceptance. Both Durable
Object alarms and Cloudflare Queues are at-least-once systems, so a crash after
publish but before the dispatch mark may duplicate delivery. The Queue consumer
and every future provider adapter deduplicate by stable command identity and a
fenced execution lease.

Dispatch is mechanically bounded to 32 envelopes per alarm, with a 250 ms
initial coalescing delay and a 250 ms continuation re-arm. One room epoch
retains at most 4,096 commands and then rejects new intake with explicit
backpressure rather than growing without bound. That implies an ideal
scheduling ceiling of 128 envelopes/second per continuously hot room, but it is
not a platform latency SLO. Cross-room scale is horizontal: each opaque
session/epoch room key has an independent Durable Object and outbox. A
33-command workerd proof drains 32 then 1; the 5k/10k hot-room gate remains
unproven and is not weakened by this smaller correctness receipt.

A valid message that exhausts the main consumer enters a mandatory DLQ handled
by the same Worker. An unattempted command terminalizes as `unsupported` with
`resultCode=queue_delivery_exhausted` and
`providerMutationApplied=false`. Once a provider attempt has begun, an
unobserved deadline or exhausted delivery is outcome uncertainty instead:
`status=conflict`, `resultCode=VOICE_CONTROL_CONFLICT`,
`providerStateObserved=false`, and `causalityProven=false`; it omits the legacy
`providerMutationApplied` field because unknown is not false. The room alarm
enforces the matching lease-aware ten-minute deadline from command creation or
attempt start, so neither Queue/DLQ failure nor a missing observation leaves an
eternal command. Any later Queue duplicate observes terminal or
`pending_observation` state and is a no-op. Uncertain Queue send is logged
without identifiers and rethrown, keeping Cloudflare's native alarm retry in
addition to the pre-armed 30-second recovery wake-up.

The asynchronous executor must freshly recheck actor authority and target
membership through a server-to-server Senti path after acquiring its Queue
lease and immediately before provider I/O. It must not persist or replay the
caller's bearer. Authorization unavailable, denied, or expired fails closed;
in particular, authority revoked between intake and execution produces zero
provider calls. Provider operations are set-to-desired-state transitions
rather than toggles. A retry reuses one durable attempt identity and the exact
pinned peer generation. An expired or replaced execution fence never
authorizes a stale worker to call or finalize over a newer fence.

Provider acceptance is not a confirmation receipt. The three independent truth
fields are `providerRequestAccepted`, `providerStateObserved`, and
`causalityProven`; this RealtimeKit kernel can never set the last field true.
After an accepted remove request, the command remains `pending_observation`
until an authoritative exact-peer event matches it. Its only positive terminal
is `desired_state_observed`; neither the state nor result vocabulary says
"confirmed." Past the bounded window, the reconciler records
`VOICE_CONTROL_CONFLICT`; it never silently upgrades an unobserved command to
success. A later signed Senti receipt must preserve this truth ceiling.
Audience delivery uses RealtimeKit's own participant channel and/or a cached,
coalesced `afterRevision` pull. The Durable Object may notify only the bounded
stage set (operational default at most eight publishers); it never loops over
the audience.

There is a current provider gap. RealtimeKit's signed-webhook catalog checked
on 2026-07-29 includes meeting lifecycle, participant join/left, chat export,
recording/livestream status, transcript, and summary events, but no participant
mute, preset, role, or stage-change event. SDK `audioUpdate` and participant
callbacks are unsigned client observations.

The gap is action-specific:

| Action | Available observation | Honest gate |
|---|---|---|
| `remove` | Signed `meeting.participantLeft` for the exact meeting, provider session, participant key, and peer generation, after attempt start | Proves only `desired_state_observed` / `REMOVE_LEAVE_OBSERVED`; causality remains false. |
| `promote` / `demote` | Session participant detail includes `preset_name` | Conditionally confirmable only if the implementation mutates the participant preset and a live capability probe proves readback changes to the expected preset. Stage `grantAccess`/`leave` alone is a separate state and does not qualify. |
| `mute` | Unsigned SDK `audioUpdate` only | Blocked: no signed webhook or backend live-audio readback. |
| `deny_publish` / `allow_publish` | No reviewed authoritative live publish-state observation | Blocked until an authoritative provider surface or different provider adapter exists. |

The reviewed session participant-detail API exposes `preset_name`, `left_at`,
and connection-only peer events (`PEER_CREATED`, `PEER_JOINING`,
`PEER_LEAVING`); it exposes no audio-state transition. Every current action
still uses the unavailable zero-I/O executor. A future action becomes live only
after its own mutation and confirmation adapter passes fault, causality, and
replay tests; one confirmable action does not waive another action's gate.

RealtimeKit's signed join/left payloads distinguish the stable
`customParticipantId` from the connection-specific `peerId`. The room ledger
therefore maintains one ordered active peer generation per opaque participant
key. Stale joins cannot replace a newer generation; an old peer's leave cannot
clear the replacement; and a leave predating `attemptStartedAt` cannot satisfy
the command. At most one nonterminal remove exists for one exact
`(providerSessionId, peerId)` pair, while terminal history does not block a
later rejoin with a new peer ID. The local coordinator retains at most four
inactive, unreferenced peer generations per participant plus active generations
and peers still pinned by nonterminal removes. This bounds reconnect churn
without allowing an evicted stale join to become current; late usage outside
that diagnostic history remains an estimate, never billing truth.

Execution is intentionally stricter than RealtimeKit can currently provide.
The reviewed backend kick API targets permanent participant/custom IDs, not a
connection-specific peer ID. A preflight can compare the live peer with the
pinned peer, but the bound peer can leave and a replacement can rejoin under
the same custom ID between that read and the kick. That preflight-to-kick
TOCTOU window can target the replacement. No production RealtimeKit remove
adapter is eligible until a peer-exact mutation primitive is proven or this
residual receives a separate explicit risk decision and review. This atom does
neither; its production provider port remains unavailable.

Finalized unsupported command identities are currently retained for eight
days as a bounded local proof. Applied results require an explicit production
retention and archive policy that preserves safe retry semantics across the
maximum client retry window.

## 5. Browser and iOS are equal clients

Both clients support:

- join, leave, listen-only, mute, and request-to-speak;
- stage and audience views;
- paginated/searchable roster;
- active-speaker and speaking-state presentation;
- role-appropriate promote, demote, mute, and remove controls;
- connection quality and recovery state;
- request-correlated, copyable failures.

The browser exposes microphone selection and output selection where the
browser implements `setSinkId`. Where it does not, the UI states that the OS
default route is in use rather than showing a fake selector.

iOS supports receiver/earpiece, speaker, wired, and Bluetooth routes through
the system audio session. APNs/PushKit and CallKit remain the invite/wake and
call-lifecycle boundary. WebRTC starts only after authenticated app hydration;
a push payload is never a room credential or membership proof.

RealtimeKit types may exist only inside its adapters. Domain repositories,
Senti event code, views, and governed action contracts depend on
`MediaRoomProvider` or `VoiceMediaTransport`, never on vendor SDK types.

## 6. True agent participant

The north-star agent is a distinct, non-human media participant. It:

1. receives the room mix or attributed participant audio on the server;
2. preserves provider-bound speaker identity;
3. performs STT, reasoning, and TTS under a fenced room-turn lease;
4. handles overlap, interruption, cancellation, and barge-in;
5. publishes one agent audio track to the room;
6. emits final attributed utterances through the same durable projector;
7. has zero authority to execute a governed write.

Any action suggested in conversation still becomes a typed proposal, rendered
preview, exact read-back, single-use confirmation, deterministic execution,
and signed receipt through the existing Senti write path.

The degraded edge-text mode performs STT on each client and may synthesize
agent text locally. It must be labeled `degraded_edge_text`, report its reduced
speaker/room semantics, and never be presented as proof of a true media agent.

### Per-agent voice identity

Every agent principal has a stable, distinct, server-owned
`AgentVoiceProfile`. One generic assistant voice for all agents is not
conforming. A profile versions:

- the agent principal and public voice-profile identity;
- synthesis provider and opaque provider voice reference;
- style/tone policy and bounded tone tags;
- effective/disabled timestamps;
- an honest fallback profile.

The same agent profile is resolved consistently on web and iOS. In the
north-star path, the server uses it to publish one shared room track, so every
listener hears the same agent, timing, and interruption result. In degraded
client-TTS mode, clients receive only safe, non-secret fallback instructions
and label the mode; they do not receive a premium provider credential.

ElevenLabs may be configured later as an optional premium synthesis provider.
Its account key remains server-side. Provider selection and available credit
do not change agent identity, transcript identity, governance, or the fallback
contract. Each durable agent utterance records the voice-profile revision,
synthesis provider/model, output mode, and applied tone tags—never the API key
or private provider response.

The official RealtimeKit AI surface reviewed on 2026-07-29 documents
transcription and summarization. It does not document a server bot, synthetic
audio-track publisher, or full agent participant. A RealtimeKit composite
recording bot is evidence that Cloudflare itself can run a virtual participant;
it is not a supported application API for publishing our TTS audio. The
headless/synthetic-track path is therefore a feasibility experiment, not a
base capability assumption.

## 7. Transcript and no-loss archive

Interim captions are ephemeral. Only finalized, non-empty, speaker-attributed
utterances become durable `session_voice_utterance` evidence.

RealtimeKit currently documents two transcript delivery paths:

- Real-time Deepgram Nova-3 events are delivered to meeting participants.
  Client events may drive captions but are not trusted durable speaker evidence.
  Near-real-time durable projection therefore requires a separately proven
  authenticated server subscriber.
- Post-meeting Whisper Large v3 Turbo output is delivered by the signed
  `meeting.transcript` webhook or fetched through the session transcript REST
  API. RealtimeKit retains it for seven days. This is the safe documented
  baseline for server-side durable ingestion, but it is not itself durable
  Senti storage and must be copied/reconciled before expiry.

The projector verifies provider provenance, binds the provider participant to
a Senti principal on the server, deduplicates by provider event and utterance
identity, and appends the normalized event. A client cannot assert the durable
speaker. Transcript ingestion never grants room membership, stage permission,
or governed-write authority.

The durable path is:

```text
provider webhook or authenticated server subscriber
  -> raw signature / authenticated-channel verification
  -> replay/dedupe guard
  -> server speaker binding
  -> normalized final utterance
  -> append-only Senti event block
  -> asynchronous checkpoint/search/ENGRAM projections
  -> paginated archive manifest and streamed Markdown materialization
```

Delayed and out-of-order provider events are normal. `roomOffsetStartMs`,
`roomOffsetEndMs`, provider event IDs, stable utterance IDs, and reconciliation
cursors preserve deterministic ordering without rewriting prior evidence.
Where the provider file lacks a globally stable segment ID, the projector
derives one deterministically from provider session, participant, room offsets,
and normalized text hash. A correction appends a new utterance with
`revisionOfUtteranceId`; it never overwrites the first observation.

Raw audio is off by default. Where every required consent and retention policy
permits audio capture, the Senti event contains only an encrypted object
reference, content hash, media type, byte count, and retention deadline. It
never contains a presigned URL, credential, or encryption key.

The current Senti Markdown renderer does not recognize voice utterances, and
the current export path can truncate at a bounded event count. Therefore
"download everything said" is not complete until:

- the renderer handles the typed voice event;
- exports are page/manifest based rather than one growing document;
- each page/block has a content hash and covered sequence range;
- the manifest declares completeness and any missing ranges;
- Markdown is streamed or materialized from immutable blocks;
- an interrupted export resumes without omission or duplication.

## 8. ENGRAM integration

Voice finals are immutable observations. ENGRAM asynchronously indexes them by
session, epoch, sequence, room offset, speaker, time, entity, topic, and linked
action/receipt. FTS and dense retrieval feed the existing fusion and graph
model; hierarchical call and session summaries are derived and rebuildable.

Retrieval, embedding, entity extraction, and consolidation failures never
block room media or durable capture. Reindexing uses stable utterance IDs and
redaction versions. Claims such as "instant recall" or ">95% recall" remain
gated by the canonical Needle-Chain, Needle-Scatter, recall, latency, and
faithfulness evaluations in `docs/pocket-memory-spec.md`.

## 9. Request, trace, and error contract

Every entry point accepts or generates `X-Request-Id`. The request ID is
returned in response headers and in the typed error envelope. W3C
`traceparent` propagates through:

```text
join/token -> room control -> provider webhook -> STT -> reasoning -> TTS
-> transcript projector -> Senti append -> governed write -> receipt
```

Relevant records also carry `voiceRoomEpochId`, `turnId`, `utteranceId`, or
`commandId`. Logs and traces use identifiers, durations, counts, state
transitions, and provider status categories. They exclude provider tokens,
bearers, raw audio, transcript text, prompts, and private participant metadata.

The public failure shape is:

```json
{
  "error": {
    "code": "VOICE_JOIN_NOT_AUTHORIZED",
    "message": "You cannot join this voice room.",
    "requestId": "req_01J...",
    "recoverable": false,
    "retryAfterMs": null
  }
}
```

Streaming failures use the same payload as a terminal typed stream event.
Errors are idempotent for one request and must not be synthesized as successful
room, transcript, or write state.

The control stream is resumable by event ID. It emits bounded room snapshots,
terminal errors, and heartbeats; it does not stream the full audience roster.
Clients resume with their last event ID. If the server can no longer fill a
gap, it emits `VOICE_STREAM_RESYNC_REQUIRED` with a request ID and the client
fetches a fresh authorized snapshot and roster page. A reconnect must never
silently skip a moderation or lifecycle transition.

## 10. Entitlements, cost, and kill switches

Billing is deliberately deferred. The first spike still implements the
provider-neutral `VoiceEntitlement`, immutable usage records, quota decisions,
spend alerts, and kill switches. Trial, default, paid, enterprise, and admin
are server-owned policy records, not hard-coded client branches.

The entitlement controls:

- concurrent rooms;
- joined participants per room;
- publishers per room;
- monthly participant minutes;
- monthly transcription minutes;
- monthly agent minutes;
- premium synthesis capability and provider-specific usage reconciliation;
- monthly recording minutes;
- recording, transcription, agent, video, and archive capabilities;
- trial and policy expiry.

Product-admin policy may be effectively unmetered for commercial entitlements,
but no principal bypasses vendor quotas, privacy rules, abuse controls,
availability ceilings, emergency spend caps, or deployment authority.

Quota is enforced at room create, token mint, promote/publish, agent enable,
transcription enable, recording enable, archive retention, and export.
Immutable usage events reconcile against provider usage. Alert thresholds are
80%, 95%, and 100%. Reaching a costly capability limit denies new costly work
gracefully; it does not abruptly drop an active human audio room unless the
emergency safety kill switch requires it.

Current transcription cost has two materially different modes. Official
RealtimeKit documentation lists 836.36 Workers AI Neurons per participant audio
minute for real-time Deepgram and 46.63 for post-meeting Whisper—about 17.9x
different. Real-time transcription is an entitlement/consent decision, not a
silent default. Post-meeting processing may be the lower-cost durable baseline
where live captions are not required.

## 11. Scale record and SLO gates

These are proof targets, not launch claims or usage forecasts:

| Gate | Concurrent rooms | Aggregate joined | Hot room | Max publishers |
|---|---:|---:|---:|---:|
| Two-week YC | 10 | 1,000 | 100 | 8 |
| One-month world-facing | 100 | 50,000 | 5,000 | 16 |
| Three-month stress | 1,000 | 100,000 | 10,000 | 16 |

Until documented provider quota and load receipts clear a gate, operational
defaults remain 50 joined and 8 publishers per room. Audio-only is the
baseline. Video is a separately enabled and metered capability.

Before any moderation executor is labeled live, its provisional control-plane
gate is 100 concurrent rooms, 50 joined per room, at most 8 publishers, and a
moderation burst concentrated on one hot room. The receipt path must show
constant/bounded room-object work as audience size grows; it is not allowed to
pass by reducing the simulated audience to the stage set.

Minimum acceptance measurements:

- join p95 under 2 seconds;
- audio RTT p95 under 300 ms;
- first agent audio under 1.5 seconds for the selected test envelope;
- correct paginated roster and active-speaker state;
- no unauthorized publication after demotion or removal;
- no force-unmute path;
- final transcript loss and duplicate rates reported, with zero silent loss;
- replayed webhooks produce one durable utterance;
- control recovery and state reconstruction under 1 second where applicable;
- 2x admission burst, sustained soak, network loss, reconnect, provider
  throttling, webhook delay/reorder, projector outage, and index outage receipts;
- participant-minute, transcription-minute, agent-minute, provider-error, and
  peak joined/publisher cost telemetry.

The two-week slice requires two physical iPhones, supported browsers, and one
server agent. The one-month and stress gates additionally require provider
quota approval and controlled load infrastructure; a local mock is not
evidence of provider capacity.

## 12. Threat and privacy model

| Threat | Required control |
|---|---|
| Client mints a broader role | Server-derived membership, role, capability, and single-room token |
| Cross-tenant/session join | Tenant/session/epoch binding at every lookup and token mint |
| Stolen join token | Short TTL, single epoch, minimum grants, no persistence/logging, revocation path |
| Forged transcript speaker | Signed provider event plus server-owned participant-to-principal binding |
| Webhook replay/reorder | Raw-body signature verification, durable delivery-ID/digest dedupe, bounded lifecycle and reconciliation rules; no invented signed-timestamp claim |
| Moderator force-unmutes user | No contract action; adapter tests prove absence; user gesture required |
| Agent speech executes a tool | Agent has no write authority; typed proposal plus explicit human confirmation |
| Transcript or prompt leaks | Text/audio excluded from operational logs/traces/errors; retention and redaction policy |
| Signed old webhook is replayed | Verify raw `rtk-signature`; durable `rtk-uuid` dedupe; bounded lifecycle/reconciliation rules |
| Raw audio retained silently | Default off, explicit consent and policy, encrypted object reference only |
| One hot room overloads control | Stateless listener minting, sharded roster, bounded RoomGovernor mutations |
| Room object fans one command to every listener | Provider participant channel and cached/coalesced revision pull; object push limited to bounded stage |
| Crash follows intent commit but precedes provider call | Pre-arm durable alarm, scan durable pending intent, at-least-once Queue, lease-fenced reconcile |
| Queue or alarm redelivers a command | Stable command identity, owner/payload fence, desired-state operation, provider observation before retry |
| Provider state diverges from Senti intent | Remain pending, bounded authoritative observation/retry, then visible conflict; never silent success |
| Two moderators race at one revision | One transactional revision winner; loser receives current revision and visible retry UX |
| Cost runaway | Entitlement checks, immutable meters, 80/95/100 alerts, emergency capability kill switches |
| Provider outage | Human-room degrade/reconnect, circuit breaker, explicit status, provider fallback runbook |
| Index outage loses speech | Append before async index; retry/reconcile by stable utterance ID |
| Export claims completeness falsely | Manifested ranges, hashes, partial marker, resumable pages |

Retention, deletion, legal hold, child safety, abuse reporting, and
jurisdictional recording-consent policy require product/legal review before
production recording or archive retention is enabled.

## 13. Failure modes and rollback

Human audio and governance fail independently:

- If ENGRAM/indexing fails, capture continues and the index backlog is visible.
- If transcript projection fails, media continues and signed provider events
  remain reconcilable; the UI reports transcript degradation.
- If STT/reasoning/TTS fails, the human room continues without the agent.
- If room control is unavailable, existing media follows the provider's safe
  behavior; no new moderator or governed-write success is invented.
- If join authorization is unavailable, new joins fail closed with a request ID.
- If RealtimeKit media fails, clients surface reconnect/degraded status and do
  not silently move to a different provider room.

Provider rollback is an explicit new epoch. Never migrate an active room in
place while preserving the same epoch ID. The provider fallback runbook must:

1. disable new RealtimeKit room creation with a server kill switch;
2. leave active safe rooms untouched or end them deliberately;
3. select the fallback adapter for newly created epochs;
4. preserve Senti identity, roles, event shape, transcript, and usage contracts;
5. mark provider and fallback reason in evidence;
6. prove the same conformance suite before production use.

## 14. Considered alternatives

### Raw Cloudflare Realtime SFU plus Durable Objects

Potentially lower fixed platform cost and high architectural control. Rejected
for the first launch spike because more web/iOS room product plumbing and the
server-agent media adapter are still beta surfaces. It remains a research
option, not an automatic fallback.

### LiveKit

Strongest documented server-agent participant model and mature web/Swift
surface. Not Carter's selected first provider. It is the predefined fallback
only if RealtimeKit cannot satisfy the true-agent contract or measured room
requirements.

### AWS Chime SDK

Viable media primitives but a heavier multi-service assembly for this product
and no advantage that justifies choosing it before the RealtimeKit spike.

### Client-only STT and TTS

Useful offline/degraded mode and cost control. Rejected as the north-star room
architecture because it cannot prove one trustworthy server participant with
room-wide turn-taking and speaker attribution.

## 15. Delivery sequence

1. Review and freeze this ADR and the provider-neutral v1 contract.
2. Build a no-deploy adapter capability probe against documented/local SDK
   surfaces.
3. Obtain explicit account, credential, and external-spend authority before any
   live provider call.
4. Prove one web client, two physical iPhones, and one true server agent.
5. Add signed webhook ingest, typed final utterances, no-loss archive manifest,
   and ENGRAM projection.
6. Add entitlement enforcement, usage reconciliation, alerts, and kill switches.
7. Run conformance, security, accessibility, load, fault, and soak gates.
8. Independently review every exact revision; Forge performs Mac/device/load
   receipts and deploys only under explicit Carter authority.

No step may weaken the existing Pocket confirmation, idempotency, membership,
signature, wrong-session, replay, offline-honesty, or receipt guarantees.

### RealtimeKit capability evidence checked 2026-07-29

| Requirement | Officially documented surface | ADR status |
|---|---|---|
| Single-meeting participant grant | Backend Add Participant API returns participant ID and token; preset chosen server-side | Supported, still wrap as a short-lived secret |
| Stage / raise hand | `requestAccess`, `cancelRequestAccess`, `grantAccess`, `denyAccess`, `join`, `leave`, `kick` | Supported |
| Host mute/remove | Participant `disableAudio`, `kick`; bulk controls and preset permissions | Supported |
| No force-unmute | Documented remote controls disable audio; no remote audio-enable method is documented | Contract-prohibited; adapter absence test required |
| Roster and pagination | Joined participant maps plus count/page/page-count/active-mode APIs | Supported; 5k/10k correctness unproven |
| Active speaker | Web and mobile active-speaker APIs/events | Supported |
| iOS routes | iOS Core release notes cover available-device updates, device selection, earpiece/speaker and Bluetooth fixes | Supported; physical-device receipt required |
| Signed webhooks | Raw body RSA-SHA256 in `rtk-signature`; `rtk-uuid` delivery identity; published public key endpoint | Supported for the documented event catalog |
| Remove observation | Signed `meeting.participantLeft` includes provider session, stable custom ID, and connection-specific peer ID | Exact peer absence is observable; kick causality is not |
| Role/preset readback | Session participant detail returns `preset_name` | Conditional on proving live preset mutation/readback; stage access alone is different state |
| Audio/publish confirmation | No documented mute/publish webhook or backend live-state readback | Blocking gap for mute/deny/allow |
| Post-meeting transcript | Speaker-separated transcript, `meeting.transcript` webhook/REST, seven-day availability | Supported but not durable |
| Real-time transcript | Per-participant Deepgram events delivered to meeting participants | Captions supported; trusted server projection unproven |
| True server voice agent | No documented server bot/synthetic-track publish API in the AI surface | Critical unproven gate |
| High-listener quota | No reviewed official 5k/10k room approval or load receipt | Critical unproven gate |
| Pricing | Beta free; GA participant-minute and export pricing; Workers AI transcription metering | Meter/alert/kill-switch gate |

## 16. Proposed implementation map

This is a path plan, not authority to create or edit the paths:

| Surface | Proposed location | Responsibility |
|---|---|---|
| Provider-neutral server domain | `services/pocket-voice-control/src/domain/` | Room identity/state, entitlements, commands, events, error/result types |
| Cloudflare entry points | `services/pocket-voice-control/src/worker/` | Authenticated join broker, control API/stream, request ID and tracing |
| Bounded room coordination | `services/pocket-voice-control/src/governor/` | Lifecycle, stage/moderation, turn lease, dedupe/cursors |
| RealtimeKit adapter | `services/pocket-voice-control/src/providers/realtimekit/` | Token, preset, participant, webhook, agent-media, usage translation |
| Transcript projector | `services/pocket-voice-control/src/transcript/` | Provider verification, binding, dedupe, final utterance and reconciliation |
| Infrastructure | `services/pocket-voice-control/infra/` | Worker/DO/queues/storage bindings, observability, alerts, kill switches |
| Swift domain/transport | new reviewed Swift package | `VoiceMediaTransport`, snapshots, device routes, RealtimeKit adapter |
| iOS composition | `apps/SentiPocketApp/` | Authenticated repository wiring, CallKit/push lifecycle, views |
| Browser client | SentinelLayer web repository | Equal room/roster/device/moderation UI and stream client |
| Durable Senti event/renderer/export | SentinelLayer API repository | Typed ingest, sequence rendering, archive manifest, streamed Markdown |
| ENGRAM projector | reviewed Pocket/Senti memory lane | Async immutable observation and rebuildable indexes |

The exact service/package names may change during review. The boundaries may
not collapse merely to reduce file count.

### Ownership precondition

The checked-in `OWNERSHIP.md` at the source base still assigns the frozen
`PocketContracts`, app composition, gateway, voice, and security paths to
Atlas, Relay, Echo, and Warden. Carter later directed in the Senti room that
Pulse writes future implementation while Forge reviews and performs
Mac/device/load/deploy work. Carter subsequently confirmed the build-go and
Forge requested a feature-branch handoff for independent review.

The current ruling is recorded at the top of `OWNERSHIP.md`: Pulse authors and
drives the Senti Pocket implementation, while Forge independently reviews it
and owns the Mac, physical-iPhone, load, and authorized deployment receipts.
That current ruling supersedes the older path table where they conflict. It
does not permit edits to frozen `packages/PocketContracts` or shared Xcode
composition without their own review boundaries, and it does not authorize
Cloudflare resources, secrets, paid features, deployment, or spend.

## 17. Current truth

| Claim | State |
|---|---|
| RealtimeKit selected for the spike | Decided |
| Provider-neutral room/event/error/entitlement contract | Versioned and validation-tested |
| RealtimeKit adapter/control-plane slice | Draft PR #122 is hosted-Omar green on exact reviewed head; not merged or deployed; no account/resources |
| Durable moderation ledger/outbox | Built locally with atomic alarm+intent+outbox, bounded Queue drain, leases, DLQ/watchdog terminalization, and unavailable zero-I/O executor |
| REMOVE execution/observation kernel | Built locally behind unavailable production composition: fresh-auth port, signed peer-generation fence, stable attempt retry, exact leave observation, conflict timeout, and three-field truth; live RealtimeKit execution remains blocked by missing authority adapter and non-peer-exact kick TOCTOU |
| Worker checks | Generated types, strict TypeScript, workerd hostile tests, and Wrangler dry-run required at every handoff |
| iOS `VoiceMediaTransport` and RealtimeKit 3.1 adapter | arm64 iOS Simulator build and 65/65 macOS tests independently green; physical-device review pending |
| Server-bound remote iOS roster/stage identity | Not built; the SDK adapter fails closed instead of treating provider correlation IDs as Senti principals |
| Web room integration | Not built |
| True server agent participant | Unproven critical gate |
| 5k/10k hot-room capacity | Unproven load gate |
| Durable typed voice utterance in Senti | Not built |
| Distinct per-agent voice/tone profiles | Contracted; not implemented |
| Voice-aware Markdown no-loss export | Not built |
| ENGRAM voice indexing | Not built |
| Billing | Intentionally not built |
| Usage meters, alerts, entitlements, kill switches | Bounded local estimate/budget only; provider billing truth and operational controls not built |
| Production deploy/provider approval | Not authorized |

## 18. Primary provider references

- [RealtimeKit overview](https://developers.cloudflare.com/realtime/realtimekit/)
- [RealtimeKit pricing and beta status](https://developers.cloudflare.com/realtime/realtimekit/pricing/)
- [RealtimeKit presets](https://developers.cloudflare.com/realtime/realtimekit/concepts/preset/)
- [RealtimeKit participants and tokens](https://developers.cloudflare.com/realtime/realtimekit/concepts/participant/)
- [RealtimeKit stage API](https://developers.cloudflare.com/realtime/realtimekit/core/api-reference/rtkstage/)
- [RealtimeKit participant moderation](https://developers.cloudflare.com/realtime/realtimekit/core/manage-participants-in-a-session/)
- [RealtimeKit remote participants and pagination](https://developers.cloudflare.com/realtime/realtimekit/core/remote-participants/)
- [RealtimeKit active speakers](https://developers.cloudflare.com/realtime/realtimekit/core/display-active-speakers/)
- [RealtimeKit webhooks and RSA-SHA256 verification](https://developers.cloudflare.com/realtime/realtimekit/webhooks/)
- [RealtimeKit Active Session backend API](https://developers.cloudflare.com/api/resources/realtime_kit/subresources/active-session/)
- [RealtimeKit session participant detail](https://developers.cloudflare.com/api/resources/realtime_kit/subresources/sessions/methods/get_session_participant_details/)
- [RealtimeKit transcription, retention, and Workers AI rates](https://developers.cloudflare.com/realtime/realtimekit/ai/transcription/)
- [RealtimeKit AI features](https://developers.cloudflare.com/realtime/realtimekit/ai/)
- [RealtimeKit iOS Core release notes](https://developers.cloudflare.com/realtime/realtimekit/release-notes/ios-core/)
- [Durable Object alarms](https://developers.cloudflare.com/durable-objects/api/alarms/)
- [Cloudflare Queues delivery guarantees](https://developers.cloudflare.com/queues/reference/delivery-guarantees/)
- [Cloudflare Queues dead-letter queues](https://developers.cloudflare.com/queues/configuration/dead-letter-queues/)
- [Cloudflare Agents voice channel](https://developers.cloudflare.com/agents/communication-channels/voice/)
- [Cloudflare Realtime SFU](https://developers.cloudflare.com/realtime/sfu/introduction/)
- [Cloudflare Realtime WebSocket adapter](https://developers.cloudflare.com/realtime/sfu/media-transport-adapters/websocket-adapter/)
- [LiveKit Agents](https://docs.livekit.io/agents/)
- [LiveKit Cloud](https://docs.livekit.io/intro/cloud/)
