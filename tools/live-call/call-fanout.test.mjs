import test from 'node:test';
import assert from 'node:assert/strict';
import { createCallRoom } from './call-room.mjs';
import { handleSignal } from './signaling.mjs';
import { buildFanout } from './call-fanout.mjs';

const SID = 'sess-1';
const mk = () => createCallRoom({ roomId: 'r', sessionId: SID, nowMs: () => 1, isMember: () => true });
const pub = (id) => ({ sessionId: `S${id.toUpperCase()}`, trackName: 'mic' });

test('open floor: each listener gets a remote track for every OTHER published participant', () => {
  const room = mk();
  handleSignal(room, { type: 'join', participantId: 'a', sessionId: SID });
  handleSignal(room, { type: 'join', participantId: 'b', sessionId: SID });
  const { directives } = buildFanout(room, { a: pub('a'), b: pub('b') });
  assert.equal(directives.a.type, 'directives');
  assert.deepEqual(directives.a.subscriptions, ['b']);
  assert.deepEqual(directives.a.remoteTracks, [{ location: 'remote', sessionId: 'SB', trackName: 'mic' }]);
  assert.deepEqual(directives.b.remoteTracks, [{ location: 'remote', sessionId: 'SA', trackName: 'mic' }]);
});

test('a participant who has not published a CF track is skipped, never fabricated', () => {
  const room = mk();
  handleSignal(room, { type: 'join', participantId: 'a', sessionId: SID });
  handleSignal(room, { type: 'join', participantId: 'b', sessionId: SID }); // b never published
  const { directives } = buildFanout(room, { a: pub('a') });
  assert.deepEqual(directives.a.remoteTracks, []); // b has no track -> nothing to subscribe to
  assert.deepEqual(directives.b.remoteTracks, [{ location: 'remote', sessionId: 'SA', trackName: 'mic' }]);
});

test('moderated floor: everyone hears only the holder; the holder hears no one', () => {
  const room = mk();
  for (const id of ['a', 'b', 'c']) handleSignal(room, { type: 'join', participantId: id, sessionId: SID });
  handleSignal(room, { type: 'set-floor', floor: 'moderated' });
  handleSignal(room, { type: 'grant-floor', participantId: 'b' });
  const { directives } = buildFanout(room, { a: pub('a'), b: pub('b'), c: pub('c') });
  assert.deepEqual(directives.a.remoteTracks, [{ location: 'remote', sessionId: 'SB', trackName: 'mic' }]);
  assert.deepEqual(directives.c.remoteTracks, [{ location: 'remote', sessionId: 'SB', trackName: 'mic' }]);
  assert.deepEqual(directives.b.remoteTracks, []); // holder hears no one
});

test('state is echoed on every directive so a late joiner reconciles floor without a second round-trip', () => {
  const room = mk();
  handleSignal(room, { type: 'join', participantId: 'a', sessionId: SID });
  const { directives, state } = buildFanout(room, { a: pub('a') });
  assert.equal(state.size, 1);
  assert.equal(directives.a.state.floor, 'open');
  assert.equal(directives.a.state.size, 1);
});

test('empty room -> empty directives and empty subscriptions', () => {
  const { directives, subscriptions } = buildFanout(mk(), {});
  assert.deepEqual(directives, {});
  assert.deepEqual(subscriptions, {});
});
