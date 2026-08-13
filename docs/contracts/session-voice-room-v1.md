# Senti session voice-room contract v1

Status: Proposed

Schema version: `session_voice_room.v1`
Wire schema: [`session-voice-room-v1.schema.json`](session-voice-room-v1.schema.json)

This document is the provider-neutral contract for browser, iOS, server room
control, transcript projection, ENGRAM ingestion, usage enforcement, and
request-correlated failures. It is normative. "MUST", "MUST NOT", "SHOULD",
and "MAY" use their RFC 2119 meanings.

## 1. Compatibility rules

1. Every durable or cross-process record MUST carry an explicit
   `schemaVersion`.
2. Consumers MUST reject a different major version and MAY preserve unknown
   fields from the same major version.
3. Identifiers are opaque, case-sensitive strings. Consumers MUST NOT derive
   authorization or tenant identity by parsing an identifier.
4. UTC instants use RFC 3339. Room offsets are non-negative integer
   milliseconds from the provider epoch.
5. Commands MUST be idempotent. Events MUST be immutable.
6. Provider SDK types MUST NOT cross a port boundary.
7. No record may contain an API key, bearer, join token, presigned URL,
   encryption key, raw audio, or unredacted operational secret.

## 2. Stable identity

| Field | Meaning | Authority |
|---|---|---|
| `tenantId` | Owning Senti tenant | Senti server |
| `sentiSessionId` | Durable Senti session | Senti server |
| `voiceRoomEpochId` | One media-room lifecycle inside the session | Room control server |
| `principalId` | Senti human, agent, or service identity | Senti/AIdenID |
| `providerParticipantId` | Provider participant bound to one room epoch | Provider plus server binding |
| `commandId` | One intended mutation | Command originator; deduped by server |
| `utteranceId` | Stable normalized final utterance | Transcript projector |
| `providerEventId` | Provider delivery identity | Provider |
| `providerSegmentId` | Segment identity within one provider delivery/file | Provider or deterministic projector derivation |
| `turnId` | One agent/human conversational turn | Turn coordinator |
| `voiceProfileId` | Stable public synthesis identity for one agent | Voice-profile service |
| `requestId` | One request/error correlation | Edge entry point |
| `traceId` / `traceparent` | Distributed trace correlation | W3C tracing boundary |

The tuple `(tenantId, sentiSessionId, voiceRoomEpochId)` MUST be present at
every authorization, persistence, and adapter lookup. A room ID alone is not
an authorization key.

## 3. Server media provider port

This pseudocode defines behavior, not a source-language ABI:

```text
interface MediaRoomProvider {
  createRoom(ctx: VoiceRequestContext, input: CreateRoomInput)
    -> ProviderRoom

  closeRoom(ctx: VoiceRequestContext, input: CloseRoomInput)
    -> RoomMutationReceipt

  createParticipant(ctx: VoiceRequestContext, input: CreateParticipantInput)
    -> ProviderParticipant

  issueJoinCredential(ctx: VoiceRequestContext, input: IssueJoinCredentialInput)
    -> Sensitive<JoinCredential>

  moderate(ctx: VoiceRequestContext, command: VoiceModerationCommand)
    -> RoomMutationReceipt

  startAgentParticipant(ctx: VoiceRequestContext, input: AgentParticipantInput)
    -> AgentMediaSession

  ingestWebhook(ctx: VoiceRequestContext, delivery: SignedProviderDelivery)
    -> WebhookIngestReceipt

  readUsage(ctx: VoiceRequestContext, window: UsageWindow)
    -> ProviderUsagePage
}
```

Required semantics:

- `createRoom` is idempotent by tenant/session/epoch.
- `createParticipant` accepts a server-derived role and capabilities, not a
  client role.
- `issueJoinCredential` returns a short-lived credential scoped to exactly one
  epoch and participant. `Sensitive<T>` MUST be non-serializable to logs.
- `moderate` accepts only the actions in section 7. There is no remote-unmute
  action.
- `startAgentParticipant` MUST expose real media ingress and egress or return
  `VOICE_AGENT_MEDIA_UNSUPPORTED`. Edge-text is a different capability.
- `ingestWebhook` verifies authenticity before returning accepted, deduplicates
  replay, and treats delivery ordering as non-authoritative.
- `readUsage` is for reconciliation. Provider usage does not replace immutable
  first-party usage events.

## 4. Client media transport port

```text
interface VoiceMediaTransport {
  connect(grant: VoiceJoinGrant) -> VoiceRoomSnapshot
  disconnect(reason: ClientLeaveReason) -> Void
  setMicrophoneEnabled(enabled: Bool) -> VoiceRoomSnapshot
  selectInput(deviceId: OpaqueDeviceId) -> VoiceRoomSnapshot
  selectOutput(routeId: OpaqueRouteId) -> VoiceRoomSnapshot
  raiseHand() -> VoiceRoomSnapshot
  cancelHandRaise() -> VoiceRoomSnapshot
  moderate(command: VoiceModerationCommand) -> VoiceRoomSnapshot
  snapshots() -> AsyncSequence<VoiceRoomSnapshot>
  terminalErrors() -> AsyncSequence<VoiceErrorEnvelope>
}
```

`VoiceJoinGrant` contains non-secret room/role/capability metadata plus an
in-memory opaque credential handle. It MUST NOT be cached, encoded into app
state, or exposed to views. A view consumes snapshots and commands; it does
not call provider SDK APIs.

The browser MAY report `outputSelectionSupported=false`. iOS MAY report only
system routes that are currently available. Neither client may invent an
input/output route.

## 5. Request context

Every command carries:

| Field | Required | Rule |
|---|---|---|
| `requestId` | Yes | Accept or generate at ingress; return in headers and errors |
| `traceparent` | Yes | Valid W3C trace context |
| `traceId` | Yes | Must correspond to `traceparent` |
| `tenantId` | Yes | Server-bound |
| `sentiSessionId` | Yes | Server-bound |
| `voiceRoomEpochId` | Yes after room creation | Never silently substituted |
| `principalId` | Yes | Authenticated server identity |
| `commandId` | Mutations | Stable across safe retries |
| `idempotencyKey` | Mutations | Owner-fenced and operation scoped |
| `expectedRevision` | Serialized mutations | Optimistic concurrency fence |

The same `requestId` MUST NOT be reused for unrelated logical requests.
Idempotent retry of one logical request retains its `commandId` and
`idempotencyKey`; it MAY receive a new transport request ID while linking the
original correlation.

## 6. Room and participant state

Room lifecycle:

```text
provisioning -> open -> draining -> ended
                |          |
                +-------> failed
```

`ended` and `failed` are terminal. Opening the same epoch after a terminal
state is forbidden; create a new epoch.

Participant media state is an observation, not membership authority:

```text
invited -> joining -> joined -> reconnecting -> left
                         |
                         +-> removed
```

Room snapshots MUST include a monotonically increasing control revision.
Provider presence revisions and control revisions are separate. Consumers MUST
not compare them as one clock.

## 7. Roles and moderation

Roles:

- `owner`
- `moderator`
- `speaker`
- `listener`
- `agent`

Allowed moderation actions:

- `promote`
- `demote`
- `mute`
- `remove`
- `deny_publish`
- `allow_publish`

`allow_publish` grants permission; it does not turn on another person's
microphone. `unmute`, `force_unmute`, and semantic equivalents are invalid.

Every moderation command contains actor, target, server-derived actor role,
expected room revision, command ID, and idempotency key. The server rechecks
authorization at execution time. A stale revision returns
`VOICE_CONTROL_CONFLICT` and the current safe snapshot.

## 8. Per-agent voice profile

Every agent principal MUST resolve to one active, versioned
`AgentVoiceProfile`. A room MUST NOT collapse distinct agents onto one generic
assistant profile. The profile is server-owned and contains:

- `voiceProfileId`, `tenantId`, and `agentPrincipalId`;
- monotonic `revision`;
- user-facing `displayName`;
- open, provider-neutral `synthesisProvider`;
- opaque `providerVoiceRef`;
- `stylePolicyId` and bounded `toneTags`;
- optional `fallbackVoiceProfileId`;
- effective and disabled timestamps.

The public profile identity is stable even when a provider or provider voice
changes. A profile revision is immutable after use; changes create the next
revision. Two simultaneously active agent principals in one room MUST resolve
to distinct effective voice profiles and distinct provider voice references
unless Carter explicitly defines a shared-character exception.

Provider credentials are not profile fields. They remain server-side and MUST
NOT enter web/iOS state, Senti events, logs, traces, errors, or screenshots.
An opaque provider voice reference is not authority to call that provider.

An agent utterance MUST include synthesis provenance:

- voice profile ID and revision;
- synthesis provider and model;
- `shared_room_track` or `degraded_client_tts` output mode;
- applied bounded tone tags.

Human utterances MUST NOT contain synthesis provenance. In degraded mode,
clients receive safe fallback rendering instructions, never a premium-provider
key. A fallback that cannot preserve the exact premium voice remains the same
agent identity but MUST be presented as a fallback, not a byte/voice-equivalent
render.

ElevenLabs MAY be one synthesis provider when Carter provisions credit and
server-side credentials. It is not hard-coded into the domain contract.

```json
{
  "schemaVersion": "agent_voice_profile.v1",
  "voiceProfileId": "voice_profile_forge",
  "tenantId": "tenant_demo",
  "agentPrincipalId": "agent_forge",
  "revision": 3,
  "displayName": "Forge",
  "synthesisProvider": "elevenlabs",
  "providerVoiceRef": "voice_forge_01",
  "stylePolicyId": "agent_tone_forge.v1",
  "toneTags": [
    "direct",
    "measured"
  ],
  "fallbackVoiceProfileId": "voice_profile_forge_ondevice",
  "effectiveAt": "2026-07-29T07:00:00.000Z",
  "disabledAt": null
}
```

## 9. Durable `session_voice_utterance`

Only a final utterance may use this type. Interim text MUST NOT enter Senti as
this event.

Normative example:

```json
{
  "schemaVersion": "session_voice_utterance.v1",
  "event": "session_voice_utterance",
  "tenantId": "tenant_demo",
  "sentiSessionId": "session_demo",
  "voiceRoomEpochId": "vre_01JABC",
  "utteranceId": "utt_01JABD",
  "provider": "realtimekit",
  "providerEventId": "rtk_event_901",
  "providerSegmentId": "segment_1",
  "projectorPrincipalId": "svc_voice_projector",
  "speaker": {
    "principalId": "agent_forge",
    "providerParticipantId": "rtk_agent_forge",
    "providerTrackId": "rtk_track_agent_forge",
    "kind": "agent",
    "role": "agent",
    "bindingAuthority": "server"
  },
  "timing": {
    "roomOffsetStartMs": 1200,
    "roomOffsetEndMs": 3580,
    "startedAt": "2026-07-29T07:00:01.200Z",
    "endedAt": "2026-07-29T07:00:03.580Z"
  },
  "transcript": {
    "text": "I recommend RealtimeKit for the human-room spike.",
    "language": "en-US",
    "confidence": 0.98,
    "model": "provider-model-version",
    "isFinal": true,
    "redactionVersion": "voice-redaction.v1",
    "consent": {
      "transcriptAllowed": true,
      "audioRetentionAllowed": false,
      "policyId": "voice-consent.v1"
    }
  },
  "correlation": {
    "requestId": "req_01JABE",
    "traceId": "4bf92f3577b34da6a3ce929d0e0e4736",
    "traceparent": "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
    "turnId": "turn_01JABF",
    "causationId": "rtk_session_88"
  },
  "synthesis": {
    "voiceProfileId": "voice_profile_forge",
    "voiceProfileRevision": 3,
    "provider": "elevenlabs",
    "model": "configured-model",
    "outputMode": "shared_room_track",
    "toneTags": [
      "direct",
      "measured"
    ]
  },
  "contentHash": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "recordedAt": "2026-07-29T07:00:04.000Z"
}
```

Projector invariants:

1. `speaker.bindingAuthority` MUST equal `server`.
2. The provider participant MUST already be bound to the stated principal,
   tenant, session, and epoch.
3. `transcript.isFinal` MUST be `true`; text MUST be non-empty after the
   projector's explicit normalization policy.
4. End offset and time MUST be at or after start offset and time.
5. `contentHash` covers the canonical normalized event excluding the hash
   field itself and mutable projection metadata.
6. The unique durable key is
   `(tenantId, sentiSessionId, voiceRoomEpochId, utteranceId)`.
7. A second provider delivery with the same `providerEventId` is a replay.
   A delivery containing multiple utterances uses `providerSegmentId` to
   distinguish them. If the provider supplies no stable segment ID, the
   projector deterministically derives one from provider session, participant,
   offsets, and normalized text hash.
8. A conflicting event for an existing durable key fails closed and emits an
   integrity alert; it never overwrites the first observation.
9. Redaction produces a new derived version linked to the immutable original
   according to retention policy; it does not silently rewrite signed history.
10. Audio metadata is absent unless transcript and audio-retention consent are
    both true and policy permits it.
11. Corrections append a new utterance with `revisionOfUtteranceId`; the
    original remains immutable.
12. An agent speaker requires synthesis provenance bound to that agent's active
    voice-profile revision. A human speaker forbids it.

## 10. Optional audio reference

The optional `audio` object contains:

- opaque `objectRef`;
- `mediaType`;
- `byteCount`;
- SHA-256 content hash;
- `encrypted=true`;
- retention deadline.

It MUST NOT contain a URL, query string, bearer, provider credential, key ID
that reveals tenant secrets, or decryption material. Access is separately
authorized and audited.

## 11. Voice entitlement

`VoiceEntitlement` is server-owned and versioned. Required product limits:

- `maxConcurrentRooms`
- `maxJoinedPerRoom`
- `maxPublishersPerRoom`
- `participantMinutesMonthly`
- `transcriptionMinutesMonthly`
- `agentMinutesMonthly`
- `recordingMinutesMonthly`

Required capability flags:

- `transcriptionAllowed`
- `agentAllowed`
- `recordingAllowed`
- `videoAllowed`
- `archiveExportAllowed`

`policyClass` is one of `trial`, `default`, `paid`, `enterprise`, or `admin`.
Clients render resulting capabilities; they do not branch on policy class.
Explicit numeric limits remain subject to smaller server safety ceilings and
provider quotas. An admin policy does not mean infinite infrastructure or
bypass privacy and abuse rules.

Entitlement decisions are checked at room create, join credential mint,
promotion/publication, and enabling an agent, transcription, recording, video,
retention, or export. A decision emits telemetry with IDs and quantities but no
transcript or credential.

## 12. Immutable usage event

`VoiceUsageEvent` meters one observation:

- `participant_minute`
- `transcription_minute`
- `agent_minute`
- `recording_minute`
- `room_peak_joined`
- `room_peak_publishers`
- `provider_error`

Usage is append-only, idempotent by provider event plus metric identity, and
reconciled with provider reports. Corrections are compensating events, not
updates. Alert state at 80%, 95%, and 100% is derived.

## 13. Error envelope

All HTTP and terminal stream errors use:

```json
{
  "error": {
    "code": "VOICE_CONTROL_CONFLICT",
    "message": "The room changed before this command could be applied.",
    "requestId": "req_01JABE",
    "recoverable": true,
    "retryAfterMs": 0
  }
}
```

Canonical codes:

| Code | Recoverable default | Meaning |
|---|---:|---|
| `VOICE_BAD_REQUEST` | No | Invalid shape or unsupported major version |
| `VOICE_NOT_AUTHENTICATED` | No | Missing or invalid product authentication |
| `VOICE_JOIN_NOT_AUTHORIZED` | No | No current session membership/grant |
| `VOICE_ENTITLEMENT_EXCEEDED` | Sometimes | Product limit denies new costly work |
| `VOICE_PROVIDER_QUOTA_EXCEEDED` | Sometimes | Provider/platform ceiling reached |
| `VOICE_ROOM_NOT_FOUND` | No | Epoch does not exist in requested session |
| `VOICE_ROOM_ENDED` | No | Epoch is terminal |
| `VOICE_CONTROL_CONFLICT` | Yes | Revision fence failed |
| `VOICE_PROVIDER_UNAVAILABLE` | Yes | Provider dependency unavailable |
| `VOICE_AGENT_MEDIA_UNSUPPORTED` | No | True server media agent seam unavailable |
| `VOICE_TRANSCRIPT_DEGRADED` | Yes | Capture/projector is delayed or unavailable |
| `VOICE_EXPORT_PARTIAL` | Yes | Manifest contains missing/unavailable ranges |
| `VOICE_STREAM_RESYNC_REQUIRED` | Yes | Retained control events cannot fill a resume gap |
| `VOICE_INTERNAL` | Maybe | Safe unexpected failure with request ID |

`message` is safe for end users. It MUST NOT echo transcript, prompt, token,
provider body, stack trace, participant private data, or policy internals.
`retryAfterMs` is `null` when retry is not advised.

## 14. Resumable control and error stream

The browser and iOS control stream carries bounded snapshots, terminal errors,
and heartbeats. It MUST NOT carry provider credentials, transcript text, raw
audio, a full unbounded roster, or governed-write secrets.

Each `voice_control_stream_event.v1` contains:

- stable `eventId`;
- monotonically increasing per-epoch `sequence`;
- tenant/session/epoch identity;
- `requestId`;
- emitted timestamp;
- exactly one of `snapshot`, `error`, or `heartbeat`.

A snapshot includes control revision, provider-presence revision, lifecycle,
the current participant, bounded stage participants, active speakers,
connection state, and roster count/cursor metadata. The audience roster is a
separately authorized, paginated read model.

Clients resume with the last event ID. A server MAY replay already observed
events; the client deduplicates by event ID. It MUST NOT silently bridge an
unknown gap. If the retained stream cannot satisfy resume, it emits
`VOICE_STREAM_RESYNC_REQUIRED`; the client fetches a fresh snapshot and roster
page, then resumes from the returned sequence.

Every terminal stream error contains the exact error envelope from section 13.
Heartbeat events contain no semantic state beyond current control revision and
time. UI state MUST NOT turn a transport heartbeat into a successful room or
moderation result.

## 15. Webhook and transcript ordering

Provider deliveries are at-least-once and may be late or out of order.
Authenticity, freshness/replay policy, dedupe, and parsing happen before
projection.
Acknowledging a valid delivery means it is durably accepted for processing,
not that every downstream index is already current.

For RealtimeKit, the adapter verifies RSA-SHA256 `rtk-signature` against the
exact raw request bytes using the published webhook public key. It deduplicates
the `rtk-uuid` delivery ID and records `rtk-webhook-id`. The documented headers
do not provide a signed delivery timestamp, so the adapter MUST NOT claim
cryptographic age/freshness from an unsigned local receive time. Durable
delivery dedupe plus valid lifecycle/reconciliation bounds provide replay
control.

The projector records:

- high-water provider cursor where one exists;
- seen provider event IDs;
- per-epoch reconciliation window;
- last successful durable Senti sequence;
- backlog age and count;
- dead-letter identity and safe reason category.

Recovery replays from the provider or accepted-delivery store and is
idempotent. It never depends on one in-memory process.

## 16. No-loss export contract

An archive manifest contains:

- tenant/session identity;
- included voice epoch IDs;
- Senti sequence and time ranges;
- immutable page/block identifiers and hashes;
- utterance count;
- missing ranges;
- `complete` boolean;
- renderer and redaction versions;
- generated timestamp and request ID.

`complete=true` is legal only when every declared source range is covered.
Markdown is a rendering of the manifest's blocks, not the source of truth.
Pagination and resume MUST neither omit nor duplicate an utterance.

## 17. ENGRAM projection contract

Every final utterance becomes an immutable ENGRAM observation referencing the
Senti event and stable utterance ID. Index records MAY contain lexical text,
embedding, speaker, time, entity, topic, action, and graph bindings under the
privacy policy. Derived indexes MUST be rebuildable.

Index failure:

- MUST NOT roll back the Senti append;
- MUST expose backlog age/count;
- MUST retry idempotently;
- MUST preserve the source redaction version;
- MUST NOT claim search/recall completeness while behind.

## 18. Cross-field validators

JSON Schema validates record shape. Domain validation MUST additionally reject:

- a timing end before its start;
- a `traceId` that differs from the trace ID encoded in `traceparent`;
- an audio reference when `audioRetentionAllowed` is false;
- `maxPublishersPerRoom` greater than `maxJoinedPerRoom`;
- a trial expiry outside the entitlement validity window;
- minute metrics with a unit other than `minute`;
- room peak metrics with a unit other than `participant`;
- `provider_error` with a unit other than `error`;
- a client-supplied actor role or speaker binding that does not match
  server-owned identity;
- an agent utterance without synthesis provenance, or a human utterance with it;
- two active room agents resolving to the same effective voice profile or
  provider voice reference without an explicit product exception;
- reuse of an owner-fenced idempotency key by a different principal or payload.

These checks require comparisons or trusted server context and therefore are
not represented as misleading shape-only constraints.

## 19. Conformance gates

An adapter is not conforming until independent receipts cover:

### Contract and security

- wrong-tenant/session/epoch join rejected;
- client role escalation rejected;
- expired/single-room token rejected elsewhere;
- credential absent from logs, traces, errors, events, and snapshots;
- unsupported schema major rejected;
- same idempotency key and same command returns the same result;
- same idempotency key with different content fails closed;
- remote unmute is absent and cannot be synthesized;
- replayed webhook yields one durable utterance;
- conflicting utterance identity cannot overwrite evidence;
- transcript event cannot authorize a write;
- agent utterance cannot bypass human confirmation.

### Client behavior

- browser input and supported output selection;
- honest output fallback where unsupported;
- iOS receiver, speaker, wired, and Bluetooth routing;
- foreground/background/rejoin behavior;
- VoiceOver, keyboard, focus, dynamic type, contrast, and responsive roster;
- stale room/participant callbacks cannot corrupt a new epoch.
- each agent keeps a distinct stable voice/tone profile across web and iOS;
- premium-provider loss produces a labeled, non-secret fallback without
  changing agent identity.

### Media and resilience

- two physical iPhones, one supported browser, and one server agent;
- join, leave, reconnect, promotion, demotion, mute, remove, and barge-in;
- provider throttle/outage and network loss;
- delayed/reordered/replayed webhook;
- projector and ENGRAM outage with later reconciliation;
- kill-switch and new-epoch fallback;
- soak, burst, hot-room, many-room, transcript-integrity, and cost receipts
  for the gate being claimed.

### Delivery

- unit, contract, integration, and real end-to-end tests;
- IaC and drift detection before deployment;
- request/trace dashboards and safe alerts;
- dependency/SBOM and artifact provenance;
- rollback and provider fallback rehearsal;
- independent exact-revision review plus physical-device gate.

Passing local mocks proves contract logic only. It does not prove provider
features, quota, latency, scale, billing, or production readiness.
