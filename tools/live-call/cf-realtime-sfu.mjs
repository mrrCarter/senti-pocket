// tools/live-call/cf-realtime-sfu.mjs
//
// Thin adapter for the Cloudflare Realtime SFU HTTP API (rtc.live.cloudflare.com/v1), grounded in the live
// docs: endpoints + Bearer auth are fixed here; SDP/track request bodies are PASSED THROUGH (the WebRTC
// client + OpenAPI schema own their exact shape — this layer does not invent SDP fields). Pure: `fetchImpl`
// is injected so it is unit-testable with no network; the App Secret stays server-side (fail-closed if absent).
//
// Pairs with CallRoom/signaling: `remoteTracksForListener` maps the who-hears-whom subscription map into the
// CF "remote track" subscribe body the SFU expects.

const BASE = 'https://rtc.live.cloudflare.com/v1';

export function createCfRealtimeSfu({
  appId,
  appSecret = process.env.CF_REALTIME_APP_SECRET,
  base = BASE,
  fetchImpl = globalThis.fetch,
} = {}) {
  if (!appId) throw new Error('cf-realtime requires appId');
  if (typeof fetchImpl !== 'function') throw new Error('cf-realtime requires a fetch implementation');
  const app = `${base}/apps/${encodeURIComponent(appId)}`;

  async function call(method, path, body) {
    if (!appSecret) throw new Error('missing-cf-app-secret'); // fail closed; secret never leaves the backend
    const res = await fetchImpl(`${app}${path}`, {
      method,
      headers: { authorization: `Bearer ${appSecret}`, 'content-type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    if (!res || !res.ok) throw new Error(`cf-realtime-${res ? res.status : 'no-response'}`);
    return res.json();
  }

  return {
    // {sessionDescription:{type:'offer',sdp}} -> {sessionId, sessionDescription:{type:'answer',sdp}}
    newSession: (body) => call('POST', '/sessions/new', body),
    // publish: body.tracks[] are {location:'local', mid, trackName}
    addLocalTracks: (sessionId, body) => call('POST', `/sessions/${encodeURIComponent(sessionId)}/tracks/new`, body),
    // subscribe: body.tracks[] are {location:'remote', sessionId:<publisher>, trackName}
    addRemoteTracks: (sessionId, body) => call('POST', `/sessions/${encodeURIComponent(sessionId)}/tracks/new`, body),
    renegotiate: (sessionId, body) => call('PUT', `/sessions/${encodeURIComponent(sessionId)}/renegotiate`, body),
    updateTracks: (sessionId, body) => call('PUT', `/sessions/${encodeURIComponent(sessionId)}/tracks/update`, body),
    closeTracks: (sessionId, body) => call('PUT', `/sessions/${encodeURIComponent(sessionId)}/tracks/close`, body),
    getSession: (sessionId) => call('GET', `/sessions/${encodeURIComponent(sessionId)}`),
  };
}

/**
 * Turn CallRoom.subscriptions() into the CF "remote track" subscribe body for one listener.
 * @param {object} subscriptions - { listenerId: [publisherId, ...] } from CallRoom.subscriptions().
 * @param {string} listenerId
 * @param {(publisherId:string)=>({sessionId:string, trackName:string}|null)} trackOf - publisher → their CF track.
 */
export function remoteTracksForListener(subscriptions, listenerId, trackOf) {
  const heard = (subscriptions && subscriptions[listenerId]) || [];
  const tracks = heard
    .map((pubId) => {
      const t = trackOf(pubId);
      return t && t.sessionId && t.trackName ? { location: 'remote', sessionId: t.sessionId, trackName: t.trackName } : null;
    })
    .filter(Boolean);
  return { tracks };
}
