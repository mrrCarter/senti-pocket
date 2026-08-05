import assert from 'node:assert/strict';
import test from 'node:test';

import { deriveDeviceOwnerHandle } from '../src/device-registry-v2.mjs';
import {
  DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID_MAX_BYTES,
  DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID_MIN_BYTES,
  REGISTRY_OPERATION_ADMISSION_AUTH_MODE,
  createOperationAdmissionApp,
  createReusableSentiSessionVerifierGuard,
} from '../src/operation-admission-app.mjs';
import { createOperationAdmissionProxy } from '../src/operation-admission-proxy.mjs';
import {
  createOperationAdmissionAssertionVerifier,
  isOperationAdmissionAssertionContext,
  OPERATION_ADMISSION_ASSERTION_EVENT_FIELD,
} from '../src/operation-admission-assertion.mjs';

const HMAC_KEY = Buffer.alloc(32, 0x61);
const HMAC_VERSION_ID = '0123456789abcdef0123456789abcdef';
const HMAC_SECRET_ARN = 'arn:aws:secretsmanager:us-east-1:123456789012:secret:senti-pocket-registry-hmac-AbCdEf';
const HUMAN_ID = 'user_42';
const PRINCIPAL = 'pocket.principal.senti.v1\n7:user_42';
const INSTALLATION_ID = Buffer.alloc(32, 0x42).toString('base64url');
const GATEWAY_VERSION_ARN = 'arn:aws:lambda:us-east-1:123456789012:function:senti-pocket-gateway:42';

function validEnv(overrides = {}) {
  return {
    REGISTRY_OPERATION_ADMISSION_AUTH_MODE,
    SENTI_API_BASE_URL: 'https://api.sentinelayer.example',
    OPERATION_ADMISSION_DDB_TABLE: 'operation-admission-test',
    DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID: HMAC_VERSION_ID,
    DEVICE_REGISTRY_HMAC_SECRET_ARN: HMAC_SECRET_ARN,
    GATEWAY_LAMBDA_VERSION_ARN: GATEWAY_VERSION_ARN,
    ...overrides,
  };
}

function memoryDynamoClient() {
  const records = new Map();
  const calls = [];
  const keyOf = ({ pk, sk }) => `${pk}\u0000${sk}`;
  return {
    calls,
    async get(params) {
      calls.push({ method: 'get', params });
      const Item = records.get(keyOf(params.Key));
      return Item ? { Item } : {};
    },
    async put(params) {
      calls.push({ method: 'put', params });
      records.set(keyOf(params.Item), params.Item);
      return {};
    },
    async delete(params) {
      calls.push({ method: 'delete', params });
      records.delete(keyOf(params.Key));
      return {};
    },
  };
}

function validDependencies(overrides = {}) {
  return {
    fetch: async () => ({ ok: true, status: 200, json: async () => ({ id: HUMAN_ID }) }),
    dynamoClient: memoryDynamoClient(),
    invokeGateway: async () => ({ statusCode: 200, headers: {}, body: '{"ok":true}' }),
    hmacKey: HMAC_KEY,
    hmacKeyVersionId: HMAC_VERSION_ID,
    now: () => 1_800_000_000_000,
    retryDelay: async () => {},
    ...overrides,
  };
}

function registration() {
  return {
    registrationVersion: 2,
    ownerVersion: 1,
    ownerHandle: deriveDeviceOwnerHandle(HMAC_KEY, PRINCIPAL, HUMAN_ID),
    installationId: INSTALLATION_ID,
    idempotencyKey: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    voipToken: 'private-routing-token',
    sessionId: 'session-v2',
    platform: 'apns',
  };
}

function apiEvent(headers = { authorization: 'Bearer reusable-senti-session' }) {
  return {
    version: '2.0',
    rawPath: '/dial/register',
    headers,
    requestContext: { http: { method: 'POST', path: '/dial/register' } },
    body: JSON.stringify(registration()),
    isBase64Encoded: false,
  };
}

function assertUnavailable(response) {
  assert.equal(response.statusCode, 503);
  assert.deepEqual(JSON.parse(response.body), {
    error: 'registration operation admission unavailable',
    reason: 'operation-admission-unavailable',
  });
}

test('reusable Senti bearer is verified once and becomes a request-bound private-gateway assertion', async () => {
  const fetchCalls = [];
  const fetch = async (url, init) => {
    fetchCalls.push({ url, init });
    return { ok: true, status: 200, json: async () => ({ id: HUMAN_ID }) };
  };
  const assertionVerifier = createOperationAdmissionAssertionVerifier({
    hmacKey: HMAC_KEY.toString('base64'),
    kid: HMAC_VERSION_ID,
    secretArn: HMAC_SECRET_ARN,
    audience: GATEWAY_VERSION_ARN,
    now: () => 1_800_000_000_000,
    replayGuard: { seen: async () => false },
  });
  const dynamoClient = memoryDynamoClient();
  const event = apiEvent();
  const originalBody = event.body;
  let forwarded;
  const expected = {
    statusCode: 202,
    headers: { 'content-type': 'application/json' },
    body: '{"accepted":true}',
    isBase64Encoded: false,
  };

  const handler = createOperationAdmissionApp(validEnv(), validDependencies({
    fetch,
    dynamoClient,
    invokeGateway: async (received) => {
      forwarded = received;
      const identity = await assertionVerifier.verify(received);
      assert.ok(isOperationAdmissionAssertionContext(identity));
      assert.equal(identity.tokenClaims.authMethod, 'senti_session');
      assert.equal(identity.tokenClaims.via, 'operation_admission_assertion');
      assert.equal(identity.principal, PRINCIPAL);
      return expected;
    },
  }));

  const response = await handler(event);

  assert.strictEqual(response, expected);
  assert.notStrictEqual(forwarded, event, 'the private gateway receives a shallow assertion-bearing clone');
  assert.strictEqual(forwarded.headers, event.headers);
  assert.ok(Object.hasOwn(forwarded, OPERATION_ADMISSION_ASSERTION_EVENT_FIELD));
  assert.ok(!Object.hasOwn(event, OPERATION_ADMISSION_ASSERTION_EVENT_FIELD));
  assert.equal(forwarded.body, originalBody, 'the original body string is not normalized or replaced');
  assert.equal(fetchCalls.length, 1, 'only admission calls /auth/me; the gateway verifies the internal assertion');
  assert.ok(fetchCalls.every((call) => call.init.headers.authorization === event.headers.authorization));
  assert.deepEqual(dynamoClient.calls.map((call) => call.method), ['get', 'put']);
});

test('invalid credentials return 401 while verifier outages return the generic 503 before Dynamo or invoke', async () => {
  const cases = [
    {
      name: 'missing bearer',
      headers: {},
      fetch: async () => { throw new Error('must not call'); },
      expectedStatus: 401,
    },
    {
      name: 'rejected bearer',
      headers: { authorization: 'Bearer rejected' },
      fetch: async () => ({ ok: false, status: 401, json: async () => ({}) }),
      expectedStatus: 401,
    },
    {
      name: 'transport outage',
      headers: { authorization: 'Bearer secret-transport' },
      fetch: async () => { throw new Error('upstream leaked secret-transport'); },
      expectedStatus: 503,
    },
    {
      name: 'upstream outage',
      headers: { authorization: 'Bearer secret-upstream' },
      fetch: async () => ({ ok: false, status: 500, json: async () => ({ detail: 'secret-upstream' }) }),
      expectedStatus: 503,
    },
    {
      name: 'malformed verifier contract',
      headers: { authorization: 'Bearer secret-contract' },
      fetch: async () => ({ ok: true, status: 200, json: async () => ({ email: 'missing-id' }) }),
      expectedStatus: 503,
    },
  ];

  for (const scenario of cases) {
    const dynamoClient = memoryDynamoClient();
    let invokeCalls = 0;
    const handler = createOperationAdmissionApp(validEnv(), validDependencies({
      fetch: scenario.fetch,
      dynamoClient,
      invokeGateway: async () => {
        invokeCalls += 1;
        return { statusCode: 200, body: '{}' };
      },
    }));
    const response = await handler(apiEvent(scenario.headers));
    assert.equal(response.statusCode, scenario.expectedStatus, scenario.name);
    if (scenario.expectedStatus === 503) assertUnavailable(response);
    if (scenario.expectedStatus === 401) {
      assert.deepEqual(JSON.parse(response.body), { error: 'authentication required' });
    }
    assert.equal(dynamoClient.calls.length, 0, `${scenario.name}: admission store must not run`);
    assert.equal(invokeCalls, 0, `${scenario.name}: private gateway must not run`);
    assert.ok(!response.body.includes('secret-'), `${scenario.name}: verifier details must not leak`);
  }
});

test('DPoP and every non-Senti verifier identity fail before admission', async () => {
  const hostile = { principal: PRINCIPAL, humanId: HUMAN_ID };
  Object.defineProperty(hostile, 'tokenClaims', {
    enumerable: true,
    get() { throw new Error('hostile claims'); },
  });
  const identities = [
    { principal: PRINCIPAL, humanId: HUMAN_ID, tokenClaims: { authMethod: 'dpop' } },
    { principal: PRINCIPAL, humanId: HUMAN_ID, tokenClaims: { authMethod: 'aidenid_dpop' } },
    { principal: PRINCIPAL, humanId: HUMAN_ID, tokenClaims: {} },
    { principal: PRINCIPAL, humanId: HUMAN_ID },
    hostile,
    'not-an-identity',
  ];

  for (const identity of identities) {
    let admissionCalls = 0;
    let invokeCalls = 0;
    const proxy = createOperationAdmissionProxy({
      hmacKey: HMAC_KEY,
      verifyToken: createReusableSentiSessionVerifierGuard(async () => identity),
      admission: {
        admit: async () => {
          admissionCalls += 1;
          return { admitted: true, replay: false };
        },
      },
      createAssertion: () => { throw new Error('must not sign'); },
      invokeGateway: async () => {
        invokeCalls += 1;
        return { statusCode: 200, body: '{}' };
      },
    });
    assertUnavailable(await proxy(apiEvent()));
    assert.equal(admissionCalls, 0);
    assert.equal(invokeCalls, 0);
  }
});

test('boot requires the explicit reusable auth mode and matching immutable HMAC version metadata', () => {
  const badCases = [
    [validEnv({ REGISTRY_OPERATION_ADMISSION_AUTH_MODE: undefined }), validDependencies(), /AUTH_MODE/],
    [validEnv({ REGISTRY_OPERATION_ADMISSION_AUTH_MODE: 'dpop_single_use_v1' }), validDependencies(), /AUTH_MODE/],
    [validEnv({ DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID: undefined }), validDependencies(), /VERSION_ID/],
    [validEnv({ DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID: ' version' }), validDependencies(), /VERSION_ID/],
    [validEnv({ DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID: 'a'.repeat(DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID_MAX_BYTES + 1) }), validDependencies(), /VERSION_ID/],
    [validEnv({ GATEWAY_LAMBDA_VERSION_ARN: undefined }), validDependencies(), /GATEWAY_LAMBDA_VERSION_ARN/],
    [validEnv(), validDependencies({ hmacKeyVersionId: undefined }), /hmacKeyVersionId/],
    [validEnv(), validDependencies({ hmacKeyVersionId: 'fedcba9876543210fedcba9876543210' }), /does not match/],
    [validEnv(), validDependencies({ hmacKeyVersionId: 'bad version' }), /hmacKeyVersionId/],
    [validEnv(), validDependencies({ hmacKeyVersionId: 'a'.repeat(DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID_MIN_BYTES - 1) }), /hmacKeyVersionId/],
    [validEnv(), validDependencies({ hmacKeyVersionId: `${'a'.repeat(DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID_MIN_BYTES - 1)}_` }), /hmacKeyVersionId/],
    [validEnv(), validDependencies({ hmacKey: Buffer.alloc(31) }), /HMAC key is invalid/],
  ];
  for (const [env, dependencies, pattern] of badCases) {
    assert.throws(() => createOperationAdmissionApp(env, dependencies), pattern);
  }
});

test('HMAC secret VersionId accepts the exact AWS 32 and 64 character boundaries', () => {
  const minVersion = 'a'.repeat(DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID_MIN_BYTES);
  const maxVersion = 'Z'.repeat(DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID_MAX_BYTES);
  assert.equal(typeof createOperationAdmissionApp(
    validEnv({ DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID: minVersion }),
    validDependencies({ hmacKeyVersionId: minVersion }),
  ), 'function');
  assert.equal(typeof createOperationAdmissionApp(
    validEnv({ DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID: maxVersion }),
    validDependencies({ hmacKeyVersionId: maxVersion }),
  ), 'function');
});

test('boot snapshots mutable HMAC Buffer material before serving requests', async () => {
  const mutableKey = Buffer.alloc(32, 0x73);
  const event = apiEvent();
  event.body = JSON.stringify({
    ...registration(),
    ownerHandle: deriveDeviceOwnerHandle(mutableKey, PRINCIPAL, HUMAN_ID),
  });
  const handler = createOperationAdmissionApp(validEnv(), validDependencies({ hmacKey: mutableKey }));

  mutableKey.fill(0);

  assert.equal((await handler(event)).statusCode, 200);
});

test('boot rejects missing transport dependencies and noncanonical required strings', () => {
  assert.throws(
    () => createOperationAdmissionApp(validEnv({ SENTI_API_BASE_URL: ' ' }), validDependencies()),
    /SENTI_API_BASE_URL/,
  );
  assert.throws(
    () => createOperationAdmissionApp(validEnv({ OPERATION_ADMISSION_DDB_TABLE: '' }), validDependencies()),
    /OPERATION_ADMISSION_DDB_TABLE/,
  );
  for (const value of [
    'http://api.sentinelayer.example',
    'https://user:pass@api.sentinelayer.example',
    'https://api.sentinelayer.example/v1',
    'https://api.sentinelayer.example?tenant=x',
    'https://api.sentinelayer.example#fragment',
    'not-a-url',
  ]) {
    assert.throws(
      () => createOperationAdmissionApp(validEnv({ SENTI_API_BASE_URL: value }), validDependencies()),
      /SENTI_API_BASE_URL/,
    );
  }
  assert.throws(() => createOperationAdmissionApp(validEnv(), validDependencies({ fetch: null })), /fetch/);
  assert.throws(() => createOperationAdmissionApp(validEnv(), validDependencies({ dynamoClient: {} })), /Dynamo/);
  assert.throws(() => createOperationAdmissionApp(validEnv(), validDependencies({ invokeGateway: null })), /invoker/);
});
