# pocket-realtime

Provider-neutral voice-room control plane for Senti Pocket. The first adapter uses
Cloudflare RealtimeKit for media and presence and a SQLite-backed Durable Object
for one room's bounded control state.

This directory is local source only. It has not been deployed, connected to a
Cloudflare account, or used to create billable resources.

## What this slice does

- `POST /v1/voice-rooms/open`
  - requires a real Senti bearer;
  - re-verifies `/api/v1/auth/me` and visible session membership;
  - fails closed until that session response exposes its server-owned `tenantId`;
  - permits only Senti `owner`/`admin`;
  - requires explicit transcript consent and operator-enabled transcription;
  - idempotently provisions one RealtimeKit meeting per `(sessionId, roomEpoch)`.
- `POST /v1/voice-rooms/join`
  - derives `moderator`, `speaker`, or `listener` from server-returned Senti role;
  - permits caller-requested downgrades but never elevation;
  - returns server-derived capabilities plus the opaque provider correlation
    key so the media client can bind self callbacks without confusing that key
    with the canonical Senti principal;
  - returns only a participant join token, never the RealtimeKit API token;
  - marks that token memory-only with a five-minute client discard policy
    because RealtimeKit does not disclose the provider expiry;
  - refreshes the stable participant on a repeated join.
- `POST /v1/voice-rooms/moderate`
  - accepts only the provider-neutral actions in the frozen voice contract and
    rejects client-supplied authority or remote-unmute vocabulary;
  - re-authenticates the current Senti member and requires both current
    owner/admin authority and an active moderator admission;
  - binds the target to the active canonical principal, opaque participant key,
    and provider participant ID before reserving work;
  - HMAC-fingerprints the owner-scoped idempotency key and command payload, so
    the raw key is never stored, logged, or returned;
  - for `remove`, pins the signed RealtimeKit provider session and
    connection-specific peer generation; one nonterminal remove may control
    that exact peer;
  - in one SQLite transaction, writes one durable command intent and advances
    `controlRevision` once, while exact retries return the original record and
    stale or colliding commands return `VOICE_CONTROL_CONFLICT`;
  - currently calls only `UnavailableVoiceControlExecutor`, performs zero
    provider I/O, finalizes the command as `unsupported`, and returns an honest
    `VOICE_PROVIDER_UNAVAILABLE`.
- `POST /v1/voice-rooms/usage`
  - owner/admin only;
  - returns per-room completed participant-presence and a clearly labeled
    transcription-neuron estimate;
  - never presents the estimate as provider billing truth.
- `POST /v1/voice-rooms/roster`
  - re-verifies current Senti membership on every page;
  - returns only server-bound canonical principals and exact signed peer
    generations, never treating provider correlation IDs as authority;
  - requires clients to reject duplicate provider participant IDs as well as
    duplicate principals, correlations, and exact peers across staged pages;
  - pages at most 200 participants from one of sixteen deterministic roster
    shards;
  - binds its opaque HMAC cursor to the room/meeting, shard revision/count
    vector, page position, joined total, and ten-minute expiry;
  - revalidates every shard before the final page and returns
    `VOICE_STREAM_RESYNC_REQUIRED` on any concurrent mutation, so clients can
    discard partial staging instead of displaying an inconsistent roster.
- `POST /v1/realtimekit/webhooks`
  - verifies RSA-SHA256 over the bounded raw body;
  - routes by a non-PII HMAC room locator in the meeting title;
  - deduplicates `rtk-uuid` in SQLite;
  - orders signed participant joins by peer generation and allows a leave to
    observe a remove only for the exact provider session, participant key, and
    peer after the durable attempt began;
  - bounds reconnect history to four inactive unreferenced peers per
    participant, while preserving active and nonterminal-command peers;
  - idempotently mirrors valid participant generations into the sharded roster
    read model before final webhook acceptance;
  - queues only the provider session reference and bounded metadata, never the
    presigned transcript URL or transcript body.

Media and transcript bodies never pass through or persist in the Durable
Object. The room object also performs no audience fanout. The
`TRANSCRIPT_INGEST_QUEUE` consumer and permanent ENGRAM materialization are a
future slice; production activation is blocked until that consumer exists.

An uncomposed scalability kernel adds sixty-four deterministic
`RoomAdmissionShard` objects per room. The first six bits of the
server-derived HMAC participant key choose the shard. Each shard owns bounded
admission leases, monotonic participant revisions, an exact share of the daily
room-admission budget, and the server-owned principal/provider binding. A
room-scoped quota authority is pinned once on provider-identity owner shard
zero, so the sixty-four shards cannot accept different ceilings. A separate
sixty-four-way `RoomProviderIdentityShard` namespace owns irreversible,
room-epoch-scoped provider-ID claims. Completion pins one provider ID locally
before its cross-object RPC, then persists an applied fence/attempt receipt;
crash replay cannot claim a second ID or lose a committed result. A provider
call remains outside the object. An expired lease or ambiguous provider result
becomes sticky `reconciliation_required`; it cannot silently issue a second
create. Both physical DO names and logical shard indices are verified.

Admission timestamps must be exact JavaScript UTC instants
(`YYYY-MM-DDTHH:mm:ss.sssZ`) before a quota day is derived. They remain a
trusted internal server-clock input: this deploy-inert kernel does not defend
against a compromised binding caller deliberately selecting another canonical
day. The future composer must create the value server-side and must never
accept client time. These classes are exported for workerd proof only. The
current `/open` and `/join` handlers do not call them.

Shared in-room agent audio is required but not yet proven on RealtimeKit. Room
descriptors report `unsupported-pending-spike`. Client-TTS of governed edge text
is only a labeled degraded fallback, not the default product path.

## Honest boundary of this slice

This is a tested local control-plane foundation, not a complete or
production-ready Senti Pocket voice implementation.

- The current Senti visible-session response does not expose `tenantId`, so
  real open/join requests intentionally fail closed.
- The shared server track, headless agent participant, per-agent synthesis,
  live moderation/stage executor, web/app integration, and physical-iPhone
  proof are not implemented. The command ledger is not a live executor.
- Every runtime admission still serializes through one per-room Durable
  Object. A sixty-four-way admission ledger kernel now proves the local
  reservation state machine and room-wide provider-ID ownership, but room-open
  priming, lifecycle/revision propagation, `/join` composition, roster
  projection, and moderation revalidation are not wired. Provider-ID
  tombstones are bounded but intentionally unreleased; end-of-epoch retention
  and object disposal must be reviewed before activation. The 5k/10k hot-room
  target remains unproven.
- The roster page itself is sharded and vector-fenced, but initial admission
  and webhook delivery acceptance still touch the room governor. This slice
  does not claim end-to-end hot-room throughput or provider quota.
- `VoiceRosterProjection` stages authenticated pages atomically in the Swift
  package and rejects same-page and cross-page provider participant aliasing,
  but it is not wired into the SDK media adapter/app. This Windows host has no
  Swift toolchain; Mac/iOS compile and device receipts remain pending Forge
  review.
- Alarm/outbox dispatch, the at-least-once Queue/DLQ, leases, and watchdog are
  implemented locally. A provider-neutral REMOVE execution/observation kernel
  is also locally proven with test adapters: execution-time fresh
  authorization, stable attempts, signed peer-generation binding,
  `pending_observation`, exact leave observation, and conflict timeout.
  Production still composes only the unavailable executor, so none of this
  enables a provider call.
- RealtimeKit's current signed webhook catalog does not contain participant
  mute, preset, role, or stage updates. Unsigned SDK callbacks are UX
  observations, not governance proof. Confirmation is action-specific:
  `remove` may earn only `desired_state_observed` /
  `REMOVE_LEAVE_OBSERVED` from an exact signed `participantLeft`;
  `causalityProven` remains false. Promote/demote are conditionally confirmable
  only if implemented as preset mutations and a live probe proves the expected
  `preset_name` through session-participant readback. Mute/deny/allow remain
  blocked because no authoritative live audio/publish state is exposed.
- Current target authorization is bound to the active admission. A future
  asynchronous executor must freshly recheck both actor authority and target
  Senti membership without persisting the caller bearer before any provider
  mutation.
- The fresh-authority port has no production Senti adapter, and RealtimeKit's
  backend kick targets stable participant/custom IDs rather than the signed
  connection-specific peer ID. A preflight cannot eliminate a rapid-rejoin
  TOCTOU window, so the live remove adapter remains unavailable until
  peer-exact mutation is proven or the residual is explicitly accepted and
  independently reviewed.
- Finalized `unsupported` command identities are retained for eight days only.
  Production idempotency/result retention and archive policy must be decided
  before any applied result is possible.
- The expanded command/peer schema descends from unpublished local heads and no
  room Durable Object has been deployed. Any future rollout over an older
  persisted schema requires an explicit migration and rollback proof; this
  slice does not claim one.
- A crash in the current runtime after provider meeting/participant creation
  can leave an orphan or require reconciliation. The uncomposed shard kernel
  prevents a blind duplicate by retaining one stable attempt in
  `reconciliation_required`, but the authoritative provider lookup that must
  resolve that state is not implemented.
- RealtimeKit controls participant-token scope and expiry. The service labels
  that expiry as provider-undisclosed and gives clients a five-minute local
  discard deadline; the deadline is memory hygiene, not provider revocation.
- The transcript Queue consumer, seven-day fetch/materialization workflow,
  ENGRAM indexing, provider billing truth, alerts, entitlements, kill switch,
  rollback exercise, and parity/load/device gates remain backlogged.
- No Cloudflare account, app, Queue, secrets, paid transcription, webhook, or
  deployment has been created or changed by this work.

## Local checks

```text
npm install
npm run check
```

`npm run check` first generates binding/runtime types from `wrangler.jsonc`,
then runs strict TypeScript, workerd/Miniflare tests, and
`wrangler deploy --dry-run`. Generated types stay local and are not hand-edited
or committed. The command does not deploy.

## Deployment-gated configuration

Non-secret bindings live in `wrangler.jsonc`. The checked-in account/app values
are deliberately invalid placeholders and `TRANSCRIPTION_MODE` defaults to
`disabled`, which makes room opening fail closed.

These secrets must be supplied through Worker secret bindings, never source or
client configuration:

- `CLOUDFLARE_API_TOKEN`
- `ROOM_KEY_HMAC_SECRET`
- `IDENTITY_HMAC_SECRET`

`IDENTITY_HMAC_SECRET` is part of the participant identity and shard-routing
derivation. It must remain stable for every live or reconciling room epoch.
Rotation requires an epoch rollover or an explicitly reviewed dual-key
migration. Replacing it in place can orphan or duplicate principal routing and
is forbidden.

Before any authorized deployment:

1. create and inspect least-privilege RealtimeKit presets;
2. expose a server-owned `tenantId` from the Senti visible-session API;
3. replace the account/app placeholders;
4. provision and connect the transcript-ingest consumer;
5. prove or reject the shared-agent-track spike;
6. obtain explicit paid-transcription authorization, then set
   `TRANSCRIPTION_MODE=post-meeting`;
7. implement the fresh Senti authority adapter, resolve the peer-exact remove
   mutation gap, prove each action-specific mutation/observation adapter, and
   implement bounded-pull and receipt projection;
8. compose admission shards only after proving room-open priming, irreversible
   end propagation, revision-floor delivery, authoritative provider
   reconciliation, roster binding, and fresh actor/target revalidation;
9. register the webhook and run signed parity, hot-room moderation, rollback,
   and physical-iPhone gates.

See `docs/architecture/ADR-0001-realtimekit-session-voice.md` for the threat,
cost, scale, and rollout decisions.
