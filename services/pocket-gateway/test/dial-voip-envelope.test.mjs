// dial-voip-envelope.test.mjs — the CONFORMANCE LOCK on the one dial-ring seam with zero in-repo coverage: the shape of
// the PKPushPayload.dictionaryPayload the deploy's apnsSend delivers to the phone. The gateway suite exercises a FAKE
// apnsSend that only captures `payload`, so a REAL-transport envelope bug (nesting the DTO) can't be caught there. This
// pins buildVoipPushDictionary to the contract SentiCallKit.receiveState enforces (reads id/who/callerName/… TOP-LEVEL,
// ignores `aps`; nested DTO => top-level `id` absent => decode nil => every ring silently declines).
//
// It ALSO pins the `who` CONTRACT (DialPayloadV1): `who` is the ring SOURCE ('senti-pocket'), NOT the requesting agent.
// The requesting agent identity is `requestedBy`, kept AUTHED (hydrated via GET /dial?id=), never on the unauthenticated
// push. These tests guard against re-threading requestedBy->who (a caller-spoof seam on the unauth push).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildDialPayload, buildVoipPushDictionary } from '../src/dial-registry.mjs';
import { mapSignalToPushInput } from '../src/need-carter-dial.mjs';

const NOW = 1_770_000_000_000;
const KNOWN = '6cf7e861-546a-4b9f-b937-39182a5bd395';
// The exact top-level keys SentiCallKit.receiveState decodes (Atlas L176/L185-187): the app reads these OFF THE TOP LEVEL.
const APP_DECODE_KEYS = ['id', 'who', 'callerName', 'priority', 'sessionId', 'ts', 'fetch', 'kind', 'v'];

const ringOwnerSignal = (over = {}) => ({
  id: 'need_abc123', kind: 'decisionYours', question: 'Ship the auth-boundary PR #752?',
  context: { sessionId: KNOWN, checkpointId: 'cp_752', whatWeNeed: 'go/no-go' },
  confidence: 1.0, requestedBy: 'claude-atlas', createdAt: Math.floor(NOW / 1000), ...over,
});

// ---- the `who` contract: source, NOT the agent (agent stays authed in callerName / hydrated requestedBy) -----------

test('ring-owner ring pins the who CONTRACT: who = source "senti-pocket", the agent is in the AUTHED callerName', () => {
  const mapped = mapSignalToPushInput(ringOwnerSignal(), { humanId: 'consumer-carter' });
  assert.equal(mapped.ring, true);
  assert.equal('who' in mapped.input, false, 'mapSignalToPushInput does NOT thread who — the requesting agent must not ride the unauth push');
  const payload = buildDialPayload(mapped.input, NOW);
  assert.equal(payload.who, 'senti-pocket', 'who is the ring SOURCE (DialPayloadV1 contract), never the requesting agent');
  assert.equal(payload.callerName, 'Senti · claude-atlas needs your decision', 'the agent identity rides callerName (authed on the hydrated wire)');
  // the raw requesting agent lives ONLY in the authed hydration signal, never on the push payload.
  assert.equal(mapped.storedSignal.requestedBy, 'claude-atlas', 'requestedBy is carried on the AUTHED storedSignal (GET /dial?id=), not the push');
});

test('a signal WITHOUT requestedBy: who stays "senti-pocket", callerName falls back gracefully', () => {
  const mapped = mapSignalToPushInput(ringOwnerSignal({ requestedBy: '' }), { humanId: 'consumer-carter' });
  assert.equal(mapped.ring, true);
  const payload = buildDialPayload(mapped.input, NOW);
  assert.equal(payload.who, 'senti-pocket');
  assert.equal(payload.callerName, 'Senti · an agent needs your decision', 'empty requestedBy -> the callerName fallback, never a crash');
});

// ---- the envelope conformance lock (buildVoipPushDictionary) -------------------------------------------------------

test('write-kind (LEAN) ring: every app-decode key is TOP-LEVEL, governed content shed, aps a sibling', () => {
  const payload = buildDialPayload(mapSignalToPushInput(ringOwnerSignal(), { humanId: 'consumer-carter' }).input, NOW);
  assert.equal(payload.fetch, true, 'decisionYours is a write-kind -> LEAN doorbell');
  const dict = buildVoipPushDictionary(payload);
  for (const k of APP_DECODE_KEYS) assert.ok(k in dict, `app decode key "${k}" is present TOP-LEVEL in the delivered dictionary`);
  assert.equal(dict.who, 'senti-pocket', 'who = the ring source top-level (the agent is in callerName)');
  assert.equal(dict.callerName, 'Senti · claude-atlas needs your decision');
  assert.equal(dict.checkpointId, 'cp_752', 'checkpointId (present) rides top-level');
  assert.equal(dict.message, undefined, 'a write-kind sheds the governed decision — it is NOT in the push (doorbell policy)');
  assert.ok(dict.aps && typeof dict.aps === 'object', 'aps envelope present as a SIBLING (ignored by the decode)');
});

test('non-write-kind (RICH) ring: governed content rides top-level too', () => {
  const payload = buildDialPayload({ humanId: 'h', sessionId: KNOWN, message: 'FYI: deploy finished', priority: 'medium', id: 'need_info1', kind: 'info', callerName: 'Senti · update from detector' }, NOW);
  assert.equal(payload.fetch, false, 'info is a non-write-kind -> RICH (self-contained)');
  const dict = buildVoipPushDictionary(payload);
  assert.equal(dict.message, 'FYI: deploy finished', 'RICH governed message rides TOP-LEVEL');
  assert.equal(dict.who, 'senti-pocket', 'who defaults to the source when not supplied');
  assert.equal(dict.id, payload.id);
});

test('THE anti-nesting invariant: the DTO is top-level, never under a payload/data wrapper', () => {
  const payload = buildDialPayload({ humanId: 'h', sessionId: KNOWN, message: 'x', id: 'need_n1', kind: 'info', callerName: 'Senti needs you' }, NOW);
  const dict = buildVoipPushDictionary(payload);
  // the correct shape: `id` is a DIRECT top-level property (what SentiCallKit reads).
  assert.equal(typeof dict.id, 'string');
  // and the DTO is NOT hidden under a wrapper key — these MUST be absent (their presence would mean the app finds no top-level id).
  assert.equal(dict.payload, undefined, 'no `payload` wrapper (nesting = silent .rejected)');
  assert.equal(dict.data, undefined, 'no `data` wrapper');
  assert.equal(dict.body, undefined, 'no `body` wrapper');
  // document the failure mode this guards: a nested envelope has NO top-level id.
  const nested = { aps: {}, payload };
  assert.equal(nested.id, undefined, 'the WRONG (nested) shape has no top-level id -> app decode returns nil');
});

test('aps overrides merge; the dial fields are never clobbered by aps', () => {
  const payload = buildDialPayload({ humanId: 'h', sessionId: KNOWN, message: 'x', id: 'need_a1', kind: 'info', callerName: 'Senti needs you' }, NOW);
  const dict = buildVoipPushDictionary(payload, { 'content-available': 1, 'apns-priority': 10 });
  assert.equal(dict.aps['content-available'], 1);
  assert.equal(dict.aps['apns-priority'], 10);
  assert.equal(dict.id, 'need_a1', 'the dial id is untouched by the aps envelope');
});

test('fail-closed: a blank/nested/invalid payload throws (never emits a dead-id dictionary)', () => {
  assert.throws(() => buildVoipPushDictionary(null), /payload object required/);
  assert.throws(() => buildVoipPushDictionary([{ id: 'x' }]), /payload object required/);
  assert.throws(() => buildVoipPushDictionary({}), /payload\.id .* required/);
  assert.throws(() => buildVoipPushDictionary({ id: '' }), /payload\.id .* required/);
  const payload = buildDialPayload({ humanId: 'h', sessionId: KNOWN, message: 'x', id: 'need_ok', kind: 'info', callerName: 'Senti needs you' }, NOW);
  assert.throws(() => buildVoipPushDictionary(payload, [1, 2]), /aps must be an object/);
});
