// dial-registry.test.mjs — device registration (/dial/register logic) + the deterministic dispatch payload wire.
// Hermetic: in-memory deviceRegistry + injected clock. Proves humanId-from-token binding, membership gating,
// fail-closed (no registry -> 501), and a stable/testable payload for forge decode() (id/who/priority).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  createDialRegistry, createDialPushBackend, createStoreDeviceRegistry, validateRegistration, validateUnregistration,
  buildDialPayload, computeDialId, DIAL_LIMITS, DIAL_PRIORITIES, DIAL_PUSHKIT_CAP, DIAL_PAYLOAD_MAX_BYTES,
} from '../src/dial-registry.mjs';
import { createInMemoryStore } from '../src/store.mjs';

// Shared byte fixtures — the SAME file forge's Swift decoder byte-matches (KAV parity). Generated from buildDialPayload.
const fixtures = JSON.parse(readFileSync(new URL('./fixtures/dial-payload-v1.json', import.meta.url), 'utf8'));
const bindingV2Fixture = JSON.parse(readFileSync(new URL('./fixtures/dial-binding-v2.json', import.meta.url), 'utf8'));

const NOW = 1_770_000_000_000; // fixed injected clock
const fakeRegistry = () => {
  const records = [];
  return {
    records,
    async register(r) { records.push(r); return { deviceCount: records.filter((x) => x.humanId === r.humanId && x.sessionId === r.sessionId).length }; },
    async lookup({ humanId, sessionId }) { return records.filter((x) => x.humanId === humanId && x.sessionId === sessionId).map((x) => ({ voipToken: x.voipToken, platform: x.platform })); },
  };
};

test('computeDialId: deterministic, prefixed, and injective over its inputs', () => {
  const id = computeDialId('u', 'sess-1', 'ring', NOW);
  assert.equal(id, computeDialId('u', 'sess-1', 'ring', NOW), 'same inputs -> same id');
  assert.match(id, /^dial_[A-Za-z0-9_-]{16}$/);
  // each field participates (length-prefixed join => no boundary collision)
  assert.notEqual(id, computeDialId('u2', 'sess-1', 'ring', NOW));
  assert.notEqual(id, computeDialId('u', 'sess-2', 'ring', NOW));
  assert.notEqual(id, computeDialId('u', 'sess-1', 'ring!', NOW));
  assert.notEqual(id, computeDialId('u', 'sess-1', 'ring', NOW + 1));
  // boundary-collision guard: ("a","bc") vs ("ab","c") must differ
  assert.notEqual(computeDialId('a', 'bc', 'm', NOW), computeDialId('ab', 'c', 'm', NOW));
});

test('validateRegistration: happy path defaults platform to apns', () => {
  assert.deepEqual(validateRegistration({ voipToken: ' abc ', sessionId: ' sess-1 ' }), { ok: true, value: { voipToken: 'abc', sessionId: 'sess-1', platform: 'apns' } });
  assert.deepEqual(validateRegistration({ voipToken: 'abc', sessionId: 'sess-1', platform: 'FCM' }).value.platform, 'fcm');
});

test('validateRegistration: rejects missing/oversized/bad fields', () => {
  assert.deepEqual(validateRegistration({ sessionId: 'sess-1' }), { ok: false, status: 400, error: 'voipToken required' });
  assert.equal(validateRegistration({ voipToken: 'x'.repeat(DIAL_LIMITS.VOIP_TOKEN + 1), sessionId: 'sess-1' }).status, 413);
  assert.deepEqual(validateRegistration({ voipToken: 'abc' }), { ok: false, status: 400, error: 'sessionId required' });
  assert.equal(validateRegistration({ voipToken: 'abc', sessionId: 'sess-1', platform: 'carrier-pigeon' }).status, 400);
  assert.equal(validateRegistration(null).ok, false);
});

test('buildDialPayload v1: RICH shape (core + governed), deterministic, legacy defaults', () => {
  const p = buildDialPayload({ humanId: 'u', sessionId: 'sess-1', message: 'Two shipped; one blocker.', priority: 'high', who: 'Warden' }, NOW);
  assert.deepEqual(Object.keys(p).sort(), ['callerName', 'fetch', 'id', 'kind', 'message', 'priority', 'sessionId', 'ts', 'v', 'who']);
  assert.equal(p.v, 1);
  assert.equal(p.fetch, false, 'fits -> complete/renderable');
  assert.equal(p.kind, 'info', 'legacy default kind');
  assert.equal(p.callerName, 'Senti needs you', 'legacy default callerName');
  assert.equal(p.id, computeDialId('u', 'sess-1', 'Two shipped; one blocker.', NOW), 'no override -> computeDialId');
  assert.equal(p.who, 'Warden');
  assert.equal(p.priority, 'high');
  assert.equal(p.ts, new Date(NOW).toISOString());
  assert.deepEqual(p, buildDialPayload({ humanId: 'u', sessionId: 'sess-1', message: 'Two shipped; one blocker.', priority: 'high', who: 'Warden' }, NOW), 'deterministic');
  const d = buildDialPayload({ humanId: 'u', sessionId: 'sess-1', message: 'x', priority: 'nope' }, NOW);
  assert.equal(d.who, 'senti-pocket', 'who default');
  assert.equal(d.priority, 'medium', 'unknown priority -> medium');
  assert.equal('context' in d, false, 'no context key when absent');
  assert.ok(DIAL_PRIORITIES.includes('urgent'), 'urgent kept in sync with warden /dial');
});

test('buildDialPayload v1: signal core fields — opaque id override, kind, callerName, checkpointId (write-kind -> LEAN, governed shed)', () => {
  const p = buildDialPayload({ humanId: 'u', sessionId: '6cf7e861', id: 'need_1', kind: 'decisionYours', callerName: 'Senti needs your decision', message: 'Ship it?', checkpointId: 'cp_9', evidenceSeqs: [315050, 315038, 315038, 315050] }, NOW);
  assert.equal(p.id, 'need_1', 'opaque id override used verbatim (NOT computeDialId)');
  assert.equal(p.kind, 'decisionYours');
  assert.equal(p.callerName, 'Senti needs your decision');
  assert.equal(p.checkpointId, 'cp_9', 'checkpointId is CORE -> stays on the doorbell (not governed content)');
  assert.equal(p.fetch, true, 'decisionYours is a WRITE-KIND -> ALWAYS a LEAN doorbell (Warden push-model)');
  assert.equal('message' in p, false, 'governed question SHED from the push (hydrate via GET /dial?id=)');
  assert.equal('evidenceSeqs' in p, false, 'governed evidenceSeqs SHED from the push');
});

test('buildDialPayload v1: info RICH carries governed (message/context/evidenceSeqs dedup+sort/confidence) when it fits', () => {
  const p = buildDialPayload({ humanId: 'u', sessionId: '6cf7e861', id: 'need_4', kind: 'info', callerName: 'Senti · update', message: 'Deploy green.', context: 'summary', evidenceSeqs: [520, 511, 511, 520], confidence: 0.8 }, NOW);
  assert.equal(p.fetch, false, 'info is LOW-SENSITIVITY -> RICH when it fits');
  assert.equal(p.message, 'Deploy green.');
  assert.equal(p.context, 'summary');
  assert.deepEqual(p.evidenceSeqs, [511, 520], 'de-duped + sorted ascending (deterministic)');
  assert.equal(p.confidence, 0.8);
});

test('buildDialPayload v1: pickOption is a WRITE-KIND -> LEAN (options SHED from the push); empty options still throws (validated pre-shed)', () => {
  const p = buildDialPayload({ sessionId: 's', message: 'which?', kind: 'pickOption', options: ['A', 'B'] }, NOW);
  assert.equal(p.fetch, true, 'pickOption -> LEAN doorbell');
  assert.equal('options' in p, false, 'options SHED from the push (never ride it) -> hydrate via GET /dial?id=');
  assert.equal('message' in p, false, 'the question is SHED too');
  assert.throws(() => buildDialPayload({ sessionId: 's', message: 'which?', kind: 'pickOption', options: [] }, NOW), /pickOption requires/, 'malformed pickOption fails closed BEFORE it is shed to LEAN');
});

test('buildDialPayload v1 SECURITY: every WRITE-KIND is a LEAN doorbell even when tiny — governed content NEVER in the push', () => {
  for (const kind of ['decisionYours', 'go']) {
    const p = buildDialPayload({ sessionId: 's', id: 'need_x', kind, callerName: 'c', message: 'approve the wire to acct Y?', context: 'sensitive', evidenceSeqs: [1, 2], confidence: 0.9 }, NOW);
    assert.equal(p.fetch, true, `${kind} forces LEAN even when it would fit RICH`);
    for (const g of ['message', 'context', 'options', 'evidenceSeqs', 'confidence']) assert.equal(g in p, false, `${kind}: governed ${g} shed from the push`);
    assert.equal(p.kind, kind); assert.equal(p.id, 'need_x'); assert.equal(p.sessionId, 's'); // core survives (the doorbell still routes)
  }
  const po = buildDialPayload({ sessionId: 's', id: 'need_y', kind: 'pickOption', options: ['A', 'B'], message: 'which?' }, NOW);
  assert.equal(po.fetch, true); assert.equal('options' in po, false); assert.equal('message' in po, false);
});

test('buildDialPayload v1: over-budget -> LEAN (fetch=true, ALL governed shed, core-only); NEVER truncates the question', () => {
  const big = buildDialPayload({ humanId: 'u', sessionId: 's', id: 'need_big', kind: 'info', message: 'Q'.repeat(4000), context: 'C'.repeat(2000) }, NOW);
  assert.equal(big.fetch, true, 'message+context exceed budget -> LEAN');
  assert.equal('message' in big, false, 'governed content shed (hydrate via GET), not truncated');
  assert.equal('context' in big, false);
  assert.equal(big.id, 'need_big', 'core identity preserved for the ring + hydration');
  assert.ok(Buffer.byteLength(JSON.stringify(big)) <= DIAL_PAYLOAD_MAX_BYTES, 'lean core within budget');
});

test('buildDialPayload v1: confidence rides a RICH low-sensitivity ring (present when it fits; clamped); a write-kind sheds it', () => {
  const p = buildDialPayload({ sessionId: 's', message: 'm', kind: 'checkpointReady', confidence: 0.87 }, NOW);
  assert.equal(p.confidence, 0.87);
  assert.equal(p.fetch, false, 'checkpointReady is low-sensitivity -> RICH when it fits');
  assert.equal(buildDialPayload({ sessionId: 's', message: 'm', kind: 'checkpointReady', confidence: 1.9 }, NOW).confidence, 1, 'clamped to [0,1]');
  const g = buildDialPayload({ sessionId: 's', message: 'm', kind: 'go', confidence: 0.87 }, NOW);
  assert.equal(g.fetch, true, 'go is a write-kind -> LEAN'); assert.equal('confidence' in g, false, 'confidence shed from a write-kind doorbell');
});

test('buildDialPayload v1: identity FAIL-CLOSED (blank/overbound/control id|sessionId, present-invalid checkpointId); opaque need_1 accepted', () => {
  assert.throws(() => buildDialPayload({ sessionId: '', message: 'x' }, NOW), /sessionId required/);
  assert.throws(() => buildDialPayload({ sessionId: 'x'.repeat(129), message: 'm' }, NOW), /exceeds/);
  assert.throws(() => buildDialPayload({ sessionId: 's', id: 'a' + String.fromCharCode(1) + 'b', message: 'm' }, NOW), /control chars/);
  assert.throws(() => buildDialPayload({ sessionId: 's', checkpointId: 'c'.repeat(129), message: 'm' }, NOW), /checkpointId exceeds/);
  // the SHIPPED NeedCarterSignal opaque vector is ACCEPTED — never require dial_/UUID syntax (Pulse C)
  assert.equal(buildDialPayload({ humanId: 'u', sessionId: '6cf7e861', id: 'need_1', kind: 'go', message: 'm' }, NOW).id, 'need_1');
});

test('buildDialPayload v1: EVERY shared fixture reproduced byte-for-byte + declared bytes locked (KAV parity for forge)', () => {
  assert.ok(Object.keys(fixtures.cases).length >= 5, 'fixtures present (incl max_core)');
  for (const [name, c] of Object.entries(fixtures.cases)) {
    const got = buildDialPayload(c.input, fixtures.meta.clockMs);
    assert.deepEqual(got, c.payload, `fixture ${name} reproduced exactly (drift -> regenerate the fixture)`);
    const bytes = Buffer.byteLength(JSON.stringify(got), 'utf8');
    assert.equal(bytes, c.bytes, `fixture ${name} declared byte count === actual (R6 metadata lock; catches serialization drift)`);
    assert.ok(bytes <= DIAL_PUSHKIT_CAP, `fixture ${name} <= 5120 (PushKit cap)`);
  }
  // R6: the max-core case proves the WORST-CASE core (exact 128-byte identities + 128 astral display codepoints) fits as LEAN.
  const mc = fixtures.cases.max_core;
  assert.ok(mc, 'max_core fixture present');
  assert.equal(mc.payload.fetch, true, 'max_core is LEAN (all governed shed)');
  assert.equal('message' in mc.payload, false, 'max_core is core-only');
  assert.ok(mc.bytes <= DIAL_PAYLOAD_MAX_BYTES, `max_core core (${mc.bytes}B) <= ${DIAL_PAYLOAD_MAX_BYTES} budget`);
});

test('pushBackend: a resolved device with invalid identity -> fail-closed invalid-dial-payload (never a garbage ring)', async () => {
  const badSession = 'bad' + String.fromCharCode(1); // control char -> buildDialPayload throws
  const reg = fakeRegistry();
  await reg.register({ humanId: 'u', sessionId: badSession, voipToken: 't', platform: 'apns' }); // device found -> reaches buildDialPayload
  const sent = [];
  const pb = createDialPushBackend({ deviceRegistry: reg, apnsSend: async (a) => { sent.push(a); return { delivered: true }; }, now: () => NOW });
  const out = await pb({ message: 'm', sessionId: badSession, humanId: 'u' });
  assert.deepEqual(out, { dispatched: false, reason: 'invalid-dial-payload' });
  assert.equal(sent.length, 0, 'no ring sent on a fail-closed payload');
});

// ── R1-R4 regression vectors (Pulse impl review of #77 @ ca1a095) ────────────────────────────────────────────
test('R1: pickOption options validated-but-SHED — a large valid set is accepted (never capped-to-error) then shed to LEAN; invalid fails closed', () => {
  // pickOption is a WRITE-KIND -> ALWAYS LEAN, so options never ride the push (the full, uncapped set hydrates via GET
  // /dial?id=). buildDialPayload still VALIDATES options (fail-closed on an invalid label) before shedding them.
  const opts = Array.from({ length: 9 }, (_, i) => 'option-' + i);
  const p = buildDialPayload({ sessionId: 's', message: 'which?', kind: 'pickOption', options: opts }, NOW);
  assert.equal(p.fetch, true, 'pickOption -> LEAN doorbell');
  assert.equal('options' in p, false, 'all 9 options SHED from the push (never capped, never on the wire) — hydrate via GET');
  const longLabel = 'L'.repeat(200);
  assert.equal('options' in buildDialPayload({ sessionId: 's', message: 'q', kind: 'pickOption', options: [longLabel] }, NOW), false, 'a 200-char label is accepted (not truncated-to-error) then shed');
  assert.throws(() => buildDialPayload({ sessionId: 's', message: 'q', kind: 'pickOption', options: ['ok', ''] }, NOW), /non-empty string/, 'invalid label fails closed BEFORE shedding');
});

test('R1: evidenceSeqs are COMPLETE — 65 stay 65 (deduped/sorted, never capped); unsafe/invalid ints fail closed', () => {
  const seqs = Array.from({ length: 65 }, (_, i) => i + 1);
  assert.equal(buildDialPayload({ sessionId: 's', message: 'm', evidenceSeqs: seqs }, NOW).evidenceSeqs.length, 65, 'all 65 preserved (was capped to 64)');
  assert.throws(() => buildDialPayload({ sessionId: 's', message: 'm', evidenceSeqs: [9007199254740993] }, NOW), /positive safe integer/, 'unsafe int64 -> fail closed (no numeric corruption)');
  assert.throws(() => buildDialPayload({ sessionId: 's', message: 'm', evidenceSeqs: [-1] }, NOW), /positive safe integer/);
  assert.throws(() => buildDialPayload({ sessionId: 's', message: 'm', evidenceSeqs: [1.5] }, NOW), /positive safe integer/);
});

test('R5: PRESENT non-array evidenceSeqs/options/checkpointId fail closed; ONLY undefined is absent', () => {
  assert.equal('evidenceSeqs' in buildDialPayload({ sessionId: 's', message: 'm' }, NOW), false, 'absent (undefined) evidenceSeqs -> omitted');
  assert.throws(() => buildDialPayload({ sessionId: 's', message: 'm', evidenceSeqs: '315' }, NOW), /must be an array/, 'string evidenceSeqs rejected (was silently [])');
  assert.throws(() => buildDialPayload({ sessionId: 's', message: 'm', evidenceSeqs: { 0: 315 } }, NOW), /must be an array/, 'object evidenceSeqs rejected');
  assert.throws(() => buildDialPayload({ sessionId: 's', message: 'm', evidenceSeqs: null }, NOW), /must be an array/, 'null evidenceSeqs rejected (present-invalid, not absent)');
  assert.throws(() => buildDialPayload({ sessionId: 's', message: 'q', kind: 'pickOption', options: 'A' }, NOW), /must be an array/, 'string options rejected');
  assert.throws(() => buildDialPayload({ sessionId: 's', message: 'm', checkpointId: null }, NOW), /checkpointId/, 'null checkpointId rejected (only undefined is absent)');
});

test('R2: kind absent -> info (legacy); PRESENT-invalid -> fail closed; message required', () => {
  assert.equal(buildDialPayload({ sessionId: 's', message: 'm' }, NOW).kind, 'info', 'absent kind -> legacy info');
  assert.throws(() => buildDialPayload({ sessionId: 's', message: 'm', kind: 'bogus' }, NOW), /unknown kind/, 'present-invalid kind fails closed');
  assert.throws(() => buildDialPayload({ sessionId: 's', id: 'i' }, NOW), /message required/, 'no message -> fail closed (fetch=false must carry a validated question)');
  assert.throws(() => buildDialPayload({ sessionId: 's', message: '   ' }, NOW), /message required/, 'whitespace-only message -> fail closed');
});

test('R3: opaque id — whitespace-only rejected; a valid opaque value kept UNALTERED; C1 controls rejected', () => {
  assert.throws(() => buildDialPayload({ sessionId: 's', id: '   ', message: 'm' }, NOW), /required/, 'whitespace-only id rejected');
  assert.equal(buildDialPayload({ sessionId: 's', id: ' need 1 ', message: 'm' }, NOW).id, ' need 1 ', 'valid opaque value kept byte-for-byte (not trimmed)');
  const c1 = 'a' + String.fromCharCode(0x85) + 'b'; // U+0085 NEL — a C1 control
  assert.throws(() => buildDialPayload({ sessionId: 's', id: c1, message: 'm' }, NOW), /control chars/, 'C1 control in id rejected (was only C0+DEL)');
  assert.throws(() => buildDialPayload({ sessionId: c1, message: 'm' }, NOW), /control chars/, 'C1 control in sessionId rejected');
});

test('R4: display truncation is codepoint-safe — never a lone surrogate at the bound', () => {
  const emoji = String.fromCodePoint(0x1f600); // an astral char (surrogate pair)
  // 'a'*127 + emoji + 'b' = 129 codepoints -> slice(0,128) keeps 'a'*127 + the WHOLE emoji. OLD .slice(0,128) split the pair.
  const split = buildDialPayload({ sessionId: 's', message: 'm', callerName: 'a'.repeat(127) + emoji + 'b' }, NOW).callerName;
  assert.equal([...split].length, 128, 'bounded to 128 codepoints');
  assert.ok(split.endsWith(emoji), 'emoji at the 128th codepoint kept whole');
  assert.equal(Buffer.from(split, 'utf8').toString('utf8'), split, 'valid UTF-8 — no lone surrogate');
  assert.equal(buildDialPayload({ sessionId: 's', message: 'm', callerName: 'a'.repeat(200) + emoji }, NOW).callerName, 'a'.repeat(128), 'past-bound astral char dropped whole');
});

test('register: happy path binds token to the token-derived humanId (never the body)', async () => {
  const reg = fakeRegistry();
  const svc = createDialRegistry({ deviceRegistry: reg, now: () => NOW });
  const r = await svc.register({ humanId: 'u', body: { voipToken: 'tok-1', sessionId: 'sess-1' }, isMember: async () => true });
  assert.equal(r.status, 200);
  assert.deepEqual(r.body, { registered: true, sessionId: 'sess-1', platform: 'apns', deviceCount: 1 });
  // the stored record is keyed by the humanId ARGUMENT (from the verified token), with the injected registeredAt
  assert.equal(reg.records[0].humanId, 'u');
  assert.equal(reg.records[0].voipToken, 'tok-1');
  assert.equal(reg.records[0].registeredAt, new Date(NOW).toISOString());
  // idempotent-ish upsert bumps deviceCount for a 2nd device on the same session
  const r2 = await svc.register({ humanId: 'u', body: { voipToken: 'tok-2', sessionId: 'sess-1' }, isMember: async () => true });
  assert.equal(r2.body.deviceCount, 2);
});

test('register: fail-closed — invalid body 4xx, no registry 501, non-member 403', async () => {
  const reg = fakeRegistry();
  const svc = createDialRegistry({ deviceRegistry: reg, now: () => NOW });
  assert.equal((await svc.register({ humanId: 'u', body: { sessionId: 'sess-1' }, isMember: async () => true })).status, 400); // no token
  assert.equal((await svc.register({ humanId: 'u', body: { voipToken: 't', sessionId: 'other' }, isMember: async () => false })).status, 403);
  assert.equal(reg.records.length, 0, 'nothing written on a rejected register');
  // no registry wired -> 501 dial-not-configured (checked AFTER validation so a bad body still 400s first)
  const noReg = createDialRegistry({ now: () => NOW });
  const r = await noReg.register({ humanId: 'u', body: { voipToken: 't', sessionId: 'sess-1' }, isMember: async () => true });
  assert.equal(r.status, 501);
  assert.match(r.body.reason, /dial-not-configured/);
});

test('register: isMember throw -> 500; registry.register throw -> 502 (honest, never a silent success)', async () => {
  const svc500 = createDialRegistry({ deviceRegistry: fakeRegistry(), now: () => NOW });
  assert.equal((await svc500.register({ humanId: 'u', body: { voipToken: 't', sessionId: 's' }, isMember: async () => { throw new Error('lookup down'); } })).status, 500);
  const throwingReg = { async register() { throw new Error('dynamo down'); } };
  const svc502 = createDialRegistry({ deviceRegistry: throwingReg, now: () => NOW });
  const r = await svc502.register({ humanId: 'u', body: { voipToken: 't', sessionId: 's' }, isMember: async () => true });
  assert.equal(r.status, 502);
  assert.match(r.body.reason, /registry-write-failed/);
});

test('service buildPayload uses the injected clock', () => {
  const svc = createDialRegistry({ deviceRegistry: fakeRegistry(), now: () => NOW });
  assert.equal(svc.buildPayload({ humanId: 'u', sessionId: 's', message: 'm' }).ts, new Date(NOW).toISOString());
});

// ---- createDialPushBackend: the registry-backed impl warden's /dial calls ------------------------------------------

test('pushBackend: happy path resolves the registered device, sends the deterministic payload, dispatched=true', async () => {
  const reg = fakeRegistry();
  await reg.register({ humanId: 'u', sessionId: 'sess-1', voipToken: 'tok-1', platform: 'apns' });
  const sent = [];
  const apnsSend = async (a) => { sent.push(a); return { delivered: true }; };
  const pb = createDialPushBackend({ deviceRegistry: reg, apnsSend, now: () => NOW });
  const out = await pb({ message: 'ship it?', context: 'ctx', priority: 'high', sessionId: 'sess-1', humanId: 'u' });
  assert.deepEqual(out, { dispatched: true, dialId: computeDialId('u', 'sess-1', 'ship it?', NOW), delivered: 1, devices: 1 });
  assert.equal(sent[0].voipToken, 'tok-1');
  assert.equal(sent[0].payload.id, out.dialId, 'payload id == returned dialId');
  assert.equal(sent[0].payload.priority, 'high');
  assert.equal(sent[0].payload.message, 'ship it?');
});

test('pushBackend: 0 registered devices -> no-device-token (== warden /dial 502 expectation)', async () => {
  const pb = createDialPushBackend({ deviceRegistry: fakeRegistry(), apnsSend: async () => ({ delivered: true }), now: () => NOW });
  assert.deepEqual(await pb({ message: 'x', sessionId: 'sess-1', humanId: 'u' }), { dispatched: false, reason: 'no-device-token' });
});

test('pushBackend: fail-closed at every gap (never a fake dispatch)', async () => {
  // no registry
  assert.equal((await createDialPushBackend({ apnsSend: async () => ({ delivered: true }) })({ humanId: 'u', sessionId: 's' })).reason, 'dial-not-configured');
  // lookup throws
  const throwing = { lookup: async () => { throw new Error('dynamo down'); } };
  assert.equal((await createDialPushBackend({ deviceRegistry: throwing, apnsSend: async () => ({ delivered: true }) })({ humanId: 'u', sessionId: 's' })).reason, 'registry-lookup-failed');
  // registered device but no apnsSend transport
  const reg = fakeRegistry();
  await reg.register({ humanId: 'u', sessionId: 's', voipToken: 't', platform: 'apns' });
  assert.equal((await createDialPushBackend({ deviceRegistry: reg })({ humanId: 'u', sessionId: 's', message: 'm' })).reason, 'push-transport-not-configured');
});

test('pushBackend: fan-out — one dead token never fails the ring; all-fail is honest', async () => {
  const reg = fakeRegistry();
  await reg.register({ humanId: 'u', sessionId: 's', voipToken: 'good', platform: 'apns' });
  await reg.register({ humanId: 'u', sessionId: 's', voipToken: 'dead', platform: 'apns' });
  const apnsSend = async ({ voipToken }) => { if (voipToken === 'dead') throw new Error('BadDeviceToken'); return { delivered: true }; };
  const out = await createDialPushBackend({ deviceRegistry: reg, apnsSend, now: () => NOW })({ message: 'm', sessionId: 's', humanId: 'u' });
  assert.equal(out.dispatched, true);
  assert.equal(out.delivered, 1);
  assert.equal(out.devices, 2);
  // ALL deliveries fail -> honest all-deliveries-failed (still carries the dialId)
  const allFail = createDialPushBackend({ deviceRegistry: reg, apnsSend: async () => ({ delivered: false }), now: () => NOW });
  const r = await allFail({ message: 'm', sessionId: 's', humanId: 'u' });
  assert.equal(r.dispatched, false);
  assert.equal(r.reason, 'all-deliveries-failed');
  assert.equal(r.dialId, computeDialId('u', 's', 'm', NOW));
});

// ---- pushBackend PR-B2: rich-field passthrough + GET /dial?id= hydration store-write --------------------------------
const fakeSignalStore = () => { const m = new Map(); return { async put(id, sig) { m.set(id, sig); return { stored: true, expiresAtSec: 0 }; }, async get(id) { return m.get(id); } }; };

test('pushBackend PR-B2: RICH low-sensitivity (info) ring threads rich fields onto the payload + stores the full signal', async () => {
  const reg = fakeRegistry();
  await reg.register({ humanId: 'u', sessionId: '6cf7e861', voipToken: 'tok', platform: 'apns' });
  const sent = [];
  const sig = fakeSignalStore();
  // info is a LOW-SENSITIVITY kind -> RICH-eligible, so its governed fields DO ride the push when they fit (a write-kind
  // would force LEAN; that is covered by the SECURITY test in buildDialPayload + the LEAN fail-closed test below).
  const storedSignal = { id: 'need_1', kind: { info: {} }, question: 'Deploy done.', context: { sessionId: '6cf7e861', whatWeNeed: 'fyi' }, confidence: 0.9, requestedBy: 'claude-warden' };
  const pb = createDialPushBackend({ deviceRegistry: reg, apnsSend: async (a) => { sent.push(a); return { delivered: true }; }, now: () => NOW, signalStore: sig });
  const out = await pb({ message: 'Deploy done.', context: 'fyi', priority: 'medium', sessionId: '6cf7e861', humanId: 'u', id: 'need_1', kind: 'info', callerName: 'Senti · update from relay', evidenceSeqs: [315038], confidence: 0.9, storedSignal });
  assert.equal(out.dispatched, true);
  assert.equal(out.dialId, 'need_1', 'signal-originated id becomes the dialId (== the store key)');
  const p = sent[0].payload;
  assert.equal(p.fetch, false, 'small info signal -> RICH (self-contained)');
  assert.equal(p.kind, 'info');
  assert.equal(p.callerName, 'Senti · update from relay');
  assert.deepEqual(p.evidenceSeqs, [315038], 'rich fields reach the wire (were dropped pre-PR-B2)');
  assert.deepEqual(await sig.get('need_1'), storedSignal, 'full signal stored under the dialId for GET /dial?id=');
});

test('pushBackend PR-B2: LEAN ring FAILS CLOSED when the signal cannot be persisted (no dead doorbell)', async () => {
  const reg = fakeRegistry();
  await reg.register({ humanId: 'u', sessionId: 's', voipToken: 'tok', platform: 'apns' });
  const bigMsg = 'Q'.repeat(4000), bigCtx = 'C'.repeat(2000); // over budget -> buildDialPayload emits LEAN (fetch=true)
  const storedSignal = { id: 'need_big', kind: { info: {} }, question: bigMsg, context: { sessionId: 's', whatWeNeed: bigCtx }, confidence: 0.9, requestedBy: 'detector' };
  const base = { message: bigMsg, context: bigCtx, sessionId: 's', humanId: 'u', id: 'need_big', kind: 'info', storedSignal };
  let sent = 0;
  const apnsSend = async () => { sent += 1; return { delivered: true }; };
  // (a) store-write THROWS -> a LEAN ring must fail closed BEFORE the phone is rung
  const throwingStore = { async put() { throw new Error('dynamo down'); }, async get() {} };
  assert.deepEqual(await createDialPushBackend({ deviceRegistry: reg, apnsSend, now: () => NOW, signalStore: throwingStore })(base),
    { dispatched: false, reason: 'signal-store-write-failed' });
  assert.equal(sent, 0, 'a LEAN ring that could not persist NEVER reached the phone');
  // (b) NO signalStore wired at all + LEAN -> fail closed (no hydration source)
  assert.equal((await createDialPushBackend({ deviceRegistry: reg, apnsSend, now: () => NOW })(base)).reason, 'signal-store-not-configured');
  // (c) store OK -> the LEAN ring fires AND the full (untruncated) signal is persisted for hydration
  const sig = fakeSignalStore();
  const outOk = await createDialPushBackend({ deviceRegistry: reg, apnsSend, now: () => NOW, signalStore: sig })(base);
  assert.equal(outOk.dispatched, true);
  assert.equal(sent, 1, 'exactly one ring after a successful persist');
  assert.equal((await sig.get('need_big')).question, bigMsg, 'full untruncated signal stored for GET /dial?id= hydration');
});

test('pushBackend PR-B2: RICH (low-sensitivity) ring rings anyway when the best-effort store-write fails (self-contained payload)', async () => {
  const reg = fakeRegistry();
  await reg.register({ humanId: 'u', sessionId: 's', voipToken: 'tok', platform: 'apns' });
  // info is RICH-eligible, so the payload is self-contained -> a store-write hiccup is best-effort, never blocks the ring.
  // (A write-kind would be LEAN and MUST persist -> fail-closed; that is the LEAN test above, not this one.)
  const storedSignal = { id: 'need_1', kind: { info: {} }, question: 'FYI: deploy green.', context: { sessionId: 's', whatWeNeed: 'note' }, confidence: 0.9, requestedBy: 'detector' };
  let sent = 0;
  const throwingStore = { async put() { throw new Error('dynamo down'); }, async get() {} };
  const out = await createDialPushBackend({ deviceRegistry: reg, apnsSend: async () => { sent += 1; return { delivered: true }; }, now: () => NOW, signalStore: throwingStore })(
    { message: 'FYI: deploy green.', sessionId: 's', humanId: 'u', id: 'need_1', kind: 'info', storedSignal });
  assert.equal(out.dispatched, true, 'RICH info ring is self-contained -> a store hiccup never blocks it');
  assert.equal(sent, 1, 'the phone still got the complete RICH push');
});

test('pushBackend PR-B2: legacy /dial path (no storedSignal) rings with NO store-write (backward-compatible)', async () => {
  const reg = fakeRegistry();
  await reg.register({ humanId: 'u', sessionId: 's', voipToken: 'tok', platform: 'apns' });
  let putCalls = 0;
  const spyStore = { async put() { putCalls += 1; return { stored: true }; }, async get() {} };
  const out = await createDialPushBackend({ deviceRegistry: reg, apnsSend: async () => ({ delivered: true }), now: () => NOW, signalStore: spyStore })(
    { message: 'ship it?', sessionId: 's', humanId: 'u' });
  assert.equal(out.dispatched, true);
  assert.equal(putCalls, 0, 'no storedSignal -> the store is never written (legacy behavior preserved)');
  assert.equal(out.dialId, computeDialId('u', 's', 'ship it?', NOW), 'legacy computed dialId unchanged');
});

test('createStoreDeviceRegistry: register (atomic put) + lookup over the KV store; latest-wins single device v1', async () => {
  const m = new Map();
  const store = { async get(k) { return m.get(k); }, async put(k, v) { m.set(k, v); return v; } };
  const reg = createStoreDeviceRegistry({ store, now: () => NOW });
  assert.deepEqual(await reg.lookup({ humanId: 'u', sessionId: 's' }), [], 'empty before register');
  assert.deepEqual(await reg.register({ humanId: 'u', sessionId: 's', voipToken: 'tok-1', platform: 'apns' }), { deviceCount: 1 });
  assert.deepEqual(await reg.lookup({ humanId: 'u', sessionId: 's' }), [{ voipToken: 'tok-1', platform: 'apns' }]);
  // re-register the same session -> latest device wins (v1 single-device semantics, not a race)
  await reg.register({ humanId: 'u', sessionId: 's', voipToken: 'tok-2', platform: 'fcm' });
  assert.deepEqual(await reg.lookup({ humanId: 'u', sessionId: 's' }), [{ voipToken: 'tok-2', platform: 'fcm' }]);
  // isolation: a different human is a distinct record
  assert.deepEqual(await reg.lookup({ humanId: 'other', sessionId: 's' }), []);
  // key injection-safe (humanId length-prefixed): ("a","b:c") vs ("a:b","c") never collide
  await reg.register({ humanId: 'a', sessionId: 'b:c', voipToken: 'x', platform: 'apns' });
  await reg.register({ humanId: 'a:b', sessionId: 'c', voipToken: 'y', platform: 'apns' });
  assert.equal((await reg.lookup({ humanId: 'a', sessionId: 'b:c' }))[0].voipToken, 'x');
  assert.equal((await reg.lookup({ humanId: 'a:b', sessionId: 'c' }))[0].voipToken, 'y');
});

test('createStoreDeviceRegistry: requires a get/put store', () => {
  assert.throws(() => createStoreDeviceRegistry({}), /requires a \{ get, put \} store/);
});

test('createStoreDeviceRegistry composes with createDialPushBackend end-to-end (register -> lookup -> ring)', async () => {
  const m = new Map();
  const store = { async get(k) { return m.get(k); }, async put(k, v) { m.set(k, v); return v; } };
  const reg = createStoreDeviceRegistry({ store, now: () => NOW });
  await reg.register({ humanId: 'u', sessionId: 's', voipToken: 'tok-store', platform: 'apns' });
  const sent = [];
  const pb = createDialPushBackend({ deviceRegistry: reg, apnsSend: async (a) => { sent.push(a); return { delivered: true }; }, now: () => NOW });
  const out = await pb({ message: 'ring', sessionId: 's', humanId: 'u' });
  assert.equal(out.dispatched, true);
  assert.equal(sent[0].voipToken, 'tok-store', 'the store-registered token is resolved + rung');
});

test('pushBackend: duplicate voipToken records ring the device ONCE (dedup — no double-ring on re-login)', async () => {
  const reg = fakeRegistry();
  await reg.register({ humanId: 'u', sessionId: 's', voipToken: 'same', platform: 'apns' });
  await reg.register({ humanId: 'u', sessionId: 's', voipToken: 'same', platform: 'apns' }); // a re-login left a 2nd record for the same device
  const sent = [];
  const pb = createDialPushBackend({ deviceRegistry: reg, apnsSend: async (a) => { sent.push(a); return { delivered: true }; }, now: () => NOW });
  const out = await pb({ message: 'm', sessionId: 's', humanId: 'u' });
  assert.equal(sent.length, 1, 'the duplicate token is rung exactly once');
  assert.equal(out.devices, 1, 'device count reflects DISTINCT devices');
  assert.equal(out.dispatched, true);
});

// ---- Registry V2: installation-owned monotonic lease + exact push proof -------------------------------------------

const V2_HMAC_KEY = 'registry-v2-test-key-material-32-bytes-minimum';
const INSTALL_A = 'A'.repeat(43);
const INSTALL_B = 'B'.repeat(43);
const INSTALL_C = 'C'.repeat(43);
const v2Input = (overrides = {}) => ({
  humanId: 'human-A',
  sessionId: 'session-shared',
  voipToken: 'token-A',
  platform: 'apns',
  installationId: INSTALL_A,
  installationGeneration: '1',
  ...overrides,
});

test('Registry V2 validators require a complete versioned tuple and canonical uint64 generations', () => {
  const valid = validateRegistration({
    voipToken: 'token-A',
    sessionId: 'session-shared',
    platform: 'apns',
    registryVersion: 2,
    installationId: INSTALL_A,
    installationGeneration: '18446744073709551615',
  });
  assert.equal(valid.ok, true);
  assert.equal(valid.value.installationGeneration, '18446744073709551615', 'generation stays an exact decimal string');
  assert.equal(validateRegistration({
    voipToken: 't', sessionId: 's', registryVersion: 2, installationId: INSTALL_A, installationGeneration: 1,
  }).ok, false, 'JSON number generations are rejected before JavaScript precision can matter');
  assert.equal(validateRegistration({
    voipToken: 't', sessionId: 's', installationId: INSTALL_A,
  }).ok, false, 'a partial V2 tuple never downgrades to V1');

  const unreg = validateUnregistration({
    registryVersion: 2,
    installationId: INSTALL_A,
    installationGeneration: '2',
    previousInstallationGeneration: '1',
    bindingId: 'i'.repeat(24),
    bindingRevision: 'r'.repeat(32),
    sessionId: 'session-shared',
  });
  assert.equal(unreg.ok, true);
  assert.equal(validateUnregistration({
    registryVersion: 2,
    installationId: INSTALL_A,
    installationGeneration: '1',
    previousInstallationGeneration: '1',
    bindingId: 'i'.repeat(24),
    bindingRevision: 'r'.repeat(32),
    sessionId: 'session-shared',
  }).ok, false, 'unregister must advance the durable installation generation');
});

test('Registry V2 additive push fixture is reproduced exactly without changing legacy fixture bytes', () => {
  assert.deepEqual(
    buildDialPayload(bindingV2Fixture.input, bindingV2Fixture.nowMs),
    bindingV2Fixture.payload,
  );
});

test('createDialRegistry V2 returns only a validated server binding; unregister is auth-bound but not membership-bound', async () => {
  const calls = [];
  const deviceRegistry = {
    async registerV2(input) {
      calls.push(['register', input]);
      return {
        deviceCount: 1,
        installationGeneration: input.installationGeneration,
        bindingId: 'i'.repeat(24),
        bindingRevision: 'r'.repeat(32),
        leaseExpiresAtSec: Math.floor(NOW / 1000) + 60,
      };
    },
    async unregisterV2(input) { calls.push(['unregister', input]); return { unregistered: true }; },
  };
  const service = createDialRegistry({ deviceRegistry, now: () => NOW });
  const registered = await service.register({
    humanId: 'verified-human',
    principal: 'issuer:site:pairwise-human',
    isMember: async () => true,
    body: {
      registryVersion: 2,
      installationId: INSTALL_A,
      installationGeneration: '1',
      voipToken: 'token-A',
      sessionId: 'session-shared',
      platform: 'apns',
    },
  });
  assert.equal(registered.status, 200);
  assert.equal(registered.body.registryVersion, 2);
  assert.equal(registered.body.bindingRevision, 'r'.repeat(32));
  assert.equal(calls[0][1].humanId, 'verified-human', 'humanId is still derived from auth, never the body');
  assert.equal(calls[0][1].principal, 'issuer:site:pairwise-human');

  const unregistered = await service.unregister({
    humanId: 'verified-human',
    principal: 'issuer:site:pairwise-human',
    body: {
      registryVersion: 2,
      installationId: INSTALL_A,
      installationGeneration: '2',
      previousInstallationGeneration: '1',
      bindingId: 'i'.repeat(24),
      bindingRevision: 'r'.repeat(32),
      sessionId: 'session-shared',
    },
  });
  assert.deepEqual(unregistered, { status: 200, body: { unregistered: true } });
  assert.equal(calls[1][1].humanId, 'verified-human');
  assert.equal(calls[1][1].principal, 'issuer:site:pairwise-human');
});

test('Registry V2 same-generation retry is idempotent; changed binding conflicts; A→B same-session rebind is global', async () => {
  const store = createInMemoryStore();
  const registry = createStoreDeviceRegistry({ store, now: () => NOW, installationHmacKey: V2_HMAC_KEY });
  const first = await registry.registerV2(v2Input());
  const retry = await registry.registerV2(v2Input());
  assert.equal(retry.bindingId, first.bindingId);
  assert.equal(retry.bindingRevision, first.bindingRevision, 'an exact retry renews the same server revision');

  await assert.rejects(
    registry.registerV2(v2Input({ voipToken: 'changed-at-same-generation' })),
    (error) => error.registryStatus === 409 && error.registryReason === 'binding-generation-conflict',
  );

  const second = await registry.registerV2(v2Input({
    humanId: 'human-B',
    voipToken: 'token-B',
    installationGeneration: '2',
  }));
  assert.notEqual(second.bindingRevision, first.bindingRevision);
  assert.deepEqual(await registry.lookup({ humanId: 'human-A', sessionId: 'session-shared' }), [],
    'A stale target index is inert after the durable installation head moves to B');
  const rowsB = await registry.lookup({ humanId: 'human-B', sessionId: 'session-shared' });
  assert.equal(rowsB.length, 1);
  assert.equal(rowsB[0].voipToken, 'token-B');
  assert.equal(rowsB[0].installationGeneration, '2');
  await assert.rejects(
    registry.registerV2(v2Input()),
    (error) => error.registryStatus === 409 && error.registryReason === 'binding-superseded',
    'a delayed A register cannot roll the durable head back after B completes',
  );

  for (const key of store._records.keys()) {
    assert.equal(key.includes(INSTALL_A), false, 'raw installation id never appears in a store key');
    assert.equal(key.includes('human-A'), false, 'raw human id never appears in a store key');
    assert.equal(key.includes('session-shared'), false, 'raw session id never appears in a store key');
  }
});

test('Registry V2 logical TTL excludes a lease even while the in-memory/Dynamo record physically remains', async () => {
  let clock = NOW;
  const store = createInMemoryStore();
  const registry = createStoreDeviceRegistry({
    store,
    now: () => clock,
    installationHmacKey: V2_HMAC_KEY,
    leaseSeconds: 10,
  });
  await registry.registerV2(v2Input());
  assert.equal((await registry.lookup({ humanId: 'human-A', sessionId: 'session-shared' })).length, 1);
  const physicalRecords = store._records.size;
  clock += 10_000;
  assert.deepEqual(await registry.lookup({ humanId: 'human-A', sessionId: 'session-shared' }), []);
  assert.equal(store._records.size, physicalRecords, 'test store still physically contains TTL records; lookup enforced logical expiry');
});

test('Registry V2 unregister tombstone blocks resurrection; stale cleanup cannot remove a newer B binding', async () => {
  const registry = createStoreDeviceRegistry({
    store: createInMemoryStore(),
    now: () => NOW,
    installationHmacKey: V2_HMAC_KEY,
  });
  const first = await registry.registerV2(v2Input());
  const cleanup = {
    humanId: 'human-A',
    sessionId: 'session-shared',
    installationId: INSTALL_A,
    previousInstallationGeneration: '1',
    installationGeneration: '2',
    bindingId: first.bindingId,
    bindingRevision: first.bindingRevision,
  };
  await registry.unregisterV2(cleanup);
  assert.deepEqual(await registry.lookup({ humanId: 'human-A', sessionId: 'session-shared' }), []);
  await assert.rejects(
    registry.registerV2(v2Input()),
    (error) => error.registryStatus === 409 && error.registryReason === 'binding-superseded',
    'the durable tombstone rejects a delayed generation-1 retry',
  );

  const principalB = await registry.registerV2(v2Input({
    humanId: 'human-B',
    voipToken: 'token-B',
    installationGeneration: '3',
  }));
  await registry.unregisterV2(cleanup); // delayed duplicate A cleanup after B won
  const rowsB = await registry.lookup({ humanId: 'human-B', sessionId: 'session-shared' });
  assert.equal(rowsB.length, 1, 'stale compare-delete must retain B even when the physical installation is the same');
  assert.equal(rowsB[0].bindingRevision, principalB.bindingRevision);
});

test('Registry V2 bounded target index enforces the device cap before lookup fan-out', async () => {
  const registry = createStoreDeviceRegistry({
    store: createInMemoryStore(),
    now: () => NOW,
    installationHmacKey: V2_HMAC_KEY,
    maxDevices: 2,
  });
  await registry.registerV2(v2Input({ installationId: INSTALL_A, voipToken: 'one' }));
  await registry.registerV2(v2Input({ installationId: INSTALL_B, voipToken: 'two' }));
  await assert.rejects(
    registry.registerV2(v2Input({ installationId: INSTALL_C, voipToken: 'three' })),
    (error) => error.registryStatus === 409 && error.registryReason === 'device-cap-reached',
  );
  assert.equal((await registry.lookup({ humanId: 'human-A', sessionId: 'session-shared', limit: 99 })).length, 2);
});

test('Registry V2 namespaces device targets by full principal while membership remains humanId-based', async () => {
  const registry = createStoreDeviceRegistry({
    store: createInMemoryStore(),
    now: () => NOW,
    installationHmacKey: V2_HMAC_KEY,
  });
  await registry.registerV2(v2Input({
    principal: 'issuer-A:site-A:pairwise-1',
    installationId: INSTALL_A,
    voipToken: 'site-A-token',
  }));
  await registry.registerV2(v2Input({
    principal: 'issuer-A:site-B:pairwise-1',
    installationId: INSTALL_B,
    voipToken: 'site-B-token',
  }));

  const siteA = await registry.lookup({
    humanId: 'human-A',
    principal: 'issuer-A:site-A:pairwise-1',
    sessionId: 'session-shared',
  });
  const siteB = await registry.lookup({
    humanId: 'human-A',
    principal: 'issuer-A:site-B:pairwise-1',
    sessionId: 'session-shared',
  });
  assert.deepEqual(siteA.map((row) => row.voipToken), ['site-A-token']);
  assert.deepEqual(siteB.map((row) => row.voipToken), ['site-B-token']);
  assert.deepEqual(
    await registry.lookup({ humanId: 'human-A', sessionId: 'session-shared' }),
    [],
    'the humanId compatibility namespace cannot see either full-principal target',
  );

  const sender = createDialPushBackend({
    deviceRegistry: {
      async lookup() { return [{ voipToken: 'token', platform: 'apns' }]; },
      async revalidate() { return true; },
    },
    apnsSend: async () => ({ delivered: true }),
    now: () => NOW,
  });
  const dialA = await sender({
    humanId: 'human-A',
    principal: 'issuer-A:site-A:pairwise-1',
    sessionId: 'session-shared',
    message: 'same message',
  });
  const dialB = await sender({
    humanId: 'human-A',
    principal: 'issuer-A:site-B:pairwise-1',
    sessionId: 'session-shared',
    message: 'same message',
  });
  assert.notEqual(dialA.dialId, dialB.dialId, 'durable dial/signal identity is full-principal namespaced too');
});

test('Registry V1 migration fallback is exact-principal scoped and ignores untagged historical rows', async () => {
  const store = createInMemoryStore();
  const registry = createStoreDeviceRegistry({
    store,
    now: () => NOW,
    installationHmacKey: V2_HMAC_KEY,
  });
  const principalA = 'issuer-A:site-A:same-human';
  const principalB = 'issuer-A:site-B:same-human';
  await registry.register({
    humanId: 'same-human',
    principal: principalA,
    sessionId: 'same-session',
    voipToken: 'legacy-site-a-token',
    platform: 'apns',
  });

  const siteA = await registry.lookup({
    humanId: 'same-human',
    principal: principalA,
    sessionId: 'same-session',
  });
  assert.deepEqual(siteA.map((row) => row.voipToken), ['legacy-site-a-token']);
  assert.deepEqual(
    await registry.lookup({
      humanId: 'same-human',
      principal: principalB,
      sessionId: 'same-session',
    }),
    [],
    'an equal humanId at another site cannot see the V1 fallback',
  );
  assert.equal(await registry.revalidate({
    humanId: 'same-human',
    principal: principalB,
    sessionId: 'same-session',
    device: siteA[0],
  }), false, 'lookup-to-send revalidation keeps the same full-principal fence');

  await store.put('dial:dev:10:same-human:historical-session', {
    voipToken: 'untagged-historical-token',
    platform: 'apns',
    registeredAt: new Date(NOW).toISOString(),
    expiresAtSec: Math.floor(NOW / 1000) + 60,
  });
  assert.deepEqual(
    await registry.lookup({
      humanId: 'same-human',
      principal: principalA,
      sessionId: 'historical-session',
    }),
    [],
    'historical rows without a principal tag fail closed instead of becoming cross-site authority',
  );
});

test('Registry V2 target-cap rejection happens before head/lease mutation and preserves the old target', async () => {
  const store = createInMemoryStore();
  const registry = createStoreDeviceRegistry({
    store,
    now: () => NOW,
    installationHmacKey: V2_HMAC_KEY,
    maxDevices: 1,
  });
  const old = await registry.registerV2(v2Input({
    principal: 'principal-A',
    sessionId: 'session-old',
    voipToken: 'old-authoritative-token',
  }));
  await registry.registerV2(v2Input({
    principal: 'principal-B',
    humanId: 'human-B',
    installationId: INSTALL_B,
    sessionId: 'session-full',
    voipToken: 'capacity-winner-token',
  }));

  await assert.rejects(
    registry.registerV2(v2Input({
      principal: 'principal-B',
      sessionId: 'session-full',
      voipToken: 'must-never-enter-a-lease',
      installationGeneration: '2',
    })),
    (error) => error.registryStatus === 409 && error.registryReason === 'device-cap-reached',
  );
  const stillOld = await registry.lookup({
    humanId: 'human-A',
    principal: 'principal-A',
    sessionId: 'session-old',
  });
  assert.equal(stillOld.length, 1);
  assert.equal(stillOld[0].bindingRevision, old.bindingRevision);
  assert.equal(stillOld[0].voipToken, 'old-authoritative-token');
  assert.equal(
    [...store._records.values()].some((value) =>
      JSON.stringify(value).includes('must-never-enter-a-lease')
    ),
    false,
    'a capacity loser leaves no raw-token lease behind',
  );
});

test('Registry V2 concurrent contenders for the last target slot produce one durable winner', async () => {
  const store = createInMemoryStore();
  const registry = createStoreDeviceRegistry({
    store,
    now: () => NOW,
    installationHmacKey: V2_HMAC_KEY,
    maxDevices: 1,
  });
  const results = await Promise.allSettled([
    registry.registerV2(v2Input({ installationId: INSTALL_A, voipToken: 'contender-A' })),
    registry.registerV2(v2Input({ installationId: INSTALL_B, voipToken: 'contender-B' })),
  ]);
  assert.equal(results.filter((result) => result.status === 'fulfilled').length, 1);
  const loser = results.find((result) => result.status === 'rejected');
  assert.equal(loser.reason.registryReason, 'device-cap-reached');
  const rows = await registry.lookup({ humanId: 'human-A', sessionId: 'session-shared' });
  assert.equal(rows.length, 1);
  assert.equal(
    ['contender-A', 'contender-B'].includes(rows[0].voipToken),
    true,
  );
  const losingToken = rows[0].voipToken === 'contender-A' ? 'contender-B' : 'contender-A';
  assert.equal(
    [...store._records.values()].some((value) => JSON.stringify(value).includes(losingToken)),
    false,
    'the losing raw APNs token never enters a lease',
  );
});

test('Registry V2 token claim has one installation owner and stale cleanup cannot release its successor', async () => {
  const registry = createStoreDeviceRegistry({
    store: createInMemoryStore(),
    now: () => NOW,
    installationHmacKey: V2_HMAC_KEY,
    tokenScope: 'com.plexaura.sentipocket.app:development',
  });
  const first = await registry.registerV2(v2Input({
    principal: 'principal-A',
    voipToken: 'shared-apns-token',
  }));
  await assert.rejects(
    registry.registerV2(v2Input({
      humanId: 'human-B',
      principal: 'principal-B',
      installationId: INSTALL_B,
      voipToken: 'shared-apns-token',
    })),
    (error) => error.registryStatus === 409 && error.registryReason === 'device-token-claimed',
  );
  assert.equal((await registry.lookup({
    humanId: 'human-A',
    principal: 'principal-A',
    sessionId: 'session-shared',
  })).length, 1);

  const staleCleanup = {
    humanId: 'human-A',
    principal: 'principal-A',
    sessionId: 'session-shared',
    installationId: INSTALL_A,
    previousInstallationGeneration: '1',
    installationGeneration: '2',
    bindingId: first.bindingId,
    bindingRevision: first.bindingRevision,
  };
  await registry.unregisterV2(staleCleanup);
  const successor = await registry.registerV2(v2Input({
    humanId: 'human-B',
    principal: 'principal-B',
    installationId: INSTALL_B,
    voipToken: 'shared-apns-token',
  }));
  await registry.unregisterV2(staleCleanup);
  const rows = await registry.lookup({
    humanId: 'human-B',
    principal: 'principal-B',
    sessionId: 'session-shared',
  });
  assert.equal(rows.length, 1);
  assert.equal(rows[0].bindingRevision, successor.bindingRevision);
  await assert.rejects(
    registry.registerV2(v2Input({
      principal: 'principal-A',
      voipToken: 'shared-apns-token',
    })),
    (error) => error.registryStatus === 409 && error.registryReason === 'binding-superseded',
    'the old installation cannot reclaim the transferred token with its delayed generation',
  );
});

test('Registry V2 duplicate-token loser releases its target reservation for an unrelated valid device', async () => {
  const registry = createStoreDeviceRegistry({
    store: createInMemoryStore(),
    now: () => NOW,
    installationHmacKey: V2_HMAC_KEY,
    tokenScope: 'com.plexaura.sentipocket.app:development',
    maxDevices: 1,
  });
  await registry.registerV2(v2Input({
    humanId: 'human-A',
    principal: 'principal-A',
    sessionId: 'session-A',
    installationId: INSTALL_A,
    voipToken: 'already-owned-token',
  }));
  await assert.rejects(
    registry.registerV2(v2Input({
      humanId: 'human-B',
      principal: 'principal-B',
      sessionId: 'session-B',
      installationId: INSTALL_B,
      voipToken: 'already-owned-token',
    })),
    (error) => error.registryStatus === 409 && error.registryReason === 'device-token-claimed',
  );
  assert.deepEqual(
    await registry.lookup({
      humanId: 'human-B',
      principal: 'principal-B',
      sessionId: 'session-B',
    }),
    [],
    'the token-claim loser has no authoritative target binding',
  );

  const winner = await registry.registerV2(v2Input({
    humanId: 'human-B',
    principal: 'principal-B',
    sessionId: 'session-B',
    installationId: INSTALL_C,
    voipToken: 'independent-token',
  }));
  const rows = await registry.lookup({
    humanId: 'human-B',
    principal: 'principal-B',
    sessionId: 'session-B',
  });
  assert.equal(rows.length, 1, 'the synchronous loser did not poison the one-slot target for the reservation TTL');
  assert.equal(rows[0].bindingRevision, winner.bindingRevision);
  assert.equal(rows[0].voipToken, 'independent-token');
});

test('Registry V2 rollback cannot erase an exact same-generation sibling that is about to activate', async () => {
  const deferred = () => {
    let resolve;
    const promise = new Promise((r) => { resolve = r; });
    return { promise, resolve };
  };
  const base = createInMemoryStore();
  const aAtSecondTokenClaim = deferred();
  const resumeA = deferred();
  const bAtHeadActivation = deferred();
  const resumeB = deferred();
  let aTokenCasCount = 0;
  const storeA = {
    ...base,
    async compareAndSwap(key, expectedVersion, value) {
      if (key.startsWith('dial:v2:token:')) {
        aTokenCasCount += 1;
        if (aTokenCasCount === 2) {
          aAtSecondTokenClaim.resolve();
          await resumeA.promise;
          throw new Error('injected ambiguous token CAS failure');
        }
      }
      return base.compareAndSwap(key, expectedVersion, value);
    },
  };
  let bPaused = false;
  const storeB = {
    ...base,
    async advanceGeneration(key, value) {
      if (!bPaused) {
        bPaused = true;
        bAtHeadActivation.resolve();
        await resumeB.promise;
      }
      return base.advanceGeneration(key, value);
    },
  };
  const registryA = createStoreDeviceRegistry({
    store: storeA,
    now: () => NOW,
    installationHmacKey: V2_HMAC_KEY,
  });
  const registryB = createStoreDeviceRegistry({
    store: storeB,
    now: () => NOW,
    installationHmacKey: V2_HMAC_KEY,
  });

  const attemptA = registryA.registerV2(v2Input());
  await aAtSecondTokenClaim.promise;
  const attemptB = registryB.registerV2(v2Input());
  await bAtHeadActivation.promise;
  resumeA.resolve();
  await assert.rejects(attemptA, /injected ambiguous token CAS failure/);
  resumeB.resolve();
  const accepted = await attemptB;

  const rows = await registryB.lookup({
    humanId: 'human-A',
    sessionId: 'session-shared',
  });
  assert.equal(rows.length, 1, 'the fulfilled sibling remains reachable through its shared target index');
  assert.equal(rows[0].bindingRevision, accepted.bindingRevision);
  assert.equal(rows[0].voipToken, 'token-A');
});

test('Registry V2 equal-generation stale unregister cannot erase an about-to-activate register', async () => {
  const deferred = () => {
    let resolve;
    const promise = new Promise((r) => { resolve = r; });
    return { promise, resolve };
  };
  const base = createInMemoryStore();
  const stable = createStoreDeviceRegistry({
    store: base,
    now: () => NOW,
    installationHmacKey: V2_HMAC_KEY,
  });
  const first = await stable.registerV2(v2Input());
  const atTokenActivation = deferred();
  const resumeActivation = deferred();
  let paused = false;
  const pausingStore = {
    ...base,
    async compareAndSwap(key, expectedVersion, value) {
      if (!paused &&
          key.startsWith('dial:v2:token:') &&
          value?.active?.generation === '2' &&
          value?.pending === null) {
        paused = true;
        atTokenActivation.resolve();
        await resumeActivation.promise;
      }
      return base.compareAndSwap(key, expectedVersion, value);
    },
  };
  const rotating = createStoreDeviceRegistry({
    store: pausingStore,
    now: () => NOW,
    installationHmacKey: V2_HMAC_KEY,
  });
  const rotation = rotating.registerV2(v2Input({
    installationGeneration: '2',
    voipToken: 'rotated-token',
  }));
  await atTokenActivation.promise;

  await stable.unregisterV2({
    humanId: 'human-A',
    sessionId: 'session-shared',
    installationId: INSTALL_A,
    previousInstallationGeneration: '1',
    installationGeneration: '2',
    bindingId: first.bindingId,
    bindingRevision: first.bindingRevision,
  });
  resumeActivation.resolve();
  const accepted = await rotation;

  const rows = await stable.lookup({
    humanId: 'human-A',
    sessionId: 'session-shared',
  });
  assert.equal(rows.length, 1, 'the in-flight generation-2 register retains its target candidate');
  assert.equal(rows[0].bindingRevision, accepted.bindingRevision);
  assert.equal(rows[0].voipToken, 'rotated-token');
});

test('Registry V2 token migration fence suppresses only the matching legacy device through unregister', async () => {
  const matchingStore = createInMemoryStore();
  const matching = createStoreDeviceRegistry({
    store: matchingStore,
    now: () => NOW,
    installationHmacKey: V2_HMAC_KEY,
  });
  await matching.register(v2Input({ voipToken: 'migrated-token' }));
  const accepted = await matching.registerV2(v2Input({ voipToken: 'migrated-token' }));
  assert.equal((await matching.lookup({
    humanId: 'human-A',
    sessionId: 'session-shared',
  })).length, 1, 'the matching V1 record is suppressed as soon as its token enters V2');
  await matching.unregisterV2({
    humanId: 'human-A',
    sessionId: 'session-shared',
    installationId: INSTALL_A,
    previousInstallationGeneration: '1',
    installationGeneration: '2',
    bindingId: accepted.bindingId,
    bindingRevision: accepted.bindingRevision,
  });
  assert.deepEqual(
    await matching.lookup({ humanId: 'human-A', sessionId: 'session-shared' }),
    [],
    'the durable token claim/tombstone prevents matching V1 resurrection after logout',
  );

  const distinct = createStoreDeviceRegistry({
    store: createInMemoryStore(),
    now: () => NOW,
    installationHmacKey: V2_HMAC_KEY,
  });
  await distinct.register(v2Input({ voipToken: 'older-distinct-device' }));
  const v2 = await distinct.registerV2(v2Input({ voipToken: 'new-v2-device' }));
  assert.deepEqual(
    (await distinct.lookup({ humanId: 'human-A', sessionId: 'session-shared' }))
      .map((row) => row.voipToken)
      .sort(),
    ['new-v2-device', 'older-distinct-device'],
    'an unrelated legacy device remains available during the explicit grace window',
  );
  await distinct.unregisterV2({
    humanId: 'human-A',
    sessionId: 'session-shared',
    installationId: INSTALL_A,
    previousInstallationGeneration: '1',
    installationGeneration: '2',
    bindingId: v2.bindingId,
    bindingRevision: v2.bindingRevision,
  });
  assert.deepEqual(
    (await distinct.lookup({ humanId: 'human-A', sessionId: 'session-shared' }))
      .map((row) => row.voipToken),
    ['older-distinct-device'],
  );
});

test('Registry V2 lease-write failure after reservations keeps old authority and exact retry rolls forward', async () => {
  const base = createInMemoryStore();
  const stable = createStoreDeviceRegistry({
    store: base,
    now: () => NOW,
    installationHmacKey: V2_HMAC_KEY,
  });
  const old = await stable.registerV2(v2Input({
    principal: 'principal-A',
    sessionId: 'session-old',
    voipToken: 'same-device-token',
  }));
  let failLeaseOnce = true;
  const faulting = {
    ...base,
    async put(key, value, options) {
      if (failLeaseOnce && key.startsWith('dial:v2:lease:')) {
        failLeaseOnce = false;
        throw new Error('injected lease write failure');
      }
      return base.put(key, value, options);
    },
  };
  const registry = createStoreDeviceRegistry({
    store: faulting,
    now: () => NOW,
    installationHmacKey: V2_HMAC_KEY,
  });
  const replacementInput = v2Input({
    principal: 'principal-A',
    sessionId: 'session-new',
    voipToken: 'same-device-token',
    installationGeneration: '2',
  });
  await assert.rejects(registry.registerV2(replacementInput), /injected lease write failure/);
  const stillOld = await stable.lookup({
    humanId: 'human-A',
    principal: 'principal-A',
    sessionId: 'session-old',
  });
  assert.equal(stillOld.length, 1);
  assert.equal(stillOld[0].bindingRevision, old.bindingRevision);

  const replacement = await registry.registerV2(replacementInput);
  assert.equal(replacement.installationGeneration, '2');
  assert.deepEqual(await registry.lookup({
    humanId: 'human-A',
    principal: 'principal-A',
    sessionId: 'session-old',
  }), []);
  assert.equal((await registry.lookup({
    humanId: 'human-A',
    principal: 'principal-A',
    sessionId: 'session-new',
  })).length, 1);
});

test('Registry V2 token-activation failure is fail-closed and exact retry completes the prepared head', async () => {
  const base = createInMemoryStore();
  const stable = createStoreDeviceRegistry({
    store: base,
    now: () => NOW,
    installationHmacKey: V2_HMAC_KEY,
  });
  await stable.registerV2(v2Input({
    principal: 'principal-A',
    sessionId: 'session-old',
    voipToken: 'activation-token',
  }));

  let tokenClaimCas = 0;
  const faulting = {
    ...base,
    async compareAndSwap(key, expectedVersion, value) {
      if (key.startsWith('dial:v2:token:')) {
        tokenClaimCas += 1;
        if (tokenClaimCas === 3) throw new Error('injected token activation failure');
      }
      return base.compareAndSwap(key, expectedVersion, value);
    },
  };
  const registry = createStoreDeviceRegistry({
    store: faulting,
    now: () => NOW,
    installationHmacKey: V2_HMAC_KEY,
  });
  const replacementInput = v2Input({
    principal: 'principal-A',
    sessionId: 'session-new',
    voipToken: 'activation-token',
    installationGeneration: '2',
  });
  await assert.rejects(registry.registerV2(replacementInput), /injected token activation failure/);
  assert.deepEqual(await registry.lookup({
    humanId: 'human-A',
    principal: 'principal-A',
    sessionId: 'session-old',
  }), [], 'the new head invalidates old authority, but an unactivated token can never ring');
  assert.deepEqual(await registry.lookup({
    humanId: 'human-A',
    principal: 'principal-A',
    sessionId: 'session-new',
  }), [], 'the partially committed head remains fail-closed until exact retry');

  const recovered = await registry.registerV2(replacementInput);
  assert.equal(recovered.installationGeneration, '2');
  assert.equal((await registry.lookup({
    humanId: 'human-A',
    principal: 'principal-A',
    sessionId: 'session-new',
  })).length, 1);
});

test('Registry V2 push carries the exact per-device proof and pre-send revalidation closes a lookup/rebind race', async () => {
  const registry = createStoreDeviceRegistry({
    store: createInMemoryStore(),
    now: () => NOW,
    installationHmacKey: V2_HMAC_KEY,
  });
  const first = await registry.registerV2(v2Input());
  const sent = [];
  const normal = createDialPushBackend({
    deviceRegistry: registry,
    apnsSend: async (request) => { sent.push(request); return { delivered: true }; },
    now: () => NOW,
  });
  assert.equal((await normal({ humanId: 'human-A', sessionId: 'session-shared', message: 'ring' })).dispatched, true);
  assert.equal(sent[0].payload.bindingVersion, 2);
  assert.equal(sent[0].payload.bindingId, first.bindingId);
  assert.equal(sent[0].payload.bindingRevision, first.bindingRevision);
  assert.equal(sent[0].payload.installationGeneration, '1');

  let switched = false;
  const racingRegistry = {
    async lookup(args) {
      const captured = await registry.lookup(args);
      await registry.registerV2(v2Input({
        humanId: 'human-B',
        voipToken: 'token-B',
        installationGeneration: '2',
      }));
      switched = true;
      return captured;
    },
    revalidate: registry.revalidate,
  };
  let racedSends = 0;
  const raced = await createDialPushBackend({
    deviceRegistry: racingRegistry,
    apnsSend: async () => { racedSends += 1; return { delivered: true }; },
    now: () => NOW,
  })({ humanId: 'human-A', sessionId: 'session-shared', message: 'must not reach B' });
  assert.equal(switched, true);
  assert.equal(raced.reason, 'stale-device-binding');
  assert.equal(racedSends, 0, 'a row captured before B rebind is revalidated immediately before transport');
});
