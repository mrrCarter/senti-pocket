# live-call transport

Server side of multi-party live voice (PHONE05). Turns a Senti session into a call room:
members join over a WebSocket signaling channel, the room decides **who hears whom** by a
floor policy, and each client is told exactly which remote tracks to subscribe to on the
Cloudflare Realtime SFU.

## Layers

| File | Role | Verified by |
| --- | --- | --- |
| `call-room.mjs` | Membership + capacity + idle sweep + floor (`open` / `round-robin` / `moderated`) + who-hears-whom | unit tests |
| `signaling.mjs` | Typed message → CallRoom op, returns fresh subscriptions + state | unit tests |
| `cf-realtime-sfu.mjs` | Thin CF Realtime HTTP adapter (Bearer App Secret, SDP passed through) + `remoteTracksForListener` | unit tests |
| `call-fanout.mjs` | Per-listener subscribe directives (subscriptions × published tracks) | unit tests |
| `call-do.mjs` | Durable Object: hibernatable WS, role-gated floor, mint-bound tracks, reconnect-kick, sweep, rebuild | unit tests (mocked CF runtime) |
| `worker.mjs` | Edge router: fail-closed (session,room) auth, host-pin, token-strip, DO routing, SFU mint + bind | unit tests (helpers) |
| `join-call.mjs` | In-process demo of floor routing (no network) | `node join-call.mjs demo` |

The decision logic is pure and unit-tested with no network. The DO's orchestration (identity anti-spoof, floor-role
gate, mint-binding, reconnect, sweep, hibernation rebuild) is unit-tested against a mocked CF runtime, and the
Worker's auth/forward helpers are unit-tested directly. The **live WebSocket upgrade + real CF Realtime negotiation**
still only run under deploy / miniflare — do not read the green unit suite as proof the end-to-end socket path works.

## Signaling protocol (client ⇄ DO over the WS)

Client → DO (JSON): `{ type, ... }` where `type` ∈
`join | leave | touch | set-floor | grant-floor | advance-floor | roster`.
On `join`, a client that has already negotiated its publish with the SFU includes
`cfSessionId` + `cfTrackName` — accepted **only if they match a session the Worker minted for that
participant** (a client cannot claim another's CF session). `participantId` / `sessionId` on
`join`/`leave`/`touch` are **ignored and overwritten** with the identity bound to the socket at
accept time (anti-spoof). `grant-floor`'s `participantId` is the grantee. **Floor ops**
(`set-floor` / `grant-floor` / `advance-floor`) are privileged — **owner/admin only**, by the
gateway role carried in the socket; anyone else gets `ack ok:false reason:'forbidden-role'`. A
reconnecting participant **kicks its own stale socket**; messages over 16 KiB are rejected.

DO → client (JSON):
- `{ type:'ack', op, ok, reason?, state }` — the result of the sender's own op.
- `{ type:'directives', state, subscriptions, remoteTracks }` — broadcast to every member after
  any change; `remoteTracks` is the exact CF `tracks/new` subscribe body for that listener.

## Authorization (mirrors the gateway — not a reinvention)

The Pocket gateway holds **no signing key**: it authorizes by forwarding the caller's own Senti bearer to the
SentinelLayer API and trusting the returned role (`senti-target-membership.mjs`). So this Worker mints nothing — it
forwards the **client's own bearer** to a configured gateway authorize endpoint, which returns a member role + the
participant id the **gateway** bound to that bearer for the **(session, room)** pair (the caller never chooses its own
id or room — those shapes are the confused-deputy / room-squatting bugs). The DO is keyed by
`${encode(session)}::${encode(room)}`, so one session can't reach (or collide into) another's room. Fail-closed:
`GATEWAY_AUTHORIZE_URL` or `GATEWAY_HOST` unset, or the URL host ≠ `GATEWAY_HOST`, and every `/call/*` route 403s; the
authorize fetch is `redirect:'manual'` + 3 s timeout, and the gateway must echo the (session, room) it authorized.
The WS forward is **GET-only** and a **fresh** request — no client header or body (the bearer, any
`x-live-call-internal`, any POST body) reaches the DO. Every SFU op is authorized against the DO, which owns the
per-participant minted sessions + the room's published set: `/sfu/session` is mint-capped per participant, and
`/sfu/tracks` + `/sfu/renegotiate` accept only a sessionId minted for that participant with remote tracks drawn only
from the room's published set. The Worker↔DO internal ops live at an **exact path** gated by a **required**
`INTERNAL_BIND_KEY` (no default), unreachable by any client request.

The exact authorize endpoint is being **co-designed with warden** (gateway owns `/dial` + the resolver; a store-backed
one-time join grant via the existing `dialSignalStore` is one candidate). Until it's wired, deploy stands up the
transport but admits no one — intentionally.

Routes: `GET /call/:room/ws` (WS signaling), `POST /call/:room/sfu/session` (mint — also binds the minted CF session
to the participant inside the DO), `POST /call/:room/sfu/tracks`, `POST /call/:room/sfu/renegotiate`, `GET /health`.

## Deploy (needs CF Realtime app + wrangler; co-set up with warden)

```sh
cd tools/live-call
# one-time secrets (NEVER committed):
wrangler secret put CF_REALTIME_APP_SECRET   # CF Realtime App Secret (stays server-side)
wrangler secret put INTERNAL_BIND_KEY        # Worker->DO minted-session bind key (defense-in-depth)
# set CF_REALTIME_APP_ID + GATEWAY_AUTHORIZE_URL + GATEWAY_HOST in wrangler.toml [vars], then:
wrangler deploy
```
