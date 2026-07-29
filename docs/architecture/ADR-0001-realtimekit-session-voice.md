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
| Signed webhooks | Raw body RSA-SHA256 in `rtk-signature`; `rtk-uuid` delivery identity; published public key endpoint | Supported |
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
| RealtimeKit adapter/control-plane slice | Built locally and under feature-branch review; no account/resources |
| Worker checks | Generated types, strict TypeScript, workerd tests, and Wrangler dry-run required at handoff |
| iOS `VoiceMediaTransport` and RealtimeKit 3.1 adapter | Built locally; Mac/Xcode and physical-device review pending |
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
- [RealtimeKit transcription, retention, and Workers AI rates](https://developers.cloudflare.com/realtime/realtimekit/ai/transcription/)
- [RealtimeKit AI features](https://developers.cloudflare.com/realtime/realtimekit/ai/)
- [RealtimeKit iOS Core release notes](https://developers.cloudflare.com/realtime/realtimekit/release-notes/ios-core/)
- [Cloudflare Agents voice channel](https://developers.cloudflare.com/agents/communication-channels/voice/)
- [Cloudflare Realtime SFU](https://developers.cloudflare.com/realtime/sfu/introduction/)
- [Cloudflare Realtime WebSocket adapter](https://developers.cloudflare.com/realtime/sfu/media-transport-adapters/websocket-adapter/)
- [LiveKit Agents](https://docs.livekit.io/agents/)
- [LiveKit Cloud](https://docs.livekit.io/intro/cloud/)
