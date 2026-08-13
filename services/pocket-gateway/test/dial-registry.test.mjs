// dial-registry.test.mjs — device registration (/dial/register logic) + the deterministic dispatch payload wire.
// Hermetic: in-memory deviceRegistry + injected clock. Proves humanId-from-token binding, membership gating,
// fail-closed (no registry -> 501), and a stable/testable payload for forge decode() (id/who/priority).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import {
  createDialRegistry, createDialPushBackend, createStoreDeviceRegistry, validateRegistration, buildDialPayload, computeDialId,
  DIAL_LIMITS, DIAL_PRIORITIES, DIAL_PUSHKIT_CAP, DIAL_PAYLOAD_MAX_BYTES,
} from '../src/dial-registry.mjs';
import {
  DEVICE_REGISTRY_OWNER_VERSION,
  DeviceRegistryV2Error,
  createInMemoryDeviceRegistryV2,
  deriveDeviceOwnerHandle,
} from '../src/device-registry-v2.mjs';

// Shared byte fixtures — the SAME file forge's Swift decoder byte-matches (KAV parity). Generated from buildDialPayload.
const fixtures = JSON.parse(readFileSync(new URL('./fixtures/dial-payload-v1.json', import.meta.url), 'utf8'));
const cleanupKav = JSON.parse(
  readFileSync(new URL('./fixtures/device-registration-cleanup-v2.json', import.meta.url), 'utf8'),
);

const NOW = 1_770_000_000_000; // fixed injected clock
const V2_KEY = Buffer.alloc(32, 0x41);
const V2_INSTALLATION = Buffer.alloc(32, 0x42).toString('base64url');
const V2_IDEMPOTENCY = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const V2_OWNER = deriveDeviceOwnerHandle(V2_KEY, 'principal-a', 'verified-human');
const v2Registration = (overrides = {}) => ({
  registrationVersion: 2,
  ownerVersion: DEVICE_REGISTRY_OWNER_VERSION,
  ownerHandle: V2_OWNER,
  installationId: V2_INSTALLATION,
  idempotencyKey: V2_IDEMPOTENCY,
  voipToken: 'private-routing-token',
  sessionId: 'session-v2',
  platform: 'apns',
  ...overrides,
});
const v2DeniedReceipt = (body, error) => ({
  registered: false,
  committed: false,
  authorized: false,
  revocationRequired: false,
  reason: 'registration-denied-before-commit',
  error,
  registrationVersion: body.registrationVersion,
  ownerVersion: body.ownerVersion,
  ownerHandle: body.ownerHandle,
  sessionId: body.sessionId,
  platform: body.platform,
  idempotent: true,
});
const v2Cleanup = (overrides = {}) => {
  const source = v2Registration(overrides);
  return {
    registrationVersion: source.registrationVersion,
    ownerVersion: source.ownerVersion,
    ownerHandle: source.ownerHandle,
    installationId: source.installationId,
    idempotencyKey: source.idempotencyKey,
    tokenDigest: createHash('sha256').update(source.voipToken, 'utf8').digest('base64url'),
    sessionId: source.sessionId,
    platform: source.platform,
  };
};
const v2Unregister = (bindingId, bindingRevision, overrides = {}) => ({
  registrationVersion: 2,
  ownerVersion: DEVICE_REGISTRY_OWNER_VERSION,
  ownerHandle: V2_OWNER,
  installationId: V2_INSTALLATION,
  sessionId: 'session-v2',
  bindingId,
  bindingRevision,
  ...overrides,
});
const completeV2Registry = (overrides = {}) => ({
  protocolVersion: 2,
  operationOutcomeVersion: 1,
  async registrationContext() {
    return { registrationVersion: 2, ownerVersion: DEVICE_REGISTRY_OWNER_VERSION, ownerHandle: V2_OWNER };
  },
  async register() { throw new Error('unexpected register'); },
  async reconcileRegistration() { return null; },
  async denyRegistration() {
    return { state: 'denied', ownerVersion: DEVICE_REGISTRY_OWNER_VERSION, ownerHandle: V2_OWNER };
  },
  async unregister() {
    return { removed: false, ownerVersion: DEVICE_REGISTRY_OWNER_VERSION, ownerHandle: V2_OWNER };
  },
  async lookup() { return []; },
  ...overrides,
});
const v2AuthorityResult = (overrides = {}) => ({
  ownerVersion: DEVICE_REGISTRY_OWNER_VERSION,
  ownerHandle: V2_OWNER,
  bindingId: 'bind_0123456789abcdef0123456789abcdef',
  bindingRevision: 3,
  expiresAtEpochSec: Math.floor(NOW / 1000) + 60,
  idempotent: false,
  renewed: false,
  tokenClaimId: 'claim_0123456789abcdef0123456789abcdef',
  tokenClaimRevision: 4,
  ...overrides,
});
const fakeRegistry = () => {
  const records = [];
  return {
    records,
    async register(r) { records.push(r); return { deviceCount: records.filter((x) => x.humanId === r.humanId && x.sessionId === r.sessionId).length }; },
    async lookup({ humanId, sessionId }) { return records.filter((x) => x.humanId === humanId && x.sessionId === sessionId).map((x) => ({ voipToken: x.voipToken, platform: x.platform })); },
  };
};

test('createDialRegistry fails boot on a partial Registry V2 outcome interface', () => {
  assert.doesNotThrow(() => createDialRegistry({ deviceRegistry: completeV2Registry() }));
  for (const missingCapability of [
    'operationOutcomeVersion',
    'registrationContext',
    'register',
    'reconcileRegistration',
    'denyRegistration',
    'unregister',
    'lookup',
  ]) {
    const partial = completeV2Registry();
    delete partial[missingCapability];
    assert.throws(
      () => createDialRegistry({ deviceRegistry: partial }),
      /requires operationOutcomeVersion=1 and registrationContext, register, reconcileRegistration, denyRegistration, unregister, lookup/,
      `missing ${missingCapability} must fail boot`,
    );
  }
});

test('registration context returns one strict stable owner bootstrap and rejects malformed adapters', async (t) => {
  const calls = [];
  const service = createDialRegistry({
    deviceRegistry: completeV2Registry({
      async registrationContext(args) {
        calls.push(args);
        return { registrationVersion: 2, ownerVersion: DEVICE_REGISTRY_OWNER_VERSION, ownerHandle: V2_OWNER };
      },
    }),
    now: () => NOW,
  });
  const expected = {
    status: 200,
    body: {
      registrationVersion: 2,
      ownerVersion: DEVICE_REGISTRY_OWNER_VERSION,
      ownerHandle: V2_OWNER,
      serverTime: new Date(NOW).toISOString(),
    },
  };
  assert.deepEqual(
    await service.registrationContext({ principal: 'principal-a', humanId: 'verified-human' }),
    expected,
  );
  assert.deepEqual(
    await service.registrationContext({ principal: 'principal-a', humanId: 'verified-human' }),
    expected,
  );
  assert.deepEqual(calls, [
    { principal: 'principal-a', humanId: 'verified-human' },
    { principal: 'principal-a', humanId: 'verified-human' },
  ]);

  const malformed = [
    undefined,
    { registrationVersion: 2, ownerVersion: DEVICE_REGISTRY_OWNER_VERSION, ownerHandle: V2_OWNER, extra: true },
    { registrationVersion: 1, ownerVersion: DEVICE_REGISTRY_OWNER_VERSION, ownerHandle: V2_OWNER },
    { registrationVersion: 2, ownerVersion: 2, ownerHandle: V2_OWNER },
    { registrationVersion: 2, ownerVersion: DEVICE_REGISTRY_OWNER_VERSION, ownerHandle: `${'A'.repeat(42)}B` },
  ];
  for (const [index, value] of malformed.entries()) {
    await t.test(`malformed adapter ${index + 1}`, async () => {
      const malformedService = createDialRegistry({
        deviceRegistry: completeV2Registry({ async registrationContext() { return value; } }),
        now: () => NOW,
      });
      assert.deepEqual(
        await malformedService.registrationContext({ principal: 'principal-a', humanId: 'verified-human' }),
        { status: 502, body: { error: 'registry context failed', reason: 'registry-context-failed' } },
      );
    });
  }
});

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

test('buildDialPayload V2 budgets the versioned binding envelope before the RICH -> LEAN decision', () => {
  const payload = buildDialPayload({
    humanId: 'u',
    sessionId: 's',
    id: 'need_bound',
    kind: 'info',
    message: 'Q'.repeat(4000),
    context: 'C'.repeat(2000),
    binding: {
      v: 2,
      id: 'bind_0123456789abcdef0123456789abcdef',
      revision: Number.MAX_SAFE_INTEGER,
    },
  }, NOW);
  assert.equal(payload.v, 2);
  assert.deepEqual(payload.binding, {
    v: 2,
    id: 'bind_0123456789abcdef0123456789abcdef',
    revision: Number.MAX_SAFE_INTEGER,
  });
  assert.equal(payload.fetch, true);
  assert.ok(Buffer.byteLength(JSON.stringify(payload), 'utf8') <= DIAL_PAYLOAD_MAX_BYTES,
    'binding is core and survives shedding without exceeding the PushKit budget');
  assert.throws(() => buildDialPayload({
    sessionId: 's',
    message: 'x',
    binding: { v: 1, id: 'bind_0123456789abcdef0123456789abcdef', revision: 1 },
  }, NOW), /invalid binding envelope/);
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
  const r = await svc.register({
    principal: 'issuer:site:pairwise-u',
    humanId: 'u',
    body: { voipToken: 'tok-1', sessionId: 'sess-1' },
    isMember: async () => true,
  });
  assert.equal(r.status, 200);
  assert.deepEqual(r.body, { registered: true, sessionId: 'sess-1', platform: 'apns', deviceCount: 1 });
  // the stored record is keyed by the humanId ARGUMENT (from the verified token), with the injected registeredAt
  assert.equal(reg.records[0].humanId, 'u');
  assert.equal(reg.records[0].principal, 'issuer:site:pairwise-u', 'full verified principal reaches the registry');
  assert.equal(reg.records[0].voipToken, 'tok-1');
  assert.equal(reg.records[0].registeredAt, new Date(NOW).toISOString());
  // idempotent-ish upsert bumps deviceCount for a 2nd device on the same session
  const r2 = await svc.register({
    principal: 'issuer:site:pairwise-u',
    humanId: 'u',
    body: { voipToken: 'tok-2', sessionId: 'sess-1' },
    isMember: async () => true,
  });
  assert.equal(r2.body.deviceCount, 2);
});

test('register V2: membership-gated response returns only server binding/token-claim fences, never installation/token', async () => {
  const registry = createInMemoryDeviceRegistryV2({ hmacKey: V2_KEY, now: () => NOW });
  const service = createDialRegistry({ deviceRegistry: registry, now: () => NOW });
  const body = v2Registration();
  let membershipSession;
  const response = await service.register({
    principal: 'principal-a',
    humanId: 'verified-human',
    body,
    isMember: async (sessionId) => { membershipSession = sessionId; return true; },
  });
  assert.equal(response.status, 200);
  assert.equal(membershipSession, 'session-v2');
  assert.equal(response.body.registrationVersion, 2);
  assert.match(response.body.bindingId, /^bind_[0-9a-f]{32}$/);
  assert.equal(response.body.bindingRevision, 1);
  assert.match(response.body.tokenClaimId, /^claim_[0-9a-f]{32}$/);
  assert.equal(response.body.tokenClaimRevision, 1);
  assert.equal(response.body.idempotent, false);
  assert.equal(response.body.serverTime, new Date(NOW).toISOString());
  assert.deepEqual(Object.keys(response.body).sort(), [
    'bindingId',
    'bindingRevision',
    'expiresAt',
    'idempotent',
    'ownerHandle',
    'ownerVersion',
    'platform',
    'registered',
    'registrationVersion',
    'serverTime',
    'sessionId',
    'tokenClaimId',
    'tokenClaimRevision',
  ]);
  assert.equal(Object.hasOwn(response.body, 'installationId'), false);
  assert.equal(Object.hasOwn(response.body, 'voipToken'), false);
});

test('register V2 fails closed on malformed adapter authority results without echoing them', async (t) => {
  const rawSecret = 'raw-adapter-authority-secret';
  const invalidResults = [
    ['missing result', undefined],
    ['extra field', v2AuthorityResult({ adapterDetail: rawSecret })],
    ['wrong owner version', v2AuthorityResult({ ownerVersion: 2 })],
    ['wrong owner handle', v2AuthorityResult({ ownerHandle: deriveDeviceOwnerHandle(V2_KEY, 'other', 'owner') })],
    ['invalid binding id', v2AuthorityResult({ bindingId: rawSecret })],
    ['invalid binding revision', v2AuthorityResult({ bindingRevision: 0 })],
    ['invalid token-claim id', v2AuthorityResult({ tokenClaimId: rawSecret })],
    ['invalid token-claim revision', v2AuthorityResult({ tokenClaimRevision: 0 })],
    ['invalid expiry type', v2AuthorityResult({ expiresAtEpochSec: String(Math.floor(NOW / 1000) + 60) })],
    ['unrepresentable expiry', v2AuthorityResult({ expiresAtEpochSec: 8_640_000_000_001 })],
    ['expired at response time', v2AuthorityResult({ expiresAtEpochSec: Math.floor(NOW / 1000) })],
    ['invalid idempotent type', v2AuthorityResult({ idempotent: 'false' })],
    ['invalid renewed type', v2AuthorityResult({ renewed: 1 })],
  ];
  for (const [name, adapterResult] of invalidResults) {
    await t.test(name, async () => {
      let membershipCalls = 0;
      const service = createDialRegistry({
        deviceRegistry: completeV2Registry({ async register() { return adapterResult; } }),
        now: () => NOW,
      });
      const response = await service.register({
        principal: 'principal-a',
        humanId: 'verified-human',
        body: v2Registration(),
        isMember: async () => { membershipCalls += 1; return true; },
      });
      assert.deepEqual(response, {
        status: 502,
        body: { error: 'registry write failed', reason: 'registry-write-failed' },
      });
      assert.equal(membershipCalls, 1);
      assert.equal(JSON.stringify(response).includes(rawSecret), false);
    });
  }
});

test('register V2 accepts the reference adapter ordinary renewal semantics', async () => {
  const service = createDialRegistry({
    deviceRegistry: completeV2Registry({
      async register() { return v2AuthorityResult({ idempotent: true, renewed: true }); },
    }),
    now: () => NOW,
  });
  const response = await service.register({
    principal: 'principal-a',
    humanId: 'verified-human',
    body: v2Registration(),
    isMember: async () => true,
  });
  assert.equal(response.status, 200);
  assert.equal(response.body.idempotent, true);
  assert.deepEqual(Object.keys(response.body).sort(), [
    'bindingId', 'bindingRevision', 'expiresAt', 'idempotent', 'ownerHandle', 'ownerVersion',
    'platform', 'registered', 'registrationVersion', 'serverTime', 'sessionId',
    'tokenClaimId', 'tokenClaimRevision',
  ]);
});

test('register V2 accepts only a strict, time-consistent reconcile adapter result', async (t) => {
  const rawSecret = 'raw-reconcile-authority-secret';
  const validReplay = v2AuthorityResult({ idempotent: true, renewed: false });
  const invalidResults = [
    ['undefined is not an authoritative miss', undefined],
    ['extra field', { ...validReplay, adapterDetail: rawSecret }],
    ['wrong owner echo', { ...validReplay, ownerHandle: deriveDeviceOwnerHandle(V2_KEY, 'other', 'owner') }],
    ['invalid binding id', { ...validReplay, bindingId: rawSecret }],
    ['non-idempotent replay', { ...validReplay, idempotent: false }],
    ['renewing replay', { ...validReplay, renewed: true }],
    ['false expired marker', { ...validReplay, expired: false }],
    ['premature expired marker', { ...validReplay, expired: true }],
    ['missing expired marker at logical expiry', {
      ...validReplay,
      expiresAtEpochSec: Math.floor(NOW / 1000),
    }],
  ];
  for (const [name, adapterResult] of invalidResults) {
    await t.test(name, async () => {
      let membershipCalls = 0;
      let writes = 0;
      const service = createDialRegistry({
        deviceRegistry: completeV2Registry({
          async reconcileRegistration() { return adapterResult; },
          async register() { writes += 1; return v2AuthorityResult(); },
        }),
        now: () => NOW,
      });
      const response = await service.register({
        principal: 'principal-a',
        humanId: 'verified-human',
        body: v2Registration(),
        isMember: async () => { membershipCalls += 1; return true; },
      });
      assert.deepEqual(response, {
        status: 502,
        body: { error: 'registry reconciliation failed', reason: 'registry-reconciliation-failed' },
      });
      assert.equal(membershipCalls, 0);
      assert.equal(writes, 0);
      assert.equal(JSON.stringify(response).includes(rawSecret), false);
    });
  }

  await t.test('expired true is the only valid optional replay form at logical expiry', async () => {
    let membershipCalls = 0;
    const expiredReplay = {
      ...validReplay,
      expiresAtEpochSec: Math.floor(NOW / 1000),
      expired: true,
    };
    const service = createDialRegistry({
      deviceRegistry: completeV2Registry({ async reconcileRegistration() { return expiredReplay; } }),
      now: () => NOW,
    });
    const response = await service.register({
      principal: 'principal-a',
      humanId: 'verified-human',
      body: v2Registration(),
      isMember: async () => { membershipCalls += 1; return true; },
    });
    assert.equal(response.status, 410);
    assert.equal(response.body.reason, 'registration-expired');
    assert.equal(response.body.bindingId, expiredReplay.bindingId);
    assert.equal(response.body.tokenClaimId, expiredReplay.tokenClaimId);
    assert.equal(response.body.idempotent, true);
    assert.equal(membershipCalls, 0);
  });
});

test('register V2: exact replay is read-only; lost membership returns revocation-only fences, not authority', async () => {
  let now = NOW;
  const registry = createInMemoryDeviceRegistryV2({ hmacKey: V2_KEY, now: () => now, leaseSeconds: 60 });
  const service = createDialRegistry({ deviceRegistry: registry, now: () => now });
  const body = v2Registration();
  const first = await service.register({
    principal: 'principal-a',
    humanId: 'verified-human',
    body,
    isMember: async () => true,
  });
  const snapshots = {
    records: structuredClone([...registry._records]),
    claims: structuredClone([...registry._tokenClaims]),
    directories: structuredClone([...registry._targetDirectories]),
  };

  now += 30_000;
  let membershipCalls = 0;
  const authorizedReplay = await service.register({
    principal: 'principal-a',
    humanId: 'verified-human',
    body,
    isMember: async () => { membershipCalls += 1; return true; },
  });
  assert.equal(authorizedReplay.status, 200);
  assert.equal(authorizedReplay.body.idempotent, true);
  assert.equal(authorizedReplay.body.bindingId, first.body.bindingId);
  assert.equal(authorizedReplay.body.tokenClaimId, first.body.tokenClaimId);
  assert.equal(authorizedReplay.body.expiresAt, first.body.expiresAt, 'read-only replay does not renew the lease');
  assert.equal(membershipCalls, 1, 'a normal 200 replay still requires current membership');
  assert.deepEqual([...registry._records], snapshots.records);
  assert.deepEqual([...registry._tokenClaims], snapshots.claims);
  assert.deepEqual([...registry._targetDirectories], snapshots.directories);

  membershipCalls = 0;
  const revokedReplay = await service.register({
    principal: 'principal-a',
    humanId: 'verified-human',
    body,
    isMember: async () => { membershipCalls += 1; return false; },
  });
  assert.equal(revokedReplay.status, 409);
  assert.deepEqual(revokedReplay.body, {
    registered: false,
    committed: true,
    authorized: false,
    revocationRequired: true,
    reason: 'registration-committed-but-unauthorized',
    error: 'registration committed but current authorization is missing',
    registrationVersion: 2,
    ownerVersion: body.ownerVersion,
    ownerHandle: body.ownerHandle,
    sessionId: body.sessionId,
    platform: body.platform,
    bindingId: first.body.bindingId,
    bindingRevision: first.body.bindingRevision,
    tokenClaimId: first.body.tokenClaimId,
    tokenClaimRevision: first.body.tokenClaimRevision,
    expiresAt: first.body.expiresAt,
    serverTime: new Date(now).toISOString(),
    idempotent: true,
  });
  assert.equal(membershipCalls, 1);
  assert.deepEqual([...registry._records], snapshots.records);
  assert.deepEqual([...registry._tokenClaims], snapshots.claims);
  assert.deepEqual([...registry._targetDirectories], snapshots.directories);
});

test('register V2: membership lookup crossing lease expiry returns one response-time 410 receipt', async () => {
  let now = NOW;
  const registry = createInMemoryDeviceRegistryV2({ hmacKey: V2_KEY, now: () => now, leaseSeconds: 60 });
  const service = createDialRegistry({ deviceRegistry: registry, now: () => now });
  const body = v2Registration();
  const first = await service.register({
    principal: 'principal-a',
    humanId: 'verified-human',
    body,
    isMember: async () => true,
  });
  const expiryMs = Date.parse(first.body.expiresAt);
  now = expiryMs - 1;
  const response = await service.register({
    principal: 'principal-a',
    humanId: 'verified-human',
    body,
    isMember: async () => {
      now = expiryMs;
      return false;
    },
  });
  assert.equal(response.status, 410);
  assert.equal(response.body.reason, 'registration-expired');
  assert.equal(response.body.serverTime, new Date(expiryMs).toISOString());
  assert.equal(response.body.expiresAt, first.body.expiresAt);
  assert.equal(response.body.bindingId, first.body.bindingId);
  assert.equal(response.body.authorized, false);
});

test('register V2: changed requests still require membership and reveal no committed fences', async () => {
  const registry = createInMemoryDeviceRegistryV2({ hmacKey: V2_KEY, now: () => NOW });
  const service = createDialRegistry({ deviceRegistry: registry, now: () => NOW });
  const body = v2Registration();
  await service.register({
    principal: 'principal-a',
    humanId: 'verified-human',
    body,
    isMember: async () => true,
  });
  const snapshots = {
    records: structuredClone([...registry._records]),
    claims: structuredClone([...registry._tokenClaims]),
    directories: structuredClone([...registry._targetDirectories]),
  };
  let membershipCalls = 0;
  for (const [changed, expectedBody] of [
    [
      { ...body, idempotencyKey: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' },
      v2DeniedReceipt(
        { ...body, idempotencyKey: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' },
        'not a known session for this user',
      ),
    ],
    [{ ...body, voipToken: 'different-token' }, { error: 'not a known session for this user' }],
  ]) {
    const response = await service.register({
      principal: 'principal-a',
      humanId: 'verified-human',
      body: changed,
      isMember: async () => { membershipCalls += 1; return false; },
    });
    assert.deepEqual(response, {
      status: 403,
      body: expectedBody,
    });
    assert.equal(Object.hasOwn(response.body, 'bindingId'), false);
    assert.equal(Object.hasOwn(response.body, 'tokenClaimId'), false);
  }
  assert.equal(membershipCalls, 2);
  assert.deepEqual([...registry._records], snapshots.records);
  assert.deepEqual([...registry._tokenClaims], snapshots.claims);
  assert.deepEqual([...registry._targetDirectories], snapshots.directories);
});

test('register V2: exact replay at logical expiry is a typed 410 with revocation fences and no renewal', async () => {
  let now = NOW;
  const registry = createInMemoryDeviceRegistryV2({ hmacKey: V2_KEY, now: () => now, leaseSeconds: 60 });
  const service = createDialRegistry({ deviceRegistry: registry, now: () => now });
  const body = v2Registration();
  const first = await service.register({
    principal: 'principal-a',
    humanId: 'verified-human',
    body,
    isMember: async () => true,
  });
  now = Date.parse(first.body.expiresAt);
  let membershipCalls = 0;
  const expired = await service.register({
    principal: 'principal-a',
    humanId: 'verified-human',
    body,
    isMember: async () => { membershipCalls += 1; return true; },
  });
  assert.equal(expired.status, 410);
  assert.equal(expired.body.reason, 'registration-expired');
  assert.equal(expired.body.registered, false);
  assert.equal(expired.body.committed, true);
  assert.equal(expired.body.authorized, false);
  assert.equal(expired.body.revocationRequired, true);
  assert.equal(expired.body.bindingId, first.body.bindingId);
  assert.equal(expired.body.tokenClaimId, first.body.tokenClaimId);
  assert.equal(expired.body.expiresAt, first.body.expiresAt);
  assert.equal(membershipCalls, 0, 'logical expiry is definitive before an authorization lookup');
});

test('cleanup V2: digest-only absent operation is durably denied and replays one strict non-authorizing receipt', async () => {
  const registry = createInMemoryDeviceRegistryV2({ hmacKey: V2_KEY, now: () => NOW });
  const service = createDialRegistry({ deviceRegistry: registry, now: () => NOW });
  const body = v2Cleanup();
  const expected = {
    registrationVersion: 2,
    ownerVersion: body.ownerVersion,
    ownerHandle: body.ownerHandle,
    idempotencyKey: body.idempotencyKey,
    sessionId: body.sessionId,
    platform: body.platform,
    registered: false,
    authorized: false,
    cleanupComplete: true,
    serverTime: new Date(NOW).toISOString(),
  };

  assert.deepEqual(
    await service.cleanupRegistration({ principal: 'principal-a', humanId: 'verified-human', body }),
    { status: 200, body: expected },
  );
  assert.deepEqual(
    await service.cleanupRegistration({ principal: 'principal-a', humanId: 'verified-human', body }),
    { status: 200, body: expected },
    'a lost cleanup response is safely replayable',
  );
  assert.equal(registry._operations.size, 1);
  assert.equal(registry._records.size, 0);
  const deniedRetry = await service.register({
    principal: 'principal-a',
    humanId: 'verified-human',
    body: v2Registration(),
    isMember: async () => true,
  });
  assert.equal(deniedRetry.status, 409);
  assert.equal(deniedRetry.body.reason, 'registration-denied-before-commit');
  assert.equal(deniedRetry.body.committed, false);
});

test('cleanup V2 shared KAV produces the exact strict non-authorizing success wire', async () => {
  for (const vector of cleanupKav.vectors) {
    const registry = createInMemoryDeviceRegistryV2({ hmacKey: V2_KEY, now: () => NOW });
    const service = createDialRegistry({ deviceRegistry: registry, now: () => NOW });
    assert.deepEqual(
      await service.cleanupRegistration({
        principal: 'kav-principal',
        humanId: 'verified-human',
        body: vector.request,
      }),
      { status: 200, body: vector.successResponse },
    );
    assert.deepEqual(
      Object.keys(vector.successResponse).sort(),
      [
        'authorized', 'cleanupComplete', 'idempotencyKey', 'ownerHandle', 'ownerVersion',
        'platform', 'registered', 'registrationVersion', 'serverTime', 'sessionId',
      ],
    );
  }
});

test('cleanup V2: a committed operation is exact-deleted, while stale cleanup cannot delete a newer binding', async () => {
  const registry = createInMemoryDeviceRegistryV2({ hmacKey: V2_KEY, now: () => NOW });
  const service = createDialRegistry({ deviceRegistry: registry, now: () => NOW });
  const aBody = v2Registration();
  const a = await service.register({
    principal: 'principal-a',
    humanId: 'verified-human',
    body: aBody,
    isMember: async () => true,
  });
  assert.equal(a.status, 200);
  const bBody = v2Registration({
    idempotencyKey: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    voipToken: 'newer-routing-token',
    expectedBindingId: a.body.bindingId,
    expectedBindingRevision: a.body.bindingRevision,
  });
  const b = await service.register({
    principal: 'principal-a',
    humanId: 'verified-human',
    body: bBody,
    isMember: async () => true,
  });
  assert.equal(b.status, 200);

  const staleCleanup = await service.cleanupRegistration({
    principal: 'principal-a',
    humanId: 'verified-human',
    body: v2Cleanup(),
  });
  assert.equal(staleCleanup.status, 200);
  assert.deepEqual(
    (await registry.lookup({ principal: 'principal-a', humanId: 'verified-human', sessionId: 'session-v2' })).map(
      ({ bindingId }) => bindingId,
    ),
    [b.body.bindingId],
    'A cleanup compares A fences and cannot delete the newer B binding',
  );

  const currentCleanup = await service.cleanupRegistration({
    principal: 'principal-a',
    humanId: 'verified-human',
    body: v2Cleanup({ idempotencyKey: bBody.idempotencyKey, voipToken: bBody.voipToken }),
  });
  assert.equal(currentCleanup.status, 200);
  assert.deepEqual(
    await registry.lookup({ principal: 'principal-a', humanId: 'verified-human', sessionId: 'session-v2' }),
    [],
  );
});

test('cleanup V2: stale operation cannot delete a newer same-intent renewal', async () => {
  let now = NOW;
  const registry = createInMemoryDeviceRegistryV2({ hmacKey: V2_KEY, now: () => now, leaseSeconds: 60 });
  const service = createDialRegistry({ deviceRegistry: registry, now: () => now });
  const aBody = v2Registration();
  const a = await service.register({
    principal: 'principal-a',
    humanId: 'verified-human',
    body: aBody,
    isMember: async () => true,
  });
  assert.equal(a.status, 200);

  now += 10_000;
  const bBody = v2Registration({
    idempotencyKey: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    expectedBindingId: a.body.bindingId,
    expectedBindingRevision: a.body.bindingRevision,
  });
  const b = await service.register({
    principal: 'principal-a',
    humanId: 'verified-human',
    body: bBody,
    isMember: async () => true,
  });
  assert.equal(b.status, 200);
  assert.equal(b.body.bindingId, a.body.bindingId, 'same semantic route keeps its stable identity');
  assert.equal(b.body.bindingRevision, a.body.bindingRevision + 1, 'new operation advances the cleanup fence');

  assert.equal((await service.cleanupRegistration({
    principal: 'principal-a',
    humanId: 'verified-human',
    body: v2Cleanup(),
  })).status, 200);
  assert.deepEqual(
    (await registry.lookup({ principal: 'principal-a', humanId: 'verified-human', sessionId: 'session-v2' })).map(
      ({ bindingRevision }) => bindingRevision,
    ),
    [b.body.bindingRevision],
    'cleanup A is fenced away from the newer same-intent B grant',
  );

  assert.equal((await service.cleanupRegistration({
    principal: 'principal-a',
    humanId: 'verified-human',
    body: v2Cleanup({ idempotencyKey: bBody.idempotencyKey }),
  })).status, 200);
  assert.deepEqual(
    await registry.lookup({ principal: 'principal-a', humanId: 'verified-human', sessionId: 'session-v2' }),
    [],
  );
});

test('cleanup V2 rejects raw-token/unknown-field bodies and never returns lease-authority fences', async () => {
  const registry = createInMemoryDeviceRegistryV2({ hmacKey: V2_KEY, now: () => NOW });
  const service = createDialRegistry({ deviceRegistry: registry, now: () => NOW });
  const invalid = await service.cleanupRegistration({
    principal: 'p',
    humanId: 'u',
    body: { ...v2Cleanup(), voipToken: 'must-not-be-accepted' },
  });
  assert.equal(invalid.status, 400);
  assert.equal(invalid.body.reason, 'registration-cleanup-v2-required');
  const response = await service.cleanupRegistration({
    principal: 'principal-a',
    humanId: 'verified-human',
    body: v2Cleanup(),
  });
  for (const forbidden of ['bindingId', 'bindingRevision', 'tokenClaimId', 'tokenClaimRevision', 'expiresAt', 'idempotent']) {
    assert.equal(Object.hasOwn(response.body, forbidden), false, `cleanup response cannot grant ${forbidden}`);
  }
});

test('cleanup V2 maps adapter conflicts and malformed outcomes without authority leakage', async () => {
  const committedRegistration = {
    ownerVersion: DEVICE_REGISTRY_OWNER_VERSION,
    ownerHandle: V2_OWNER,
    bindingId: 'bind_0123456789abcdef0123456789abcdef',
    bindingRevision: 3,
    expiresAtEpochSec: Math.floor(NOW / 1000) + 60,
    idempotent: true,
    renewed: false,
    tokenClaimId: 'claim_0123456789abcdef0123456789abcdef',
    tokenClaimRevision: 4,
  };
  const cases = [
    {
      registry: completeV2Registry({
        async denyRegistration() { throw new DeviceRegistryV2Error('idempotency-conflict', 'different intent'); },
      }),
      status: 409,
      reason: 'idempotency-conflict',
    },
    {
      registry: completeV2Registry({
        async denyRegistration() {
          throw new DeviceRegistryV2Error('registration-outcome-conflict', 'contended');
        },
      }),
      status: 503,
      reason: 'registration-cleanup-conflict',
    },
    {
      registry: completeV2Registry({ async denyRegistration() { return { state: 'unknown' }; } }),
      status: 502,
      reason: 'registry-cleanup-failed',
    },
    {
      registry: completeV2Registry({
        async denyRegistration() { return { state: 'committed', registration: {} }; },
      }),
      status: 502,
      reason: 'registry-cleanup-failed',
    },
    {
      registry: completeV2Registry({
        async denyRegistration() { return { state: 'denied', extra: true }; },
      }),
      status: 502,
      reason: 'registry-cleanup-failed',
    },
    {
      registry: completeV2Registry({
        async denyRegistration() {
          return {
            state: 'denied',
            ownerVersion: DEVICE_REGISTRY_OWNER_VERSION,
            ownerHandle: deriveDeviceOwnerHandle(V2_KEY, 'other', 'owner'),
          };
        },
      }),
      status: 502,
      reason: 'registry-cleanup-failed',
    },
    {
      registry: completeV2Registry({
        async denyRegistration() { return { state: 'committed', registration: committedRegistration }; },
        async unregister() { throw new DeviceRegistryV2Error('unregistration-conflict', 'contended'); },
      }),
      status: 503,
      reason: 'registration-cleanup-conflict',
    },
    {
      registry: completeV2Registry({
        async denyRegistration() { return { state: 'committed', registration: committedRegistration }; },
        async unregister() { return undefined; },
      }),
      status: 502,
      reason: 'registry-cleanup-failed',
    },
    {
      registry: completeV2Registry({
        async denyRegistration() { return { state: 'committed', registration: committedRegistration }; },
        async unregister() {
          return {
            removed: false,
            ownerVersion: DEVICE_REGISTRY_OWNER_VERSION,
            ownerHandle: deriveDeviceOwnerHandle(V2_KEY, 'other', 'owner'),
          };
        },
      }),
      status: 502,
      reason: 'registry-cleanup-failed',
    },
  ];
  for (const entry of cases) {
    const response = await createDialRegistry({ deviceRegistry: entry.registry, now: () => NOW })
      .cleanupRegistration({ principal: 'p', humanId: 'u', body: v2Cleanup() });
    assert.equal(response.status, entry.status);
    assert.equal(response.body.reason, entry.reason);
    for (const forbidden of ['bindingId', 'bindingRevision', 'tokenClaimId', 'tokenClaimRevision', 'expiresAt']) {
      assert.equal(Object.hasOwn(response.body, forbidden), false);
    }
  }
});

test('register V2: unversioned migration fails closed; V2 request on legacy registry is honestly unavailable', async () => {
  const v2 = createDialRegistry({
    deviceRegistry: createInMemoryDeviceRegistryV2({ hmacKey: V2_KEY, now: () => NOW }),
    now: () => NOW,
  });
  assert.equal((await v2.register({
    humanId: 'u',
    body: { voipToken: 't', sessionId: 's', platform: 'apns' },
    isMember: async () => true,
  })).status, 426);

  const legacyRegistry = fakeRegistry();
  const legacy = createDialRegistry({ deviceRegistry: legacyRegistry, now: () => NOW });
  const response = await legacy.register({
    humanId: 'u',
    body: v2Registration({ voipToken: 't', sessionId: 's' }),
    isMember: async () => true,
  });
  assert.equal(response.status, 501);
  assert.equal(response.body.reason, 'dial-registry-v2-not-configured');
  assert.equal((await legacy.register({
    humanId: 'u',
    body: {
      voipToken: 't',
      sessionId: 's',
      expectedBindingId: 'bind_0123456789abcdef0123456789abcdef',
      expectedBindingRevision: 1,
    },
    isMember: async () => true,
  })).status, 501, 'V2-only CAS fields cannot be silently discarded by the legacy validator');
  assert.equal((await legacy.register({
    humanId: 'u',
    body: {
      voipToken: 't',
      sessionId: 's',
      expectedTokenClaimId: 'claim_0123456789abcdef0123456789abcdef',
      expectedTokenClaimRevision: 1,
    },
    isMember: async () => true,
  })).status, 501, 'token-owner CAS fields cannot be silently discarded by the legacy validator');

  const v2OnlyMarkers = [
    'registrationVersion', 'registryVersion', 'ownerVersion', 'ownerHandle', 'installationId',
    'installationGeneration', 'previousInstallationGeneration', 'idempotencyKey', 'tokenDigest', 'binding',
    'bindingVersion', 'bindingId', 'bindingRevision', 'tokenClaimId', 'tokenClaimRevision',
    'expectedBindingId', 'expectedBindingRevision', 'expectedTokenClaimId', 'expectedTokenClaimRevision',
  ];
  for (const marker of v2OnlyMarkers) {
    const writesBefore = legacyRegistry.records.length;
    const markerResponse = await legacy.register({
      humanId: 'u',
      body: { voipToken: 't', sessionId: 's', [marker]: null },
      isMember: async () => true,
    });
    assert.equal(markerResponse.status, 501, `${marker} cannot downgrade into V1`);
    assert.equal(legacyRegistry.records.length, writesBefore, `${marker} cannot write a V1 row`);
  }
});

test('register V2 maps idempotency reuse to 409 and does not leak registry internals', async () => {
  const rawSecret = 'raw-idempotency-adapter-message';
  const service = createDialRegistry({
    deviceRegistry: completeV2Registry({
      async register() {
        throw new DeviceRegistryV2Error('idempotency-conflict', rawSecret);
      },
    }),
  });
  const response = await service.register({
    humanId: 'u',
    body: v2Registration({ voipToken: 't', sessionId: 's' }),
    isMember: async () => true,
  });
  assert.deepEqual(response, {
    status: 409,
    body: {
      error: 'idempotency key was reused for different registration data',
      reason: 'idempotency-conflict',
    },
  });
  assert.equal(JSON.stringify(response).includes(rawSecret), false);
});

test('register V2 maps a strict binding conflict fence and exact null without adapter metadata', async (t) => {
  const currentBinding = {
    bindingId: 'bind_0123456789abcdef0123456789abcdef',
    bindingRevision: 7,
    expiresAtEpochSec: Math.floor(NOW / 1000) + 60,
    idempotent: false,
    renewed: false,
  };
  for (const [name, detail, expected] of [
    ['current', { currentBinding }, {
      bindingId: currentBinding.bindingId,
      bindingRevision: currentBinding.bindingRevision,
      expiresAt: new Date(NOW + 60_000).toISOString(),
    }],
    ['absent', { currentBinding: null }, null],
  ]) {
    await t.test(name, async () => {
      const service = createDialRegistry({
        deviceRegistry: completeV2Registry({
          async register() { throw new DeviceRegistryV2Error('binding-conflict', 'private detail', detail); },
        }),
        now: () => NOW,
      });
      const response = await service.register({
        humanId: 'u',
        body: v2Registration(),
        isMember: async () => true,
      });
      assert.deepEqual(response, {
        status: 409,
        body: {
          error: 'registration expected binding is no longer current',
          reason: 'binding-conflict',
          ownerVersion: DEVICE_REGISTRY_OWNER_VERSION,
          ownerHandle: V2_OWNER,
          currentBinding: expected,
        },
      });
    });
  }
});

test('register V2 maps token-owner conflict to the exact retry CAS tuple without leaking its owner', async () => {
  const service = createDialRegistry({
    deviceRegistry: completeV2Registry({
      async register() {
        throw new DeviceRegistryV2Error(
          'token-claim-conflict',
          'token owner moved',
          {
            currentTokenClaim: {
              tokenClaimId: 'claim_0123456789abcdef0123456789abcdef',
              tokenClaimRevision: 7,
              expiresAtEpochSec: Math.floor(NOW / 1000) + 60,
            },
          },
        );
      },
    }),
  });
  const response = await service.register({
    humanId: 'u',
    body: v2Registration({ voipToken: 't', sessionId: 's' }),
    isMember: async () => true,
  });
  assert.equal(response.status, 409);
  assert.deepEqual(response.body.currentTokenClaim, {
    tokenClaimId: 'claim_0123456789abcdef0123456789abcdef',
    tokenClaimRevision: 7,
    expiresAt: new Date(NOW + 60_000).toISOString(),
  });
  assert.equal(response.body.reason, 'token-claim-conflict');
  assert.equal(response.body.ownerVersion, DEVICE_REGISTRY_OWNER_VERSION);
  assert.equal(response.body.ownerHandle, V2_OWNER);
  assert.deepEqual(Object.keys(response.body.currentTokenClaim).sort(), [
    'expiresAt', 'tokenClaimId', 'tokenClaimRevision',
  ]);
});

test('register V2 accepts an exact null token conflict fence', async () => {
  const service = createDialRegistry({
    deviceRegistry: completeV2Registry({
      async register() {
        throw new DeviceRegistryV2Error(
          'token-claim-conflict',
          'private detail',
          { currentTokenClaim: null },
        );
      },
    }),
    now: () => NOW,
  });
  const response = await service.register({
    humanId: 'u',
    body: v2Registration(),
    isMember: async () => true,
  });
  assert.deepEqual(response, {
    status: 409,
    body: {
      error: 'registration expected token claim is no longer current',
      reason: 'token-claim-conflict',
      ownerVersion: DEVICE_REGISTRY_OWNER_VERSION,
      ownerHandle: V2_OWNER,
      currentTokenClaim: null,
    },
  });
});

test('register V2 rejects malformed conflict details as typed 502 without echo or date throws', async (t) => {
  const rawSecret = 'raw-conflict-adapter-secret';
  const binding = {
    bindingId: 'bind_0123456789abcdef0123456789abcdef',
    bindingRevision: 7,
    expiresAtEpochSec: Math.floor(NOW / 1000) + 60,
    idempotent: false,
    renewed: false,
  };
  const claim = {
    tokenClaimId: 'claim_0123456789abcdef0123456789abcdef',
    tokenClaimRevision: 8,
    expiresAtEpochSec: Math.floor(NOW / 1000) + 60,
  };
  const cases = [
    ['binding missing detail', 'binding-conflict', undefined],
    ['binding throwing detail shape', 'binding-conflict', new Proxy({}, {
      ownKeys() { throw new Error(rawSecret); },
    })],
    ['binding extra detail', 'binding-conflict', { currentBinding: binding, adapterDetail: rawSecret }],
    ['binding extra fence field', 'binding-conflict', {
      currentBinding: { ...binding, adapterDetail: rawSecret },
    }],
    ['binding bad id', 'binding-conflict', { currentBinding: { ...binding, bindingId: rawSecret } }],
    ['binding bad revision', 'binding-conflict', { currentBinding: { ...binding, bindingRevision: 0 } }],
    ['binding bad metadata semantics', 'binding-conflict', {
      currentBinding: { ...binding, idempotent: true },
    }],
    ['binding invalid expiry', 'binding-conflict', {
      currentBinding: { ...binding, expiresAtEpochSec: 8_640_000_000_001 },
    }],
    ['claim missing detail', 'token-claim-conflict', undefined],
    ['claim extra detail', 'token-claim-conflict', { currentTokenClaim: claim, adapterDetail: rawSecret }],
    ['claim extra fence field', 'token-claim-conflict', {
      currentTokenClaim: { ...claim, ownerInstallationKey: rawSecret },
    }],
    ['claim bad id', 'token-claim-conflict', { currentTokenClaim: { ...claim, tokenClaimId: rawSecret } }],
    ['claim bad revision', 'token-claim-conflict', { currentTokenClaim: { ...claim, tokenClaimRevision: 0 } }],
    ['claim invalid expiry', 'token-claim-conflict', {
      currentTokenClaim: { ...claim, expiresAtEpochSec: 'not-an-epoch' },
    }],
  ];
  for (const [name, code, details] of cases) {
    await t.test(name, async () => {
      const service = createDialRegistry({
        deviceRegistry: completeV2Registry({
          async register() { throw new DeviceRegistryV2Error(code, rawSecret, details); },
        }),
        now: () => NOW,
      });
      const response = await service.register({
        humanId: 'u',
        body: v2Registration(),
        isMember: async () => true,
      });
      assert.deepEqual(response, {
        status: 502,
        body: { error: 'registry write failed', reason: 'registry-write-failed' },
      });
      assert.equal(JSON.stringify(response).includes(rawSecret), false);
    });
  }
});

test('register V2 maps bounded target admission to a typed 409', async () => {
  const service = createDialRegistry({
    deviceRegistry: completeV2Registry({
      async register() {
        throw new DeviceRegistryV2Error('target-capacity', 'full');
      },
    }),
  });
  const response = await service.register({
    humanId: 'u',
    body: v2Registration({ voipToken: 't', sessionId: 's' }),
    isMember: async () => true,
  });
  assert.deepEqual(response, {
    status: 409,
    body: {
      error: 'target already has the maximum number of active device installations',
      reason: 'target-capacity',
    },
  });
});

test('register V2 preserves bounded-contention and permanent-revision 409 reasons', async () => {
  for (const reason of ['registration-conflict', 'revision-exhausted']) {
    const service = createDialRegistry({
      deviceRegistry: completeV2Registry({
        async register() {
          throw new DeviceRegistryV2Error(reason, 'internal detail');
        },
      }),
    });
    assert.deepEqual(
      await service.register({
        humanId: 'u',
        body: v2Registration({ voipToken: 't', sessionId: 's' }),
        isMember: async () => true,
      }),
      {
        status: 409,
        body: {
          error: 'registration could not be serialized',
          reason,
        },
      },
    );
  }
});

test('unregister V2 is membership-independent, exact-fenced, idempotent, and existence-oblivious', async () => {
  const registry = createInMemoryDeviceRegistryV2({ hmacKey: V2_KEY, now: () => NOW });
  const service = createDialRegistry({ deviceRegistry: registry, now: () => NOW });
  const registered = await service.register({
    principal: 'principal-a',
    humanId: 'verified-human',
    body: v2Registration({ voipToken: 't', sessionId: 'lost-room' }),
    isMember: async () => true,
  });
  const body = v2Unregister(registered.body.bindingId, registered.body.bindingRevision, {
    sessionId: 'lost-room',
  });
  const expected = {
    status: 200,
    body: {
      unregistered: true,
      registrationVersion: 2,
      ownerVersion: DEVICE_REGISTRY_OWNER_VERSION,
      ownerHandle: V2_OWNER,
      sessionId: 'lost-room',
    },
  };
  const args = { principal: 'principal-a', humanId: 'verified-human', body };
  assert.deepEqual(await service.unregister(args), expected);
  assert.deepEqual(await service.unregister(args), expected);
});

test('unregister V2 validation uses operation-specific reason and operation-neutral unknown-field text', async () => {
  const service = createDialRegistry({
    deviceRegistry: completeV2Registry({
      async unregister() {
        throw new Error('invalid requests must not reach the registry');
      },
    }),
  });
  const response = await service.unregister({
    humanId: 'u',
    body: {
      ...v2Unregister('bind_0123456789abcdef0123456789abcdef', 1, { sessionId: 's' }),
      generation: 7,
    },
  });
  assert.deepEqual(response, {
    status: 400,
    body: {
      error: 'unsupported registry field: generation',
      reason: 'unregistration-v2-required',
    },
  });
});

test('unregister V2 rejects a malformed owner echo from an injected adapter', async () => {
  const service = createDialRegistry({
    deviceRegistry: completeV2Registry({
      async unregister() {
        return {
          removed: false,
          ownerVersion: DEVICE_REGISTRY_OWNER_VERSION,
          ownerHandle: deriveDeviceOwnerHandle(V2_KEY, 'other', 'owner'),
        };
      },
    }),
  });
  assert.deepEqual(
    await service.unregister({
      principal: 'principal-a',
      humanId: 'verified-human',
      body: v2Unregister('bind_0123456789abcdef0123456789abcdef', 1),
    }),
    { status: 502, body: { error: 'registry delete failed', reason: 'registry-delete-failed' } },
  );
});

test('unregister V2 keeps local state retryable when the exact active tuple cannot serialize', async () => {
  const service = createDialRegistry({
    deviceRegistry: completeV2Registry({
      async unregister() {
        throw new DeviceRegistryV2Error('unregistration-conflict', 'still active');
      },
    }),
  });
  const response = await service.unregister({
    humanId: 'u',
    body: v2Unregister('bind_0123456789abcdef0123456789abcdef', 1, { sessionId: 's' }),
  });
  assert.deepEqual(response, {
    status: 503,
    body: {
      error: 'registry delete could not be serialized',
      reason: 'unregistration-conflict',
    },
  });
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
  assert.deepEqual(sent[0].payload.aps, {}, 'live dispatch receives the final APNs dictionary, not a bare DTO');
  assert.ok(Buffer.byteLength(JSON.stringify(sent[0].payload), 'utf8') <= DIAL_PUSHKIT_CAP);
});

test('pushBackend snapshots the injected lookup capability exactly once and fails closed on a throwing getter', async () => {
  let reads = 0;
  const registry = {
    get lookup() {
      reads += 1;
      if (reads > 1) throw new Error('lookup getter read twice');
      return async () => [{ voipToken: 'tok', platform: 'apns' }];
    },
  };
  const result = await createDialPushBackend({
    deviceRegistry: registry,
    apnsSend: async () => ({ delivered: true }),
    now: () => NOW,
  })({ humanId: 'u', sessionId: 's', message: 'ring' });
  assert.equal(result.dispatched, true);
  assert.equal(reads, 1, 'the same snapshotted function services both authority reads');

  const throwingRegistry = {
    get lookup() { throw new Error('adapter getter failed'); },
  };
  const disabled = createDialPushBackend({
    deviceRegistry: throwingRegistry,
    apnsSend: async () => ({ delivered: true }),
  });
  assert.deepEqual(
    await disabled({ humanId: 'u', sessionId: 's', message: 'ring' }),
    { dispatched: false, reason: 'dial-not-configured' },
  );
});

test('pushBackend V2 places the exact versioned server binding fence inside the byte-budgeted payload', async () => {
  const registry = createInMemoryDeviceRegistryV2({ hmacKey: V2_KEY, now: () => NOW });
  const bound = await registry.register({
    principal: 'u',
    humanId: 'u',
    registrationVersion: 2,
    ownerVersion: DEVICE_REGISTRY_OWNER_VERSION,
    ownerHandle: deriveDeviceOwnerHandle(V2_KEY, 'u', 'u'),
    installationId: V2_INSTALLATION,
    idempotencyKey: V2_IDEMPOTENCY,
    voipToken: 'tok-v2',
    sessionId: 's',
    platform: 'apns',
  });
  const sent = [];
  const result = await createDialPushBackend({
    deviceRegistry: registry,
    apnsSend: async (input) => { sent.push(input); return { delivered: true }; },
    now: () => NOW,
  })({ humanId: 'u', sessionId: 's', message: 'ring' });
  assert.equal(result.dispatched, true);
  assert.equal(sent[0].payload.v, 2, 'old V1 binaries reject a binding-required push');
  assert.deepEqual(sent[0].payload.binding, {
    v: 2,
    id: bound.bindingId,
    revision: bound.bindingRevision,
  });
  assert.equal(Object.hasOwn(sent[0].payload, 'bindingId'), false, 'the fence is one versioned envelope');
  assert.deepEqual(sent[0].payload.aps, {}, 'the final APNs envelope is built before the transport seam');
  assert.ok(Buffer.byteLength(JSON.stringify(sent[0].payload), 'utf8') <= DIAL_PUSHKIT_CAP);
});

test('pushBackend V2 rejects an incomplete/invalid binding record before APNs', async () => {
  let sends = 0;
  const registry = {
    protocolVersion: 2,
    async lookup() { return [{ voipToken: 'tok', platform: 'apns', bindingId: 'bad', bindingRevision: 1 }]; },
  };
  const result = await createDialPushBackend({
    deviceRegistry: registry,
    apnsSend: async () => { sends += 1; return { delivered: true }; },
    now: () => NOW,
  })({ humanId: 'u', sessionId: 's', message: 'ring' });
  assert.deepEqual(result, { dispatched: false, reason: 'no-device-token' });
  assert.equal(sends, 0);
});

test('pushBackend revalidates the exact V2 route once after payload preparation and closes a revision race', async () => {
  const bindingId = 'bind_0123456789abcdef0123456789abcdef';
  const snapshots = [
    [{ voipToken: 'tok', platform: 'apns', bindingId, bindingRevision: 1 }],
    [{ voipToken: 'tok', platform: 'apns', bindingId, bindingRevision: 2 }],
  ];
  const lookupArgs = [];
  const registry = {
    protocolVersion: 2,
    async lookup(args) {
      lookupArgs.push({ ...args });
      return snapshots.shift();
    },
  };
  let sends = 0;
  const result = await createDialPushBackend({
    deviceRegistry: registry,
    apnsSend: async () => { sends += 1; return { delivered: true }; },
    now: () => NOW,
  })({
    principal: 'issuer:site:pairwise-u',
    humanId: 'u',
    sessionId: 's',
    message: 'ring',
  });
  assert.deepEqual(result, {
    dispatched: false,
    reason: 'stale-device-binding',
    dialId: computeDialId('issuer:site:pairwise-u', 's', 'ring', NOW),
    devices: 0,
  });
  assert.equal(sends, 0);
  assert.equal(lookupArgs.length, 2);
  assert.deepEqual(lookupArgs[0], lookupArgs[1], 'both snapshots use identical authority coordinates');
  assert.deepEqual(lookupArgs[0], {
    principal: 'issuer:site:pairwise-u',
    humanId: 'u',
    sessionId: 's',
  });
});

test('pushBackend sends only exact routes that survive the second bounded snapshot', async () => {
  const bindingA = 'bind_0123456789abcdef0123456789abcdef';
  const bindingB = 'bind_fedcba9876543210fedcba9876543210';
  const routeA = { voipToken: 'tok-a', platform: 'apns', bindingId: bindingA, bindingRevision: 1 };
  const routeB = { voipToken: 'tok-b', platform: 'apns', bindingId: bindingB, bindingRevision: 4 };
  const snapshots = [[routeA, routeB], [routeB]];
  const sent = [];
  const result = await createDialPushBackend({
    deviceRegistry: { protocolVersion: 2, async lookup() { return snapshots.shift(); } },
    apnsSend: async (input) => { sent.push(input); return { delivered: true }; },
    now: () => NOW,
  })({ humanId: 'u', sessionId: 's', message: 'ring' });
  assert.equal(result.dispatched, true);
  assert.equal(result.devices, 1, 'reported devices count only post-revalidation survivors');
  assert.equal(result.delivered, 1);
  assert.deepEqual(sent.map(({ voipToken }) => voipToken), ['tok-b']);
  assert.deepEqual(sent[0].payload.binding, { v: 2, id: bindingB, revision: 4 });
});

test('pushBackend fails typed and sends nothing when the final registry snapshot is unavailable', async () => {
  const events = [];
  let lookups = 0;
  const registry = {
    async lookup(args) {
      events.push(['lookup', { ...args }]);
      lookups += 1;
      if (lookups === 2) throw new Error('registry unavailable');
      return [{ voipToken: 'tok', platform: 'apns' }];
    },
  };
  let sends = 0;
  const result = await createDialPushBackend({
    deviceRegistry: registry,
    apnsSend: async () => { sends += 1; return { delivered: true }; },
    signalStore: { async put() { events.push(['signal-put']); } },
    now: () => NOW,
  })({
    principal: 'issuer:site:u',
    humanId: 'u',
    sessionId: 's',
    message: 'ring',
    storedSignal: { id: 'signal' },
  });
  assert.deepEqual(result, {
    dispatched: false,
    reason: 'registry-revalidation-failed',
    dialId: computeDialId('issuer:site:u', 's', 'ring', NOW),
  });
  assert.equal(sends, 0);
  assert.deepEqual(events.map(([event]) => event), ['lookup', 'signal-put', 'lookup']);
  assert.deepEqual(events[0][1], events[2][1]);
});

test('pushBackend exact V2 freshness key rejects every changed route dimension', async (t) => {
  const bindingId = 'bind_0123456789abcdef0123456789abcdef';
  const captured = { voipToken: 'tok', platform: 'apns', bindingId, bindingRevision: 3 };
  const cases = [
    ['token', { ...captured, voipToken: 'other' }],
    ['platform', { ...captured, platform: 'fcm' }],
    ['binding id', { ...captured, bindingId: 'bind_fedcba9876543210fedcba9876543210' }],
    ['binding revision', { ...captured, bindingRevision: 4 }],
  ];
  for (const [name, current] of cases) {
    await t.test(name, async () => {
      const snapshots = [[captured], [current]];
      let sends = 0;
      const result = await createDialPushBackend({
        deviceRegistry: { protocolVersion: 2, async lookup() { return snapshots.shift(); } },
        apnsSend: async () => { sends += 1; return { delivered: true }; },
        now: () => NOW,
      })({ humanId: 'u', sessionId: 's', message: 'ring' });
      assert.equal(result.reason, 'stale-device-binding');
      assert.equal(result.devices, 0);
      assert.equal(sends, 0);
    });
  }
});

test('pushBackend never downgrades a partial V2 lookup row into an unfenced V1 delivery', async (t) => {
  const routeMarkers = [
    'registrationVersion', 'registryVersion', 'ownerVersion', 'ownerHandle', 'installationId',
    'installationGeneration', 'installationHash', 'previousInstallationGeneration', 'idempotencyKey', 'tokenDigest', 'binding',
    'bindingVersion', 'bindingId', 'bindingRevision', 'tokenClaimId', 'tokenClaimRevision',
    'expiresAtEpochSec',
    'expectedBindingId', 'expectedBindingRevision', 'expectedTokenClaimId', 'expectedTokenClaimRevision',
  ];
  for (const marker of routeMarkers) {
    await t.test(marker, async () => {
      let sends = 0;
      const result = await createDialPushBackend({
        deviceRegistry: {
          protocolVersion: 1,
          async lookup() {
            const row = { voipToken: 'tok', platform: 'apns' };
            Object.defineProperty(row, marker, { value: null, enumerable: false });
            return [row];
          },
        },
        apnsSend: async () => { sends += 1; return { delivered: true }; },
        now: () => NOW,
      })({ humanId: 'u', sessionId: 's', message: 'ring' });
      assert.deepEqual(result, { dispatched: false, reason: 'no-device-token' });
      assert.equal(sends, 0);
    });
  }
});

test('pushBackend namespaces generated dial and hydration identity by full principal', async () => {
  const registry = { async lookup() { return [{ voipToken: 'tok', platform: 'apns' }]; } };
  const backend = createDialPushBackend({
    deviceRegistry: registry,
    apnsSend: async () => ({ delivered: true }),
    now: () => NOW,
  });
  const a = await backend({ principal: 'issuer:site-a:u', humanId: 'u', sessionId: 's', message: 'ring' });
  const b = await backend({ principal: 'issuer:site-b:u', humanId: 'u', sessionId: 's', message: 'ring' });
  assert.equal(a.dialId, computeDialId('issuer:site-a:u', 's', 'ring', NOW));
  assert.equal(b.dialId, computeDialId('issuer:site-b:u', 's', 'ring', NOW));
  assert.notEqual(a.dialId, b.dialId);
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

test('createStoreDeviceRegistry: V1 authority is exact-principal tagged, expiring, and physically TTL bounded', async () => {
  let clock = NOW;
  const records = new Map();
  const writes = [];
  const store = {
    async get(key) { return records.get(key); },
    async put(key, value, options) {
      writes.push({ key, value, options });
      records.set(key, value);
      return value;
    },
  };
  const registry = createStoreDeviceRegistry({ store, now: () => clock, leaseSeconds: 60 });
  const principalA = 'issuer:site-a:same-human';
  const principalB = 'issuer:site-b:same-human';
  await registry.register({
    principal: principalA,
    humanId: 'same-human',
    sessionId: 'same-session',
    voipToken: 'token-a',
    platform: 'apns',
  });
  assert.equal(writes[0].value.principal, principalA);
  assert.equal(writes[0].value.expiresAtSec, Math.floor(NOW / 1000) + 60);
  assert.deepEqual(writes[0].options, { ttlEpochSec: Math.floor(NOW / 1000) + 60 });
  assert.deepEqual(
    await registry.lookup({ principal: principalA, humanId: 'same-human', sessionId: 'same-session' }),
    [{ voipToken: 'token-a', platform: 'apns' }],
  );
  assert.deepEqual(
    await registry.lookup({ principal: principalB, humanId: 'same-human', sessionId: 'same-session' }),
    [],
    'an equal humanId from another site cannot see principal A',
  );

  await registry.register({
    principal: principalB,
    humanId: 'same-human',
    sessionId: 'same-session',
    voipToken: 'token-b',
    platform: 'fcm',
  });
  assert.notEqual(writes[0].key, writes[1].key, 'site principals occupy separate compatibility keys');
  assert.deepEqual(
    await registry.lookup({ principal: principalB, humanId: 'same-human', sessionId: 'same-session' }),
    [{ voipToken: 'token-b', platform: 'fcm' }],
  );

  records.set(writes[0].key, {
    voipToken: 'untagged-token',
    platform: 'apns',
    expiresAtSec: Math.floor(NOW / 1000) + 60,
  });
  assert.deepEqual(
    await registry.lookup({ principal: principalA, humanId: 'same-human', sessionId: 'same-session' }),
    [],
    'a row without the exact principal tag has no authority',
  );
  records.set('dial:dev:10:same-human:historical-session', {
    voipToken: 'historical-token',
    platform: 'apns',
    registeredAt: new Date(NOW).toISOString(),
    expiresAtSec: Math.floor(NOW / 1000) + 60,
  });
  assert.deepEqual(
    await registry.lookup({ principal: principalA, humanId: 'same-human', sessionId: 'historical-session' }),
    [],
    'historical human-only keys are never consulted',
  );

  clock = NOW + 59_000;
  assert.equal((await registry.lookup({
    principal: principalB,
    humanId: 'same-human',
    sessionId: 'same-session',
  })).length, 1, 'the tagged row remains live immediately before expiry');
  clock = NOW + 60_000;
  assert.deepEqual(await registry.lookup({
    principal: principalB,
    humanId: 'same-human',
    sessionId: 'same-session',
  }), [], 'logical authority ends exactly at expiresAtSec even before physical TTL deletion');
});

test('createStoreDeviceRegistry: requires a get/put store', () => {
  assert.throws(() => createStoreDeviceRegistry({}), /requires a \{ get, put \} store/);
  const store = { async get() {}, async put() {} };
  for (const leaseSeconds of [0, -1, 1.5, Number.MAX_SAFE_INTEGER + 1, '60']) {
    assert.throws(
      () => createStoreDeviceRegistry({ store, leaseSeconds }),
      /leaseSeconds must be a positive safe integer/,
    );
  }
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

test('pushBackend: the same token text in different platform namespaces rings both routes', async () => {
  const reg = fakeRegistry();
  await reg.register({ humanId: 'u', sessionId: 's', voipToken: 'same', platform: 'apns' });
  await reg.register({ humanId: 'u', sessionId: 's', voipToken: 'same', platform: 'fcm' });
  const sent = [];
  const pb = createDialPushBackend({
    deviceRegistry: reg,
    apnsSend: async (input) => { sent.push(input); return { delivered: true }; },
    now: () => NOW,
  });
  const out = await pb({ message: 'm', sessionId: 's', humanId: 'u' });
  assert.deepEqual(sent.map(({ platform }) => platform), ['apns', 'fcm']);
  assert.equal(out.devices, 2);
  assert.equal(out.delivered, 2);
});

test('pushBackend V2 groups routes before cap: exact fence duplicates collapse, conflicting fences are skipped', async () => {
  const bindingA = 'bind_0123456789abcdef0123456789abcdef';
  const bindingB = 'bind_fedcba9876543210fedcba9876543210';
  const device = (voipToken, platform, bindingId, bindingRevision = 1) => ({
    voipToken, platform, bindingId, bindingRevision,
  });
  const sent = [];
  const registry = {
    protocolVersion: 2,
    async lookup() {
      return [
        device('ambiguous', 'apns', bindingA),
        device('ambiguous', 'apns', bindingB),
        device('valid', 'apns', bindingA),
        device('valid', 'apns', bindingA),
        device('valid', 'fcm', bindingB),
      ];
    },
  };
  const out = await createDialPushBackend({
    deviceRegistry: registry,
    maxDevices: 2,
    apnsSend: async (input) => { sent.push(input); return { delivered: true }; },
    now: () => NOW,
  })({ message: 'm', sessionId: 's', humanId: 'u' });
  assert.deepEqual(sent.map(({ voipToken, platform, payload }) => ({
    voipToken,
    platform,
    binding: payload.binding,
  })), [
    { voipToken: 'valid', platform: 'apns', binding: { v: 2, id: bindingA, revision: 1 } },
    { voipToken: 'valid', platform: 'fcm', binding: { v: 2, id: bindingB, revision: 1 } },
  ]);
  assert.equal(out.devices, 2);
  assert.equal(out.delivered, 2);
});

test('pushBackend V2 fails typed when every route has conflicting binding fences', async () => {
  let sends = 0;
  const registry = {
    protocolVersion: 2,
    async lookup() {
      return [
        { voipToken: 'same', platform: 'apns', bindingId: 'bind_0123456789abcdef0123456789abcdef', bindingRevision: 1 },
        { voipToken: 'same', platform: 'apns', bindingId: 'bind_fedcba9876543210fedcba9876543210', bindingRevision: 2 },
      ];
    },
  };
  const out = await createDialPushBackend({
    deviceRegistry: registry,
    apnsSend: async () => { sends += 1; return { delivered: true }; },
    now: () => NOW,
  })({ message: 'm', sessionId: 's', humanId: 'u' });
  assert.deepEqual(out, { dispatched: false, reason: 'registry-route-conflict' });
  assert.equal(sends, 0);
});
