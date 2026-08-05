import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import {
  DEVICE_REGISTRATION_VERSION,
  DEVICE_REGISTRATION_RECLAIM_GRACE_SECONDS,
  DEVICE_REGISTRY_MAX_SERIALIZATION_ATTEMPTS,
  DeviceRegistryV2Error,
  createDynamoDeviceRegistryV2,
  createInMemoryDeviceRegistryV2,
  deriveDeviceInstallationKey,
  deriveDeviceTargetKey,
  deriveDeviceTokenKey,
  validateDeviceRegistrationV2,
  validateDeviceUnregistrationV2,
} from '../src/device-registry-v2.mjs';

const NOW = Date.parse('2026-07-31T06:00:00.000Z');
const KEY = Buffer.alloc(32, 0x5a);
const INSTALLATION_ID = Buffer.alloc(32, 0x31).toString('base64url');
const IDEM_A = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const IDEM_B = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const IDEM_C = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const IDEM_D = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
const physicalTtl = (expiresAtEpochSec) => expiresAtEpochSec + DEVICE_REGISTRATION_RECLAIM_GRACE_SECONDS;
const javascriptTransactionCancellation = (codes) =>
  Object.assign(
    new Error(`Transaction cancelled, please refer cancellation reasons for specific reasons [${codes.join(', ')}]`),
    {
      name: 'TransactionCanceledException',
      $fault: 'client',
      $metadata: {
        httpStatusCode: 400,
        requestId: 'test-request-id',
        attempts: 1,
        totalRetryDelay: 0,
      },
      CancellationReasons: undefined,
    },
  );

const registration = (overrides = {}) => ({
  registrationVersion: DEVICE_REGISTRATION_VERSION,
  installationId: INSTALLATION_ID,
  idempotencyKey: IDEM_A,
  voipToken: 'aabbccddeeff',
  sessionId: 'session-a',
  platform: 'apns',
  ...overrides,
});

const indexedRegistration = (index, overrides = {}) =>
  registration({
    installationId: Buffer.alloc(32, index).toString('base64url'),
    idempotencyKey: `${index.toString(16).padStart(8, '0')}-0000-4000-8000-${index.toString(16).padStart(12, '0')}`,
    voipToken: `token-${index}`,
    ...overrides,
  });

const targetDirectoryFor = (binding, overrides = {}) => ({
  pk: binding.targetKey,
  sk: 'directory',
  schema: 'dial-device-target-directory-v2',
  directoryId: 'dir_0123456789abcdef0123456789abcdef',
  capacity: 20,
  revision: 1,
  members: [
    {
      installationKey: binding.pk,
      bindingId: binding.bindingId,
      bindingRevision: binding.bindingRevision,
      expiresAtEpochSec: binding.expiresAtEpochSec,
    },
  ],
  updatedAtEpochSec: Math.floor(NOW / 1000),
  expiresAtEpochSec: binding.expiresAtEpochSec,
  ttl: physicalTtl(binding.expiresAtEpochSec),
  ...overrides,
});

test('V2 validators require the exact versioned wire and reject confused-deputy/unknown fields', () => {
  assert.deepEqual(validateDeviceRegistrationV2(registration()), { ok: true, value: registration() });
  assert.equal(
    validateDeviceRegistrationV2({
      installationId: INSTALLATION_ID,
      idempotencyKey: IDEM_A,
      voipToken: 'aa',
      sessionId: 's',
      platform: 'apns',
    }).status,
    426,
    'unversioned registration fails closed',
  );
  assert.equal(validateDeviceRegistrationV2({ ...registration(), humanId: 'attacker' }).status, 400);
  assert.equal(validateDeviceRegistrationV2({ ...registration(), installationId: 'raw-device-id' }).status, 400);
  assert.equal(
    validateDeviceRegistrationV2({
      ...registration(),
      installationId: INSTALLATION_ID.slice(0, -1) + 'F',
    }).status,
    400,
    'non-canonical base64url identity is rejected',
  );
  assert.equal(validateDeviceRegistrationV2({ ...registration(), idempotencyKey: 'not-a-uuid' }).status, 400);
  assert.equal(validateDeviceRegistrationV2({ ...registration(), sessionId: ' padded ' }).status, 400);
  assert.equal(validateDeviceRegistrationV2({ ...registration(), voipToken: 'bad\nvalue' }).status, 400);
  assert.equal(
    validateDeviceRegistrationV2({
      ...registration(),
      expectedBindingId: 'bind_0123456789abcdef0123456789abcdef',
    }).status,
    400,
    'expected binding fields are an atomic pair',
  );
  assert.equal(
    validateDeviceRegistrationV2({
      ...registration(),
      expectedTokenClaimId: 'claim_0123456789abcdef0123456789abcdef',
    }).status,
    400,
    'expected token-claim fields are an atomic pair',
  );
});

test('V2 unregister requires exact server binding identity/revision and rejects unknown fields', () => {
  const body = {
    registrationVersion: 2,
    installationId: INSTALLATION_ID,
    sessionId: 'session-a',
    bindingId: 'bind_0123456789abcdef0123456789abcdef',
    bindingRevision: 7,
  };
  assert.deepEqual(validateDeviceUnregistrationV2(body), { ok: true, value: body });
  assert.equal(validateDeviceUnregistrationV2({ ...body, bindingRevision: 0 }).status, 400);
  assert.equal(validateDeviceUnregistrationV2({ ...body, bindingId: 'client-made' }).status, 400);
  assert.equal(validateDeviceUnregistrationV2({ ...body, generation: 7 }).status, 400);
});

test('installation and target keys are domain-separated HMACs; raw installation/human/session never appear', () => {
  const installationKey = deriveDeviceInstallationKey(KEY, INSTALLATION_ID);
  const targetKey = deriveDeviceTargetKey(KEY, 'principal-a', 'human-a', 'session-a');
  const tokenKey = deriveDeviceTokenKey(KEY, 'apns', 'aabbccddeeff');
  assert.match(installationKey, /^dial:install:v2:[A-Za-z0-9_-]{43}$/);
  assert.match(targetKey, /^dial:target:v2:[A-Za-z0-9_-]{43}$/);
  assert.match(tokenKey, /^dial:token:v2:[A-Za-z0-9_-]{43}$/);
  assert.equal(
    installationKey,
    'dial:install:v2:S2g7pke-ewGbrHV--Y0FBYZyAAsCbBwgyvduejj3ZlA',
    'installation HMAC KAV is locked',
  );
  assert.equal(targetKey, 'dial:target:v2:JCPY1JJRsWpAgJFsvWcFrQlt3tgxa7irIzeol0D4sHM', 'target HMAC KAV is locked');
  assert.equal(
    tokenKey,
    'dial:token:v2:scTS-xXmETXetLfV9Fw050YwLTFKAMyFLlWJVRuxhto',
    'platform-scoped APNs token HMAC KAV is locked',
  );
  assert.notEqual(installationKey, targetKey);
  assert.notEqual(tokenKey, installationKey);
  assert.equal(installationKey.includes(INSTALLATION_ID), false);
  assert.equal(targetKey.includes('human-a'), false);
  assert.equal(targetKey.includes('session-a'), false);
});

test('verifier-owned production principal namespaces may contain their canonical newline separator', async () => {
  const principal = 'pocket.principal.senti.v1\n7:user_42';
  const registry = createInMemoryDeviceRegistryV2({ hmacKey: KEY, now: () => NOW });
  await registry.register({ principal, humanId: 'user_42', ...registration() });
  assert.equal(
    (
      await registry.lookup({
        principal,
        humanId: 'user_42',
        sessionId: 'session-a',
      })
    ).length,
    1,
  );
});

test('one installation rebinds A -> B by replacing one physical item; A is no longer addressable', async () => {
  const registry = createInMemoryDeviceRegistryV2({ hmacKey: KEY, now: () => NOW });
  const a = await registry.register({ principal: 'principal-a', humanId: 'same-human', ...registration() });
  assert.equal(a.bindingRevision, 1);
  assert.equal(
    (
      await registry.lookup({
        principal: 'principal-a',
        humanId: 'same-human',
        sessionId: 'session-a',
      })
    ).length,
    1,
  );

  const b = await registry.register({
    principal: 'principal-b',
    humanId: 'same-human',
    ...registration({
      idempotencyKey: IDEM_B,
      voipToken: 'new-token',
      expectedBindingId: a.bindingId,
      expectedBindingRevision: a.bindingRevision,
    }),
  });
  assert.equal(b.bindingRevision, 2);
  assert.notEqual(b.bindingId, a.bindingId);
  assert.deepEqual(
    await registry.lookup({
      principal: 'principal-a',
      humanId: 'same-human',
      sessionId: 'session-a',
    }),
    [],
  );
  assert.deepEqual(
    (await registry.lookup({ principal: 'principal-b', humanId: 'same-human', sessionId: 'session-a' })).map(
      ({ voipToken, bindingId, bindingRevision }) => ({ voipToken, bindingId, bindingRevision }),
    ),
    [{ voipToken: 'new-token', bindingId: b.bindingId, bindingRevision: 2 }],
  );
  assert.equal(registry._records.size, 1, 'one installation owns exactly one physical binding item');
  assert.equal(
    JSON.stringify([...registry._records.values()]).includes(INSTALLATION_ID),
    false,
    'raw installation id is never persisted',
  );
});

test('B-first/A-late: a delayed old expected binding cannot steal the installation back', async () => {
  const registry = createInMemoryDeviceRegistryV2({ hmacKey: KEY, now: () => NOW });
  const initial = await registry.register({ principal: 'origin', humanId: 'u', ...registration() });
  const b = await registry.register({
    principal: 'principal-b',
    humanId: 'u',
    ...registration({
      idempotencyKey: IDEM_B,
      sessionId: 'session-b',
      voipToken: 'token-b',
      expectedBindingId: initial.bindingId,
      expectedBindingRevision: initial.bindingRevision,
    }),
  });
  await assert.rejects(
    registry.register({
      principal: 'principal-a',
      humanId: 'u',
      ...registration({
        idempotencyKey: IDEM_C,
        sessionId: 'session-a-late',
        voipToken: 'token-a-late',
        expectedBindingId: initial.bindingId,
        expectedBindingRevision: initial.bindingRevision,
      }),
    }),
    (error) =>
      error instanceof DeviceRegistryV2Error &&
      error.code === 'binding-conflict' &&
      error.details?.currentBinding?.bindingId === b.bindingId,
  );
  assert.equal(
    (
      await registry.lookup({
        principal: 'principal-b',
        humanId: 'u',
        sessionId: 'session-b',
      })
    )[0].bindingId,
    b.bindingId,
  );
  assert.deepEqual(
    await registry.lookup({
      principal: 'principal-a',
      humanId: 'u',
      sessionId: 'session-a-late',
    }),
    [],
  );
});

test('A-first/B-reconcile: the same semantic operation can retry a 409 with the returned current tuple', async () => {
  const registry = createInMemoryDeviceRegistryV2({ hmacKey: KEY, now: () => NOW });
  const initial = await registry.register({ principal: 'origin', humanId: 'u', ...registration() });
  const aRequest = registration({
    idempotencyKey: IDEM_B,
    sessionId: 'session-a-wins-first',
    voipToken: 'token-a',
    expectedBindingId: initial.bindingId,
    expectedBindingRevision: initial.bindingRevision,
  });
  const a = await registry.register({ principal: 'principal-a', humanId: 'u', ...aRequest });
  const bRequest = registration({
    idempotencyKey: IDEM_C,
    sessionId: 'session-b-reconciles',
    voipToken: 'token-b',
    expectedBindingId: initial.bindingId,
    expectedBindingRevision: initial.bindingRevision,
  });
  let conflict;
  await assert.rejects(registry.register({ principal: 'principal-b', humanId: 'u', ...bRequest }), (error) => {
    conflict = error;
    return error instanceof DeviceRegistryV2Error && error.code === 'binding-conflict';
  });
  assert.equal(conflict.details.currentBinding.bindingId, a.bindingId);
  const b = await registry.register({
    principal: 'principal-b',
    humanId: 'u',
    ...bRequest,
    expectedBindingId: a.bindingId,
    expectedBindingRevision: a.bindingRevision,
  });
  assert.equal(b.bindingRevision, a.bindingRevision + 1);
  assert.equal(
    (
      await registry.lookup({
        principal: 'principal-b',
        humanId: 'u',
        sessionId: 'session-b-reconciles',
      })
    )[0].bindingId,
    b.bindingId,
  );
  await assert.rejects(
    registry.register({ principal: 'principal-a', humanId: 'u', ...aRequest }),
    (error) => error instanceof DeviceRegistryV2Error && error.code === 'binding-conflict',
    'the now-stale A task cannot reconcile itself after B wins',
  );
});

test('token rotation on the same owner/session mints a new server binding and revision', async () => {
  const registry = createInMemoryDeviceRegistryV2({ hmacKey: KEY, now: () => NOW });
  const one = await registry.register({ principal: 'p', humanId: 'u', ...registration() });
  const two = await registry.register({
    principal: 'p',
    humanId: 'u',
    ...registration({
      idempotencyKey: IDEM_D,
      voipToken: 'rotated-token',
      expectedBindingId: one.bindingId,
      expectedBindingRevision: one.bindingRevision,
    }),
  });
  assert.equal(two.bindingRevision, one.bindingRevision + 1);
  assert.notEqual(two.bindingId, one.bindingId);
  assert.equal(
    (
      await registry.lookup({
        principal: 'p',
        humanId: 'u',
        sessionId: 'session-a',
      })
    )[0].voipToken,
    'rotated-token',
  );
});

test('same-intent retry renews the lease without rotating; idempotency-key reuse with different intent conflicts', async () => {
  let now = NOW;
  const registry = createInMemoryDeviceRegistryV2({ hmacKey: KEY, now: () => now, leaseSeconds: 60 });
  const first = await registry.register({ principal: 'p', humanId: 'u', ...registration() });
  now += 30_000;
  const retry = await registry.register({ principal: 'p', humanId: 'u', ...registration() });
  assert.equal(retry.bindingId, first.bindingId);
  assert.equal(retry.bindingRevision, first.bindingRevision);
  assert.equal(retry.expiresAtEpochSec, first.expiresAtEpochSec + 30);
  assert.equal(retry.idempotent, true);
  assert.equal(retry.renewed, true);
  await assert.rejects(
    registry.register({ principal: 'p', humanId: 'u', ...registration({ voipToken: 'different' }) }),
    (error) => error instanceof DeviceRegistryV2Error && error.code === 'idempotency-conflict',
  );
  assert.equal(registry._records.size, 1);
});

test('stale unregister cannot delete a newer target/revision; exact current unregister is existence-oblivious', async () => {
  const registry = createInMemoryDeviceRegistryV2({ hmacKey: KEY, now: () => NOW });
  const a = await registry.register({ principal: 'pa', humanId: 'a', ...registration() });
  const b = await registry.register({
    principal: 'pb',
    humanId: 'b',
    ...registration({
      idempotencyKey: IDEM_B,
      sessionId: 'session-b',
      expectedBindingId: a.bindingId,
      expectedBindingRevision: a.bindingRevision,
    }),
  });

  assert.deepEqual(
    await registry.unregister({
      principal: 'pa',
      humanId: 'a',
      registrationVersion: 2,
      installationId: INSTALLATION_ID,
      sessionId: 'session-a',
      bindingId: a.bindingId,
      bindingRevision: a.bindingRevision,
    }),
    { removed: false },
  );
  assert.equal((await registry.lookup({ principal: 'pb', humanId: 'b', sessionId: 'session-b' })).length, 1);

  const exact = {
    principal: 'pb',
    humanId: 'b',
    registrationVersion: 2,
    installationId: INSTALLATION_ID,
    sessionId: 'session-b',
    bindingId: b.bindingId,
    bindingRevision: b.bindingRevision,
  };
  assert.deepEqual(await registry.unregister(exact), { removed: true });
  assert.deepEqual(await registry.unregister(exact), { removed: false });
});

test('logical expiry hides a binding immediately without waiting for physical TTL deletion', async () => {
  let now = NOW;
  const registry = createInMemoryDeviceRegistryV2({ hmacKey: KEY, now: () => now, leaseSeconds: 60 });
  await registry.register({ principal: 'p', humanId: 'u', ...registration() });
  assert.equal((await registry.lookup({ principal: 'p', humanId: 'u', sessionId: 'session-a' })).length, 1);
  now += 60_000;
  assert.deepEqual(await registry.lookup({ principal: 'p', humanId: 'u', sessionId: 'session-a' }), []);
  assert.equal(registry._records.size, 1, 'logical expiry is independent of eventual TTL cleanup');
});

test('reclaim grace hides at logical expiry but forces an exact transfer until skew-safe physical expiry', async () => {
  let now = NOW;
  const sharedToken = 'expiry-shared-token';
  const registry = createInMemoryDeviceRegistryV2({
    hmacKey: KEY,
    now: () => now,
    leaseSeconds: 60,
  });
  const owner = await registry.register({
    principal: 'p',
    humanId: 'u',
    ...indexedRegistration(1, { voipToken: sharedToken }),
  });
  now = owner.expiresAtEpochSec * 1000;

  assert.deepEqual(
    await registry.lookup({
      principal: 'p',
      humanId: 'u',
      sessionId: 'session-a',
    }),
    [],
    'routing visibility ends exactly at the logical lease',
  );

  let conflict;
  await assert.rejects(
    registry.register({
      principal: 'p2',
      humanId: 'u2',
      ...indexedRegistration(2, { voipToken: sharedToken, sessionId: 'session-b' }),
    }),
    (error) => {
      conflict = error;
      return error instanceof DeviceRegistryV2Error && error.code === 'token-claim-conflict';
    },
  );
  const currentTokenClaim = conflict.details.currentTokenClaim;
  assert.equal(
    currentTokenClaim.expiresAtEpochSec,
    owner.expiresAtEpochSec,
    'the conflict reports logical route expiry, not the later automatic-reclaim boundary',
  );
  const replacement = await registry.register({
    principal: 'p2',
    humanId: 'u2',
    ...indexedRegistration(2, {
      voipToken: sharedToken,
      sessionId: 'session-b',
      expectedTokenClaimId: currentTokenClaim.tokenClaimId,
      expectedTokenClaimRevision: currentTokenClaim.tokenClaimRevision,
    }),
  });

  assert.equal(registry._records.size, 1, 'explicit transfer removes the expired displaced base');
  assert.equal(registry._tokenClaims.size, 1);
  assert.equal(registry._targetDirectories.size, 1, 'explicit transfer removes the displaced directory member');
  assert.deepEqual(
    await registry.lookup({
      principal: 'p2',
      humanId: 'u2',
      sessionId: 'session-b',
    }),
    [
      {
        voipToken: sharedToken,
        platform: 'apns',
        bindingId: replacement.bindingId,
        bindingRevision: replacement.bindingRevision,
        expiresAtEpochSec: replacement.expiresAtEpochSec,
      },
    ],
  );
});

test('same owner can renew during reclaim grace, and exact unregister can revoke an expired retained claim', async () => {
  let renewalNow = NOW;
  const renewalRegistry = createInMemoryDeviceRegistryV2({
    hmacKey: KEY,
    now: () => renewalNow,
    leaseSeconds: 60,
  });
  const first = await renewalRegistry.register({
    principal: 'p',
    humanId: 'u',
    ...registration(),
  });
  renewalNow = first.expiresAtEpochSec * 1000;
  const renewed = await renewalRegistry.register({
    principal: 'p',
    humanId: 'u',
    ...registration({ idempotencyKey: IDEM_C }),
  });
  assert.equal(renewed.bindingId, first.bindingId);
  assert.equal(renewed.bindingRevision, first.bindingRevision);
  assert.equal(renewed.tokenClaimId, first.tokenClaimId);
  assert.equal(renewed.tokenClaimRevision, first.tokenClaimRevision);
  assert.equal(renewed.expiresAtEpochSec, first.expiresAtEpochSec + 60);

  let revokeNow = NOW;
  const revokeRegistry = createInMemoryDeviceRegistryV2({
    hmacKey: KEY,
    now: () => revokeNow,
    leaseSeconds: 60,
  });
  const revocable = await revokeRegistry.register({
    principal: 'p',
    humanId: 'u',
    ...registration(),
  });
  revokeNow = revocable.expiresAtEpochSec * 1000;
  assert.deepEqual(
    await revokeRegistry.unregister({
      principal: 'p',
      humanId: 'u',
      registrationVersion: 2,
      installationId: INSTALLATION_ID,
      sessionId: 'session-a',
      bindingId: revocable.bindingId,
      bindingRevision: revocable.bindingRevision,
    }),
    { removed: true },
  );
  assert.equal(revokeRegistry._records.size, 0);
  assert.equal(revokeRegistry._tokenClaims.size, 0);
  assert.equal(revokeRegistry._targetDirectories.size, 0);
});

test('slow workers repair or revoke a binding after a fast worker prunes its directory member at logical expiry', async () => {
  let renewalNow = NOW;
  const renewalRegistry = createInMemoryDeviceRegistryV2({
    hmacKey: KEY,
    now: () => renewalNow,
    leaseSeconds: 60,
  });
  const renewable = await renewalRegistry.register({
    principal: 'p',
    humanId: 'u',
    ...indexedRegistration(1),
  });
  renewalNow = renewable.expiresAtEpochSec * 1000;
  await renewalRegistry.register({
    principal: 'p',
    humanId: 'u',
    ...indexedRegistration(2),
  });
  assert.equal(
    [...renewalRegistry._targetDirectories.values()][0].members.some(
      ({ bindingId }) => bindingId === renewable.bindingId,
    ),
    false,
    'the fast worker reclaimed logical directory capacity at E',
  );

  renewalNow = (renewable.expiresAtEpochSec - 1) * 1000;
  const repaired = await renewalRegistry.register({
    principal: 'p',
    humanId: 'u',
    ...indexedRegistration(1, { idempotencyKey: IDEM_C }),
  });
  assert.equal(repaired.bindingId, renewable.bindingId);
  assert.equal(
    [...renewalRegistry._targetDirectories.values()][0].members.some(
      ({ bindingId, expiresAtEpochSec }) =>
        bindingId === repaired.bindingId && expiresAtEpochSec === repaired.expiresAtEpochSec,
    ),
    true,
    'the slow exact owner repairs the missing directory member under the normal capacity fence',
  );

  let revokeNow = NOW;
  const revokeRegistry = createInMemoryDeviceRegistryV2({
    hmacKey: KEY,
    now: () => revokeNow,
    leaseSeconds: 60,
  });
  const revocable = await revokeRegistry.register({
    principal: 'p',
    humanId: 'u',
    ...indexedRegistration(3),
  });
  revokeNow = revocable.expiresAtEpochSec * 1000;
  const survivor = await revokeRegistry.register({
    principal: 'p',
    humanId: 'u',
    ...indexedRegistration(4),
  });
  revokeNow = (revocable.expiresAtEpochSec - 1) * 1000;
  assert.deepEqual(
    await revokeRegistry.unregister({
      principal: 'p',
      humanId: 'u',
      registrationVersion: 2,
      installationId: indexedRegistration(3).installationId,
      sessionId: 'session-a',
      bindingId: revocable.bindingId,
      bindingRevision: revocable.bindingRevision,
    }),
    { removed: true },
  );
  assert.deepEqual(
    [...revokeRegistry._targetDirectories.values()][0].members.map(({ bindingId }) => bindingId),
    [survivor.bindingId],
  );
});

test('directory recovery rejects a present non-exact installation tuple instead of overwriting corruption', async () => {
  let now = NOW;
  const registry = createInMemoryDeviceRegistryV2({ hmacKey: KEY, now: () => now, leaseSeconds: 60 });
  const registered = await registry.register({
    principal: 'p',
    humanId: 'u',
    ...indexedRegistration(1),
  });
  const directory = [...registry._targetDirectories.values()][0];
  directory.members[0].bindingRevision += 1;
  await assert.rejects(
    registry.register({
      principal: 'p',
      humanId: 'u',
      ...indexedRegistration(1, { idempotencyKey: IDEM_C }),
    }),
    (error) => error instanceof DeviceRegistryV2Error && error.code === 'corrupt-record',
  );
  assert.equal([...registry._records.values()][0].bindingId, registered.bindingId);
});

test('21 target admissions retain exactly 20 and reject one without eviction', async () => {
  const registry = createInMemoryDeviceRegistryV2({ hmacKey: KEY, now: () => NOW });
  const outcomes = await Promise.allSettled(
    Array.from({ length: 21 }, (_, offset) => {
      const index = offset + 1;
      return registry.register({
        principal: 'p',
        humanId: 'u',
        ...indexedRegistration(index),
      });
    }),
  );
  assert.equal(outcomes.filter(({ status }) => status === 'fulfilled').length, 20);
  const rejected = outcomes.filter(({ status }) => status === 'rejected');
  assert.equal(rejected.length, 1);
  assert.equal(rejected[0].reason.code, 'target-capacity');
  const devices = await registry.lookup({ principal: 'p', humanId: 'u', sessionId: 'session-a' });
  assert.equal(devices.length, 20);
  assert.equal(new Set(devices.map((device) => device.voipToken)).size, 20);
  assert.equal(registry._records.size, 20, 'rejected admission leaves no half-written base');
  assert.equal(registry._targetDirectories.size, 1);
  assert.equal([...registry._targetDirectories.values()][0].members.length, 20);
});

test('21 simultaneous Dynamo admissions serialize through real directory CAS waves to 20 plus capacity', async () => {
  const itemKey = ({ pk, sk }) => JSON.stringify([pk, sk]);
  let items = new Map();
  const waveWaiters = new Map();
  let transactionCalls = 0;
  let conditionalCancellations = 0;
  let retryDelays = 0;
  const client = {
    async get({ Key }) {
      const item = items.get(itemKey(Key));
      return item ? { Item: structuredClone(item) } : {};
    },
    async transactWrite({ TransactItems }) {
      transactionCalls += 1;
      const directoryIndex = TransactItems.findIndex((entry) => entry.Put?.Item?.sk === 'directory');
      assert.notEqual(directoryIndex, -1);
      const directoryPut = TransactItems[directoryIndex].Put;
      const expectedRevision =
        directoryPut.ConditionExpression === 'attribute_not_exists(#pk)'
          ? 0
          : directoryPut.ExpressionAttributeValues[':revision'];
      const expectedWaveSize = 21 - expectedRevision;
      await new Promise((resolve) => {
        const waiters = waveWaiters.get(expectedRevision) ?? [];
        waiters.push(resolve);
        waveWaiters.set(expectedRevision, waiters);
        if (waiters.length === expectedWaveSize) {
          for (const release of waiters) release();
        }
      });

      const currentDirectory = items.get(itemKey(directoryPut.Item));
      const directoryMatches =
        expectedRevision === 0
          ? currentDirectory === undefined
          : currentDirectory?.schema === 'dial-device-target-directory-v2' &&
            currentDirectory.directoryId === directoryPut.ExpressionAttributeValues[':directoryId'] &&
            currentDirectory.revision === expectedRevision;
      if (!directoryMatches) {
        conditionalCancellations += 1;
        throw javascriptTransactionCancellation(
          TransactItems.map((_, index) => (index === directoryIndex ? 'ConditionalCheckFailed' : 'None')),
        );
      }

      const next = new Map(items);
      for (const entry of TransactItems) {
        if (entry.Put) {
          const key = itemKey(entry.Put.Item);
          if (entry.Put !== directoryPut) {
            assert.equal(next.has(key), false, 'candidate base/token key must still be absent');
          }
          next.set(key, structuredClone(entry.Put.Item));
        } else if (entry.Delete) {
          next.delete(itemKey(entry.Delete.Key));
        } else {
          assert.fail('unexpected transaction action');
        }
      }
      items = next;
    },
  };
  const registry = createDynamoDeviceRegistryV2({
    client,
    table: 'Pocket',
    hmacKey: KEY,
    now: () => NOW,
    retryDelay: async () => {
      retryDelays += 1;
    },
  });
  const outcomes = await Promise.allSettled(
    Array.from({ length: 21 }, (_, offset) =>
      registry.register({
        principal: 'p',
        humanId: 'u',
        ...indexedRegistration(offset + 1),
      }),
    ),
  );
  const fulfilled = outcomes.filter(({ status }) => status === 'fulfilled');
  const rejected = outcomes.filter(({ status }) => status === 'rejected');
  assert.equal(fulfilled.length, 20);
  assert.equal(rejected.length, 1);
  assert.equal(rejected[0].reason.code, 'target-capacity');
  assert.equal(conditionalCancellations, 210, '20+19+…+1 real directory CAS losses');
  assert.equal(retryDelays, conditionalCancellations);
  assert.equal(transactionCalls, 230, '20 commits plus 210 canceled transactions');
  assert.equal([...items.values()].filter(({ sk }) => sk === 'binding').length, 20);
  assert.equal([...items.values()].filter(({ sk }) => sk === 'claim').length, 20);
  const directories = [...items.values()].filter(({ sk }) => sk === 'directory');
  assert.equal(directories.length, 1);
  assert.equal(directories[0].members.length, 20);
  assert.equal(directories[0].revision, 20);
  assert.equal(
    DEVICE_REGISTRY_MAX_SERIALIZATION_ATTEMPTS,
    21,
    'the last writer gets 20 CAS retries, then observes capacity on attempt 21',
  );
});

test('renewal and token rotation remain admissible while the target directory is full', async () => {
  const registry = createInMemoryDeviceRegistryV2({ hmacKey: KEY, now: () => NOW });
  let first;
  for (let index = 1; index <= 20; index += 1) {
    const result = await registry.register({
      principal: 'p',
      humanId: 'u',
      ...indexedRegistration(index),
    });
    if (index === 1) first = result;
  }
  const renewed = await registry.register({
    principal: 'p',
    humanId: 'u',
    ...indexedRegistration(1, { idempotencyKey: IDEM_C }),
  });
  assert.equal(renewed.bindingId, first.bindingId);
  assert.equal(renewed.bindingRevision, first.bindingRevision);
  const rotated = await registry.register({
    principal: 'p',
    humanId: 'u',
    ...indexedRegistration(1, {
      idempotencyKey: IDEM_D,
      voipToken: 'token-1-rotated',
      expectedBindingId: renewed.bindingId,
      expectedBindingRevision: renewed.bindingRevision,
    }),
  });
  assert.equal(rotated.bindingRevision, renewed.bindingRevision + 1);
  assert.equal(
    (
      await registry.lookup({
        principal: 'p',
        humanId: 'u',
        sessionId: 'session-a',
      })
    ).length,
    20,
  );
  assert.equal([...registry._targetDirectories.values()][0].members.length, 20);
});

test('logical expiry reclaims target capacity before Dynamo-style physical TTL deletion', async () => {
  let now = NOW;
  const registry = createInMemoryDeviceRegistryV2({
    hmacKey: KEY,
    now: () => now,
    leaseSeconds: 60,
  });
  for (let index = 1; index <= 20; index += 1) {
    await registry.register({ principal: 'p', humanId: 'u', ...indexedRegistration(index) });
  }
  now += 60_000;
  await registry.register({
    principal: 'p',
    humanId: 'u',
    ...indexedRegistration(21),
  });
  assert.equal(registry._records.size, 21, 'expired base rows may still await physical TTL deletion');
  assert.deepEqual(
    (
      await registry.lookup({
        principal: 'p',
        humanId: 'u',
        sessionId: 'session-a',
      })
    ).map(({ voipToken }) => voipToken),
    ['token-21'],
  );
  assert.equal([...registry._targetDirectories.values()][0].members.length, 1);
});

test('move into a full target fails atomically; move into a free target preserves the old CAS semantics', async () => {
  const registry = createInMemoryDeviceRegistryV2({ hmacKey: KEY, now: () => NOW });
  const source = await registry.register({
    principal: 'p',
    humanId: 'u',
    ...indexedRegistration(30, { sessionId: 'session-a', voipToken: 'source-token' }),
  });
  for (let index = 1; index <= 20; index += 1) {
    await registry.register({
      principal: 'p',
      humanId: 'u',
      ...indexedRegistration(index, { sessionId: 'session-b' }),
    });
  }
  await assert.rejects(
    registry.register({
      principal: 'p',
      humanId: 'u',
      ...indexedRegistration(30, {
        idempotencyKey: IDEM_B,
        sessionId: 'session-b',
        voipToken: 'source-token',
        expectedBindingId: source.bindingId,
        expectedBindingRevision: source.bindingRevision,
      }),
    }),
    (error) => error instanceof DeviceRegistryV2Error && error.code === 'target-capacity',
  );
  assert.equal(
    (
      await registry.lookup({
        principal: 'p',
        humanId: 'u',
        sessionId: 'session-a',
      })
    )[0].voipToken,
    'source-token',
    'failed move leaves the old target fully intact',
  );
  assert.equal(
    (
      await registry.lookup({
        principal: 'p',
        humanId: 'u',
        sessionId: 'session-b',
      })
    ).length,
    20,
  );

  const moved = await registry.register({
    principal: 'p',
    humanId: 'u',
    ...indexedRegistration(30, {
      idempotencyKey: IDEM_C,
      sessionId: 'session-c',
      voipToken: 'source-token',
      expectedBindingId: source.bindingId,
      expectedBindingRevision: source.bindingRevision,
    }),
  });
  assert.equal(moved.bindingRevision, source.bindingRevision + 1);
  assert.deepEqual(
    await registry.lookup({
      principal: 'p',
      humanId: 'u',
      sessionId: 'session-a',
    }),
    [],
  );
  assert.equal(
    (
      await registry.lookup({
        principal: 'p',
        humanId: 'u',
        sessionId: 'session-c',
      })
    ).length,
    1,
  );
});

test('cross-target token-claim transfer evicts the displaced base and directory atomically', async () => {
  const registry = createInMemoryDeviceRegistryV2({ hmacKey: KEY, now: () => NOW });
  const sharedToken = 'cross-target-token';
  const a = await registry.register({
    principal: 'p',
    humanId: 'u',
    ...indexedRegistration(1, { sessionId: 'session-a', voipToken: sharedToken }),
  });
  const requestB = {
    principal: 'p',
    humanId: 'u',
    ...indexedRegistration(2, {
      sessionId: 'session-b',
      voipToken: sharedToken,
    }),
  };
  await assert.rejects(
    registry.register(requestB),
    (error) => error instanceof DeviceRegistryV2Error && error.code === 'token-claim-conflict',
  );
  await registry.register({
    ...requestB,
    expectedTokenClaimId: a.tokenClaimId,
    expectedTokenClaimRevision: a.tokenClaimRevision,
  });
  assert.deepEqual(
    await registry.lookup({
      principal: 'p',
      humanId: 'u',
      sessionId: 'session-a',
    }),
    [],
  );
  assert.equal(
    (
      await registry.lookup({
        principal: 'p',
        humanId: 'u',
        sessionId: 'session-b',
      })
    )[0].voipToken,
    sharedToken,
  );
  assert.equal(registry._records.size, 1);
  assert.equal(registry._targetDirectories.size, 1);
});

test('duplicate APNs token has one atomic owner; explicit claim-CAS transfer wins and stale A cannot steal it back', async () => {
  const registry = createInMemoryDeviceRegistryV2({ hmacKey: KEY, now: () => NOW });
  const sharedToken = 'shared-apns-token';
  const installationB = Buffer.alloc(32, 0x42).toString('base64url');
  const a = await registry.register({
    principal: 'p',
    humanId: 'u',
    ...registration({ voipToken: sharedToken }),
  });
  const requestB = {
    principal: 'p',
    humanId: 'u',
    ...registration({
      installationId: installationB,
      idempotencyKey: IDEM_B,
      voipToken: sharedToken,
    }),
  };
  await assert.rejects(
    registry.register(requestB),
    (error) =>
      error instanceof DeviceRegistryV2Error &&
      error.code === 'token-claim-conflict' &&
      error.details.currentTokenClaim.tokenClaimId === a.tokenClaimId,
    'a second installation cannot take a live token with an unconditional last write',
  );
  assert.equal(registry._records.size, 1, 'failed token claim leaves no half-written installation binding');

  const b = await registry.register({
    ...requestB,
    expectedTokenClaimId: a.tokenClaimId,
    expectedTokenClaimRevision: a.tokenClaimRevision,
  });
  assert.notEqual(b.tokenClaimId, a.tokenClaimId);
  assert.equal(b.tokenClaimRevision, a.tokenClaimRevision + 1);
  assert.equal(registry._records.size, 1, 'explicit token transfer atomically evicts the displaced owner base');
  assert.deepEqual(
    await registry.lookup({
      principal: 'p',
      humanId: 'u',
      sessionId: 'session-a',
    }),
    [
      {
        voipToken: sharedToken,
        platform: 'apns',
        bindingId: b.bindingId,
        bindingRevision: b.bindingRevision,
        expiresAtEpochSec: b.expiresAtEpochSec,
      },
    ],
    'lookup emits only the exact authoritative token owner, never an older duplicate binding',
  );

  await assert.rejects(
    registry.register({
      principal: 'p',
      humanId: 'u',
      ...registration({
        idempotencyKey: IDEM_C,
        voipToken: sharedToken,
        expectedBindingId: a.bindingId,
        expectedBindingRevision: a.bindingRevision,
        expectedTokenClaimId: a.tokenClaimId,
        expectedTokenClaimRevision: a.tokenClaimRevision,
      }),
    }),
    (error) => error instanceof DeviceRegistryV2Error && error.code === 'binding-conflict',
    'a delayed A request carrying the evicted binding cannot reclaim the APNs token',
  );
});

const tokenClaimFor = (binding, overrides = {}) => ({
  pk: deriveDeviceTokenKey(KEY, binding.platform, binding.voipToken),
  sk: 'claim',
  schema: 'dial-device-token-claim-v2',
  ownerInstallationKey: binding.pk,
  targetKey: binding.targetKey,
  tokenHash: binding.voipTokenHash,
  platform: binding.platform,
  bindingId: binding.bindingId,
  bindingRevision: binding.bindingRevision,
  tokenClaimId: 'claim_0123456789abcdef0123456789abcdef',
  tokenClaimRevision: 1,
  updatedAtEpochSec: Math.floor(NOW / 1000),
  expiresAtEpochSec: binding.expiresAtEpochSec,
  ttl: physicalTtl(binding.expiresAtEpochSec),
  ...overrides,
});

async function sameIntentRenewalSnapshots() {
  let now = NOW;
  const registry = createInMemoryDeviceRegistryV2({ hmacKey: KEY, now: () => now });
  await registry.register({ principal: 'p', humanId: 'u', ...registration() });
  const old = {
    binding: structuredClone([...registry._records.values()][0]),
    claim: structuredClone([...registry._tokenClaims.values()][0]),
    directory: structuredClone([...registry._targetDirectories.values()][0]),
  };
  now += 10_000;
  await registry.register({
    principal: 'p',
    humanId: 'u',
    ...registration({ idempotencyKey: IDEM_C }),
  });
  const renewed = {
    binding: structuredClone([...registry._records.values()][0]),
    claim: structuredClone([...registry._tokenClaims.values()][0]),
    directory: structuredClone([...registry._targetDirectories.values()][0]),
  };
  return { old, renewed, now };
}

async function expiringRegistrationSnapshot() {
  const registry = createInMemoryDeviceRegistryV2({
    hmacKey: KEY,
    now: () => NOW,
    leaseSeconds: 60,
  });
  await registry.register({ principal: 'p', humanId: 'u', ...registration() });
  return {
    binding: structuredClone([...registry._records.values()][0]),
    claim: structuredClone([...registry._tokenClaims.values()][0]),
    directory: structuredClone([...registry._targetDirectories.values()][0]),
  };
}

test('Dynamo register atomically writes HMAC installation, token claim, and bounded target directory', async () => {
  let transaction;
  const client = {
    async get() {
      return {};
    },
    async transactWrite(params) {
      transaction = params;
    },
  };
  const registry = createDynamoDeviceRegistryV2({
    client,
    table: 'Pocket',
    hmacKey: KEY,
    now: () => NOW,
  });
  const out = await registry.register({ principal: 'p', humanId: 'u', ...registration() });
  assert.equal(out.bindingRevision, 1);
  assert.equal(out.tokenClaimRevision, 1);
  assert.equal(
    Object.hasOwn(transaction, 'ClientRequestToken'),
    false,
    'logical idempotency UUID is not reused as a Dynamo transaction token across changing lease payloads',
  );
  assert.equal(transaction.TransactItems.length, 3);
  const basePut = transaction.TransactItems[0].Put;
  const claimPut = transaction.TransactItems[1].Put;
  const directoryPut = transaction.TransactItems[2].Put;
  assert.match(basePut.Item.pk, /^dial:install:v2:/);
  assert.equal(basePut.Item.targetKey, deriveDeviceTargetKey(KEY, 'p', 'u', 'session-a'));
  assert.equal(Object.hasOwn(basePut.Item, 'deviceTargetPk'), false, 'routing correctness has no GSI dependency');
  assert.equal(basePut.Item.voipTokenHash.length, 43);
  assert.equal(basePut.Item.expiresAtEpochSec, Math.floor(NOW / 1000) + 7 * 24 * 60 * 60);
  assert.equal(basePut.Item.ttl, physicalTtl(basePut.Item.expiresAtEpochSec));
  assert.equal(basePut.ConditionExpression, 'attribute_not_exists(#pk)');
  assert.match(claimPut.Item.pk, /^dial:token:v2:/);
  assert.equal(claimPut.Item.ownerInstallationKey, basePut.Item.pk);
  assert.equal(claimPut.Item.bindingId, basePut.Item.bindingId);
  assert.equal(claimPut.Item.bindingRevision, 1);
  assert.equal(claimPut.Item.expiresAtEpochSec, basePut.Item.expiresAtEpochSec);
  assert.equal(claimPut.Item.ttl, basePut.Item.ttl);
  assert.equal(directoryPut.Item.pk, basePut.Item.targetKey);
  assert.equal(directoryPut.Item.sk, 'directory');
  assert.equal(directoryPut.Item.ttl, physicalTtl(directoryPut.Item.expiresAtEpochSec));
  assert.match(directoryPut.Item.directoryId, /^dir_[0-9a-f]{32}$/);
  assert.equal(directoryPut.Item.capacity, 20);
  assert.deepEqual(directoryPut.Item.members, [
    {
      installationKey: basePut.Item.pk,
      bindingId: basePut.Item.bindingId,
      bindingRevision: basePut.Item.bindingRevision,
      expiresAtEpochSec: basePut.Item.expiresAtEpochSec,
    },
  ]);
  assert.equal(directoryPut.ConditionExpression, 'attribute_not_exists(#pk)');
  assert.equal(
    JSON.stringify(claimPut.Item).includes(registration().voipToken),
    false,
    'the ownership claim contains only a token HMAC/digest, never the raw APNs token',
  );
  assert.equal(
    JSON.stringify(transaction).includes(INSTALLATION_ID),
    false,
    'the raw installation identity never reaches Dynamo',
  );
});

test('Dynamo automatic token reclaim waits through grace, so a maximally slow worker already hides the old route', async () => {
  const expiring = await expiringRegistrationSnapshot();
  let earlyTransactions = 0;
  const earlyRegistry = createDynamoDeviceRegistryV2({
    table: 'Pocket',
    hmacKey: KEY,
    now: () => (expiring.claim.ttl - 1) * 1000,
    leaseSeconds: 60,
    client: {
      async get({ Key }) {
        if (Key.sk === 'claim') return { Item: structuredClone(expiring.claim) };
        return {};
      },
      async transactWrite() {
        earlyTransactions += 1;
      },
    },
  });
  await assert.rejects(
    earlyRegistry.register({
      principal: 'p2',
      humanId: 'u2',
      ...indexedRegistration(2, {
        voipToken: expiring.binding.voipToken,
        sessionId: 'session-b',
      }),
    }),
    (error) =>
      error instanceof DeviceRegistryV2Error &&
      error.code === 'token-claim-conflict' &&
      error.details.currentTokenClaim.expiresAtEpochSec === expiring.binding.expiresAtEpochSec,
  );
  assert.equal(earlyTransactions, 0, 'automatic reclaim is still fenced one second before the grace boundary');

  let reclaimTransaction;
  const reclaimNowMs = expiring.claim.ttl * 1000;
  const fastRegistry = createDynamoDeviceRegistryV2({
    table: 'Pocket',
    hmacKey: KEY,
    now: () => reclaimNowMs,
    leaseSeconds: 60,
    client: {
      async get({ Key }) {
        if (Key.sk === 'claim') return { Item: structuredClone(expiring.claim) };
        return {};
      },
      async transactWrite(params) {
        reclaimTransaction = params;
      },
    },
  });
  await fastRegistry.register({
    principal: 'p2',
    humanId: 'u2',
    ...indexedRegistration(2, {
      voipToken: expiring.binding.voipToken,
      sessionId: 'session-b',
    }),
  });
  const reclaimPut = reclaimTransaction.TransactItems.find((item) => item.Put?.Item.sk === 'claim').Put;
  assert.equal(reclaimPut.ConditionExpression, '(attribute_not_exists(#pk) OR #ttl <= :now)');
  assert.equal(reclaimPut.ExpressionAttributeValues[':now'], expiring.claim.ttl);

  const slowNowMs = expiring.binding.expiresAtEpochSec * 1000;
  assert.equal(Math.floor((reclaimNowMs - slowNowMs) / 1000), DEVICE_REGISTRATION_RECLAIM_GRACE_SECONDS);
  let directoryReads = 0;
  let nonDirectoryReads = 0;
  const slowRegistry = createDynamoDeviceRegistryV2({
    table: 'Pocket',
    hmacKey: KEY,
    now: () => slowNowMs,
    retryDelay: async () => {},
    client: {
      async get({ Key }) {
        if (Key.sk === 'directory') {
          directoryReads += 1;
          return { Item: structuredClone(expiring.directory) };
        }
        nonDirectoryReads += 1;
        return {};
      },
      async transactWrite() {
        throw new Error('unexpected transaction');
      },
    },
  });
  assert.deepEqual(
    await slowRegistry.lookup({
      principal: 'p',
      humanId: 'u',
      sessionId: 'session-a',
    }),
    [],
  );
  assert.equal(directoryReads, 2, 'the old directory is coherently fenced');
  assert.equal(nonDirectoryReads, 0, 'the slow worker never treats the old member as active');
});

test('Dynamo retries when an observed claim crosses its reclaim boundary mid-attempt', async () => {
  const expiring = await expiringRegistrationSnapshot();
  let wallMs = (expiring.claim.ttl - 1) * 1000;
  const delays = [];
  let transaction;
  const registry = createDynamoDeviceRegistryV2({
    table: 'Pocket',
    hmacKey: KEY,
    now: () => wallMs,
    leaseSeconds: 60,
    retryDelay: async (attempt) => {
      delays.push(attempt);
    },
    client: {
      async get({ Key }) {
        if (Key.sk === 'claim') {
          wallMs = expiring.claim.ttl * 1000;
          return { Item: structuredClone(expiring.claim) };
        }
        return {};
      },
      async transactWrite(params) {
        transaction = params;
      },
    },
  });
  await registry.register({
    principal: 'p2',
    humanId: 'u2',
    ...indexedRegistration(2, {
      voipToken: expiring.binding.voipToken,
      sessionId: 'session-b',
    }),
  });
  assert.deepEqual(delays, [1]);
  const claimPut = transaction.TransactItems.find((item) => item.Put?.Item.sk === 'claim').Put;
  assert.equal(claimPut.ExpressionAttributeValues[':now'], expiring.claim.ttl);
});

test('Dynamo admission prunes a physically retained full directory at logical expiry', async () => {
  const memory = createInMemoryDeviceRegistryV2({
    hmacKey: KEY,
    now: () => NOW,
    leaseSeconds: 60,
  });
  for (let index = 1; index <= 20; index += 1) {
    await memory.register({
      principal: 'p',
      humanId: 'u',
      ...indexedRegistration(index),
    });
  }
  const retainedDirectory = structuredClone([...memory._targetDirectories.values()][0]);
  let transaction;
  const registry = createDynamoDeviceRegistryV2({
    table: 'Pocket',
    hmacKey: KEY,
    now: () => retainedDirectory.expiresAtEpochSec * 1000,
    leaseSeconds: 60,
    client: {
      async get({ Key }) {
        if (Key.sk === 'directory') return { Item: structuredClone(retainedDirectory) };
        return {};
      },
      async transactWrite(params) {
        transaction = params;
      },
    },
  });
  const admitted = await registry.register({
    principal: 'p',
    humanId: 'u',
    ...indexedRegistration(21),
  });
  const directoryPut = transaction.TransactItems.find((item) => item.Put?.Item.sk === 'directory').Put;
  assert.deepEqual(directoryPut.Item.members, [
    {
      installationKey: deriveDeviceInstallationKey(KEY, indexedRegistration(21).installationId),
      bindingId: admitted.bindingId,
      bindingRevision: admitted.bindingRevision,
      expiresAtEpochSec: admitted.expiresAtEpochSec,
    },
  ]);
  assert.equal(directoryPut.ExpressionAttributeValues[':directoryId'], retainedDirectory.directoryId);
  assert.equal(directoryPut.ExpressionAttributeValues[':revision'], retainedDirectory.revision);
});

test('Dynamo slow-worker renewal repairs a directory member pruned by a fast worker at logical expiry', async () => {
  let memoryNow = NOW;
  const memory = createInMemoryDeviceRegistryV2({
    hmacKey: KEY,
    now: () => memoryNow,
    leaseSeconds: 60,
  });
  const old = await memory.register({
    principal: 'p',
    humanId: 'u',
    ...indexedRegistration(1),
  });
  const oldBinding = structuredClone(
    memory._records.get(deriveDeviceInstallationKey(KEY, indexedRegistration(1).installationId)),
  );
  const oldClaim = structuredClone(memory._tokenClaims.get(deriveDeviceTokenKey(KEY, 'apns', 'token-1')));
  memoryNow = old.expiresAtEpochSec * 1000;
  const fastAdmission = await memory.register({
    principal: 'p',
    humanId: 'u',
    ...indexedRegistration(2),
  });
  const fastDirectory = structuredClone([...memory._targetDirectories.values()][0]);
  assert.deepEqual(
    fastDirectory.members.map(({ bindingId }) => bindingId),
    [fastAdmission.bindingId],
    'the fast worker has already pruned the old logical member',
  );

  let transaction;
  const registry = createDynamoDeviceRegistryV2({
    table: 'Pocket',
    hmacKey: KEY,
    now: () => (old.expiresAtEpochSec - 1) * 1000,
    leaseSeconds: 60,
    client: {
      async get({ Key }) {
        if (Key.sk === 'binding' && Key.pk === oldBinding.pk) return { Item: structuredClone(oldBinding) };
        if (Key.sk === 'claim' && Key.pk === oldClaim.pk) return { Item: structuredClone(oldClaim) };
        if (Key.sk === 'directory') return { Item: structuredClone(fastDirectory) };
        return {};
      },
      async transactWrite(params) {
        transaction = params;
      },
    },
  });
  const repaired = await registry.register({
    principal: 'p',
    humanId: 'u',
    ...indexedRegistration(1, { idempotencyKey: IDEM_C }),
  });
  const directoryPut = transaction.TransactItems.find((item) => item.Put?.Item.sk === 'directory').Put;
  assert.deepEqual(
    new Set(directoryPut.Item.members.map(({ bindingId }) => bindingId)),
    new Set([fastAdmission.bindingId, repaired.bindingId]),
  );
  assert.equal(directoryPut.ExpressionAttributeValues[':directoryId'], fastDirectory.directoryId);
  assert.equal(directoryPut.ExpressionAttributeValues[':revision'], fastDirectory.revision);
});

test('Dynamo explicit token transfer atomically deletes the displaced base and replaces one directory member', async () => {
  const memory = createInMemoryDeviceRegistryV2({ hmacKey: KEY, now: () => NOW });
  const a = await memory.register({
    principal: 'p',
    humanId: 'u',
    ...indexedRegistration(1, { voipToken: 'shared-token' }),
  });
  const bindingA = [...memory._records.values()][0];
  const claimA = [...memory._tokenClaims.values()][0];
  const directoryA = [...memory._targetDirectories.values()][0];
  const installationB = indexedRegistration(2, { voipToken: 'shared-token' });
  const installationKeyB = deriveDeviceInstallationKey(KEY, installationB.installationId);
  let transaction;
  const registry = createDynamoDeviceRegistryV2({
    table: 'Pocket',
    hmacKey: KEY,
    now: () => NOW,
    client: {
      async get({ Key }) {
        if (Key.sk === 'binding' && Key.pk === bindingA.pk) return { Item: bindingA };
        if (Key.sk === 'binding' && Key.pk === installationKeyB) return {};
        if (Key.sk === 'claim') return { Item: claimA };
        if (Key.sk === 'directory') return { Item: directoryA };
        return {};
      },
      async transactWrite(params) {
        transaction = params;
      },
    },
  });
  const b = await registry.register({
    principal: 'p',
    humanId: 'u',
    ...installationB,
    expectedTokenClaimId: a.tokenClaimId,
    expectedTokenClaimRevision: a.tokenClaimRevision,
  });
  assert.equal(transaction.TransactItems.length, 4);
  const winnerBase = transaction.TransactItems[0].Put.Item;
  const winnerClaim = transaction.TransactItems[1].Put.Item;
  const victimDelete = transaction.TransactItems[2].Delete;
  const directoryPut = transaction.TransactItems[3].Put;
  assert.equal(winnerBase.pk, installationKeyB);
  assert.equal(winnerClaim.ownerInstallationKey, installationKeyB);
  assert.deepEqual(victimDelete.Key, { pk: bindingA.pk, sk: 'binding' });
  assert.equal(victimDelete.ExpressionAttributeValues[':bindingId'], bindingA.bindingId);
  assert.deepEqual(directoryPut.Item.members, [
    {
      installationKey: installationKeyB,
      bindingId: b.bindingId,
      bindingRevision: b.bindingRevision,
      expiresAtEpochSec: b.expiresAtEpochSec,
    },
  ]);
  assert.equal(
    directoryPut.Item.members.some(({ installationKey }) => installationKey === bindingA.pk),
    false,
  );
});

test('Dynamo same-intent retry atomically extends base+claim lease without rotating either identity', async () => {
  const memory = createInMemoryDeviceRegistryV2({ hmacKey: KEY, now: () => NOW });
  const first = await memory.register({ principal: 'p', humanId: 'u', ...registration() });
  const current = [...memory._records.values()][0];
  const currentClaim = [...memory._tokenClaims.values()][0];
  const currentDirectory = [...memory._targetDirectories.values()][0];
  let transaction;
  const registry = createDynamoDeviceRegistryV2({
    table: 'Pocket',
    hmacKey: KEY,
    now: () => NOW + 60_000,
    client: {
      async get({ Key }) {
        if (Key.sk === 'binding') return { Item: current };
        if (Key.sk === 'claim') return { Item: currentClaim };
        if (Key.sk === 'directory') return { Item: currentDirectory };
        return {};
      },
      async transactWrite(params) {
        transaction = params;
      },
    },
  });
  const renewed = await registry.register({ principal: 'p', humanId: 'u', ...registration() });
  assert.equal(renewed.bindingId, first.bindingId);
  assert.equal(renewed.bindingRevision, first.bindingRevision);
  assert.equal(renewed.tokenClaimId, first.tokenClaimId);
  assert.equal(renewed.tokenClaimRevision, first.tokenClaimRevision);
  assert.equal(renewed.expiresAtEpochSec, first.expiresAtEpochSec + 60);
  assert.equal(renewed.idempotent, true);
  assert.equal(renewed.renewed, true);
  const basePut = transaction.TransactItems[0].Put;
  const claimPut = transaction.TransactItems[1].Put;
  const directoryPut = transaction.TransactItems[2].Put;
  assert.equal(basePut.Item.bindingId, current.bindingId);
  assert.equal(basePut.Item.bindingRevision, current.bindingRevision);
  assert.equal(basePut.Item.expiresAtEpochSec, current.expiresAtEpochSec + 60);
  assert.equal(claimPut.Item.tokenClaimId, currentClaim.tokenClaimId);
  assert.equal(claimPut.Item.tokenClaimRevision, currentClaim.tokenClaimRevision);
  assert.equal(claimPut.Item.expiresAtEpochSec, basePut.Item.expiresAtEpochSec);
  assert.equal(directoryPut.Item.directoryId, currentDirectory.directoryId);
  assert.equal(directoryPut.Item.revision, currentDirectory.revision + 1);
  assert.equal(directoryPut.Item.members[0].expiresAtEpochSec, basePut.Item.expiresAtEpochSec);
  assert.match(directoryPut.ConditionExpression, /#directoryId = :directoryId/);
  assert.equal(directoryPut.ExpressionAttributeValues[':directoryId'], currentDirectory.directoryId);
  assert.match(basePut.ConditionExpression, /#expires = :expires/);
  assert.equal(
    basePut.ExpressionAttributeValues[':expires'],
    current.expiresAtEpochSec,
    'renewal CAS fences the observed lease so a slower renewal cannot shorten a newer lease',
  );
  assert.match(basePut.ConditionExpression, /#fingerprint = :fingerprint/);
});

test('Dynamo concurrent same-tuple renewals re-read after CAS loss, so a slower clock cannot shorten the lease', async () => {
  const memory = createInMemoryDeviceRegistryV2({ hmacKey: KEY, now: () => NOW });
  await memory.register({ principal: 'p', humanId: 'u', ...registration() });
  const state = {
    binding: { ...[...memory._records.values()][0] },
    claim: { ...[...memory._tokenClaims.values()][0] },
    directory: structuredClone([...memory._targetDirectories.values()][0]),
  };
  const conditionalCancellation = () =>
    Object.assign(new Error('transaction CAS lost'), {
      name: 'TransactionCanceledException',
      CancellationReasons: [{ Code: 'ConditionalCheckFailed' }, { Code: 'None' }, { Code: 'None' }],
    });
  const applyTransaction = (params) => {
    const [basePut, claimPut, directoryPut] = params.TransactItems.map((item) => item.Put);
    const expectedBase = basePut.ExpressionAttributeValues;
    const expectedClaim = claimPut.ExpressionAttributeValues;
    const expectedDirectory = directoryPut.ExpressionAttributeValues;
    if (
      state.binding.expiresAtEpochSec !== expectedBase[':expires'] ||
      state.binding.requestFingerprint !== expectedBase[':fingerprint'] ||
      state.claim.tokenClaimId !== expectedClaim[':claimId'] ||
      state.claim.tokenClaimRevision !== expectedClaim[':claimRevision'] ||
      state.directory.directoryId !== expectedDirectory[':directoryId'] ||
      state.directory.revision !== expectedDirectory[':revision']
    ) {
      throw conditionalCancellation();
    }
    state.binding = { ...basePut.Item };
    state.claim = { ...claimPut.Item };
    state.directory = structuredClone(directoryPut.Item);
  };
  let initialRace = true;
  const waiting = [];
  const client = {
    async get({ Key }) {
      if (Key.sk === 'binding') return { Item: { ...state.binding } };
      if (Key.sk === 'claim') return { Item: { ...state.claim } };
      if (Key.sk === 'directory') return { Item: structuredClone(state.directory) };
      return {};
    },
    async transactWrite(params) {
      if (!initialRace) return applyTransaction(params);
      return new Promise((resolve, reject) => {
        waiting.push({ params, resolve, reject });
        if (waiting.length !== 2) return;
        initialRace = false;
        waiting
          .sort(
            (a, b) =>
              b.params.TransactItems[0].Put.Item.expiresAtEpochSec -
              a.params.TransactItems[0].Put.Item.expiresAtEpochSec,
          )
          .forEach((entry) => {
            try {
              applyTransaction(entry.params);
              entry.resolve();
            } catch (error) {
              entry.reject(error);
            }
          });
      });
    },
  };
  const fast = createDynamoDeviceRegistryV2({
    client,
    table: 'Pocket',
    hmacKey: KEY,
    now: () => NOW + 60_000,
  });
  const slow = createDynamoDeviceRegistryV2({
    client,
    table: 'Pocket',
    hmacKey: KEY,
    now: () => NOW + 30_000,
  });
  const [fastResult, slowResult] = await Promise.all([
    fast.register({
      principal: 'p',
      humanId: 'u',
      ...registration({ idempotencyKey: IDEM_C }),
    }),
    slow.register({
      principal: 'p',
      humanId: 'u',
      ...registration({ idempotencyKey: IDEM_D }),
    }),
  ]);
  const expectedMax = Math.floor((NOW + 60_000) / 1000) + 7 * 24 * 60 * 60;
  assert.equal(state.binding.expiresAtEpochSec, expectedMax);
  assert.equal(state.claim.expiresAtEpochSec, expectedMax);
  assert.equal(state.directory.expiresAtEpochSec, expectedMax);
  assert.equal(fastResult.expiresAtEpochSec, expectedMax);
  assert.equal(
    slowResult.expiresAtEpochSec,
    expectedMax,
    'the losing slower renewal re-read the higher lease and preserved it',
  );
});

test('Dynamo target-directory CAS fences delete/recreate ABA with directoryId plus revision', async () => {
  const memory = createInMemoryDeviceRegistryV2({ hmacKey: KEY, now: () => NOW });
  await memory.register({ principal: 'p', humanId: 'u', ...registration() });
  const state = {
    binding: [...memory._records.values()][0],
    claim: [...memory._tokenClaims.values()][0],
    directory: structuredClone([...memory._targetDirectories.values()][0]),
  };
  const originalDirectoryId = state.directory.directoryId;
  const recreatedDirectoryId = 'dir_fedcba9876543210fedcba9876543210';
  let attempts = 0;
  const registry = createDynamoDeviceRegistryV2({
    table: 'Pocket',
    hmacKey: KEY,
    now: () => NOW + 1_000,
    client: {
      async get({ Key }) {
        if (Key.sk === 'binding') return { Item: state.binding };
        if (Key.sk === 'claim') return { Item: state.claim };
        if (Key.sk === 'directory') return { Item: structuredClone(state.directory) };
        return {};
      },
      async transactWrite(params) {
        attempts += 1;
        const directoryPut = params.TransactItems.at(-1).Put;
        if (attempts === 1) {
          assert.equal(directoryPut.ExpressionAttributeValues[':directoryId'], originalDirectoryId);
          state.directory = { ...state.directory, directoryId: recreatedDirectoryId };
          throw Object.assign(new Error('stale directory generation'), {
            name: 'TransactionCanceledException',
            CancellationReasons: [{ Code: 'None' }, { Code: 'None' }, { Code: 'ConditionalCheckFailed' }],
          });
        }
        assert.equal(
          directoryPut.ExpressionAttributeValues[':directoryId'],
          recreatedDirectoryId,
          'retry re-reads and fences the recreated generation, not only its reused revision',
        );
      },
    },
  });
  await registry.register({
    principal: 'p',
    humanId: 'u',
    ...registration({ idempotencyKey: IDEM_C }),
  });
  assert.equal(attempts, 2);
});

test('Dynamo register retries a torn base/claim renewal snapshot instead of returning a false conflict', async () => {
  const { old, renewed, now } = await sameIntentRenewalSnapshots();
  let baseReads = 0;
  let transactions = 0;
  const delays = [];
  const registry = createDynamoDeviceRegistryV2({
    table: 'Pocket',
    hmacKey: KEY,
    now: () => now + 10_000,
    retryDelay: async (attempt) => {
      delays.push(attempt);
    },
    client: {
      async get({ Key }) {
        if (Key.sk === 'binding') {
          const item = baseReads++ === 0 ? old.binding : renewed.binding;
          return { Item: structuredClone(item) };
        }
        if (Key.sk === 'claim') return { Item: structuredClone(renewed.claim) };
        if (Key.sk === 'directory') return { Item: structuredClone(renewed.directory) };
        return {};
      },
      async transactWrite() {
        transactions += 1;
      },
    },
  });
  const result = await registry.register({
    principal: 'p',
    humanId: 'u',
    ...registration({
      idempotencyKey: IDEM_D,
      expectedTokenClaimId: old.claim.tokenClaimId,
      expectedTokenClaimRevision: old.claim.tokenClaimRevision,
    }),
  });
  assert.equal(result.bindingId, renewed.binding.bindingId);
  assert.equal(result.bindingRevision, renewed.binding.bindingRevision);
  assert.equal(result.tokenClaimId, renewed.claim.tokenClaimId);
  assert.deepEqual(delays, [1], 'one changed read-set causes exactly one bounded retry');
  assert.equal(transactions, 1, 'the torn read never reached a transaction');
});

test('Dynamo unregister retries a torn base/claim renewal snapshot and removes the exact renewed tuple', async () => {
  const { old, renewed, now } = await sameIntentRenewalSnapshots();
  let baseReads = 0;
  let transactions = 0;
  const delays = [];
  const registry = createDynamoDeviceRegistryV2({
    table: 'Pocket',
    hmacKey: KEY,
    now: () => now + 10_000,
    retryDelay: async (attempt) => {
      delays.push(attempt);
    },
    client: {
      async get({ Key }) {
        if (Key.sk === 'binding') {
          const item = baseReads++ === 0 ? old.binding : renewed.binding;
          return { Item: structuredClone(item) };
        }
        if (Key.sk === 'claim') return { Item: structuredClone(renewed.claim) };
        if (Key.sk === 'directory') return { Item: structuredClone(renewed.directory) };
        return {};
      },
      async transactWrite() {
        transactions += 1;
      },
    },
  });
  const result = await registry.unregister({
    principal: 'p',
    humanId: 'u',
    registrationVersion: 2,
    installationId: INSTALLATION_ID,
    sessionId: 'session-a',
    bindingId: old.binding.bindingId,
    bindingRevision: old.binding.bindingRevision,
  });
  assert.deepEqual(result, { removed: true });
  assert.deepEqual(delays, [1]);
  assert.equal(transactions, 1);
});

test('Dynamo lookup retries old-directory/new-binding skew and an absent-directory appearance', async () => {
  const { old, renewed, now } = await sameIntentRenewalSnapshots();
  for (const firstDirectory of [old.directory, undefined]) {
    let directoryReads = 0;
    const delays = [];
    const registry = createDynamoDeviceRegistryV2({
      table: 'Pocket',
      hmacKey: KEY,
      now: () => now,
      retryDelay: async (attempt) => {
        delays.push(attempt);
      },
      client: {
        async get({ Key }) {
          if (Key.sk === 'directory') {
            const item = directoryReads++ === 0 ? firstDirectory : renewed.directory;
            return item ? { Item: structuredClone(item) } : {};
          }
          if (Key.sk === 'binding') return { Item: structuredClone(renewed.binding) };
          if (Key.sk === 'claim') return { Item: structuredClone(renewed.claim) };
          return {};
        },
        async transactWrite() {
          throw new Error('unexpected transaction');
        },
      },
    });
    assert.deepEqual(
      await registry.lookup({
        principal: 'p',
        humanId: 'u',
        sessionId: 'session-a',
      }),
      [
        {
          voipToken: renewed.binding.voipToken,
          platform: renewed.binding.platform,
          bindingId: renewed.binding.bindingId,
          bindingRevision: renewed.binding.bindingRevision,
          expiresAtEpochSec: renewed.binding.expiresAtEpochSec,
        },
      ],
    );
    assert.deepEqual(delays, [1]);
  }
});

test('Dynamo same-owner renewal repairs a retained base and directory after independent claim TTL deletion', async () => {
  const expiring = await expiringRegistrationSnapshot();
  const nowEpochSec = expiring.claim.ttl;
  let claimReads = 0;
  let transaction;
  const delays = [];
  const registry = createDynamoDeviceRegistryV2({
    table: 'Pocket',
    hmacKey: KEY,
    now: () => nowEpochSec * 1000,
    leaseSeconds: 60,
    retryDelay: async (attempt) => {
      delays.push(attempt);
    },
    client: {
      async get({ Key }) {
        if (Key.sk === 'binding') return { Item: structuredClone(expiring.binding) };
        if (Key.sk === 'claim') {
          claimReads += 1;
          return {};
        }
        if (Key.sk === 'directory') return { Item: structuredClone(expiring.directory) };
        return {};
      },
      async transactWrite(params) {
        transaction = params;
      },
    },
  });
  const result = await registry.register({
    principal: 'p',
    humanId: 'u',
    ...registration({ idempotencyKey: IDEM_C }),
  });
  assert.equal(result.bindingId, expiring.binding.bindingId);
  assert.equal(result.bindingRevision, expiring.binding.bindingRevision);
  assert.equal(result.tokenClaimRevision, 1);
  assert.equal(result.expiresAtEpochSec, nowEpochSec + 60);
  assert.deepEqual(delays, []);
  assert.equal(claimReads, 1);
  assert.equal(transaction.TransactItems.length, 3);
  const claimPut = transaction.TransactItems.find((item) => item.Put?.Item.sk === 'claim').Put;
  assert.equal(claimPut.Item.expiresAtEpochSec, nowEpochSec + 60);
  assert.equal(claimPut.ConditionExpression, '(attribute_not_exists(#pk) OR #ttl <= :now)');
  assert.equal(claimPut.ExpressionAttributeValues[':now'], nowEpochSec);
});

test('Dynamo unregister cleans retained old base and directory after automatic token reclaim', async () => {
  const expiring = await expiringRegistrationSnapshot();
  const nowEpochSec = expiring.claim.ttl;
  const replacementBinding = {
    ...expiring.binding,
    pk: deriveDeviceInstallationKey(KEY, Buffer.alloc(32, 0x72).toString('base64url')),
    targetKey: deriveDeviceTargetKey(KEY, 'p2', 'u2', 'session-b'),
    bindingId: 'bind_fedcba9876543210fedcba9876543210',
    idempotencyKey: IDEM_B,
    requestFingerprint: 'Z'.repeat(43),
    createdAtEpochSec: nowEpochSec,
    updatedAtEpochSec: nowEpochSec,
    expiresAtEpochSec: nowEpochSec + 60,
    ttl: physicalTtl(nowEpochSec + 60),
  };
  const replacementClaim = tokenClaimFor(replacementBinding, {
    tokenClaimId: 'claim_fedcba9876543210fedcba9876543210',
    tokenClaimRevision: 1,
    updatedAtEpochSec: nowEpochSec,
    expiresAtEpochSec: replacementBinding.expiresAtEpochSec,
    ttl: physicalTtl(replacementBinding.expiresAtEpochSec),
  });
  let transaction;
  const delays = [];
  const registry = createDynamoDeviceRegistryV2({
    table: 'Pocket',
    hmacKey: KEY,
    now: () => nowEpochSec * 1000,
    retryDelay: async (attempt) => {
      delays.push(attempt);
    },
    client: {
      async get({ Key }) {
        if (Key.sk === 'binding') return { Item: structuredClone(expiring.binding) };
        if (Key.sk === 'claim') return { Item: structuredClone(replacementClaim) };
        if (Key.sk === 'directory') return { Item: structuredClone(expiring.directory) };
        return {};
      },
      async transactWrite(params) {
        transaction = params;
      },
    },
  });
  assert.deepEqual(
    await registry.unregister({
      principal: 'p',
      humanId: 'u',
      registrationVersion: 2,
      installationId: INSTALLATION_ID,
      sessionId: 'session-a',
      bindingId: expiring.binding.bindingId,
      bindingRevision: expiring.binding.bindingRevision,
    }),
    { removed: true },
  );
  assert.deepEqual(delays, []);
  assert.equal(
    transaction.TransactItems.length,
    2,
    'expired old base/directory are cleaned without deleting the replacement token claim',
  );
  assert.equal(
    transaction.TransactItems.some((item) => item.Delete?.Key.sk === 'claim'),
    false,
  );
});

test('Dynamo lookup keeps a physically retained directory dark after logical expiry', async () => {
  const expiring = await expiringRegistrationSnapshot();
  let directoryReads = 0;
  let nonDirectoryReads = 0;
  const delays = [];
  const registry = createDynamoDeviceRegistryV2({
    table: 'Pocket',
    hmacKey: KEY,
    now: () => expiring.claim.ttl * 1000,
    retryDelay: async (attempt) => {
      delays.push(attempt);
    },
    client: {
      async get({ Key }) {
        if (Key.sk === 'directory') {
          directoryReads += 1;
          return { Item: structuredClone(expiring.directory) };
        }
        nonDirectoryReads += 1;
        throw new Error('expired directory members must not trigger base or claim reads');
      },
      async transactWrite() {
        throw new Error('unexpected transaction');
      },
    },
  });
  assert.deepEqual(
    await registry.lookup({
      principal: 'p',
      humanId: 'u',
      sessionId: 'session-a',
    }),
    [],
  );
  assert.equal(directoryReads, 2);
  assert.equal(nonDirectoryReads, 0);
  assert.deepEqual(delays, []);
});

test('Dynamo lookup verifies a stable corrupt snapshot once and fails closed without retry amplification', async () => {
  const { renewed, now } = await sameIntentRenewalSnapshots();
  let directoryReads = 0;
  let baseReads = 0;
  const delays = [];
  const registry = createDynamoDeviceRegistryV2({
    table: 'Pocket',
    hmacKey: KEY,
    now: () => now,
    retryDelay: async (attempt) => {
      delays.push(attempt);
    },
    client: {
      async get({ Key }) {
        if (Key.sk === 'directory') {
          directoryReads += 1;
          return { Item: structuredClone(renewed.directory) };
        }
        if (Key.sk === 'binding') {
          baseReads += 1;
          return {};
        }
        return {};
      },
      async transactWrite() {
        throw new Error('unexpected transaction');
      },
    },
  });
  await assert.rejects(
    registry.lookup({ principal: 'p', humanId: 'u', sessionId: 'session-a' }),
    (error) => error instanceof DeviceRegistryV2Error && error.code === 'corrupt-record',
  );
  assert.equal(directoryReads, 2, 'initial snapshot plus one stability verification');
  assert.equal(baseReads, 1);
  assert.deepEqual(delays, [], 'stable corruption is surfaced immediately, not retried 21 times');
});

test('Dynamo lookup strongly reads the bounded directory, base, and token claim from exact keys', async () => {
  const installationKey = deriveDeviceInstallationKey(KEY, INSTALLATION_ID);
  const targetA = deriveDeviceTargetKey(KEY, 'pa', 'same-human', 'same-session');
  const targetB = deriveDeviceTargetKey(KEY, 'pb', 'same-human', 'same-session');
  const getCalls = [];
  const baseB = {
    pk: installationKey,
    sk: 'binding',
    schema: 'dial-device-binding-v2',
    targetKey: targetB,
    voipToken: 'current-token',
    voipTokenHash: createHash('sha256').update('current-token').digest('base64url'),
    platform: 'apns',
    bindingId: 'bind_0123456789abcdef0123456789abcdef',
    bindingRevision: 9,
    idempotencyKey: IDEM_A,
    requestFingerprint: 'A'.repeat(43),
    expiresAtEpochSec: Math.floor(NOW / 1000) + 60,
    ttl: physicalTtl(Math.floor(NOW / 1000) + 60),
  };
  const claimB = tokenClaimFor(baseB);
  const directoryB = targetDirectoryFor(baseB);
  const client = {
    async get(params) {
      getCalls.push(params);
      if (params.Key.sk === 'directory') {
        return params.Key.pk === targetB ? { Item: directoryB } : {};
      }
      if (params.Key.sk === 'binding') return { Item: baseB };
      if (params.Key.pk === claimB.pk && params.Key.sk === 'claim') return { Item: claimB };
      return {};
    },
    async transactWrite() {
      throw new Error('unexpected transaction');
    },
  };
  const registry = createDynamoDeviceRegistryV2({
    client,
    table: 'Pocket',
    hmacKey: KEY,
    now: () => NOW,
  });
  assert.deepEqual(
    await registry.lookup({
      principal: 'pa',
      humanId: 'same-human',
      sessionId: 'same-session',
    }),
    [],
    'a target with no authoritative directory has no routes',
  );
  assert.deepEqual(
    await registry.lookup({
      principal: 'pb',
      humanId: 'same-human',
      sessionId: 'same-session',
    }),
    [
      {
        voipToken: 'current-token',
        platform: 'apns',
        bindingId: baseB.bindingId,
        bindingRevision: 9,
        expiresAtEpochSec: baseB.expiresAtEpochSec,
      },
    ],
  );
  assert.deepEqual(
    getCalls,
    [
      { TableName: 'Pocket', Key: { pk: targetA, sk: 'directory' }, ConsistentRead: true },
      { TableName: 'Pocket', Key: { pk: targetA, sk: 'directory' }, ConsistentRead: true },
      { TableName: 'Pocket', Key: { pk: targetB, sk: 'directory' }, ConsistentRead: true },
      { TableName: 'Pocket', Key: { pk: installationKey, sk: 'binding' }, ConsistentRead: true },
      { TableName: 'Pocket', Key: { pk: claimB.pk, sk: 'claim' }, ConsistentRead: true },
      { TableName: 'Pocket', Key: { pk: targetB, sk: 'directory' }, ConsistentRead: true },
    ],
    'directory, candidate base, and token claim are all strongly read from exact keys',
  );
  assert.notEqual(targetA, targetB);
});

test('Dynamo lookup fails closed when an active directory member has no exact base binding', async () => {
  const target = deriveDeviceTargetKey(KEY, 'p', 'u', 'session-a');
  const liveKey = deriveDeviceInstallationKey(KEY, Buffer.alloc(32, 0x72).toString('base64url'));
  const liveToken = 'live-token';
  const live = {
    pk: liveKey,
    sk: 'binding',
    schema: 'dial-device-binding-v2',
    targetKey: target,
    voipToken: liveToken,
    voipTokenHash: createHash('sha256').update(liveToken).digest('base64url'),
    platform: 'apns',
    bindingId: 'bind_0123456789abcdef0123456789abcdef',
    bindingRevision: 3,
    idempotencyKey: IDEM_A,
    requestFingerprint: 'B'.repeat(43),
    expiresAtEpochSec: Math.floor(NOW / 1000) + 60,
    ttl: physicalTtl(Math.floor(NOW / 1000) + 60),
  };
  const directory = targetDirectoryFor(live);
  const registry = createDynamoDeviceRegistryV2({
    table: 'Pocket',
    hmacKey: KEY,
    now: () => NOW,
    client: {
      async get({ Key }) {
        if (Key.pk === target && Key.sk === 'directory') return { Item: directory };
        return {};
      },
      async transactWrite() {
        throw new Error('unexpected transaction');
      },
    },
  });
  await assert.rejects(
    registry.lookup({ principal: 'p', humanId: 'u', sessionId: 'session-a' }),
    (error) => error instanceof DeviceRegistryV2Error && error.code === 'corrupt-record',
  );
});

test('Dynamo lookup fails closed on duplicate, over-cap, or schema-drifted target directories', async () => {
  const target = deriveDeviceTargetKey(KEY, 'p', 'u', 'session-a');
  const binding = {
    pk: deriveDeviceInstallationKey(KEY, INSTALLATION_ID),
    sk: 'binding',
    schema: 'dial-device-binding-v2',
    targetKey: target,
    voipToken: 'token',
    voipTokenHash: createHash('sha256').update('token').digest('base64url'),
    platform: 'apns',
    bindingId: 'bind_0123456789abcdef0123456789abcdef',
    bindingRevision: 1,
    idempotencyKey: IDEM_A,
    requestFingerprint: 'C'.repeat(43),
    expiresAtEpochSec: Math.floor(NOW / 1000) + 60,
    ttl: physicalTtl(Math.floor(NOW / 1000) + 60),
  };
  const valid = targetDirectoryFor(binding);
  const overCapMembers = Array.from({ length: 21 }, (_, index) => ({
    installationKey: deriveDeviceInstallationKey(KEY, Buffer.alloc(32, index + 1).toString('base64url')),
    bindingId: 'bind_0123456789abcdef0123456789abcdef',
    bindingRevision: 1,
    expiresAtEpochSec: binding.expiresAtEpochSec,
  })).sort((a, b) => (a.installationKey < b.installationKey ? -1 : 1));
  const variants = [
    { ...valid, members: [valid.members[0], valid.members[0]] },
    { ...valid, members: overCapMembers },
    { ...valid, capacity: 21 },
    { ...valid, ttl: valid.expiresAtEpochSec },
  ];
  for (const directory of variants) {
    const registry = createDynamoDeviceRegistryV2({
      table: 'Pocket',
      hmacKey: KEY,
      now: () => NOW,
      client: {
        async get({ Key }) {
          return Key.sk === 'directory' ? { Item: directory } : {};
        },
        async transactWrite() {},
      },
    });
    await assert.rejects(
      registry.lookup({ principal: 'p', humanId: 'u', sessionId: 'session-a' }),
      (error) => error instanceof DeviceRegistryV2Error && error.code === 'corrupt-record',
    );
  }
});

test('Dynamo unregister transactionally deletes the exact binding, token claim, and last directory', async () => {
  const memory = createInMemoryDeviceRegistryV2({ hmacKey: KEY, now: () => NOW });
  const registered = await memory.register({ principal: 'p', humanId: 'u', ...registration() });
  const binding = [...memory._records.values()][0];
  const claim = [...memory._tokenClaims.values()][0];
  const directory = [...memory._targetDirectories.values()][0];
  const transactions = [];
  const registry = createDynamoDeviceRegistryV2({
    table: 'Pocket',
    hmacKey: KEY,
    now: () => NOW,
    client: {
      async get({ Key }) {
        if (Key.sk === 'binding') return { Item: binding };
        if (Key.sk === 'claim') return { Item: claim };
        if (Key.sk === 'directory') return { Item: directory };
        return {};
      },
      async transactWrite(params) {
        transactions.push(params);
      },
    },
  });
  const common = {
    principal: 'p',
    humanId: 'u',
    registrationVersion: 2,
    installationId: INSTALLATION_ID,
    sessionId: 'session-a',
    bindingId: registered.bindingId,
  };
  assert.deepEqual(
    await registry.unregister({
      ...common,
      bindingRevision: registered.bindingRevision + 1,
    }),
    { removed: false },
  );
  assert.equal(transactions.length, 0, 'a stale tuple cannot reach a delete transaction');
  assert.deepEqual(
    await registry.unregister({
      ...common,
      bindingRevision: registered.bindingRevision,
    }),
    { removed: true },
  );
  assert.equal(transactions[0].TransactItems.length, 3);
  const [baseDelete, claimDelete, directoryDelete] = transactions[0].TransactItems.map((item) => item.Delete);
  assert.deepEqual(baseDelete.Key, { pk: binding.pk, sk: 'binding' });
  assert.match(baseDelete.ConditionExpression, /#target = :target/);
  assert.deepEqual(claimDelete.Key, { pk: claim.pk, sk: 'claim' });
  assert.match(claimDelete.ConditionExpression, /#owner = :owner/);
  assert.equal(claimDelete.ExpressionAttributeValues[':claimId'], claim.tokenClaimId);
  assert.deepEqual(directoryDelete.Key, { pk: directory.pk, sk: 'directory' });
  assert.match(directoryDelete.ConditionExpression, /#directoryId = :directoryId/);
  assert.equal(directoryDelete.ExpressionAttributeValues[':directoryId'], directory.directoryId);
});

test('Dynamo unregister exhaustion never reports success while the exact binding tuple remains present', async () => {
  const memory = createInMemoryDeviceRegistryV2({ hmacKey: KEY, now: () => NOW });
  const registered = await memory.register({ principal: 'p', humanId: 'u', ...registration() });
  const binding = [...memory._records.values()][0];
  const claim = [...memory._tokenClaims.values()][0];
  const directory = [...memory._targetDirectories.values()][0];
  const cancellation = () =>
    Object.assign(new Error('lost delete CAS'), {
      name: 'TransactionCanceledException',
      CancellationReasons: [{ Code: 'ConditionalCheckFailed' }, { Code: 'None' }, { Code: 'None' }],
    });
  let attempts = 0;
  const registry = createDynamoDeviceRegistryV2({
    table: 'Pocket',
    hmacKey: KEY,
    now: () => NOW,
    retryDelay: async () => {},
    client: {
      async get({ Key }) {
        if (Key.sk === 'binding') return { Item: binding };
        if (Key.sk === 'claim') return { Item: claim };
        if (Key.sk === 'directory') return { Item: directory };
        return {};
      },
      async transactWrite() {
        attempts += 1;
        throw cancellation();
      },
    },
  });
  await assert.rejects(
    registry.unregister({
      principal: 'p',
      humanId: 'u',
      registrationVersion: 2,
      installationId: INSTALLATION_ID,
      sessionId: 'session-a',
      bindingId: registered.bindingId,
      bindingRevision: registered.bindingRevision,
    }),
    (error) => error instanceof DeviceRegistryV2Error && error.code === 'unregistration-conflict',
  );
  assert.equal(attempts, DEVICE_REGISTRY_MAX_SERIALIZATION_ATTEMPTS);
});

test('Dynamo retries TransactionConflict with a fresh clock but propagates mixed validation cancellation', async () => {
  let wallMs = NOW;
  const transactions = [];
  const delays = [];
  const conflict = () => javascriptTransactionCancellation(['TransactionConflict', 'None', 'None']);
  const registry = createDynamoDeviceRegistryV2({
    table: 'Pocket',
    hmacKey: KEY,
    now: () => wallMs,
    leaseSeconds: 60,
    retryDelay: async (attempt) => {
      delays.push(attempt);
      wallMs += 2_000;
    },
    client: {
      async get() {
        return {};
      },
      async transactWrite(params) {
        transactions.push(params);
        if (transactions.length === 1) throw conflict();
      },
    },
  });
  const result = await registry.register({ principal: 'p', humanId: 'u', ...registration() });
  assert.deepEqual(delays, [1]);
  assert.equal(transactions.length, 2);
  assert.equal(
    result.expiresAtEpochSec,
    Math.floor((NOW + 2_000) / 1000) + 60,
    'the retry recomputes its lease from the post-backoff clock',
  );
  assert.equal(transactions[1].TransactItems[0].Put.Item.expiresAtEpochSec, result.expiresAtEpochSec);

  const mixed = Object.assign(new Error('validation plus overlap'), {
    name: 'TransactionCanceledException',
    CancellationReasons: [{ Code: 'TransactionConflict' }, { Code: 'ValidationError' }, { Code: 'None' }],
  });
  let mixedTransactions = 0;
  let mixedDelays = 0;
  const mixedRegistry = createDynamoDeviceRegistryV2({
    table: 'Pocket',
    hmacKey: KEY,
    now: () => NOW,
    retryDelay: async () => {
      mixedDelays += 1;
    },
    client: {
      async get() {
        return {};
      },
      async transactWrite() {
        mixedTransactions += 1;
        throw mixed;
      },
    },
  });
  await assert.rejects(
    mixedRegistry.register({ principal: 'p', humanId: 'u', ...registration() }),
    (error) => error === mixed,
  );
  assert.equal(mixedTransactions, 1);
  assert.equal(mixedDelays, 0, 'a validation cancellation is never disguised as retryable contention');
});

test('Dynamo transaction retry classifier propagates unsafe or malformed JavaScript cancellation messages', async () => {
  const structuredNull = javascriptTransactionCancellation(['TransactionConflict', 'None', 'None']);
  structuredNull.CancellationReasons = null;
  const structuredNonArray = javascriptTransactionCancellation(['TransactionConflict', 'None', 'None']);
  structuredNonArray.CancellationReasons = 'TransactionConflict,None,None';
  const structuredMissingCode = javascriptTransactionCancellation(['TransactionConflict', 'None', 'None']);
  structuredMissingCode.CancellationReasons = [{ Code: 'TransactionConflict' }, {}, { Code: 'None' }];
  const structuredNonStringCode = javascriptTransactionCancellation(['TransactionConflict', 'None', 'None']);
  structuredNonStringCode.CancellationReasons = [{ Code: 'TransactionConflict' }, { Code: 7 }, { Code: 'None' }];
  const structuredUnsafe = javascriptTransactionCancellation(['TransactionConflict', 'None', 'None']);
  structuredUnsafe.CancellationReasons = [
    { Code: 'TransactionConflict' },
    { Code: 'ProvisionedThroughputExceeded' },
    { Code: 'None' },
  ];
  const structuredGetterFailure = javascriptTransactionCancellation(['TransactionConflict', 'None', 'None']);
  Object.defineProperty(structuredGetterFailure, 'CancellationReasons', {
    get() {
      throw new Error('untrusted error getter');
    },
  });
  const cancellations = [
    javascriptTransactionCancellation(['ThrottlingError', 'None', 'None']),
    javascriptTransactionCancellation(['ProvisionedThroughputExceeded', 'None', 'None']),
    javascriptTransactionCancellation(['TransactionConflict', 'ValidationError', 'None']),
    javascriptTransactionCancellation(['TransactionConflict', 'UnknownReason', 'None']),
    javascriptTransactionCancellation(['None', 'None', 'None']),
    javascriptTransactionCancellation(['TransactionConflict', 'None']),
    javascriptTransactionCancellation(['TransactionConflict', 'None', 'None', 'None']),
    Object.assign(
      new Error(
        'wrapper: Transaction cancelled, please refer cancellation reasons for specific reasons [TransactionConflict, None]',
      ),
      { name: 'TransactionCanceledException' },
    ),
    Object.assign(
      new Error(
        'Transaction cancelled, please refer cancellation reasons for specific reasons [TransactionConflict,None]',
      ),
      { name: 'TransactionCanceledException' },
    ),
    structuredNull,
    structuredNonArray,
    structuredMissingCode,
    structuredNonStringCode,
    structuredUnsafe,
    structuredGetterFailure,
  ];
  for (const cancellation of cancellations) {
    let transactionCalls = 0;
    let delays = 0;
    const registry = createDynamoDeviceRegistryV2({
      table: 'Pocket',
      hmacKey: KEY,
      now: () => NOW,
      retryDelay: async () => {
        delays += 1;
      },
      client: {
        async get() {
          return {};
        },
        async transactWrite() {
          transactionCalls += 1;
          throw cancellation;
        },
      },
    });
    await assert.rejects(
      registry.register({ principal: 'p', humanId: 'u', ...registration() }),
      (error) => error === cancellation,
    );
    assert.equal(transactionCalls, 1);
    assert.equal(delays, 0);
  }
});

test('Dynamo Registry V2 fails construction on partial infrastructure or weak HMAC config', () => {
  const client = { get() {}, transactWrite() {} };
  assert.throws(
    () =>
      createDynamoDeviceRegistryV2({
        client: { get() {} },
        table: 'T',
        hmacKey: KEY,
      }),
    /get, transactWrite/,
  );
  assert.throws(
    () =>
      createDynamoDeviceRegistryV2({
        client,
        table: 'T',
        hmacKey: Buffer.alloc(16),
      }),
    /at least 32 bytes/,
  );
  assert.throws(
    () =>
      createDynamoDeviceRegistryV2({
        client,
        table: 'T',
        hmacKey: KEY,
        maxDevices: 21,
      }),
    /schema-fixed at 20/,
  );
  assert.throws(
    () =>
      createDynamoDeviceRegistryV2({
        client,
        table: 'T',
        hmacKey: KEY,
        retryDelay: null,
      }),
    /retryDelay must be a function/,
  );
});

test('different operation id with the same semantic intent renews without rotating the binding', async () => {
  let now = NOW;
  const registry = createInMemoryDeviceRegistryV2({ hmacKey: KEY, now: () => now, leaseSeconds: 60 });
  const one = await registry.register({ principal: 'p', humanId: 'u', ...registration() });
  now += 10_000;
  const two = await registry.register({
    principal: 'p',
    humanId: 'u',
    ...registration({
      idempotencyKey: IDEM_C,
      expectedBindingId: one.bindingId,
      expectedBindingRevision: one.bindingRevision,
    }),
  });
  assert.equal(two.bindingRevision, one.bindingRevision);
  assert.equal(two.bindingId, one.bindingId);
  assert.equal(two.expiresAtEpochSec, one.expiresAtEpochSec + 10);
  assert.equal(two.idempotent, false);
  assert.equal(two.renewed, true);
});
