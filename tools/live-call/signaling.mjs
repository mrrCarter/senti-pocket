// tools/live-call/signaling.mjs
//
// The per-message request handler for the live-call transport's Durable Object: validates a typed signaling
// message, drives the CallRoom, and returns the response PLUS the fresh who-hears-whom subscription directives
// so the SFU/DO can reconcile publish/subscribe without a second round-trip. Pure: the CF Realtime session/track
// negotiation is injected by the Worker/DO wrapper; this owns the protocol + routing only.

const TYPES = new Set(['join', 'leave', 'touch', 'set-floor', 'grant-floor', 'advance-floor', 'roster']);

/**
 * @param {object} room - a CallRoom (createCallRoom).
 * @param {object} msg  - { type, participantId?, sessionId?, role?, trackId?, floor?, speaking? }.
 * @returns { ok, reason?, type, subscriptions, state, ...result }
 */
export function handleSignal(room, msg = {}) {
  const type = typeof msg?.type === 'string' ? msg.type : '';
  if (!TYPES.has(type)) return { ok: false, reason: 'unknown-type' };

  let result;
  switch (type) {
    case 'join':
      result = room.join({ participantId: msg.participantId, sessionId: msg.sessionId, role: msg.role, trackId: msg.trackId });
      break;
    case 'leave':
      result = room.leave(msg.participantId);
      break;
    case 'touch':
      result = { ok: room.touch(msg.participantId, { speaking: msg.speaking }) };
      break;
    case 'set-floor':
      result = room.setFloor(msg.floor);
      break;
    case 'grant-floor':
      result = room.grantFloor(msg.participantId);
      break;
    case 'advance-floor':
      result = room.advanceFloor();
      break;
    case 'roster':
      result = { ok: true, roster: room.roster() };
      break;
  }

  // Every signal returns the current directives so the SFU reconciles in one hop. A rejected op returns the
  // unchanged room view (never a partial/ambiguous state) — the caller sees ok:false + the real current state.
  return { ...result, type, subscriptions: room.subscriptions(), state: room.state() };
}
