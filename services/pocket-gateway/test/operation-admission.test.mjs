import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import {
  REGISTRY_OPERATION_ADMISSION_LIMITS,
  RegistryOperationAdmissionError,
  createRegistryOperationAdmission,
  deriveRegistryOperationAdmissionIdentity,
  isRegistryOperationAdmissionRoute,
  timingSafeOwnerHandleEqual,
} from '../src/operation-admission.mjs';
import { deriveDeviceOwnerHandle } from '../src/device-registry-v2.mjs';
import { createInMemoryStore } from '../src/store.mjs';

const KEY = Buffer.alloc(32, 0x5a);
const PRINCIPAL = 'pocket.principal.senti.v1\n7:user_42';
const HUMAN_ID = 'user_42';
const START = Date.parse('2026-08-04T12:00:00.000Z');

const uuidFor = (index) =>
  `${index.toString(16).padStart(8, '0')}-0000-4000-8000-${index.toString(16).padStart(12, '0')}`;
const installationFor = (index) => Buffer.alloc(32, (index % 251) + 1).toString('base64url');

function registration(index = 1, overrides = {}, principal = PRINCIPAL, humanId = HUMAN_ID) {
  return {
    registrationVersion: 2,
    ownerVersion: 1,
    ownerHandle: deriveDeviceOwnerHandle(KEY, principal, humanId),
    installationId: installationFor(index),
    idempotencyKey: uuidFor(index),
    voipToken: `token-${index}`,
    sessionId: `session-${index}`,
    platform: 'apns',
    ...overrides,
  };
}

function cleanup(index = 1, overrides = {}, principal = PRINCIPAL, humanId = HUMAN_ID) {
  const source = registration(index, {}, principal, humanId);
  return {
    registrationVersion: source.registrationVersion,
    ownerVersion: source.ownerVersion,
    ownerHandle: source.ownerHandle,
    installationId: source.installationId,
    idempotencyKey: source.idempotencyKey,
    tokenDigest: createHash('sha256').update(source.voipToken, 'utf8').digest('base64url'),
    sessionId: source.sessionId,
    platform: source.platform,
    ...overrides,
  };
}

function identity(index = 1, options = {}) {
  const path = options.path ?? '/dial/register';
  const body = options.body ?? (path.endsWith('/reconcile') ? cleanup(index) : registration(index));
  const result = deriveRegistryOperationAdmissionIdentity({
    method: options.method ?? 'POST',
    path,
    body,
    principal: options.principal ?? PRINCIPAL,
    humanId: options.humanId ?? HUMAN_ID,
    hmacKey: options.hmacKey ?? KEY,
  });
  assert.equal(result.ok, true, `fixture ${index} must derive a valid identity`);
  return result;
}

const hasCode = (code) => (error) =>
  error instanceof RegistryOperationAdmissionError && error.code === code;

test('only the two exact Registry V2 POST routes are admission protected', () => {
  assert.equal(isRegistryOperationAdmissionRoute('POST', '/dial/register'), true);
  assert.equal(isRegistryOperationAdmissionRoute('POST', '/dial/register/reconcile'), true);
  assert.equal(isRegistryOperationAdmissionRoute('GET', '/dial/register'), false);
  assert.equal(isRegistryOperationAdmissionRoute('DELETE', '/dial/register'), false);
  assert.equal(isRegistryOperationAdmissionRoute('POST', '/dial/register/'), false);
  assert.equal(isRegistryOperationAdmissionRoute('post', '/dial/register'), false);
  assert.deepEqual(
    deriveRegistryOperationAdmissionIdentity({ method: 'GET', path: '/deck' }),
    { protected: false },
  );
});

test('identity derivation reuses the frozen operation tuple across register, reconcile, and semantic changes', () => {
  const first = identity(1);
  const reconciled = identity(1, { path: '/dial/register/reconcile' });
  const changed = identity(1, {
    body: registration(1, { voipToken: 'rotated-token', sessionId: 'different-session', platform: 'fcm' }),
  });
  assert.equal(first.ledgerKey, reconciled.ledgerKey);
  assert.equal(first.operationDigest, reconciled.operationDigest);
  assert.equal(first.operationDigest, changed.operationDigest, 'semantic conflicts remain the gateway\'s authority');
  assert.match(first.ledgerKey, /^dial:admission:v1:[A-Za-z0-9_-]{43}$/);
  assert.match(first.operationDigest, /^[A-Za-z0-9_-]{43}$/);
  assert.equal(first.ledgerKey.includes(PRINCIPAL), false);
  assert.equal(first.operationDigest.includes(registration(1).installationId), false);
});

test('strict V2 validation and constant-time owner matching happen before ledger allocation', () => {
  const invalid = deriveRegistryOperationAdmissionIdentity({
    method: 'POST',
    path: '/dial/register',
    body: { ...registration(1), richPushPayload: { title: 'smuggled' } },
    principal: PRINCIPAL,
    humanId: HUMAN_ID,
    hmacKey: KEY,
  });
  assert.equal(invalid.protected, true);
  assert.equal(invalid.ok, false);
  assert.equal(invalid.status, 400);
  assert.equal(invalid.reason, 'registration-v2-required');

  const wrongOwner = deriveRegistryOperationAdmissionIdentity({
    method: 'POST',
    path: '/dial/register',
    body: registration(1, { ownerHandle: deriveDeviceOwnerHandle(KEY, 'attacker', HUMAN_ID) }),
    principal: PRINCIPAL,
    humanId: HUMAN_ID,
    hmacKey: KEY,
  });
  assert.equal(wrongOwner.ok, true);
  assert.equal(wrongOwner.ownerMatches, false);
  assert.equal(timingSafeOwnerHandleEqual(registration(1).ownerHandle, deriveDeviceOwnerHandle(KEY, PRINCIPAL, HUMAN_ID)), true);
  assert.equal(timingSafeOwnerHandleEqual('not-a-digest', registration(1).ownerHandle), false);
  assert.equal(timingSafeOwnerHandleEqual(`${'A'.repeat(42)}B`, registration(1).ownerHandle), false);
});

test('new operation is charged once; exact replay is free and refreshes retention without another rate timestamp', async () => {
  const store = createInMemoryStore();
  let now = START;
  const ttlWrites = [];
  const wrapped = {
    ...store,
    async compareAndSwap(key, version, value, opts) {
      ttlWrites.push(opts.ttlEpochSec);
      return store.compareAndSwap(key, version, value, opts);
    },
  };
  const admission = createRegistryOperationAdmission({ store: wrapped, now: () => now, retryDelay: async () => {} });
  const id = identity(1);
  assert.deepEqual(await admission.admit(id), { admitted: true, replay: false, liveOperations: 1 });
  const first = structuredClone(store._records.get(id.ledgerKey));
  now += 5_000;
  assert.deepEqual(await admission.admit(id), { admitted: true, replay: true, liveOperations: 1 });
  const replayed = store._records.get(id.ledgerKey);
  assert.equal(replayed.operations[0].expiresAtEpochSec, first.operations[0].expiresAtEpochSec + 5);
  assert.deepEqual(replayed.recentNewEpochMs, first.recentNewEpochMs, 'replay consumes no rolling-window slot');
  assert.deepEqual(replayed.recentRequestEpochMs, [START, now], 'replay still consumes the bounded total-request lane');
  assert.equal(ttlWrites.at(-1), replayed.operations[0].expiresAtEpochSec);
  assert.equal(replayed.recordVersion, '2');
});

test('strict rolling window admits 30, rejects 31st with Retry-After, and opens exactly at 60 seconds', async () => {
  const store = createInMemoryStore();
  let now = START;
  const admission = createRegistryOperationAdmission({ store, now: () => now, retryDelay: async () => {} });
  for (let index = 1; index <= 30; index += 1) await admission.admit(identity(index));
  await assert.rejects(
    admission.admit(identity(31)),
    (error) => hasCode('operation-rate-limited')(error) && Number.isSafeInteger(error.retryAfterSeconds) && error.retryAfterSeconds > 0,
  );
  assert.deepEqual(await admission.admit(identity(1)), { admitted: true, replay: true, liveOperations: 30 });
  now += REGISTRY_OPERATION_ADMISSION_LIMITS.WINDOW_MS - 1;
  await assert.rejects(admission.admit(identity(31)), hasCode('operation-rate-limited'));
  now += 1;
  assert.deepEqual(await admission.admit(identity(31)), { admitted: true, replay: false, liveOperations: 31 });
});

test('31 simultaneous distinct operations across ingress instances admit exactly 30', async () => {
  const store = createInMemoryStore();
  const left = createRegistryOperationAdmission({ store, now: () => START, retryDelay: async () => {} });
  const right = createRegistryOperationAdmission({ store, now: () => START, retryDelay: async () => {} });
  const settled = await Promise.allSettled(
    Array.from({ length: 31 }, (_, offset) => (offset % 2 ? left : right).admit(identity(offset + 1))),
  );
  const admitted = settled.filter((result) => result.status === 'fulfilled');
  const denied = settled.filter((result) => result.status === 'rejected');
  assert.equal(admitted.length, 30);
  assert.equal(denied.length, 1);
  assert.equal(denied[0].reason.code, 'operation-rate-limited');
});

test('61 simultaneous exact requests serialize to the separate 60-request replay-flood bound', async () => {
  const store = createInMemoryStore();
  const left = createRegistryOperationAdmission({ store, now: () => START, retryDelay: async () => {} });
  const right = createRegistryOperationAdmission({ store, now: () => START, retryDelay: async () => {} });
  const id = identity(1);
  const settled = await Promise.allSettled(
    Array.from({ length: 61 }, (_, index) => (index % 2 ? left : right).admit(id)),
  );
  const results = settled.filter((result) => result.status === 'fulfilled').map((result) => result.value);
  const denied = settled.filter((result) => result.status === 'rejected');
  assert.equal(results.length, 60);
  assert.equal(results.filter((result) => result.replay === false).length, 1);
  assert.equal(results.filter((result) => result.replay === true).length, 59);
  assert.equal(denied.length, 1);
  assert.equal(denied[0].reason.code, 'operation-rate-limited');
  assert.equal(denied[0].reason.retryAfterSeconds, 60);
  assert.equal(store._records.get(id.ledgerKey).recentNewEpochMs.length, 1);
  assert.equal(store._records.get(id.ledgerKey).recentRequestEpochMs.length, 60);
});

test('two concurrent instances charge one shared operation once', async () => {
  const store = createInMemoryStore();
  const a = createRegistryOperationAdmission({ store, now: () => START, retryDelay: async () => {} });
  const b = createRegistryOperationAdmission({ store, now: () => START, retryDelay: async () => {} });
  const results = await Promise.all([a.admit(identity(1)), b.admit(identity(1))]);
  assert.deepEqual(results.map((result) => result.replay).sort(), [false, true]);
  assert.equal(store._records.get(identity(1).ledgerKey).operations.length, 1);
  assert.equal(store._records.get(identity(1).ledgerKey).recentNewEpochMs.length, 1);
});

test('an older CAS loser adopts a newer winner clock without a false rollback', async () => {
  const base = createInMemoryStore();
  const id = identity(1);
  const newer = createRegistryOperationAdmission({
    store: base,
    now: () => START + 1,
    retryDelay: async () => {},
  });
  let injectWinner = true;
  const olderStore = {
    ...base,
    async compareAndSwap(key, version, value, opts) {
      if (injectWinner) {
        injectWinner = false;
        await newer.admit(id);
        return { swapped: false, current: await base.get(key, { consistent: true }) };
      }
      return base.compareAndSwap(key, version, value, opts);
    },
  };
  const older = createRegistryOperationAdmission({
    store: olderStore,
    now: () => START,
    retryDelay: async () => {},
  });
  assert.deepEqual(await older.admit(id), { admitted: true, replay: true, liveOperations: 1 });
  const ledger = base._records.get(id.ledgerKey);
  assert.equal(ledger.lastClockEpochMs, START + 1);
  assert.deepEqual(ledger.recentRequestEpochMs, [START + 1, START + 1]);
});

test('a decreasing local clock sample during CAS retry still fails closed', async () => {
  const base = createInMemoryStore();
  const id = identity(1);
  const newer = createRegistryOperationAdmission({
    store: base,
    now: () => START + 1,
    retryDelay: async () => {},
  });
  let injectWinner = true;
  const contended = {
    ...base,
    async compareAndSwap(key, version, value, opts) {
      if (injectWinner) {
        injectWinner = false;
        await newer.admit(id);
        return { swapped: false, current: await base.get(key, { consistent: true }) };
      }
      return base.compareAndSwap(key, version, value, opts);
    },
  };
  const samples = [START, START - 1];
  const older = createRegistryOperationAdmission({
    store: contended,
    now: () => samples.shift(),
    retryDelay: async () => {},
  });
  await assert.rejects(older.admit(id), hasCode('operation-admission-unavailable'));
});

test('the exact 256-live ceiling serializes concurrent candidates to one 256th winner', async () => {
  const store = createInMemoryStore();
  let now = START;
  const a = createRegistryOperationAdmission({ store, now: () => now, retryDelay: async () => {} });
  const b = createRegistryOperationAdmission({ store, now: () => now, retryDelay: async () => {} });
  for (let index = 1; index <= 255; index += 1) {
    await a.admit(identity(index));
    if (index % 29 === 0) now += REGISTRY_OPERATION_ADMISSION_LIMITS.WINDOW_MS;
  }
  const settled = await Promise.allSettled([a.admit(identity(256)), b.admit(identity(257))]);
  assert.equal(settled.filter((result) => result.status === 'fulfilled').length, 1);
  const denied = settled.find((result) => result.status === 'rejected');
  assert.equal(denied.reason.code, 'operation-rate-limited');
  assert.match(denied.reason.message, /capacity/);
  const ledger = store._records.get(identity(1).ledgerKey);
  assert.equal(ledger.operations.length, 256);
  assert.deepEqual(await a.admit(identity(1)), { admitted: true, replay: true, liveOperations: 256 });
});

test('logical expiry prunes physically retained operations and permits a fresh operation', async () => {
  const store = createInMemoryStore();
  let now = START;
  const admission = createRegistryOperationAdmission({
    store,
    now: () => now,
    retryDelay: async () => {},
    maxLiveOperations: 1,
    maxNewOperationsPerWindow: 1,
    windowMs: 1_000,
    retentionSeconds: 2,
  });
  await admission.admit(identity(1));
  now += 2_000;
  assert.deepEqual(await admission.admit(identity(2)), { admitted: true, replay: false, liveOperations: 1 });
  const ledger = store._records.get(identity(1).ledgerKey);
  assert.deepEqual(ledger.operations.map((entry) => entry.digest), [identity(2).operationDigest]);
});

test('physical TTL covers a fractional rolling-window tail even when operation retention is shorter', async () => {
  const base = createInMemoryStore();
  let capturedTtl;
  const store = {
    ...base,
    async compareAndSwap(key, version, value, opts) {
      capturedTtl = opts.ttlEpochSec;
      return base.compareAndSwap(key, version, value, opts);
    },
  };
  const now = START + 500;
  const admission = createRegistryOperationAdmission({
    store,
    now: () => now,
    retryDelay: async () => {},
    retentionSeconds: 1,
    windowMs: 1_000,
  });
  await admission.admit(identity(1));
  assert.equal(capturedTtl, Math.ceil((now + 1_000) / 1_000));
});

test('principal namespaces are isolated and persisted state contains no raw identity or request material', async () => {
  const store = createInMemoryStore();
  const admission = createRegistryOperationAdmission({ store, now: () => START, retryDelay: async () => {} });
  const first = identity(1);
  const otherPrincipal = 'pocket.principal.senti.v1\n7:user_99';
  const second = identity(1, {
    principal: otherPrincipal,
    humanId: HUMAN_ID,
    body: registration(1, {}, otherPrincipal, HUMAN_ID),
  });
  await admission.admit(first);
  await admission.admit(second);
  assert.notEqual(first.ledgerKey, second.ledgerKey);
  assert.equal(store._records.size, 2);
  const persisted = JSON.stringify([...store._records.entries()]);
  for (const prohibited of [
    PRINCIPAL,
    HUMAN_ID,
    registration(1).installationId,
    registration(1).idempotencyKey,
    registration(1).voipToken,
    registration(1).sessionId,
  ]) {
    assert.equal(persisted.includes(prohibited), false, `must not persist raw ${prohibited}`);
  }
});

test('strong reads, corrupt state, size abuse, config drift, and clock rollback all fail closed', async () => {
  const base = createInMemoryStore();
  const reads = [];
  let now = START;
  const store = {
    ...base,
    async get(key, opts) { reads.push(structuredClone(opts)); return base.get(key, opts); },
  };
  const admission = createRegistryOperationAdmission({ store, now: () => now, retryDelay: async () => {} });
  const id = identity(1);
  await admission.admit(id);
  assert.deepEqual(reads[0], { consistent: true });

  now -= 1;
  await assert.rejects(admission.admit(id), hasCode('operation-admission-unavailable'));
  now = START + 1;
  const ledger = base._records.get(id.ledgerKey);
  ledger.operations[0].digest = 'not-canonical';
  await assert.rejects(admission.admit(id), hasCode('operation-admission-unavailable'));

  base._records.set(id.ledgerKey, { padding: 'x'.repeat(70 * 1024) });
  await assert.rejects(admission.admit(id), hasCode('operation-admission-unavailable'));

  const valid = structuredClone(ledger);
  valid.operations[0].digest = id.operationDigest;
  for (const corrupt of [
    { ...valid, operations: [] },
    { ...valid, recentRequestEpochMs: [] },
    { ...valid, recentNewEpochMs: [...valid.recentNewEpochMs, valid.recentNewEpochMs[0]] },
    { ...valid, lastClockEpochMs: valid.lastClockEpochMs + 1 },
  ]) {
    base._records.set(id.ledgerKey, corrupt);
    await assert.rejects(admission.admit(id), hasCode('operation-admission-unavailable'));
  }

  base._records.delete(id.ledgerKey);
  const narrow = createRegistryOperationAdmission({
    store: base,
    now: () => START,
    retryDelay: async () => {},
    maxLiveOperations: 2,
  });
  await narrow.admit(id);
  const drifted = createRegistryOperationAdmission({
    store: base,
    now: () => START,
    retryDelay: async () => {},
    maxLiveOperations: 3,
  });
  await assert.rejects(drifted.admit(id), hasCode('operation-admission-unavailable'));
});

test('invalid verifier-owned principal or human identity cannot allocate admission state', () => {
  for (const [principal, humanId] of [
    ['', HUMAN_ID],
    ['p', ''],
    ['p', ' padded '],
    ['p', 'control\nvalue'],
    ['p'.repeat(1_025), HUMAN_ID],
    ['p', 'ü'.repeat(513)],
  ]) {
    assert.throws(
      () => deriveRegistryOperationAdmissionIdentity({
        method: 'POST',
        path: '/dial/register',
        body: registration(1, {}, PRINCIPAL, HUMAN_ID),
        principal,
        humanId,
        hmacKey: KEY,
      }),
      hasCode('operation-admission-unavailable'),
    );
  }
});

test('storage failures, malformed CAS results, contention exhaustion, and retry failures are typed unavailable', async () => {
  const id = identity(1);
  await assert.rejects(
    createRegistryOperationAdmission({
      store: { async get() { throw new Error('secret backend detail'); }, async compareAndSwap() {} },
    }).admit(id),
    (error) => hasCode('operation-admission-unavailable')(error) && error.cause?.message === 'secret backend detail',
  );
  await assert.rejects(
    createRegistryOperationAdmission({
      store: { async get() {}, async compareAndSwap() { throw new Error('ddb down'); } },
      retryDelay: async () => {},
    }).admit(id),
    hasCode('operation-admission-unavailable'),
  );
  await assert.rejects(
    createRegistryOperationAdmission({
      store: { async get() {}, async compareAndSwap() { return { unexpected: true }; } },
      retryDelay: async () => {},
    }).admit(id),
    hasCode('operation-admission-unavailable'),
  );

  let attempts = 0;
  let delays = 0;
  const contended = createRegistryOperationAdmission({
    store: {
      async get() { return undefined; },
      async compareAndSwap() { attempts += 1; return { swapped: false, current: undefined }; },
    },
    retryDelay: async () => { delays += 1; },
    maxSerializationAttempts: 3,
  });
  await assert.rejects(contended.admit(id), hasCode('operation-admission-unavailable'));
  assert.equal(attempts, 3);
  assert.equal(delays, 2);

  const retryFailure = createRegistryOperationAdmission({
    store: {
      async get() { return undefined; },
      async compareAndSwap() { return { swapped: false, current: undefined }; },
    },
    retryDelay: async () => { throw new Error('timer unavailable'); },
    maxSerializationAttempts: 2,
  });
  await assert.rejects(
    retryFailure.admit(id),
    (error) => hasCode('operation-admission-unavailable')(error) && error.cause?.message === 'timer unavailable',
  );
});

test('invalid internal identifiers and unsafe limit configuration fail closed', async () => {
  const admission = createRegistryOperationAdmission({ store: createInMemoryStore() });
  await assert.rejects(
    admission.admit({ ledgerKey: 'dial:admission:v1:not-opaque', operationDigest: 'nope' }),
    hasCode('operation-admission-unavailable'),
  );
  assert.throws(
    () => createRegistryOperationAdmission({ store: createInMemoryStore(), maxLiveOperations: 257 }),
    /cannot exceed 256/,
  );
  assert.throws(
    () => createRegistryOperationAdmission({ store: createInMemoryStore(), maxNewOperationsPerWindow: 31 }),
    /cannot exceed 30/,
  );
  assert.throws(
    () => createRegistryOperationAdmission({ store: createInMemoryStore(), maxRequestsPerWindow: 61 }),
    /cannot exceed 60/,
  );
  assert.throws(
    () => createRegistryOperationAdmission({
      store: createInMemoryStore(),
      maxNewOperationsPerWindow: 30,
      maxRequestsPerWindow: 29,
    }),
    /cannot be lower/,
  );
  assert.throws(
    () => createRegistryOperationAdmission({
      store: createInMemoryStore(),
      retentionSeconds: 1,
      windowMs: 1_001,
    }),
    /must cover the rolling window/,
  );
});
