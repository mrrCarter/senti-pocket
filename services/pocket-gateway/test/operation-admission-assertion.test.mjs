import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import test from 'node:test';

import { deriveDeviceOwnerHandle } from '../src/device-registry-v2.mjs';
import {
  OPERATION_ADMISSION_ASSERTION_EVENT_FIELD,
  OPERATION_ADMISSION_ASSERTION_LIFETIME_SECONDS,
  OPERATION_ADMISSION_ASSERTION_MAX_BODY_BYTES,
  OPERATION_ADMISSION_ASSERTION_MAX_BYTES,
  OPERATION_ADMISSION_ASSERTION_SCHEMA,
  OperationAdmissionAssertionError,
  createOperationAdmissionAssertionSigner,
  createOperationAdmissionAssertionVerifier,
  isOperationAdmissionAssertionContext,
  snapshotOperationAdmissionRawRequest,
} from '../src/operation-admission-assertion.mjs';
import { deriveRegistryOperationAdmissionIdentity } from '../src/operation-admission.mjs';

const ROOT_SECRET = Buffer.alloc(32, 0x5a).toString('base64');
const OTHER_ROOT_SECRET = Buffer.alloc(32, 0x6b).toString('base64');
const KID = 'a'.repeat(32);
const OTHER_KID = 'b'.repeat(32);
const SECRET_ARN = 'arn:aws:secretsmanager:us-east-1:123456789012:secret:senti-pocket-registry-hmac-AbCdEf';
const OTHER_SECRET_ARN = 'arn:aws:secretsmanager:us-east-1:123456789012:secret:senti-pocket-registry-hmac-ZyXwVu';
const AUDIENCE = 'arn:aws:lambda:us-east-1:123456789012:function:pocket-gateway:42';
const OTHER_AUDIENCE = 'arn:aws:lambda:us-east-1:123456789012:function:pocket-gateway:43';
const NOW = Date.parse('2026-08-05T05:00:00.000Z');
const PRINCIPAL = 'pocket.principal.senti.v1\n7:user_42';
const HUMAN_ID = 'user_42';
const INSTALLATION_ID = Buffer.alloc(32, 0x42).toString('base64url');
const IDEMPOTENCY_KEY = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const AUTHORIZATION = 'Bearer pocket-secret';
const JTI_BYTES = Buffer.alloc(32, 0x7c);
const JTI = JTI_BYTES.toString('base64url');

function deterministicRandomBytes(length) {
  assert.equal(length, 32);
  return Buffer.from(JTI_BYTES);
}

function acceptingReplayGuard() {
  return Object.freeze({
    async seen() {
      return false;
    },
  });
}

function registration(overrides = {}) {
  return {
    registrationVersion: 2,
    ownerVersion: 1,
    ownerHandle: deriveDeviceOwnerHandle(ROOT_SECRET, PRINCIPAL, HUMAN_ID),
    installationId: INSTALLATION_ID,
    idempotencyKey: IDEMPOTENCY_KEY,
    voipToken: 'private-routing-token',
    sessionId: 'session-v2',
    platform: 'apns',
    ...overrides,
  };
}

function cleanup(overrides = {}) {
  const source = registration();
  return {
    registrationVersion: 2,
    ownerVersion: 1,
    ownerHandle: source.ownerHandle,
    installationId: source.installationId,
    idempotencyKey: source.idempotencyKey,
    tokenDigest: createHash('sha256').update(source.voipToken, 'utf8').digest('base64url'),
    sessionId: source.sessionId,
    platform: source.platform,
    ...overrides,
  };
}

function apiEvent(body = registration(), {
  path = '/dial/register',
  method = 'POST',
  base64 = false,
  headers = { authorization: AUTHORIZATION },
} = {}) {
  const text = typeof body === 'string' ? body : JSON.stringify(body);
  return {
    version: '2.0',
    rawPath: path,
    headers,
    requestContext: { http: { method, path } },
    body: base64 ? Buffer.from(text, 'utf8').toString('base64') : text,
    isBase64Encoded: base64,
  };
}

function sign(event, {
  hmacKey = ROOT_SECRET,
  kid = KID,
  secretArn = SECRET_ARN,
  audience = AUDIENCE,
  now = NOW,
  principal = PRINCIPAL,
  humanId = HUMAN_ID,
  scopes = ['pocket:dial'],
  randomBytes = deterministicRandomBytes,
} = {}) {
  const snapshot = snapshotOperationAdmissionRawRequest(event);
  const derived = deriveRegistryOperationAdmissionIdentity({
    method: snapshot.method,
    path: snapshot.path,
    body: snapshot.parsedBody,
    principal,
    humanId,
    hmacKey,
  });
  assert.equal(derived.ok, true, 'fixture must satisfy the frozen Registry V2 contract');
  const signer = createOperationAdmissionAssertionSigner({
    hmacKey,
    kid,
    secretArn,
    audience,
    now: () => now,
    randomBytes,
  });
  const assertion = signer.sign({
    snapshot,
    principal,
    humanId,
    scopes,
    ownerHandle: snapshot.parsedBody.ownerHandle,
    operationDigest: derived.operationDigest,
  });
  return {
    assertion,
    snapshot,
    event: { ...event, [OPERATION_ADMISSION_ASSERTION_EVENT_FIELD]: assertion },
  };
}

function verifier({
  hmacKey = ROOT_SECRET,
  kid = KID,
  secretArn = SECRET_ARN,
  audience = AUDIENCE,
  now = NOW,
  replayGuard = acceptingReplayGuard(),
} = {}) {
  return createOperationAdmissionAssertionVerifier({
    hmacKey,
    kid,
    secretArn,
    audience,
    now: () => now,
    replayGuard,
  });
}

function withAssertion(event, assertion) {
  return { ...event, [OPERATION_ADMISSION_ASSERTION_EVENT_FIELD]: assertion };
}

function flipDigest(value) {
  const bytes = Buffer.from(value, 'base64url');
  bytes[0] ^= 0x01;
  return bytes.toString('base64url');
}

const hasCode = (code) => (error) =>
  error instanceof OperationAdmissionAssertionError && error.code === code;
const isInvalid = hasCode('operation-admission-assertion-invalid');
const isConfigurationInvalid = hasCode('operation-admission-assertion-configuration-invalid');
const isInvalidBody = hasCode('operation-admission-assertion-body-invalid');
const isBodyTooLarge = hasCode('operation-admission-assertion-body-too-large');

test('deterministic vector binds the immutable raw request and reconstructs only the signed scopes', async () => {
  const originalEvent = apiEvent();
  const originalBody = originalEvent.body;
  const originalAuthorization = originalEvent.headers.authorization;
  const signed = sign(originalEvent);

  assert.equal(Object.isFrozen(signed.snapshot), true);
  assert.equal(Object.isFrozen(signed.snapshot.parsedBody), true);
  assert.equal(signed.snapshot.authorization, originalAuthorization);
  assert.equal(signed.snapshot.authorizationSha256, '27aJtKZQDzdBBntaxQ2EN0QhD43WfKgb_GqSR9fmuDE');
  assert.equal(signed.snapshot.decodedBodySha256, '1KEG0Rae2YtZf1K-wSxxF5eLwWP489MOkRhue3EpSAc');
  assert.equal(signed.snapshot.bodyByteLength, 300);
  assert.equal(signed.snapshot.bodyEncoding, 'utf8');
  assert.equal(signed.snapshot.isBase64Encoded, false);

  const authorizationCopy = signed.snapshot.authorizationBytes;
  const bodyCopy = signed.snapshot.decodedBodyBytes;
  authorizationCopy.fill(0);
  bodyCopy.fill(0);
  assert.equal(signed.snapshot.authorizationBytes.toString('utf8'), originalAuthorization);
  assert.equal(signed.snapshot.decodedBodyBytes.toString('utf8'), originalBody);

  assert.deepEqual(signed.assertion, {
    schema: 'senti-pocket-operation-admission-assertion-v1',
    kid: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    secretArn: SECRET_ARN,
    aud: AUDIENCE,
    method: 'POST',
    path: '/dial/register',
    authorizationSha256: '27aJtKZQDzdBBntaxQ2EN0QhD43WfKgb_GqSR9fmuDE',
    decodedBodySha256: '1KEG0Rae2YtZf1K-wSxxF5eLwWP489MOkRhue3EpSAc',
    principal: PRINCIPAL,
    humanId: HUMAN_ID,
    scopes: ['pocket:dial'],
    ownerHandle: 'hM6gwt7D0Sya1SxziSclFVSHZIWnHR2IJ-3ORNcWwb0',
    operationDigest: 'tD-iRIZq2-Q8DXolgmYto6iMaT_B6nGFg_IIuZI77PY',
    jti: JTI,
    iat: 1_785_906_000,
    exp: 1_785_906_010,
    mac: 'XlI_6MNTyECrM6Oc2NOmV6P8nYX3HAId6EXxkWGnBA4',
  });
  assert.equal(Object.isFrozen(signed.assertion), true);
  const serializedAssertion = JSON.stringify(signed.assertion);
  assert.equal(serializedAssertion.includes(AUTHORIZATION), false);
  assert.equal(serializedAssertion.includes(originalBody), false);
  assert.equal(serializedAssertion.includes('private-routing-token'), false);
  assert.equal(Object.hasOwn(signed.assertion, 'authorization'), false);
  assert.equal(Object.hasOwn(signed.assertion, 'body'), false);
  assert.equal(Object.hasOwn(signed.assertion, 'voipToken'), false);

  // Mutating the caller-owned event after capture cannot change what was authenticated and admitted.
  originalEvent.headers.authorization = 'Bearer replaced-after-snapshot';
  originalEvent.body = JSON.stringify(registration({ voipToken: 'replaced-after-snapshot' }));
  originalEvent.requestContext.http.path = '/dial/register/reconcile';
  assert.equal(signed.snapshot.authorization, originalAuthorization);
  assert.equal(signed.snapshot.decodedBodyBytes.toString('utf8'), originalBody);

  const pendingContext = verifier().verify(withAssertion(apiEvent(), signed.assertion));
  assert.equal(pendingContext instanceof Promise, true);
  const context = await pendingContext;
  assert.deepEqual(context, {
    humanId: HUMAN_ID,
    principal: PRINCIPAL,
    scopes: ['pocket:dial'],
    site: null,
    tokenClaims: {
      authMethod: 'senti_session',
      via: 'operation_admission_assertion',
      exp: signed.assertion.exp,
    },
  });
  assert.equal(Object.isFrozen(context), true);
  assert.equal(Object.isFrozen(context.scopes), true);
  assert.equal(Object.isFrozen(context.tokenClaims), true);
  assert.equal(isOperationAdmissionAssertionContext(context), true);
  assert.equal(isOperationAdmissionAssertionContext({ ...context }), false);
  assert.equal(isOperationAdmissionAssertionContext(structuredClone(context)), false);
  assert.equal(isOperationAdmissionAssertionContext(signed.assertion), false);
  assert.throws(() => context.scopes.push('sessions:write'), TypeError);
  assert.throws(() => { context.tokenClaims.via = 'auth/me'; }, TypeError);
});

test('plain and canonical-base64 events produce the same decoded-body proof for both frozen routes', async () => {
  const plainRegistration = sign(apiEvent(registration()));
  const base64Registration = sign(apiEvent(registration(), { base64: true }));
  assert.equal(base64Registration.snapshot.bodyEncoding, 'base64');
  assert.equal(base64Registration.snapshot.isBase64Encoded, true);
  assert.equal(base64Registration.snapshot.decodedBodySha256, plainRegistration.snapshot.decodedBodySha256);
  assert.deepEqual(base64Registration.assertion, plainRegistration.assertion);
  assert.equal(isOperationAdmissionAssertionContext(await verifier().verify(base64Registration.event)), true);

  const plainCleanup = sign(apiEvent(cleanup(), { path: '/dial/register/reconcile' }));
  const base64Cleanup = sign(apiEvent(cleanup(), { path: '/dial/register/reconcile', base64: true }));
  assert.equal(plainCleanup.assertion.path, '/dial/register/reconcile');
  assert.deepEqual(base64Cleanup.assertion, plainCleanup.assertion);
  assert.equal(isOperationAdmissionAssertionContext(await verifier().verify(plainCleanup.event)), true);
  assert.equal(isOperationAdmissionAssertionContext(await verifier().verify(base64Cleanup.event)), true);
});

test('raw snapshot rejects noncanonical base64, fatal UTF-8, malformed JSON, and bodies beyond the 4 KiB ceiling', () => {
  const padded = Buffer.from('{"x":1}', 'utf8').toString('base64');
  assert.equal(padded.endsWith('=='), true);
  const invalidBase64Bodies = [
    padded.slice(0, -2),
    `${padded}=`,
    ` ${padded}`,
    `${padded}\n`,
    '-w==',
    'AB==',
  ];
  for (const body of invalidBase64Bodies) {
    assert.throws(
      () => snapshotOperationAdmissionRawRequest({ ...apiEvent(), body, isBase64Encoded: true }),
      isInvalidBody,
    );
  }

  const invalidUtf8 = Buffer.from([0xc3, 0x28]).toString('base64');
  assert.throws(
    () => snapshotOperationAdmissionRawRequest({ ...apiEvent(), body: invalidUtf8, isBase64Encoded: true }),
    isInvalidBody,
  );
  assert.throws(
    () => snapshotOperationAdmissionRawRequest({ ...apiEvent(), body: '{"x":"\ud800"}', isBase64Encoded: false }),
    isInvalidBody,
  );
  assert.throws(
    () => snapshotOperationAdmissionRawRequest({ ...apiEvent(), body: '{not-json', isBase64Encoded: false }),
    isInvalidBody,
  );

  const exactLimit = JSON.stringify({ x: 'a'.repeat(OPERATION_ADMISSION_ASSERTION_MAX_BODY_BYTES - 8) });
  assert.equal(Buffer.byteLength(exactLimit, 'utf8'), OPERATION_ADMISSION_ASSERTION_MAX_BODY_BYTES);
  assert.equal(snapshotOperationAdmissionRawRequest(apiEvent(exactLimit)).bodyByteLength, OPERATION_ADMISSION_ASSERTION_MAX_BODY_BYTES);
  assert.equal(snapshotOperationAdmissionRawRequest(apiEvent(exactLimit, { base64: true })).bodyByteLength, OPERATION_ADMISSION_ASSERTION_MAX_BODY_BYTES);
  const overLimit = JSON.stringify({ x: 'a'.repeat(OPERATION_ADMISSION_ASSERTION_MAX_BODY_BYTES - 7) });
  assert.throws(() => snapshotOperationAdmissionRawRequest(apiEvent(overLimit)), isBodyTooLarge);
  assert.throws(() => snapshotOperationAdmissionRawRequest(apiEvent(overLimit, { base64: true })), isBodyTooLarge);
});

test('strict API Gateway v2 extraction rejects route ambiguity, Authorization smuggling, and a pre-existing proof', () => {
  const duplicateAuthorization = apiEvent(undefined, {
    headers: { authorization: AUTHORIZATION, Authorization: 'Bearer attacker' },
  });
  assert.throws(() => snapshotOperationAdmissionRawRequest(duplicateAuthorization), isInvalid);
  assert.equal(
    snapshotOperationAdmissionRawRequest(apiEvent(undefined, { headers: { Authorization: AUTHORIZATION } })).authorization,
    AUTHORIZATION,
  );
  const missingAuthorization = snapshotOperationAdmissionRawRequest(apiEvent(undefined, { headers: {} }));
  assert.equal(missingAuthorization.hasAuthorization, false);
  assert.equal(missingAuthorization.authorization, '');
  assert.throws(
    () => snapshotOperationAdmissionRawRequest({ ...apiEvent(), multiValueHeaders: { authorization: [AUTHORIZATION] } }),
    isInvalid,
  );
  assert.throws(
    () => snapshotOperationAdmissionRawRequest({
      ...apiEvent(),
      [OPERATION_ADMISSION_ASSERTION_EVENT_FIELD]: { attacker: true },
    }),
    isInvalid,
  );

  for (const event of [
    { ...apiEvent(), version: '1.0' },
    { ...apiEvent(), rawPath: '/dial/register/' },
    apiEvent(undefined, { method: 'post' }),
    apiEvent(undefined, { method: 'GET' }),
    apiEvent(undefined, { path: '/dial/register/' }),
    { ...apiEvent(), httpMethod: 'POST' },
    { ...apiEvent(), path: '/dial/register' },
  ]) {
    assert.throws(() => snapshotOperationAdmissionRawRequest(event), isInvalid);
  }
});

test('assertion has the exact bounded schema and rejects missing, extra, accessor, and oversized forms', () => {
  const signed = sign(apiEvent());
  assert.deepEqual(Object.keys(signed.assertion), [
    'schema',
    'kid',
    'secretArn',
    'aud',
    'method',
    'path',
    'authorizationSha256',
    'decodedBodySha256',
    'principal',
    'humanId',
    'scopes',
    'ownerHandle',
    'operationDigest',
    'jti',
    'iat',
    'exp',
    'mac',
  ]);
  assert.equal(signed.assertion.schema, OPERATION_ADMISSION_ASSERTION_SCHEMA);
  assert.ok(Buffer.byteLength(JSON.stringify(signed.assertion), 'utf8') <= OPERATION_ADMISSION_ASSERTION_MAX_BYTES);

  const missing = { ...signed.assertion };
  delete missing.operationDigest;
  const extra = { ...signed.assertion, identity: { principal: PRINCIPAL } };
  const oversized = { ...signed.assertion, aud: 'x'.repeat(OPERATION_ADMISSION_ASSERTION_MAX_BYTES) };
  const accessor = { ...signed.assertion };
  Object.defineProperty(accessor, 'mac', { enumerable: true, get() { return signed.assertion.mac; } });
  const nonenumerable = { ...signed.assertion };
  Object.defineProperty(nonenumerable, 'mac', { enumerable: false, value: signed.assertion.mac });

  for (const assertion of [missing, extra, oversized, accessor, nonenumerable, [], null]) {
    assert.throws(() => verifier().verify(withAssertion(apiEvent(), assertion)), isInvalid);
  }
});

test('every route, credential, body, identity, owner, operation, key, audience, and MAC binding fails closed on tamper', () => {
  const signed = sign(apiEvent());
  const otherOwner = deriveDeviceOwnerHandle(ROOT_SECRET, 'other-principal', HUMAN_ID);
  const assertionTamper = [
    ['schema', 'senti-pocket-operation-admission-assertion-v2'],
    ['kid', OTHER_KID],
    ['secretArn', OTHER_SECRET_ARN],
    ['aud', OTHER_AUDIENCE],
    ['method', 'GET'],
    ['path', '/dial/register/reconcile'],
    ['authorizationSha256', flipDigest(signed.assertion.authorizationSha256)],
    ['decodedBodySha256', flipDigest(signed.assertion.decodedBodySha256)],
    ['principal', 'pocket.principal.senti.v1\n5:other'],
    ['humanId', 'other'],
    ['scopes', ['pocket:dial', 'sessions:write']],
    ['ownerHandle', otherOwner],
    ['operationDigest', flipDigest(signed.assertion.operationDigest)],
    ['jti', flipDigest(signed.assertion.jti)],
    ['iat', signed.assertion.iat + 1],
    ['exp', signed.assertion.exp + 1],
    ['mac', flipDigest(signed.assertion.mac)],
  ];
  for (const [field, value] of assertionTamper) {
    assert.throws(
      () => verifier().verify(withAssertion(apiEvent(), { ...signed.assertion, [field]: value })),
      isInvalid,
      `tampered ${field} must fail`,
    );
  }

  const requestTamper = [
    apiEvent(undefined, { headers: { authorization: 'Bearer attacker' } }),
    apiEvent(registration({ voipToken: 'different-private-routing-token' })),
    { ...apiEvent(), rawPath: '/dial/register/reconcile' },
    apiEvent(cleanup(), { path: '/dial/register/reconcile' }),
  ];
  for (const event of requestTamper) {
    assert.throws(() => verifier().verify(withAssertion(event, signed.assertion)), isInvalid);
  }
});

test('proof is mandatory and exact key id, secret ARN, root key, and audience are independently pinned', () => {
  const signed = sign(apiEvent());
  assert.throws(() => verifier().verify(apiEvent()), isInvalid);
  assert.throws(() => verifier({ hmacKey: OTHER_ROOT_SECRET }).verify(signed.event), isInvalid);
  assert.throws(() => verifier({ kid: OTHER_KID }).verify(signed.event), isInvalid);
  assert.throws(() => verifier({ secretArn: OTHER_SECRET_ARN }).verify(signed.event), isInvalid);
  assert.throws(() => verifier({ audience: OTHER_AUDIENCE }).verify(signed.event), isInvalid);

  const wrongAudienceProof = sign(apiEvent(), { audience: OTHER_AUDIENCE });
  assert.throws(() => verifier().verify(wrongAudienceProof.event), isInvalid);
  const wrongKidProof = sign(apiEvent(), { kid: OTHER_KID });
  assert.throws(() => verifier().verify(wrongKidProof.event), isInvalid);
  const wrongSecretProof = sign(apiEvent(), { secretArn: OTHER_SECRET_ARN });
  assert.throws(() => verifier().verify(wrongSecretProof.event), isInvalid);
  const wrongKeyOwner = deriveDeviceOwnerHandle(OTHER_ROOT_SECRET, PRINCIPAL, HUMAN_ID);
  const wrongKeyProof = sign(apiEvent(registration({ ownerHandle: wrongKeyOwner })), {
    hmacKey: OTHER_ROOT_SECRET,
  });
  assert.throws(() => verifier().verify(wrongKeyProof.event), isInvalid);
});

test('ten-second lifetime is exp-exclusive with no grace and permits at most two seconds of future iat skew', async () => {
  const signed = sign(apiEvent());
  assert.equal(signed.assertion.exp - signed.assertion.iat, OPERATION_ADMISSION_ASSERTION_LIFETIME_SECONDS);
  assert.equal(
    isOperationAdmissionAssertionContext(
      await verifier({ now: (signed.assertion.exp - 1) * 1000 + 999 }).verify(signed.event),
    ),
    true,
  );
  assert.throws(
    () => verifier({ now: signed.assertion.exp * 1000 }).verify(signed.event),
    isInvalid,
    'the exact exp second is expired',
  );
  assert.throws(
    () => verifier({ now: (signed.assertion.exp + 60) * 1000 }).verify(signed.event),
    isInvalid,
  );

  const futureByTwo = sign(apiEvent(), { now: NOW + 2_000 });
  assert.equal(isOperationAdmissionAssertionContext(await verifier({ now: NOW }).verify(futureByTwo.event)), true);
  const futureByThree = sign(apiEvent(), { now: NOW + 3_000 });
  assert.throws(() => verifier({ now: NOW }).verify(futureByThree.event), isInvalid);
});

test('secret ARN and replay guard are mandatory verifier configuration', () => {
  assert.throws(
    () => createOperationAdmissionAssertionSigner({
      hmacKey: ROOT_SECRET,
      kid: KID,
      audience: AUDIENCE,
      now: () => NOW,
      randomBytes: deterministicRandomBytes,
    }),
    isConfigurationInvalid,
  );
  assert.throws(
    () => createOperationAdmissionAssertionVerifier({
      hmacKey: ROOT_SECRET,
      kid: KID,
      audience: AUDIENCE,
      now: () => NOW,
      replayGuard: acceptingReplayGuard(),
    }),
    isConfigurationInvalid,
  );
  assert.throws(
    () => createOperationAdmissionAssertionVerifier({
      hmacKey: ROOT_SECRET,
      kid: KID,
      secretArn: SECRET_ARN,
      audience: AUDIENCE,
      now: () => NOW,
    }),
    isConfigurationInvalid,
  );
  assert.throws(
    () => createOperationAdmissionAssertionVerifier({
      hmacKey: ROOT_SECRET,
      kid: KID,
      secretArn: SECRET_ARN,
      audience: AUDIENCE,
      now: () => NOW,
      replayGuard: { seen: false },
    }),
    isConfigurationInvalid,
  );
});

test('signed scopes are canonical, immutable, and preserve an empty grant without privilege inflation', async () => {
  const signed = sign(apiEvent(), { scopes: ['sessions:write', 'pocket:dial'] });
  assert.deepEqual(signed.assertion.scopes, ['pocket:dial', 'sessions:write']);
  assert.equal(Object.isFrozen(signed.assertion.scopes), true);
  const context = await verifier().verify(signed.event);
  assert.deepEqual(context.scopes, ['pocket:dial', 'sessions:write']);

  const empty = sign(apiEvent(), { scopes: [] });
  assert.deepEqual(empty.assertion.scopes, []);
  assert.deepEqual((await verifier().verify(empty.event)).scopes, []);

  assert.throws(() => sign(apiEvent(), { scopes: ['pocket:dial', 'pocket:dial'] }), isInvalid);
  assert.throws(() => sign(apiEvent(), { scopes: [' pocket:dial'] }), isInvalid);
  assert.throws(
    () => verifier().verify(withAssertion(apiEvent(), {
      ...signed.assertion,
      scopes: ['sessions:write', 'pocket:dial'],
    })),
    isInvalid,
    'a noncanonical on-wire scope order fails before replay storage',
  );
});

test('an atomic replay guard permits exactly one concurrent success for one signed jti and receives exp as TTL', async () => {
  const signed = sign(apiEvent());
  const claimed = new Set();
  const calls = [];
  const replayGuard = {
    async seen(jti, expiresAtEpochSeconds) {
      calls.push([jti, expiresAtEpochSeconds]);
      const replayed = claimed.has(jti);
      claimed.add(jti);
      await Promise.resolve();
      return replayed;
    },
  };
  const assertionVerifier = verifier({ replayGuard });
  const attempts = Array.from({ length: 16 }, () => assertionVerifier.verify(signed.event));
  assert.equal(attempts.every((attempt) => attempt instanceof Promise), true);
  const results = await Promise.allSettled(attempts);
  const successes = results.filter(({ status }) => status === 'fulfilled');
  const failures = results.filter(({ status }) => status === 'rejected');

  assert.equal(successes.length, 1);
  assert.equal(isOperationAdmissionAssertionContext(successes[0].value), true);
  assert.equal(failures.length, 15);
  assert.equal(failures.every(({ reason }) => isInvalid(reason)), true);
  assert.equal(calls.length, attempts.length);
  assert.deepEqual(new Set(calls.map(([jti]) => jti)), new Set([signed.assertion.jti]));
  assert.equal(calls.every(([, ttl]) => ttl === signed.assertion.exp), true);
});

test('replay-store outage and every non-boolean-false result fail closed', async () => {
  const signed = sign(apiEvent());
  const cases = [
    ['synchronous outage', { seen() { throw new Error('store unavailable'); } }],
    ['asynchronous outage', { async seen() { throw new Error('store unavailable'); } }],
    ['undefined', { seen() {} }],
    ['null', { async seen() { return null; } }],
    ['true', { async seen() { return true; } }],
    ['zero', { async seen() { return 0; } }],
    ['object', { async seen() { return {}; } }],
  ];

  for (const [label, replayGuard] of cases) {
    const result = verifier({ replayGuard }).verify(signed.event);
    assert.equal(result instanceof Promise, true, `${label} must stay on the asynchronous store boundary`);
    await assert.rejects(result, isInvalid, `${label} must fail closed`);
  }
});

test('replay-store latency cannot brand an expired context or cross a backwards clock step', async () => {
  const signed = sign(apiEvent());
  for (const [label, afterReplayMs] of [
    ['expired while writing', signed.assertion.exp * 1000],
    ['clock rolled backwards', NOW - 1000],
  ]) {
    let currentMs = NOW;
    const assertionVerifier = createOperationAdmissionAssertionVerifier({
      hmacKey: ROOT_SECRET,
      kid: KID,
      secretArn: SECRET_ARN,
      audience: AUDIENCE,
      now: () => currentMs,
      replayGuard: {
        async seen() {
          currentMs = afterReplayMs;
          return false;
        },
      },
    });

    await assert.rejects(assertionVerifier.verify(signed.event), isInvalid, label);
  }
});

test('forged and expired assertions fail synchronously without touching replay storage', () => {
  const signed = sign(apiEvent());
  let replayCalls = 0;
  const replayGuard = {
    async seen() {
      replayCalls += 1;
      return false;
    },
  };

  assert.throws(
    () => verifier({ replayGuard }).verify(withAssertion(apiEvent(), {
      ...signed.assertion,
      mac: flipDigest(signed.assertion.mac),
    })),
    isInvalid,
  );
  assert.throws(
    () => verifier({ now: signed.assertion.exp * 1000, replayGuard }).verify(signed.event),
    isInvalid,
  );
  assert.equal(replayCalls, 0);
});

test('signer accepts only its immutable snapshot and exact frozen owner/operation derivation', () => {
  const event = apiEvent();
  const signed = sign(event);
  const signer = createOperationAdmissionAssertionSigner({
    hmacKey: ROOT_SECRET,
    kid: KID,
    secretArn: SECRET_ARN,
    audience: AUDIENCE,
    now: () => NOW,
    randomBytes: deterministicRandomBytes,
  });
  const base = {
    snapshot: signed.snapshot,
    principal: PRINCIPAL,
    humanId: HUMAN_ID,
    scopes: ['pocket:dial'],
    ownerHandle: signed.assertion.ownerHandle,
    operationDigest: signed.assertion.operationDigest,
  };
  assert.throws(() => signer.sign({ ...base, snapshot: { ...signed.snapshot } }), isInvalid);
  assert.throws(() => signer.sign({ ...base, principal: 'other-principal' }), isInvalid);
  assert.throws(() => signer.sign({ ...base, humanId: 'other' }), isInvalid);
  assert.throws(() => signer.sign({ ...base, ownerHandle: flipDigest(base.ownerHandle) }), isInvalid);
  assert.throws(() => signer.sign({ ...base, operationDigest: flipDigest(base.operationDigest) }), isInvalid);
});
