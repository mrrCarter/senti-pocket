// tools/live-call/worker.mjs
//
// Edge entry for the live-call transport. Authorizes a client at the edge (fail-closed) BEFORE any DO access, then
// routes WebSocket signaling to the per-(session,room) Durable Object and mints/forwards CF Realtime SFU calls on
// the client's behalf — the App Secret lives here and never reaches the client. GET /health is the only open route.
//
// AUTHORIZATION — mirrors the gateway (which holds no signing key): forward the client's OWN Senti bearer to the
// gateway authorize endpoint, which returns the role + the participant id it BOUND to that bearer for the (session,
// room) pair. The caller never chooses its own participant id or room. Every SFU op is additionally authorized
// against the DO (which owns the per-participant minted sessions + the room's published set), so no client can
// renegotiate, pull, or over-mint another participant's / another room's CF session.

import { createCfRealtimeSfu } from './cf-realtime-sfu.mjs';
import { INTERNAL_OP_PATH } from './call-do.mjs';

export { CallRoomDO } from './call-do.mjs';
export { INTERNAL_OP_PATH };

const MEMBER_ROLES = new Set(['owner', 'admin', 'contributor', 'viewer']);
const MAX_SFU_BODY = 64 * 1024;
const AUTHZ_TIMEOUT_MS = 3000;
const json = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

function bearerFrom(request, url) {
  const header = request.headers.get('authorization');
  if (header && /^Bearer\s+\S/i.test(header)) return header;
  const token = url.searchParams.get('token');
  return token ? `Bearer ${token}` : '';
}

// Pin the authorize endpoint: GATEWAY_HOST is REQUIRED (unset => fail closed), https only, host must match exactly.
export function authorizeEndpoint(env) {
  if (!env.GATEWAY_AUTHORIZE_URL || !env.GATEWAY_HOST) return null;
  try {
    const u = new URL(env.GATEWAY_AUTHORIZE_URL);
    if (u.protocol !== 'https:' || u.host !== env.GATEWAY_HOST) return null;
    return u.toString();
  } catch {
    return null;
  }
}

// Authorize the client's bearer for the (session, room) pair. Fail closed; the gateway binds the principal + room.
export async function authorize(env, { authorization, sessionId, roomId }) {
  const endpoint = authorizeEndpoint(env);
  if (!endpoint || !authorization || !sessionId || !roomId) return { ok: false };
  try {
    const r = await fetch(endpoint, {
      method: 'POST',
      headers: { authorization, 'content-type': 'application/json' },
      body: JSON.stringify({ sessionId, roomId }),
      redirect: 'manual', // never follow a redirect to another host with the bearer attached
      signal: AbortSignal.timeout(AUTHZ_TIMEOUT_MS),
    });
    if (!r.ok) return { ok: false };
    const j = await r.json().catch(() => ({}));
    if (j.sessionId !== sessionId || j.roomId !== roomId) return { ok: false }; // the gateway must echo what it bound
    const role = typeof j.role === 'string' ? j.role : '';
    const participantId = typeof j.participantId === 'string' ? j.participantId : '';
    if (!MEMBER_ROLES.has(role) || !participantId) return { ok: false };
    return { ok: true, participantId, role };
  } catch {
    return { ok: false };
  }
}

// DO instance name for an authorized (session, room) — BOTH parts are encoded so neither can forge a collision into
// another session's room (reverting this to roomId-only is the room-squat regression).
export function doName(sessionId, roomId) {
  return `${encodeURIComponent(sessionId)}::${encodeURIComponent(roomId)}`;
}
function doStub(env, sessionId, roomId) {
  return env.CALL_ROOM.get(env.CALL_ROOM.idFromName(doName(sessionId, roomId)));
}

// WS forward URL: the bearer token is STRIPPED and participant + role are the AUTHORIZED values, never the caller's.
export function buildForwardUrl(incomingUrl, { roomId, participantId, role }) {
  const fwd = new URL(incomingUrl);
  fwd.searchParams.delete('token');
  fwd.searchParams.set('room', roomId);
  fwd.searchParams.set('participant', participantId);
  fwd.searchParams.set('role', role);
  return fwd.toString();
}

// Call the DO's internal op (bind / mint-reserve / sfu-authz). Requires a configured key; the DO rejects a default.
async function internalOp(env, sessionId, roomId, op, payload) {
  const res = await doStub(env, sessionId, roomId).fetch(
    new Request(`https://do${INTERNAL_OP_PATH}`, {
      method: 'POST',
      headers: { 'x-live-call-internal': env.INTERNAL_BIND_KEY, 'content-type': 'application/json' },
      body: JSON.stringify({ op, ...payload }),
    }),
  );
  return (res && typeof res.json === 'function' ? await res.json().catch(() => ({})) : {}) || {};
}

function remoteTrackSessionIds(body) {
  return Array.isArray(body?.tracks)
    ? body.tracks.filter((t) => t && t.location === 'remote' && t.sessionId).map((t) => String(t.sessionId))
    : [];
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === '/health') return json({ ok: true, service: 'live-call' });

    const m = url.pathname.match(/^\/call\/([^/]+)\/(ws|sfu\/session|sfu\/tracks|sfu\/renegotiate)$/);
    if (!m) return new Response('not found', { status: 404 });
    const roomId = decodeURIComponent(m[1]);
    const sessionId = url.searchParams.get('session') || '';

    const authz = await authorize(env, { authorization: bearerFrom(request, url), sessionId, roomId });
    if (!authz.ok) return new Response('forbidden', { status: 403 });

    const route = m[2];
    if (route.startsWith('sfu/')) {
      if (request.method !== 'POST') return new Response('method not allowed', { status: 405 });
      if (!env.INTERNAL_BIND_KEY) return json({ ok: false, error: 'bind-not-configured' }, 503); // fail closed, no default
      const raw = await request.text();
      if (raw.length > MAX_SFU_BODY) return json({ ok: false, error: 'body-too-large' }, 413);
      let body;
      try {
        body = raw ? JSON.parse(raw) : {};
      } catch {
        return json({ ok: false, error: 'bad-json' }, 400);
      }
      try {
        const sfu = createCfRealtimeSfu({ appId: env.CF_REALTIME_APP_ID, appSecret: env.CF_REALTIME_APP_SECRET });
        if (route === 'sfu/session') {
          const reserve = await internalOp(env, sessionId, roomId, 'mint-reserve', { participantId: authz.participantId });
          if (!reserve.ok) return json({ ok: false, error: 'mint-cap' }, 429);
          const minted = await sfu.newSession(body);
          if (minted && minted.sessionId) {
            await internalOp(env, sessionId, roomId, 'bind', { participantId: authz.participantId, cfSessionId: minted.sessionId });
          }
          return json(minted);
        }
        // tracks + renegotiate: body.sessionId must be the one minted for THIS participant; remote tracks only from
        // this room's published set.
        const authzOp = await internalOp(env, sessionId, roomId, 'sfu-authz', {
          participantId: authz.participantId,
          sessionId: String(body.sessionId || ''),
          remoteSessionIds: route === 'sfu/tracks' ? remoteTrackSessionIds(body) : [],
        });
        if (!authzOp.ok) return new Response('forbidden', { status: 403 });
        if (route === 'sfu/tracks') return json(await sfu.addRemoteTracks(String(body.sessionId), body));
        return json(await sfu.renegotiate(String(body.sessionId), body));
      } catch (e) {
        return json({ ok: false, error: String(e && e.message) }, 502);
      }
    }

    // WS signaling -> per-(session,room) DO. GET-only; forward a FRESH upgrade request that copies NO client header
    // or body (drops the client's Authorization + any x-live-call-internal + any body) — only the signed-in
    // participant/role/room travel, on the URL. This closes the internal-bind bypass at the edge.
    if (request.method !== 'GET' || request.headers.get('Upgrade') !== 'websocket') {
      return new Response('expected websocket', { status: 426 });
    }
    const fwd = buildForwardUrl(url, { roomId, participantId: authz.participantId, role: authz.role });
    return doStub(env, sessionId, roomId).fetch(new Request(fwd, { method: 'GET', headers: { Upgrade: 'websocket' } }));
  },
};
