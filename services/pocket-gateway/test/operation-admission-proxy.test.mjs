import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import test from 'node:test';

import {
  createOperationAdmissionProxy,
  OPERATION_ADMISSION_MAX_BODY_BYTES,
} from '../src/operation-admission-proxy.mjs';
import {
  createOperationAdmissionAssertionSigner,
  OPERATION_ADMISSION_ASSERTION_EVENT_FIELD,
} from '../src/operation-admission-assertion.mjs';
import { deriveDeviceOwnerHandle } from '../src/device-registry-v2.mjs';

const HMAC_KEY = Buffer.alloc(32, 0x51);
const INSTALLATION_ID = Buffer.alloc(32, 0x42).toString('base64url');
const IDEMPOTENCY_KEY = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const VOIP_TOKEN = 'private-routing-token';
const HMAC_VERSION_ID = '0123456789abcdef0123456789abcdef';
const HMAC_SECRET_ARN = 'arn:aws:secretsmanager:us-east-1:123456789012:secret:senti-pocket-registry-hmac-AbCdEf';
const GATEWAY_VERSION_ARN = 'arn:aws:lambda:us-east-1:123456789012:function:senti-pocket-gateway:42';
const ASSERTION_NOW_MS = Date.parse('2026-08-05T04:00:00.000Z');
const IDENTITY = Object.freeze({
  principal: 'pocket.principal.senti.v1\n7:user_42',
  humanId: 'user_42',
  scopes: Object.freeze([]),
});
const ASSERTION_SIGNER = createOperationAdmissionAssertionSigner({
  hmacKey: HMAC_KEY.toString('base64'),
  kid: HMAC_VERSION_ID,
  secretArn: HMAC_SECRET_ARN,
  audience: GATEWAY_VERSION_ARN,
  now: () => ASSERTION_NOW_MS,
  randomBytes: () => Buffer.alloc(32, 0x7c),
});
const createAssertion = (input) => ASSERTION_SIGNER.sign(input);

function registration(overrides = {}) {
  return {
    registrationVersion: 2,
    ownerVersion: 1,
    ownerHandle: deriveDeviceOwnerHandle(HMAC_KEY, IDENTITY.principal, IDENTITY.humanId),
    installationId: INSTALLATION_ID,
    idempotencyKey: IDEMPOTENCY_KEY,
    voipToken: VOIP_TOKEN,
    sessionId: 'session-v2',
    platform: 'apns',
    ...overrides,
  };
}

function cleanup(overrides = {}) {
  return {
    registrationVersion: 2,
    ownerVersion: 1,
    ownerHandle: deriveDeviceOwnerHandle(HMAC_KEY, IDENTITY.principal, IDENTITY.humanId),
    installationId: INSTALLATION_ID,
    idempotencyKey: IDEMPOTENCY_KEY,
    tokenDigest: createHash('sha256').update(VOIP_TOKEN, 'utf8').digest('base64url'),
    sessionId: 'session-v2',
    platform: 'apns',
    ...overrides,
  };
}

function apiEvent(body = registration(), {
  method = 'POST',
  path = '/dial/register',
  base64 = false,
  headers = { authorization: 'Bearer pocket-secret' },
} = {}) {
  const json = typeof body === 'string' ? body : JSON.stringify(body);
  return {
    version: '2.0',
    rawPath: path,
    headers,
    requestContext: { http: { method, path } },
    body: base64 ? Buffer.from(json, 'utf8').toString('base64') : json,
    isBase64Encoded: base64,
  };
}

function gatewayResponse(statusCode = 200, body = { ok: true }) {
  return {
    statusCode,
    headers: { 'content-type': 'application/json', 'x-gateway': 'private' },
    body: JSON.stringify(body),
    isBase64Encoded: false,
  };
}

function responseBody(response) {
  return JSON.parse(response.body);
}

function assertUnavailable(response) {
  assert.equal(response.statusCode, 503);
  assert.deepEqual(responseBody(response), {
    error: 'registration operation admission unavailable',
    reason: 'operation-admission-unavailable',
  });
  assert.equal(response.isBase64Encoded, false);
}

function createPassingProxy(overrides = {}) {
  return createOperationAdmissionProxy({
    hmacKey: HMAC_KEY,
    verifyToken: async () => IDENTITY,
    admission: { admit: async () => ({ admitted: true, replay: false }) },
    createAssertion,
    invokeGateway: async () => gatewayResponse(),
    ...overrides,
  });
}

test('protected registration authenticates, admits, then forwards the exact original event', async () => {
  const calls = [];
  const event = apiEvent();
  const originalBody = event.body;
  const expected = gatewayResponse(202, { accepted: true });
  let admitted;
  let forwarded;
  const proxy = createOperationAdmissionProxy({
    hmacKey: HMAC_KEY,
    verifyToken: async (headers) => {
      calls.push('verify');
      assert.deepEqual(headers, { authorization: event.headers.authorization });
      assert.ok(Object.isFrozen(headers));
      return IDENTITY; // scopes are intentionally empty: admission is not authorization.
    },
    admission: {
      admit: async (input) => {
        calls.push('admit');
        admitted = input;
        return { admitted: true, replay: false, liveOperations: 1 };
      },
    },
    createAssertion,
    invokeGateway: async (input) => {
      calls.push('invoke');
      forwarded = input;
      return expected;
    },
  });

  const response = await proxy(event);

  assert.strictEqual(response, expected, 'a valid private-gateway response is returned without rewriting');
  assert.notStrictEqual(forwarded, event, 'a shallow private event clone carries the signed assertion');
  assert.strictEqual(forwarded.headers, event.headers, 'the original header container is forwarded unchanged');
  assert.equal(event.body, originalBody, 'the original body bytes are untouched');
  assert.equal(forwarded.body, originalBody, 'the private event retains the exact original body bytes');
  assert.ok(Object.hasOwn(forwarded, OPERATION_ADMISSION_ASSERTION_EVENT_FIELD));
  assert.ok(!Object.hasOwn(event, OPERATION_ADMISSION_ASSERTION_EVENT_FIELD));
  assert.deepEqual(calls, ['verify', 'admit', 'invoke']);
  assert.deepEqual(Object.keys(admitted).sort(), ['ledgerKey', 'operationDigest']);
  assert.match(admitted.ledgerKey, /^dial:admission:v1:[A-Za-z0-9_-]{43}$/);
  assert.match(admitted.operationDigest, /^[A-Za-z0-9_-]{43}$/);
  assert.ok(!JSON.stringify(admitted).includes(VOIP_TOKEN));
  assert.ok(!JSON.stringify(admitted).includes('session-v2'));
  assert.ok(!Object.hasOwn(event, 'verifiedIdentity'), 'the proxy never injects a raw trusted-identity field');
});

test('verifier scopes are canonically snapshotted before admission yields and cannot drift into the assertion', async () => {
  const mutableScopes = ['sessions:read', 'pocket:dial'];
  let scopeReads = 0;
  const identity = { principal: IDENTITY.principal, humanId: IDENTITY.humanId };
  Object.defineProperty(identity, 'scopes', {
    enumerable: true,
    get() {
      scopeReads += 1;
      return mutableScopes;
    },
  });

  let forwarded;
  const proxy = createPassingProxy({
    verifyToken: async () => identity,
    admission: {
      admit: async () => {
        mutableScopes.splice(0, mutableScopes.length, 'sessions:write', 'pocket:voice');
        return { admitted: true, replay: false };
      },
    },
    invokeGateway: async (event) => {
      forwarded = event;
      return gatewayResponse();
    },
  });

  assert.equal((await proxy(apiEvent())).statusCode, 200);
  const assertion = forwarded[OPERATION_ADMISSION_ASSERTION_EVENT_FIELD];
  assert.equal(scopeReads, 1);
  assert.deepEqual(assertion.scopes, ['pocket:dial', 'sessions:read']);
  assert.ok(Object.isFrozen(assertion.scopes));
  assert.deepEqual(mutableScopes, ['sessions:write', 'pocket:voice']);
});

test('register and reconcile derive one admission identity with empty scopes and need no membership lookup', async () => {
  const admissions = [];
  const proxy = createPassingProxy({
    verifyToken: async () => ({ principal: IDENTITY.principal, humanId: IDENTITY.humanId, scopes: [] }),
    admission: {
      admit: async (input) => {
        admissions.push(input);
        return { admitted: true, replay: admissions.length > 1 };
      },
    },
  });

  assert.equal((await proxy(apiEvent(registration()))).statusCode, 200);
  assert.equal((await proxy(apiEvent(cleanup(), { path: '/dial/register/reconcile' }))).statusCode, 200);
  assert.equal(admissions.length, 2);
  assert.deepEqual(admissions[1], admissions[0], 'both frozen endpoints share the exact operation tuple');
});

test('unprotected events fail closed without auth, admission, body access, or private invocation', async () => {
  const event = apiEvent('{not-json', { method: 'GET', path: '/sync' });
  let gatewayCalls = 0;
  let bodyReads = 0;
  const body = event.body;
  Object.defineProperty(event, 'body', { enumerable: true, get() { bodyReads += 1; return body; } });
  const proxy = createPassingProxy({
    verifyToken: async () => { throw new Error('must not run'); },
    admission: { admit: async () => { throw new Error('must not run'); } },
    invokeGateway: async () => { gatewayCalls += 1; return gatewayResponse(); },
  });

  const response = await proxy(event);
  assertUnavailable(response);
  assert.equal(bodyReads, 0);
  assert.equal(gatewayCalls, 0);
});

test('client-supplied assertion field fails before auth, body access, admission, or private invocation', async () => {
  const event = {
    ...apiEvent(),
    [OPERATION_ADMISSION_ASSERTION_EVENT_FIELD]: { attacker: true },
  };
  let bodyReads = 0;
  let authCalls = 0;
  let admissionCalls = 0;
  let gatewayCalls = 0;
  const originalBody = event.body;
  Object.defineProperty(event, 'body', {
    enumerable: true,
    get() {
      bodyReads += 1;
      return originalBody;
    },
  });
  const proxy = createPassingProxy({
    verifyToken: async () => { authCalls += 1; return IDENTITY; },
    admission: { admit: async () => { admissionCalls += 1; return { admitted: true, replay: false }; } },
    invokeGateway: async () => { gatewayCalls += 1; return gatewayResponse(); },
  });

  assertUnavailable(await proxy(event));
  assert.equal(bodyReads, 0);
  assert.equal(authCalls, 0);
  assert.equal(admissionCalls, 0);
  assert.equal(gatewayCalls, 0);
});

test('invalid credentials return 401 after a bounded immutable request snapshot and before admission or gateway invocation', async () => {
  let admissionCalls = 0;
  let gatewayCalls = 0;
  const event = apiEvent();
  const proxy = createPassingProxy({
    verifyToken: async () => null,
    admission: { admit: async () => { admissionCalls += 1; } },
    invokeGateway: async () => { gatewayCalls += 1; return gatewayResponse(); },
  });

  const response = await proxy(event);
  assert.equal(response.statusCode, 401);
  assert.deepEqual(responseBody(response), { error: 'authentication required' });
  assert.equal(response.headers['www-authenticate'], 'Bearer');
  assert.equal(admissionCalls, 0);
  assert.equal(gatewayCalls, 0);
});

test('verifier outage or malformed verified identity returns one generic typed 503', async () => {
  const throwingIdentity = {};
  Object.defineProperty(throwingIdentity, 'principal', { get() { throw new Error('hostile verifier result'); } });
  for (const verifyToken of [
    async () => { throw new Error(`upstream failed with ${VOIP_TOKEN}`); },
    async () => ({ humanId: IDENTITY.humanId }),
    async () => ({ principal: IDENTITY.principal, humanId: '' }),
    async () => ({ principal: 'p'.repeat(1025), humanId: IDENTITY.humanId }),
    async () => ({ principal: IDENTITY.principal, humanId: ` ${IDENTITY.humanId}` }),
    async () => ({ principal: IDENTITY.principal, humanId: `${IDENTITY.humanId}\n` }),
    async () => ({ principal: IDENTITY.principal, humanId: 'h'.repeat(1025) }),
    async () => ({ principal: IDENTITY.principal, humanId: IDENTITY.humanId, scopes: null }),
    async () => ({ principal: IDENTITY.principal, humanId: IDENTITY.humanId, scopes: ['not a scope'] }),
    async () => throwingIdentity,
  ]) {
    let admissionCalls = 0;
    const proxy = createPassingProxy({
      verifyToken,
      admission: { admit: async () => { admissionCalls += 1; } },
    });
    const response = await proxy(apiEvent());
    assertUnavailable(response);
    assert.ok(!response.body.includes(VOIP_TOKEN));
    assert.equal(admissionCalls, 0);
  }
});

test('base64 request is decoded strictly for admission and forwarded byte-for-byte', async () => {
  const event = apiEvent(registration(), { base64: true });
  const originalWire = event.body;
  let forwarded;
  const proxy = createPassingProxy({
    invokeGateway: async (input) => { forwarded = input; return gatewayResponse(); },
  });

  assert.equal((await proxy(event)).statusCode, 200);
  assert.notStrictEqual(forwarded, event);
  assert.ok(Object.hasOwn(forwarded, OPERATION_ADMISSION_ASSERTION_EVENT_FIELD));
  assert.equal(forwarded.body, originalWire);
  assert.equal(forwarded.isBase64Encoded, true);
});

test('invalid JSON/base64/UTF-8 is rejected before admission', async () => {
  const cases = [
    apiEvent('{not-json'),
    { ...apiEvent(), body: '%%%%', isBase64Encoded: true },
    { ...apiEvent(), body: Buffer.from([0xff]).toString('base64'), isBase64Encoded: true },
    { ...apiEvent(), body: registration(), isBase64Encoded: false },
    { ...apiEvent(), isBase64Encoded: 'true' },
  ];
  for (const event of cases) {
    let admissionCalls = 0;
    const proxy = createPassingProxy({
      admission: { admit: async () => { admissionCalls += 1; } },
    });
    const response = await proxy(event);
    assert.equal(response.statusCode, 400);
    assert.deepEqual(responseBody(response), { error: 'invalid JSON body' });
    assert.equal(admissionCalls, 0);
  }
});

test('plain and base64 bodies are byte-bounded before JSON parsing or admission', async () => {
  for (const event of [
    { ...apiEvent(), body: 'x'.repeat(65), isBase64Encoded: false },
    { ...apiEvent(), body: Buffer.alloc(65, 0x78).toString('base64'), isBase64Encoded: true },
  ]) {
    let admissionCalls = 0;
    const proxy = createPassingProxy({
      maxBodyBytes: 64,
      admission: { admit: async () => { admissionCalls += 1; } },
    });
    const response = await proxy(event);
    assert.equal(response.statusCode, 413);
    assert.deepEqual(responseBody(response), {
      error: 'registry operation request exceeds 64 bytes',
      reason: 'operation-admission-body-too-large',
    });
    assert.equal(admissionCalls, 0);
  }
  assert.equal(OPERATION_ADMISSION_MAX_BODY_BYTES, 4096);
});

test('frozen body validation errors are returned before admission', async () => {
  let admissionCalls = 0;
  const proxy = createPassingProxy({
    admission: { admit: async () => { admissionCalls += 1; } },
  });
  const missingBody = apiEvent();
  delete missingBody.body;
  const unversioned = await proxy(missingBody);
  assert.equal(unversioned.statusCode, 426);
  assert.deepEqual(responseBody(unversioned), {
    error: 'registrationVersion 2 required',
    reason: 'registration-v2-required',
  });

  const unknown = await proxy(apiEvent(registration({ principal: 'attacker' })));
  assert.equal(unknown.statusCode, 400);
  assert.deepEqual(responseBody(unknown), {
    error: 'unsupported registry field: principal',
    reason: 'registration-v2-required',
  });
  assert.equal(admissionCalls, 0);
});

test('owner mismatch returns the exact generic 409 and allocates nothing', async () => {
  let admissionCalls = 0;
  let gatewayCalls = 0;
  const otherOwner = deriveDeviceOwnerHandle(HMAC_KEY, 'different-principal', IDENTITY.humanId);
  const proxy = createPassingProxy({
    admission: { admit: async () => { admissionCalls += 1; } },
    invokeGateway: async () => { gatewayCalls += 1; return gatewayResponse(); },
  });

  const response = await proxy(apiEvent(registration({ ownerHandle: otherOwner })));
  assert.equal(response.statusCode, 409);
  assert.equal(
    response.body,
    '{"error":"registry owner does not match authenticated principal","reason":"registry-owner-conflict"}',
  );
  assert.equal(admissionCalls, 0);
  assert.equal(gatewayCalls, 0);
});

test('operation limit returns exact 429 with a positive integer Retry-After and never invokes gateway', async () => {
  let gatewayCalls = 0;
  const limited = Object.assign(new Error('do not expose ledger details'), {
    code: 'operation-rate-limited',
    retryAfterSeconds: 2.1,
  });
  const proxy = createPassingProxy({
    admission: { admit: async () => { throw limited; } },
    invokeGateway: async () => { gatewayCalls += 1; return gatewayResponse(); },
  });

  const response = await proxy(apiEvent());
  assert.equal(response.statusCode, 429);
  assert.equal(
    response.body,
    '{"error":"registration operation rate limited","reason":"operation-rate-limited"}',
  );
  assert.equal(response.headers['retry-after'], '3');
  assert.match(response.headers['retry-after'], /^[1-9][0-9]*$/);
  assert.equal(gatewayCalls, 0);
});

test('store failures, invalid limit metadata, and malformed admission decisions return generic 503', async () => {
  const admissions = [
    { admit: async () => { throw new Error(`Dynamo leaked ${VOIP_TOKEN}`); } },
    {
      admit: async () => {
        throw Object.assign(new Error('bad retry'), { code: 'operation-rate-limited', retryAfterSeconds: 0 });
      },
    },
    { admit: async () => null },
    { admit: async () => ({ admitted: true }) },
    { admit: async () => ({ admitted: false, replay: false }) },
    {
      admit: async () => {
        const hostile = { replay: false };
        Object.defineProperty(hostile, 'admitted', { get() { throw new Error('hostile store result'); } });
        return hostile;
      },
    },
  ];
  for (const admission of admissions) {
    let gatewayCalls = 0;
    const proxy = createPassingProxy({
      admission,
      invokeGateway: async () => { gatewayCalls += 1; return gatewayResponse(); },
    });
    const response = await proxy(apiEvent());
    assertUnavailable(response);
    assert.ok(!response.body.includes(VOIP_TOKEN));
    assert.equal(gatewayCalls, 0);
  }
});

test('gateway throw or malformed invoke response becomes generic 503 after admission', async () => {
  const hostileResponse = { body: '{}', headers: {} };
  Object.defineProperty(hostileResponse, 'statusCode', { get() { throw new Error('hostile invoke response'); } });
  const invokeResults = [
    async () => { throw new Error(`Lambda transport leaked ${VOIP_TOKEN}`); },
    async () => null,
    async () => ({ statusCode: 200, body: { not: 'serialized' } }),
    async () => ({ statusCode: 99, body: '{}' }),
    async () => ({ statusCode: 200, body: '{}', headers: [] }),
    async () => ({ statusCode: 200, body: '{}', isBase64Encoded: 'false' }),
    async () => hostileResponse,
  ];
  for (const invokeGateway of invokeResults) {
    let admissionCalls = 0;
    const proxy = createPassingProxy({
      admission: {
        admit: async () => { admissionCalls += 1; return { admitted: true, replay: false }; },
      },
      invokeGateway,
    });
    const response = await proxy(apiEvent());
    assertUnavailable(response);
    assert.ok(!response.body.includes(VOIP_TOKEN));
    assert.equal(admissionCalls, 1, 'the operation is durably admitted before private invocation');
  }
});

test('constructor rejects incomplete dependency injection and invalid byte bounds', () => {
  const valid = {
    hmacKey: HMAC_KEY,
    verifyToken: async () => IDENTITY,
    admission: { admit: async () => ({ admitted: true, replay: false }) },
    createAssertion,
    invokeGateway: async () => gatewayResponse(),
  };
  assert.throws(() => createOperationAdmissionProxy({ ...valid, verifyToken: null }), /verifyToken/);
  assert.throws(() => createOperationAdmissionProxy({ ...valid, admission: null }), /admission\.admit/);
  assert.throws(() => createOperationAdmissionProxy({ ...valid, createAssertion: null }), /createAssertion/);
  assert.throws(() => createOperationAdmissionProxy({ ...valid, invokeGateway: null }), /invokeGateway/);
  assert.throws(() => createOperationAdmissionProxy({ ...valid, hmacKey: undefined }), /hmacKey/);
  assert.throws(() => createOperationAdmissionProxy({ ...valid, maxBodyBytes: 0 }), /maxBodyBytes/);
  assert.throws(
    () => createOperationAdmissionProxy({ ...valid, maxBodyBytes: OPERATION_ADMISSION_MAX_BODY_BYTES + 1 }),
    /maxBodyBytes/,
  );
});
