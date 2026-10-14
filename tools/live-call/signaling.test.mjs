import test from 'node:test';
import assert from 'node:assert/strict';
import { createCallRoom } from './call-room.mjs';
import { handleSignal } from './signaling.mjs';

const SID = 'sess-1';
const mk = (over = {}) => createCallRoom({ roomId: 'r1', sessionId: SID, nowMs: () => 1000, isMember: () => true, ...over });

test('unknown message type is rejected', () => {
  assert.deepEqual(handleSignal(mk(), { type: 'bogus' }), { ok: false, reason: 'unknown-type' });
  assert.equal(handleSignal(mk(), {}).reason, 'unknown-type');
});

test('join returns ok + fresh subscriptions + state', () => {
  const r = mk();
  const res = handleSignal(r, { type: 'join', participantId: 'a', sessionId: SID, trackId: 't-a' });
  assert.equal(res.ok, true);
  assert.equal(res.type, 'join');
  assert.equal(res.state.size, 1);
  assert.ok(res.subscriptions.a);
});

test('a second join → open-floor subscriptions reconcile in one hop', () => {
  const r = mk();
  handleSignal(r, { type: 'join', participantId: 'a', sessionId: SID });
  const res = handleSignal(r, { type: 'join', participantId: 'b', sessionId: SID });
  assert.deepEqual(res.subscriptions.a, ['b']);
  assert.deepEqual(res.subscriptions.b, ['a']);
});

test('rejected join (wrong session) returns ok:false + unchanged room view (no partial state)', () => {
  const r = mk();
  handleSignal(r, { type: 'join', participantId: 'a', sessionId: SID });
  const res = handleSignal(r, { type: 'join', participantId: 'intruder', sessionId: 'other' });
  assert.equal(res.ok, false);
  assert.equal(res.reason, 'wrong-session');
  assert.equal(res.state.size, 1); // unchanged
  assert.ok(!res.subscriptions.intruder);
});

test('set-floor + grant-floor route through and reflect in subscriptions', () => {
  const r = mk();
  handleSignal(r, { type: 'join', participantId: 'a', sessionId: SID });
  handleSignal(r, { type: 'join', participantId: 'b', sessionId: SID });
  const f = handleSignal(r, { type: 'set-floor', floor: 'moderated' });
  assert.equal(f.state.floor, 'moderated');
  const g = handleSignal(r, { type: 'grant-floor', participantId: 'b' });
  assert.equal(g.state.holder, 'b');
  assert.deepEqual(g.subscriptions.a, ['b']);
});

test('leave + roster route through', () => {
  const r = mk();
  handleSignal(r, { type: 'join', participantId: 'a', sessionId: SID });
  const ros = handleSignal(r, { type: 'roster' });
  assert.equal(ros.roster.length, 1);
  const lv = handleSignal(r, { type: 'leave', participantId: 'a' });
  assert.equal(lv.state.size, 0);
});

test('touch updates liveness without changing membership', () => {
  const r = mk();
  handleSignal(r, { type: 'join', participantId: 'a', sessionId: SID });
  const res = handleSignal(r, { type: 'touch', participantId: 'a', speaking: true });
  assert.equal(res.ok, true);
  assert.equal(res.state.size, 1);
});
