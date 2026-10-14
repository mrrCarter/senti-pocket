// tools/live-call/call-do.mjs
//
// Durable Object that hosts ONE live-call room (one per authorized (session, room) pair): a CallRoom + the
// CF-Realtime track registry, driven over a WebSocket signaling channel. Uses the WebSocket Hibernation API so an
// idle call costs nothing yet survives eviction. Every socket's identity (participantId, sessionId, role) is bound at
// accept from the Worker's AUTHORIZED values and is never trusted from a message body.
//
// Security glue warden required:
//   - floor control (set/grant/advance) is owner/admin only, by the gateway role carried in the socket;
//   - published CF coords are accepted only if they match a session the Worker MINTED for that participant;
//   - Worker-only internal ops (bind / mint-reserve / sfu-authz) are reachable ONLY at an exact path with a
//     configured key (NO default) — the Worker forwards GET-only fresh upgrades, so a client can never reach them;
//   - SFU session minting is capped per participant; renegotiate/pull is authorized against the owned + published set.

import { createCallRoom } from './call-room.mjs';
import { handleSignal } from './signaling.mjs';
import { buildFanout } from './call-fanout.mjs';

export const INTERNAL_OP_PATH = '/__live-call/internal/op'; // exact path; the client can never cause a forward here
const SWEEP_INTERVAL_MS = 30000;
const MAX_MSG_BYTES = 16 * 1024;
const MINT_CAP = 5; // per-participant active-mint cap
const FLOOR_OPS = new Set(['set-floor', 'grant-floor', 'advance-floor']);
const FLOOR_ROLES = new Set(['owner', 'admin']);
const decode = (raw) => (typeof raw === 'string' ? raw : new TextDecoder().decode(raw));
const json = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

// Constant-time string compare for the internal key (content compare doesn't short-circuit; length is allowed to leak).
function ctEqual(a, b) {
  const x = typeof a === 'string' ? a : '';
  const y = typeof b === 'string' ? b : '';
  if (x.length !== y.length) return false;
  let diff = 0;
  for (let i = 0; i < x.length; i += 1) diff |= x.charCodeAt(i) ^ y.charCodeAt(i);
  return diff === 0;
}

export class CallRoomDO {
  constructor(state, env) {
    this.state = state;
    this.env = env;
    this.publishedTracks = {}; // participantId -> { sessionId, trackName } actually published
    this.mintedTracks = {}; // participantId -> cfSessionId the Worker minted (authoritative)
    this.mintCount = {}; // participantId -> active mint count (cap)
    this.sockets = new Map();
    this.meta = { roomId: '', sessionId: '', floor: 'open', holder: null };

    state.blockConcurrencyWhile(async () => {
      this.meta = (await state.storage.get('meta')) || this.meta;
      this.mintedTracks = (await state.storage.get('mintedTracks')) || {};
      this.mintCount = (await state.storage.get('mintCount')) || {};
      this.room = createCallRoom({
        roomId: this.meta.roomId || 'room',
        sessionId: this.meta.sessionId || 'pending',
        floor: this.meta.floor || 'open',
        isMember: () => true,
      });
      for (const ws of state.getWebSockets()) {
        const a = ws.deserializeAttachment();
        if (!a?.participantId || !this.meta.sessionId) continue;
        this.sockets.set(a.participantId, ws);
        this.room.join({ participantId: a.participantId, sessionId: a.sessionId, trackId: a.trackId });
        if (a.published) this.publishedTracks[a.participantId] = a.published;
      }
      if (this.meta.floor && this.meta.floor !== 'open') this.room.setFloor(this.meta.floor);
      if (this.meta.holder) this.room.grantFloor(this.meta.holder);
    });
  }

  async fetch(request) {
    const url = new URL(request.url);

    // Worker-only internal ops: EXACT path + configured key (never a default). The Worker forwards external WS traffic
    // as a fresh GET upgrade to the /ws URL, so this path is unreachable by any client request.
    if (request.method === 'POST' && url.pathname === INTERNAL_OP_PATH) {
      const key = this.env.INTERNAL_BIND_KEY;
      if (!key || !ctEqual(request.headers.get('x-live-call-internal'), key)) return json({ ok: false }, 403);
      return this.handleInternal((await request.json().catch(() => ({}))) || {});
    }

    if (request.headers.get('Upgrade') !== 'websocket') return new Response('expected websocket', { status: 426 });
    const participantId = url.searchParams.get('participant') || '';
    const sessionId = url.searchParams.get('session') || '';
    const role = url.searchParams.get('role') || 'viewer';
    if (!participantId || !sessionId) return new Response('missing participant/session', { status: 400 });

    if (!this.meta.sessionId) {
      this.meta.roomId = url.searchParams.get('room') || 'room';
      this.meta.sessionId = sessionId;
      this.meta.floor = this.meta.floor || 'open';
      await this.persistMeta();
      this.room = createCallRoom({ roomId: this.meta.roomId, sessionId, floor: this.meta.floor, isMember: () => true });
    }
    if (sessionId !== this.meta.sessionId) return new Response('wrong-session', { status: 403 });

    const prior = this.sockets.get(participantId);
    if (prior) {
      try {
        prior.close(1012, 'reconnected');
      } catch {
        /* already gone */
      }
    }

    const { 0: client, 1: server } = new WebSocketPair();
    this.state.acceptWebSocket(server, [participantId]);
    server.serializeAttachment({ participantId, sessionId, role });
    this.sockets.set(participantId, server);
    this.room.sweep();
    await this.ensureAlarm();
    return new Response(null, { status: 101, webSocket: client });
  }

  async handleInternal(b) {
    const pid = typeof b.participantId === 'string' ? b.participantId : '';
    if (!pid) return json({ ok: false, reason: 'no-participant' }, 400);
    if (b.op === 'mint-reserve') {
      const count = this.mintCount[pid] || 0;
      if (count >= MINT_CAP) return json({ ok: false, reason: 'mint-cap' });
      this.mintCount[pid] = count + 1;
      await this.state.storage.put('mintCount', this.mintCount);
      return json({ ok: true });
    }
    if (b.op === 'bind') {
      if (typeof b.cfSessionId === 'string' && b.cfSessionId) {
        this.mintedTracks[pid] = b.cfSessionId;
        await this.state.storage.put('mintedTracks', this.mintedTracks);
      }
      return json({ ok: true });
    }
    if (b.op === 'sfu-authz') {
      const owns = Boolean(this.mintedTracks[pid]) && this.mintedTracks[pid] === b.sessionId;
      const published = new Set(Object.values(this.publishedTracks).map((t) => t.sessionId));
      const remoteOk = (Array.isArray(b.remoteSessionIds) ? b.remoteSessionIds : []).every((s) => published.has(s));
      return json({ ok: owns && remoteOk });
    }
    return json({ ok: false, reason: 'unknown-op' }, 400);
  }

  async webSocketMessage(ws, raw) {
    const text = decode(raw);
    if (text.length > MAX_MSG_BYTES) return ws.send(JSON.stringify({ type: 'error', reason: 'message-too-large' }));
    let msg;
    try {
      msg = JSON.parse(text);
    } catch {
      return ws.send(JSON.stringify({ type: 'error', reason: 'bad-json' }));
    }
    const att = ws.deserializeAttachment() || {};

    if (msg.type === 'join') {
      msg.participantId = att.participantId; // anti-spoof
      msg.sessionId = att.sessionId;
      if (msg.cfSessionId && msg.cfTrackName && this.mintedTracks[att.participantId] === msg.cfSessionId) {
        this.publishedTracks[att.participantId] = { sessionId: msg.cfSessionId, trackName: msg.cfTrackName };
        ws.serializeAttachment({ ...att, trackId: msg.trackId, published: this.publishedTracks[att.participantId] });
      }
    } else if (msg.type === 'leave' || msg.type === 'touch') {
      msg.participantId = att.participantId;
    } else if (FLOOR_OPS.has(msg.type) && !FLOOR_ROLES.has(att.role)) {
      return ws.send(JSON.stringify({ type: 'ack', op: msg.type, ok: false, reason: 'forbidden-role', state: this.room.state() }));
    }

    const res = handleSignal(this.room, msg);
    if (msg.type === 'leave') this.forget(att.participantId);
    if (FLOOR_OPS.has(msg.type) && res.state) {
      this.meta.floor = res.state.floor;
      this.meta.holder = res.state.holder;
      await this.persistMeta();
    }
    ws.send(JSON.stringify({ type: 'ack', op: msg.type, ok: res.ok, reason: res.reason, state: res.state }));
    this.broadcast();
  }

  async webSocketClose(ws) {
    const att = ws.deserializeAttachment() || {};
    if (!att.participantId) return;
    if (this.sockets.get(att.participantId) === ws || !this.sockets.has(att.participantId)) {
      this.room.leave(att.participantId);
      this.forget(att.participantId);
      this.broadcast();
    }
  }

  async webSocketError(ws) {
    return this.webSocketClose(ws);
  }

  forget(participantId) {
    // NB: mintCount is NOT reset here. It is a durable per-participant lifetime count — resetting it on leave/close
    // would let a viewer mint, leave, and re-mint without bound (the CF sessions are not closed server-side).
    this.sockets.delete(participantId);
    delete this.publishedTracks[participantId];
    delete this.mintedTracks[participantId];
    void this.state.storage.put('mintedTracks', this.mintedTracks);
  }

  broadcast() {
    const { directives } = buildFanout(this.room, this.publishedTracks);
    for (const ws of this.state.getWebSockets()) {
      const att = ws.deserializeAttachment() || {};
      const d = directives[att.participantId];
      if (!d) continue;
      try {
        ws.send(JSON.stringify(d));
      } catch {
        /* a closing socket is swept by the alarm */
      }
    }
  }

  async ensureAlarm() {
    if ((await this.state.storage.getAlarm()) === null) await this.state.storage.setAlarm(Date.now() + SWEEP_INTERVAL_MS);
  }

  async alarm() {
    const dropped = this.room.sweep();
    for (const id of dropped) {
      const ws = this.sockets.get(id);
      if (ws) {
        try {
          ws.close(1000, 'idle-timeout');
        } catch {
          /* already gone */
        }
      }
      this.forget(id);
    }
    if (dropped.length) this.broadcast();
    if (this.state.getWebSockets().length > 0) await this.state.storage.setAlarm(Date.now() + SWEEP_INTERVAL_MS);
  }

  async persistMeta() {
    await this.state.storage.put('meta', this.meta);
  }
}
