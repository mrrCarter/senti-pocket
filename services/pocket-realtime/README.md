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
- `POST /v1/voice-rooms/usage`
  - owner/admin only;
  - returns per-room completed participant-presence and a clearly labeled
    transcription-neuron estimate;
  - never presents the estimate as provider billing truth.
- `POST /v1/realtimekit/webhooks`
  - verifies RSA-SHA256 over the bounded raw body;
  - routes by a non-PII HMAC room locator in the meeting title;
  - deduplicates `rtk-uuid` in SQLite;
  - queues only the provider session reference and bounded metadata, never the
    presigned transcript URL or transcript body.

Media and transcript bodies never pass through or persist in the Durable Object.
The `TRANSCRIPT_INGEST_QUEUE` consumer and permanent ENGRAM materialization are
the next slice; production activation is blocked until that consumer exists.

Shared in-room agent audio is required but not yet proven on RealtimeKit. Room
descriptors report `unsupported-pending-spike`. Client-TTS of governed edge text
is only a labeled degraded fallback, not the default product path.

## Honest boundary of this slice

This is a tested local control-plane foundation, not a complete or
production-ready Senti Pocket voice implementation.

- The current Senti visible-session response does not expose `tenantId`, so
  real open/join requests intentionally fail closed.
- The shared server track, headless agent participant, per-agent synthesis,
  moderation/stage controls, web client, and iOS client are not implemented.
- Every admission currently serializes through one per-room Durable Object.
  The 5k/10k hot-room target is unproven and requires a sharded admission/load
  design before production.
- A crash after provider meeting/participant creation can leave an orphan or
  require reconciliation; that provider reconciliation path is not built.
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

Before any authorized deployment:

1. create and inspect least-privilege RealtimeKit presets;
2. expose a server-owned `tenantId` from the Senti visible-session API;
3. replace the account/app placeholders;
4. provision and connect the transcript-ingest consumer;
5. prove or reject the shared-agent-track spike;
6. obtain explicit paid-transcription authorization, then set
   `TRANSCRIPTION_MODE=post-meeting`;
7. register the webhook and run signed parity, load, rollback, and physical
   iPhone gates.

See `docs/architecture/ADR-0001-realtimekit-session-voice.md` for the threat,
cost, scale, and rollout decisions.
