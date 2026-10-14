import test from 'node:test';
import assert from 'node:assert/strict';
import { createCallRoom } from './call-room.mjs';

const SID = 'sess-1';
const mk = (over = {}) => createCallRoom({ roomId: 'r1', sessionId: SID, nowMs: () => 1000, isMember: () => true, ...over });

test('join: a verified session member is admitted', () => {
  const r = mk();
  assert.equal(r.join({ participantId: 'a', sessionId: SID, trackId: 't-a' }).ok, true);
  assert.equal(r.state().size, 1);
});

test('join: wrong session rejected (confused-deputy-safe)', () => {
  assert.deepEqual(mk().join({ participantId: 'a', sessionId: 'other' }), { ok: false, reason: 'wrong-session' });
});

test('join: non-member rejected even with the right session', () => {
  assert.equal(mk({ isMember: () => false }).join({ participantId: 'a', sessionId: SID }).reason, 'not-a-member');
});

test('join: idempotent re-join (reconnect) does not duplicate; updates trackId', () => {
  const r = mk();
  r.join({ participantId: 'a', sessionId: SID, trackId: 't1' });
  const again = r.join({ participantId: 'a', sessionId: SID, trackId: 't2' });
  assert.equal(again.idempotent, true);
  assert.equal(r.state().size, 1);
  assert.equal(r.roster()[0].trackId, 't2');
});

test('join: capacity enforced', () => {
  const r = mk({ capacity: 1 });
  r.join({ participantId: 'a', sessionId: SID });
  assert.equal(r.join({ participantId: 'b', sessionId: SID }).reason, 'at-capacity');
});

test('open floor: everyone hears everyone else', () => {
  const r = mk();
  for (const id of ['a', 'b', 'c']) r.join({ participantId: id, sessionId: SID });
  const s = r.subscriptions();
  assert.deepEqual(s.a.sort(), ['b', 'c']);
  assert.deepEqual(s.b.sort(), ['a', 'c']);
});

test('round-robin: everyone hears the floor holder; advanceFloor rotates', () => {
  const r = mk({ floor: 'round-robin' });
  for (const id of ['a', 'b', 'c']) r.join({ participantId: id, sessionId: SID });
  assert.equal(r.state().holder, 'a'); // first joiner holds
  let s = r.subscriptions();
  assert.deepEqual(s.b, ['a']);
  assert.deepEqual(s.a, []); // the holder hears nobody extra
  assert.equal(r.advanceFloor().holder, 'b');
  s = r.subscriptions();
  assert.deepEqual(s.a, ['b']);
  assert.deepEqual(s.c, ['b']);
});

test('moderated: grantFloor sets the speaker; non-member grant rejected', () => {
  const r = mk({ floor: 'moderated' });
  r.join({ participantId: 'a', sessionId: SID });
  r.join({ participantId: 'b', sessionId: SID });
  assert.equal(r.grantFloor('b').holder, 'b');
  assert.deepEqual(r.subscriptions().a, ['b']);
  assert.equal(r.grantFloor('zzz').reason, 'not-in-room');
});

test('leave: removes + reassigns the floor holder', () => {
  const r = mk({ floor: 'round-robin' });
  r.join({ participantId: 'a', sessionId: SID });
  r.join({ participantId: 'b', sessionId: SID });
  assert.equal(r.state().holder, 'a');
  r.leave('a');
  assert.equal(r.state().size, 1);
  assert.equal(r.state().holder, 'b');
});

test('sweep: drops idle participants past the timeout, keeps fresh ones', () => {
  let t = 1000;
  const r = createCallRoom({ roomId: 'r', sessionId: SID, idleTimeoutMs: 100, nowMs: () => t, isMember: () => true });
  r.join({ participantId: 'a', sessionId: SID }); // a active @1000
  t = 1120;
  r.join({ participantId: 'b', sessionId: SID }); // b active @1120
  t = 1150; // a idle 150 (>100) -> drop; b idle 30 (<100) -> keep
  assert.deepEqual(r.sweep(), ['a']);
  assert.equal(r.state().size, 1);
});

test('setFloor open clears the holder; invalid floor rejected', () => {
  const r = mk({ floor: 'moderated' });
  r.join({ participantId: 'a', sessionId: SID });
  assert.equal(r.setFloor('open').holder, null);
  assert.equal(r.setFloor('bogus').reason, 'invalid-floor');
});

test('construction guards: bad floor / capacity / ids throw', () => {
  assert.throws(() => createCallRoom({ roomId: 'r', sessionId: SID, floor: 'x' }));
  assert.throws(() => createCallRoom({ roomId: 'r', sessionId: SID, capacity: 0 }));
  assert.throws(() => createCallRoom({ roomId: '', sessionId: SID }));
});
