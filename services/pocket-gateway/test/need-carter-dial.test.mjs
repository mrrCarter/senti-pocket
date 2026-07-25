// need-carter-dial.test.mjs — locks the RELAY JS mapper as a byte-parity mirror of the SHIPPED Swift contract
// (NeedCarterSignalTests.swift @ atlas/reasoning-seam): same priority table, same callerName strings, same 0.6
// ring floor, same dialFields mapping — so a ring produced gateway-side is identical to one the app builds. Plus
// the RELAY-specific guarantees the Swift type can't express: target-human-from-auth (confused-deputy), fail-closed
// on a malformed signal, and robustness across the kind wire shapes (seam (a)).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  RING_CONFIDENCE_FLOOR, NEED_CARTER_KINDS, kebabSlug, dialPriorityForKind, callerNameForKind,
  parseSignalKind, encodeSignalKind, normalizeSignal, signalClearsRingFloor,
  mapSignalToDialFields, mapSignalToPushInput,
} from '../src/need-carter-dial.mjs';

// Mirrors the Swift test's signal() helper. kindWire defaults to the Swift-synthesized wire shape via encodeSignalKind.
function signal({ kind = 'go', confidence = 0.8, requestedBy = 'detector', kindWire } = {}) {
  return {
    id: 'need_1',
    kind: kindWire !== undefined ? kindWire : encodeSignalKind(kind),
    question: 'Ship the consolidation to master?',
    context: { sessionId: '6cf7e861', checkpointId: 'cp_9', whatWeNeed: 'master merge go' },
    confidence,
    evidenceSeqs: [315038, 315050],
    requestedBy,
    createdAt: 1_784_370_900,
  };
}

// ── priority table (parity: Swift test_priority_mapping_per_kind) ─────────────────────────────────────────────
test('dialPriorityForKind: decisionYours -> high; go/pickOption/info/checkpointReady -> medium (Swift parity)', () => {
  assert.equal(dialPriorityForKind('decisionYours'), 'high');
  assert.equal(dialPriorityForKind('go'), 'medium');
  assert.equal(dialPriorityForKind('pickOption'), 'medium');
  assert.equal(dialPriorityForKind('info'), 'medium');
  assert.equal(dialPriorityForKind('checkpointReady'), 'medium');
});

// ── callerName strings (parity: Swift callerName(kind:requestedBy:)) ──────────────────────────────────────────
test('callerNameForKind: byte-exact with Swift, including the " · " middle-dot separator', () => {
  assert.equal(callerNameForKind('go', 'claude-warden'), 'Senti · claude-warden needs a GO');
  assert.equal(callerNameForKind('decisionYours', 'claude-warden'), 'Senti · claude-warden needs your decision');
  assert.equal(callerNameForKind('pickOption', 'atlas'), 'Senti · atlas needs you to choose');
  assert.equal(callerNameForKind('info', 'forge'), 'Senti · update from forge');
  assert.equal(callerNameForKind('checkpointReady', 'relay'), 'Senti · checkpoint ready');
});

// ── dialFields mapping (parity: Swift test_dialFields_map_to_DialRequest_shape) ───────────────────────────────
test('mapSignalToDialFields: the exact Swift vector (decisionYours + claude-warden)', () => {
  const r = mapSignalToDialFields(signal({ kind: 'decisionYours', confidence: 0.9, requestedBy: 'claude-warden' }));
  assert.equal(r.ok, true);
  assert.deepEqual(r.value, {
    dialId: 'need_1',
    message: 'Ship the consolidation to master?',
    callerName: 'Senti · claude-warden needs your decision',
    priority: 'high',
  });
});

// ── ring floor (parity: Swift test_confidence_floor_blocks_a_low_confidence_ring) ─────────────────────────────
test('signalClearsRingFloor: 0.4 blocked, 0.6 exactly clears, 0.95 clears (floor = 0.6)', () => {
  assert.equal(RING_CONFIDENCE_FLOOR, 0.6);
  assert.equal(signalClearsRingFloor(signal({ confidence: 0.4 })), false);
  assert.equal(signalClearsRingFloor(signal({ confidence: 0.6 })), true);
  assert.equal(signalClearsRingFloor(signal({ confidence: 0.95 })), true);
});

// ── kind wire parsing across all three shapes (seam (a) robustness) ───────────────────────────────────────────
test('parseSignalKind: Swift-synthesized shape (empty case + pickOption._0)', () => {
  assert.deepEqual(parseSignalKind({ go: {} }), { slug: 'go', options: [] });
  assert.deepEqual(parseSignalKind({ decisionYours: {} }), { slug: 'decisionYours', options: [] });
  assert.deepEqual(parseSignalKind({ pickOption: { _0: ['Merge now', 'Wait for forge', 'Split the PR'] } }),
    { slug: 'pickOption', options: ['Merge now', 'Wait for forge', 'Split the PR'] });
});

test('parseSignalKind: stable explicit shape + bare string (forward-compat)', () => {
  assert.deepEqual(parseSignalKind({ kind: 'pickOption', options: ['A', 'B'] }), { slug: 'pickOption', options: ['A', 'B'] });
  assert.deepEqual(parseSignalKind({ slug: 'go' }), { slug: 'go', options: [] });
  assert.deepEqual(parseSignalKind('info'), { slug: 'info', options: [] });
});

test('parseSignalKind: fail-closed on garbage / unknown case / ambiguous multi-key', () => {
  assert.equal(parseSignalKind(null), null);
  assert.equal(parseSignalKind({}), null);
  assert.equal(parseSignalKind('nope'), null);
  assert.equal(parseSignalKind({ bogusCase: {} }), null);
  assert.equal(parseSignalKind({ go: {}, info: {} }), null, 'two known keys is ambiguous -> null');
});

test('encodeSignalKind: emits the Swift-synthesized wire shape; round-trips through parseSignalKind', () => {
  assert.deepEqual(encodeSignalKind('go'), { go: {} });
  assert.deepEqual(encodeSignalKind({ slug: 'pickOption', options: ['A', 'B'] }), { pickOption: { _0: ['A', 'B'] } });
  for (const slug of NEED_CARTER_KINDS) {
    const opts = slug === 'pickOption' ? ['x', 'y'] : [];
    assert.deepEqual(parseSignalKind(encodeSignalKind({ slug, options: opts })), { slug, options: opts }, `${slug} round-trips`);
  }
  assert.equal(encodeSignalKind('bogus'), null);
});

test('pickOption labels survive parse from the Swift-synthesized wire (parity: Swift round-trip test)', () => {
  const s = signal({ kind: 'pickOption', kindWire: encodeSignalKind({ slug: 'pickOption', options: ['Merge now', 'Wait for forge', 'Split the PR'] }) });
  const n = normalizeSignal(s);
  assert.equal(n.ok, true);
  assert.deepEqual(n.value.kind, { slug: 'pickOption', options: ['Merge now', 'Wait for forge', 'Split the PR'] });
});

// ── normalizeSignal fail-closed ──────────────────────────────────────────────────────────────────────────────
test('normalizeSignal: fail-closed on each missing/mistyped load-bearing field', () => {
  assert.equal(normalizeSignal({ ...signal(), id: '' }).ok, false);
  assert.equal(normalizeSignal({ ...signal(), kind: { bogus: {} } }).ok, false);
  assert.equal(normalizeSignal({ ...signal(), question: '   ' }).ok, false);
  assert.equal(normalizeSignal({ ...signal(), context: { sessionId: '' } }).ok, false);
  // NaN / missing confidence fails CLOSED to 0 (so it can never clear the floor), not to a truthy default.
  assert.equal(normalizeSignal({ ...signal(), confidence: NaN }).value.confidence, 0);
  assert.equal(normalizeSignal({ ...signal(), confidence: undefined }).value.confidence, 0);
  // confidence clamps to [0,1]
  assert.equal(normalizeSignal({ ...signal(), confidence: 1.7 }).value.confidence, 1);
});

// ── mapSignalToPushInput: dispatch mapping + RELAY security guarantees ────────────────────────────────────────
test('mapSignalToPushInput: valid signal above floor -> RICH warden pushBackend input + frozen storedSignal (PR-B2)', () => {
  const r = mapSignalToPushInput(signal({ kind: 'decisionYours', confidence: 0.9, requestedBy: 'claude-warden' }), { humanId: 'human-mrrcarter' });
  assert.equal(r.ring, true);
  // input now carries the RICH dialPayloadV1 fields (PR-B2: on the wire via buildDialPayload). decisionYours has no options -> no options key.
  assert.deepEqual(Object.keys(r.input).sort(), ['callerName', 'checkpointId', 'confidence', 'context', 'evidenceSeqs', 'humanId', 'id', 'kind', 'message', 'priority', 'sessionId']);
  assert.deepEqual(r.input, {
    humanId: 'human-mrrcarter',
    sessionId: '6cf7e861',
    message: 'Ship the consolidation to master?',
    context: 'master merge go',
    priority: 'high',
    id: 'need_1',
    kind: 'decisionYours',
    callerName: 'Senti · claude-warden needs your decision',
    checkpointId: 'cp_9',
    evidenceSeqs: [315038, 315050],
    confidence: 0.9,
  });
  // storedSignal is the EXACT NeedCarterSignal the app decodes on GET /dial?id= hydration: kind re-encoded to the Codable
  // wire shape, ONLY canonical fields (no caller-supplied extras), id == the ring's dialId (what dial-signal-store keys on).
  assert.deepEqual(r.storedSignal, {
    id: 'need_1',
    kind: { decisionYours: {} },
    question: 'Ship the consolidation to master?',
    context: { sessionId: '6cf7e861', checkpointId: 'cp_9', whatWeNeed: 'master merge go' },
    confidence: 0.9,
    evidenceSeqs: [315038, 315050],
    requestedBy: 'claude-warden',
    createdAt: 1_784_370_900,
  });
  assert.equal(r.storedSignal.id, r.input.id, 'storedSignal.id == input.id (== the ring dialId the store keys on)');
  assert.deepEqual(r.evidenceSeqs, [315038, 315050], 'evidenceSeqs carried for audit + jump-to');
  assert.equal(r.dialFields.callerName, 'Senti · claude-warden needs your decision');
});

test('mapSignalToPushInput: pickOption carries options into input + re-encodes storedSignal.kind to the Codable wire', () => {
  const s = signal({ confidence: 0.9, requestedBy: 'atlas', kindWire: encodeSignalKind({ slug: 'pickOption', options: ['Merge now', 'Wait'] }) });
  const r = mapSignalToPushInput(s, { humanId: 'human-mrrcarter' });
  assert.equal(r.ring, true);
  assert.deepEqual(r.input.options, ['Merge now', 'Wait'], 'options ride the wire for a pickOption ring');
  assert.equal(r.input.kind, 'pickOption');
  assert.equal(r.input.callerName, 'Senti · atlas needs you to choose');
  assert.deepEqual(r.storedSignal.kind, { pickOption: { _0: ['Merge now', 'Wait'] } }, 'storedSignal re-encodes pickOption to the shape atlas decodes');
});

test('mapSignalToPushInput: absent optionals — checkpointId/options omitted, but storedSignal.evidenceSeqs ALWAYS [] (Warden #83 BUG 1)', () => {
  const bare = { id: 'need_2', kind: encodeSignalKind('go'), question: 'GO?', context: { sessionId: 'sess-1', whatWeNeed: 'ship it' }, confidence: 0.9, requestedBy: 'detector' };
  const r = mapSignalToPushInput(bare, { humanId: 'human-mrrcarter' });
  assert.equal(r.ring, true);
  assert.ok(!('checkpointId' in r.input), 'no input.checkpointId key when absent');
  assert.ok(!('evidenceSeqs' in r.input), 'input omits evidenceSeqs when empty (feeds buildDialPayload, which defaults [])');
  assert.ok(!('options' in r.input), 'no input.options key for a non-pickOption kind');
  assert.ok(!('checkpointId' in r.storedSignal.context), 'storedSignal.context omits checkpointId (Swift String? optional)');
  // BUG 1: Swift NeedCarterSignal.evidenceSeqs is NON-OPTIONAL [Int] -> synthesized decode(forKey:) throws keyNotFound if
  // omitted -> an evidence-less ring is a dead doorbell. The stored signal MUST ALWAYS carry it ([] when empty).
  assert.deepEqual(r.storedSignal.evidenceSeqs, [], 'storedSignal ALWAYS emits evidenceSeqs ([] when empty) — non-optional Swift field');
  assert.ok(!('createdAt' in r.storedSignal), 'createdAt omitted when absent (producer always emits Unix-sec; atlas decoder decodeIfPresent tolerates)');
});

test('mapSignalToPushInput: SECURITY — target humanId comes from AUTH, never the signal (confused-deputy)', () => {
  // A hostile signal tries to smuggle a target via top-level + context fields; the mapper must ignore ALL of them.
  const hostile = { ...signal({ confidence: 0.9 }), humanId: 'human-attacker', targetHumanId: 'human-attacker', context: { sessionId: '6cf7e861', whatWeNeed: 'x', humanId: 'human-attacker' } };
  const r = mapSignalToPushInput(hostile, { humanId: 'human-mrrcarter' });
  assert.equal(r.ring, true);
  assert.equal(r.input.humanId, 'human-mrrcarter', 'auth humanId wins; signal-supplied humanId is ignored');
});

test('mapSignalToPushInput: no auth humanId -> ring:false missing-target-human (never rings an unknown human)', () => {
  assert.deepEqual(mapSignalToPushInput(signal({ confidence: 0.9 }), {}), { ring: false, reason: 'missing-target-human' });
  assert.deepEqual(mapSignalToPushInput(signal({ confidence: 0.9 }), { humanId: '   ' }), { ring: false, reason: 'missing-target-human' });
});

test('mapSignalToPushInput: below the floor -> ring:false below-ring-floor (anti-false-ring)', () => {
  const r = mapSignalToPushInput(signal({ confidence: 0.4 }), { humanId: 'human-mrrcarter' });
  assert.deepEqual(r, { ring: false, reason: 'below-ring-floor' });
});

test('mapSignalToPushInput: malformed signal -> ring:false invalid-signal (fail-closed)', () => {
  const r = mapSignalToPushInput({ id: '', kind: { go: {} } }, { humanId: 'human-mrrcarter' });
  assert.equal(r.ring, false);
  assert.equal(r.reason, 'invalid-signal');
});

test('kebabSlug: parity with Swift NeedCarterKind.slug (for logging / the Stage-1 pattern gate)', () => {
  assert.equal(kebabSlug('decisionYours'), 'decision-yours');
  assert.equal(kebabSlug('pickOption'), 'pick-option');
  assert.equal(kebabSlug('checkpointReady'), 'checkpoint-ready');
  assert.equal(kebabSlug('go'), 'go');
  assert.equal(kebabSlug('bogus'), 'unknown');
});
