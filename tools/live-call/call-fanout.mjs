// tools/live-call/call-fanout.mjs
//
// Pure fan-out brain for the live-call Durable Object. After any signal changes the room, the DO must tell EACH
// connected client which remote tracks to subscribe to on the CF Realtime SFU. This module turns the room's
// who-hears-whom map (CallRoom.subscriptions) plus the registry of each participant's PUBLISHED CF track into one
// directive per listener. Pure + injected: no CF globals, so it is unit-tested with no network or miniflare.
//
// Pairs with call-do.mjs (the runtime shell that calls this after every signal and on the idle sweep).

import { remoteTracksForListener } from './cf-realtime-sfu.mjs';

/**
 * Compute one subscribe directive per connected listener.
 * @param {object} room - a CallRoom (createCallRoom).
 * @param {object} publishedTracks - { participantId: { sessionId, trackName } } CF publish coords reported by clients.
 * @returns {{ state, subscriptions, directives: { [listenerId]: { type:'directives', state, subscriptions, remoteTracks } } }}
 */
export function buildFanout(room, publishedTracks = {}) {
  const subscriptions = room.subscriptions();
  const state = room.state();
  const trackOf = (pubId) => publishedTracks[pubId] || null;
  const directives = {};
  for (const listenerId of Object.keys(subscriptions)) {
    // remoteTracksForListener skips any heard participant with no known CF track (never fabricated).
    const { tracks } = remoteTracksForListener(subscriptions, listenerId, trackOf);
    directives[listenerId] = {
      type: 'directives',
      state,
      subscriptions: subscriptions[listenerId],
      remoteTracks: tracks,
    };
  }
  return { state, subscriptions, directives };
}
