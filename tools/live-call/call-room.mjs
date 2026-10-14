// tools/live-call/call-room.mjs
//
// Deterministic room-state + floor-routing core for the live-call transport (CF Realtime SFU + Durable Object).
// Pure, no network: the Worker/DO wrapper injects `nowMs` + the CF Realtime session/track ids; THIS module owns
// who is in the room, who may join (membership-auth, confused-deputy-safe), and WHO HEARS WHOM (floor policy).
// It turns a checkpoint/standup into multi-party voice — floor ∈ open | round-robin | moderated.
//
// Lane: the call-me / voice workstream (pairs with the merged call-me CLI + routing-worker). The report-lifecycle
// (SentiCallKit) is the client side; THIS is the server-side media-room brain the SFU wrapper drives.

const str = (v) => (typeof v === 'string' ? v : '');
const FLOORS = new Set(['open', 'round-robin', 'moderated']);

export function createCallRoom({
  roomId,
  sessionId, // the Senti session this call belongs to; joiners must match it
  capacity = 16,
  floor = 'open',
  nowMs = () => Date.now(),
  isMember = () => true, // injected (participantId, sessionId) -> bool; gateway-verified membership
  idleTimeoutMs = 300000, // drop a participant after this much silence (Worker calls sweep())
} = {}) {
  if (!str(roomId) || !str(sessionId)) throw new Error('room requires roomId + sessionId');
  if (!FLOORS.has(floor)) throw new Error('invalid-floor');
  if (!Number.isInteger(capacity) || capacity < 1 || capacity > 256) throw new Error('invalid-capacity');

  const participants = new Map(); // id -> { id, sessionId, role, trackId, joinedAt, lastActiveMs, speaking }
  let floorMode = floor;
  let floorHolder = null;
  let rrOrder = [];

  const snapshot = (p) => ({ id: p.id, role: p.role, trackId: p.trackId, speaking: p.speaking, joinedAt: p.joinedAt });

  function join({ participantId, sessionId: sid, role = 'speaker', trackId = null } = {}) {
    const id = str(participantId);
    if (!id) return { ok: false, reason: 'no-participant' };
    if (str(sid) !== sessionId) return { ok: false, reason: 'wrong-session' }; // confused-deputy-safe
    if (!isMember(id, sessionId)) return { ok: false, reason: 'not-a-member' }; // gateway-verified membership
    if (participants.has(id)) {
      const p = participants.get(id); // idempotent re-join (reconnect)
      p.lastActiveMs = nowMs();
      if (trackId) p.trackId = str(trackId);
      return { ok: true, idempotent: true, participant: snapshot(p) };
    }
    if (participants.size >= capacity) return { ok: false, reason: 'at-capacity' };
    const now = nowMs();
    const p = { id, sessionId, role: str(role) || 'speaker', trackId: str(trackId) || null, joinedAt: now, lastActiveMs: now, speaking: false };
    participants.set(id, p);
    rrOrder.push(id);
    if (floorMode !== 'open' && !floorHolder) floorHolder = id; // first joiner holds a non-open floor
    return { ok: true, participant: snapshot(p) };
  }

  function leave(participantId) {
    const id = str(participantId);
    const existed = participants.delete(id);
    rrOrder = rrOrder.filter((x) => x !== id);
    if (floorHolder === id) floorHolder = rrOrder[0] || null;
    return { ok: existed };
  }

  function touch(participantId, { speaking } = {}) {
    const p = participants.get(str(participantId));
    if (!p) return false;
    p.lastActiveMs = nowMs();
    if (typeof speaking === 'boolean') p.speaking = speaking;
    return true;
  }

  function sweep() {
    const now = nowMs();
    const dropped = [...participants.values()].filter((p) => now - p.lastActiveMs > idleTimeoutMs).map((p) => p.id);
    dropped.forEach(leave);
    return dropped;
  }

  function setFloor(mode) {
    if (!FLOORS.has(mode)) return { ok: false, reason: 'invalid-floor' };
    floorMode = mode;
    if (mode === 'open') floorHolder = null;
    else if (!floorHolder) floorHolder = rrOrder[0] || null;
    return { ok: true, floor: floorMode, holder: floorHolder };
  }

  function grantFloor(participantId) {
    const id = str(participantId);
    if (floorMode === 'open') return { ok: false, reason: 'open-floor' };
    if (!participants.has(id)) return { ok: false, reason: 'not-in-room' };
    floorHolder = id;
    return { ok: true, holder: floorHolder };
  }

  function advanceFloor() {
    if (floorMode === 'open') return { ok: false, reason: 'open-floor' };
    if (!rrOrder.length) { floorHolder = null; return { ok: true, holder: null }; }
    const i = Math.max(0, rrOrder.indexOf(floorHolder));
    floorHolder = rrOrder[(i + 1) % rrOrder.length];
    return { ok: true, holder: floorHolder };
  }

  // WHO HEARS WHOM — the SFU subscription routing, derived purely from the floor.
  function subscriptions() {
    const ids = [...participants.keys()];
    const map = {};
    for (const listener of ids) {
      if (floorMode === 'open') map[listener] = ids.filter((x) => x !== listener); // everyone hears everyone else
      else map[listener] = floorHolder && floorHolder !== listener ? [floorHolder] : []; // everyone hears the floor holder
    }
    return map;
  }

  return {
    join,
    leave,
    touch,
    sweep,
    setFloor,
    grantFloor,
    advanceFloor,
    subscriptions,
    roster: () => [...participants.values()].map(snapshot),
    state: () => ({ roomId, sessionId, floor: floorMode, holder: floorHolder, size: participants.size, capacity }),
  };
}
