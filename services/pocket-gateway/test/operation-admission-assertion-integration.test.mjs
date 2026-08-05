import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync } from 'node:crypto';
import test from 'node:test';

import { createLambda } from '../src/app.mjs';
import { deriveDeviceOwnerHandle } from '../src/device-registry-v2.mjs';
import { createGateway } from '../src/handlers.mjs';
import { lambdaHandler } from '../src/lambda.mjs';
import {
  createOperationAdmissionAssertionSigner,
  createOperationAdmissionAssertionVerifier,
  isOperationAdmissionAssertionContext,
  OPERATION_ADMISSION_ASSERTION_EVENT_FIELD,
  snapshotOperationAdmissionRawRequest,
} from '../src/operation-admission-assertion.mjs';
import { createOperationAdmissionProxy } from '../src/operation-admission-proxy.mjs';
import {
  createOperationAdmissionApp,
  REGISTRY_OPERATION_ADMISSION_AUTH_MODE,
} from '../src/operation-admission-app.mjs';
import { deriveRegistryOperationAdmissionIdentity } from '../src/operation-admission.mjs';

const HMAC_KEY = Buffer.alloc(32, 0x51);
const HMAC_KEY_B64 = HMAC_KEY.toString('base64');
const KID = '0123456789abcdef0123456789abcdef';
const SECRET_ARN = 'arn:aws:secretsmanager:us-east-1:123456789012:secret:senti-pocket-registry-hmac-AbCdEf';
const AUDIENCE = 'arn:aws:lambda:us-east-1:123456789012:function:senti-pocket-gateway:42';
const NOW_MS = Date.parse('2026-08-05T04:00:00.000Z');
const PRINCIPAL = 'pocket.principal.senti.v1\n7:user_42';
const HUMAN_ID = 'user_42';
const INSTALLATION_ID = Buffer.alloc(32, 0x42).toString('base64url');

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

function event() {
  return {
    version: '2.0',
    rawPath: '/dial/register',
    headers: { authorization: 'Bearer reusable-senti-session' },
    requestContext: { http: { method: 'POST', path: '/dial/register' } },
    body: JSON.stringify(registration()),
    isBase64Encoded: false,
  };
}

function unavailableBody(response) {
  return JSON.parse(response.body);
}

function memoryDynamo() {
  const records = new Map();
  const puts = [];
  const keyOf = ({ pk, sk }) => `${pk}\u0000${sk}`;
  return {
    puts,
    async get(params) {
      const Item = records.get(keyOf(params.Key));
      return Item ? { Item } : {};
    },
    async put(params) {
      const key = keyOf(params.Item);
      if (params.ConditionExpression?.includes('attribute_not_exists(pk)') && records.has(key)) {
        const error = new Error('conditional conflict');
        error.name = 'ConditionalCheckFailedException';
        throw error;
      }
      puts.push(params);
      records.set(key, structuredClone(params.Item));
      return {};
    },
    async delete(params) {
      records.delete(keyOf(params.Key));
      return {};
    },
    async transactWrite() {
      return {};
    },
  };
}

test('admission -> private Lambda -> gateway performs exactly one reusable-session verification', async () => {
  const signer = createOperationAdmissionAssertionSigner({
    hmacKey: HMAC_KEY_B64,
    kid: KID,
    secretArn: SECRET_ARN,
    audience: AUDIENCE,
    now: () => NOW_MS,
    randomBytes: () => Buffer.alloc(32, 0x7c),
  });
  const verifier = createOperationAdmissionAssertionVerifier({
    hmacKey: HMAC_KEY_B64,
    kid: KID,
    secretArn: SECRET_ARN,
    audience: AUDIENCE,
    now: () => NOW_MS,
    replayGuard: { seen: async () => false },
  });
  let admissionAuthCalls = 0;
  let gatewayAuthCalls = 0;
  const gateway = createGateway({
    requireOperationAdmissionAssertion: true,
    verifyToken: async () => {
      gatewayAuthCalls += 1;
      throw new Error('protected V2 routes must never fall back to /auth/me');
    },
    knownSessionIdsFor: async () => ['session-v2'],
  });
  const privateLambda = lambdaHandler(gateway, {
    requireOperationAdmissionAssertion: true,
    verifyOperationAdmissionAssertion: (privateEvent, context) => {
      assert.equal(context.invokedFunctionArn, AUDIENCE);
      return verifier.verify(privateEvent);
    },
  });
  const admission = createOperationAdmissionProxy({
    hmacKey: HMAC_KEY,
    verifyToken: async () => {
      admissionAuthCalls += 1;
      return {
        principal: PRINCIPAL,
        humanId: HUMAN_ID,
        scopes: ['pocket:dial'],
        tokenClaims: { authMethod: 'senti_session' },
      };
    },
    admission: { admit: async () => ({ admitted: true, replay: false }) },
    createAssertion: (input) => signer.sign(input),
    invokeGateway: (privateEvent) => privateLambda(privateEvent, { invokedFunctionArn: AUDIENCE }),
  });

  const response = await admission(event());

  assert.equal(response.statusCode, 501, 'a valid assertion reaches the V2 handler; this fixture omits its registry backend');
  assert.equal(admissionAuthCalls, 1);
  assert.equal(gatewayAuthCalls, 0);
});

test('private Lambda handles only the verifier-frozen request when replay storage yields', async () => {
  const publicEvent = event();
  const originalBody = publicEvent.body;
  const originalAuthorization = publicEvent.headers.authorization;
  const signer = createOperationAdmissionAssertionSigner({
    hmacKey: HMAC_KEY_B64,
    kid: KID,
    secretArn: SECRET_ARN,
    audience: AUDIENCE,
    now: () => NOW_MS,
    randomBytes: () => Buffer.alloc(32, 0x7c),
  });
  const snapshot = snapshotOperationAdmissionRawRequest(publicEvent);
  const derived = deriveRegistryOperationAdmissionIdentity({
    method: snapshot.method,
    path: snapshot.path,
    body: snapshot.parsedBody,
    principal: PRINCIPAL,
    humanId: HUMAN_ID,
    hmacKey: HMAC_KEY,
  });
  const assertion = signer.sign({
    snapshot,
    principal: PRINCIPAL,
    humanId: HUMAN_ID,
    scopes: ['pocket:dial'],
    ownerHandle: registration().ownerHandle,
    operationDigest: derived.operationDigest,
  });

  let enterReplay;
  const replayEntered = new Promise((resolve) => { enterReplay = resolve; });
  let releaseReplay;
  const replayRelease = new Promise((resolve) => { releaseReplay = resolve; });
  const verifier = createOperationAdmissionAssertionVerifier({
    hmacKey: HMAC_KEY_B64,
    kid: KID,
    secretArn: SECRET_ARN,
    audience: AUDIENCE,
    now: () => NOW_MS,
    replayGuard: {
      async seen() {
        enterReplay();
        await replayRelease;
        return false;
      },
    },
  });

  let handledRequest;
  const handler = lambdaHandler({
    handle: async (request) => {
      handledRequest = request;
      return { status: 200, body: { ok: true } };
    },
  }, {
    canonicalBaseUrl: 'https://pocket.example.com',
    requireOperationAdmissionAssertion: true,
    verifyOperationAdmissionAssertion: (privateEvent) => verifier.verify(privateEvent),
  });
  const privateEvent = {
    ...publicEvent,
    headers: { ...publicEvent.headers },
    [OPERATION_ADMISSION_ASSERTION_EVENT_FIELD]: assertion,
  };

  const pending = handler(privateEvent, { invokedFunctionArn: AUDIENCE });
  await replayEntered;
  privateEvent.body = JSON.stringify({ ...registration(), sessionId: 'mutated-after-verification' });
  privateEvent.headers.authorization = 'Bearer mutated-after-verification';
  releaseReplay();

  assert.equal((await pending).statusCode, 200);
  assert.equal(handledRequest.body, originalBody);
  assert.equal(handledRequest.headers.authorization, originalAuthorization);
  assert.ok(Object.isFrozen(handledRequest));
  assert.ok(Object.isFrozen(handledRequest.headers));
});

test('private Lambda rejects missing assertion, wrong audience, and route confusion before gateway work', async () => {
  const verifierFor = (audience) => createOperationAdmissionAssertionVerifier({
    hmacKey: HMAC_KEY_B64,
    kid: KID,
    secretArn: SECRET_ARN,
    audience,
    now: () => NOW_MS,
    replayGuard: { seen: async () => false },
  });
  let gatewayCalls = 0;
  const handler = lambdaHandler({
    handle: async () => {
      gatewayCalls += 1;
      return { status: 200, body: { ok: true } };
    },
  }, {
    requireOperationAdmissionAssertion: true,
    verifyOperationAdmissionAssertion: (privateEvent, context) =>
      verifierFor(context?.invokedFunctionArn).verify(privateEvent),
  });

  for (const [candidate, context] of [
    [event(), { invokedFunctionArn: AUDIENCE }],
    [event(), undefined],
  ]) {
    const response = await handler(candidate, context);
    assert.equal(response.statusCode, 503);
    assert.deepEqual(unavailableBody(response), {
      error: 'registration operation admission unavailable',
      reason: 'operation-admission-unavailable',
    });
  }

  const signer = createOperationAdmissionAssertionSigner({
    hmacKey: HMAC_KEY_B64,
    kid: KID,
    secretArn: SECRET_ARN,
    audience: AUDIENCE,
    now: () => NOW_MS,
    randomBytes: () => Buffer.alloc(32, 0x7c),
  });
  const publicEvent = event();
  const snapshot = snapshotOperationAdmissionRawRequest(publicEvent);
  const assertion = signer.sign({
    snapshot,
    principal: PRINCIPAL,
    humanId: HUMAN_ID,
    scopes: ['pocket:dial'],
    ownerHandle: registration().ownerHandle,
    operationDigest: deriveRegistryOperationAdmissionIdentity({
      method: 'POST',
      path: '/dial/register',
      body: registration(),
      principal: PRINCIPAL,
      humanId: HUMAN_ID,
      hmacKey: HMAC_KEY,
    }).operationDigest,
  });
  const signedForNumericVersion = {
    ...publicEvent,
    [OPERATION_ADMISSION_ASSERTION_EVENT_FIELD]: assertion,
  };
  assert.equal((await handler(signedForNumericVersion, {
    invokedFunctionArn: AUDIENCE.replace(/:42$/, ':43'),
  })).statusCode, 503, 'an assertion for one immutable numeric version cannot authorize another');
  const confused = {
    ...publicEvent,
    rawPath: '/health',
    requestContext: { http: { method: 'GET', path: '/health' } },
    [OPERATION_ADMISSION_ASSERTION_EVENT_FIELD]: assertion,
  };
  assert.equal((await handler(confused, { invokedFunctionArn: AUDIENCE })).statusCode, 503);
  assert.equal(gatewayCalls, 0);
});

test('gateway requires the private verifier brand and never accepts a structural identity clone', async () => {
  const signer = createOperationAdmissionAssertionSigner({
    hmacKey: HMAC_KEY_B64,
    kid: KID,
    secretArn: SECRET_ARN,
    audience: AUDIENCE,
    now: () => NOW_MS,
    randomBytes: () => Buffer.alloc(32, 0x7c),
  });
  const verifier = createOperationAdmissionAssertionVerifier({
    hmacKey: HMAC_KEY_B64,
    kid: KID,
    secretArn: SECRET_ARN,
    audience: AUDIENCE,
    now: () => NOW_MS,
    replayGuard: { seen: async () => false },
  });
  const publicEvent = event();
  const body = registration();
  const operationDigest = deriveRegistryOperationAdmissionIdentity({
    method: 'POST',
    path: '/dial/register',
    body,
    principal: PRINCIPAL,
    humanId: HUMAN_ID,
    hmacKey: HMAC_KEY,
  }).operationDigest;
  const assertion = signer.sign({
    snapshot: snapshotOperationAdmissionRawRequest(publicEvent),
    principal: PRINCIPAL,
    humanId: HUMAN_ID,
    scopes: ['pocket:dial'],
    ownerHandle: body.ownerHandle,
    operationDigest,
  });
  const branded = await verifier.verify({ ...publicEvent, [OPERATION_ADMISSION_ASSERTION_EVENT_FIELD]: assertion });
  assert.ok(isOperationAdmissionAssertionContext(branded));

  let authCalls = 0;
  const gateway = createGateway({
    requireOperationAdmissionAssertion: true,
    verifyToken: async () => {
      authCalls += 1;
      return branded;
    },
    knownSessionIdsFor: async () => ['session-v2'],
  });
  const request = {
    method: 'POST',
    path: '/dial/register',
    headers: publicEvent.headers,
    body: publicEvent.body,
  };

  assert.equal((await gateway.handle(request)).status, 503);
  assert.equal((await gateway.handle(request, { ...branded })).status, 503);
  assert.equal((await gateway.handle({ method: 'GET', path: '/health', headers: {} }, branded)).status, 503);
  assert.equal((await gateway.handle(request, branded)).status, 501);
  assert.equal(authCalls, 0);
});

test('production admission app -> createLambda validates once, atomically consumes proof, and rejects exact replay', async () => {
  const gatewayDynamo = memoryDynamo();
  const admissionDynamo = memoryDynamo();
  let authCalls = 0;
  let denialMutations = 0;
  const fetch = async (url) => {
    assert.match(url, /\/api\/v1\/auth\/me$/);
    authCalls += 1;
    return { ok: true, status: 200, json: async () => ({ id: HUMAN_ID }) };
  };
  const deviceRegistry = {
    protocolVersion: 2,
    operationOutcomeVersion: 1,
    async registrationContext() {
      return { registrationVersion: 2, ownerVersion: 1, ownerHandle: registration().ownerHandle };
    },
    async register() {
      throw new Error('cleanup route must not register');
    },
    async reconcileRegistration() {
      return null;
    },
    async denyRegistration(input) {
      denialMutations += 1;
      return { state: 'denied', ownerVersion: input.ownerVersion, ownerHandle: input.ownerHandle };
    },
    async unregister() {
      return { removed: false, ownerVersion: 1, ownerHandle: registration().ownerHandle };
    },
    async lookup() {
      return [];
    },
  };
  const gatewayEnv = {
    DDB_TABLE: 'pocket-gateway-test',
    SIGNING_KEY_ID: 'test-signing-key',
    GATEWAY_PUBLIC_URL: 'https://pocket.example.com',
    SENTI_API_BASE_URL: 'https://api.example.com',
    DEVICE_REGISTRY_MODE: 'v2',
    DEVICE_REGISTRY_V1_PURGED: '1',
    DEVICE_REGISTRY_CLIENT_V2_READY: '1',
    DEVICE_REGISTRY_OUTCOME_PROTOCOL_READY: '1',
    DEVICE_REGISTRY_OWNER_CONTINUITY_READY: '1',
    DEVICE_REGISTRY_HMAC_KEY_B64: HMAC_KEY_B64,
    DEVICE_REGISTRY_HMAC_SECRET_ARN: SECRET_ARN,
    DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID: KID,
    AWS_LAMBDA_FUNCTION_VERSION: '42',
  };
  const privateLambda = createLambda(gatewayEnv, {
    dynamoClient: gatewayDynamo,
    signingKey: generateKeyPairSync('ed25519').privateKey,
    knownSessionIdsFor: async () => ['session-v2'],
    fetch,
    deviceRegistry,
    now: () => NOW_MS,
  });
  let privateEvent;
  const admission = createOperationAdmissionApp({
    REGISTRY_OPERATION_ADMISSION_AUTH_MODE,
    SENTI_API_BASE_URL: 'https://api.example.com',
    OPERATION_ADMISSION_DDB_TABLE: 'operation-admission-test',
    DEVICE_REGISTRY_HMAC_SECRET_ARN: SECRET_ARN,
    DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID: KID,
    GATEWAY_LAMBDA_VERSION_ARN: AUDIENCE,
  }, {
    fetch,
    dynamoClient: admissionDynamo,
    hmacKey: HMAC_KEY,
    hmacKeyVersionId: KID,
    now: () => NOW_MS,
    retryDelay: async () => {},
    randomBytes: () => Buffer.alloc(32, 0x7c),
    invokeGateway: async (received) => {
      privateEvent = received;
      return privateLambda(received, { invokedFunctionArn: AUDIENCE });
    },
  });
  const body = registration();
  const cleanupBody = {
    registrationVersion: 2,
    ownerVersion: 1,
    ownerHandle: body.ownerHandle,
    installationId: body.installationId,
    idempotencyKey: body.idempotencyKey,
    tokenDigest: createHash('sha256').update(body.voipToken, 'utf8').digest('base64url'),
    sessionId: body.sessionId,
    platform: body.platform,
  };
  const publicEvent = {
    ...event(),
    rawPath: '/dial/register/reconcile',
    requestContext: { http: { method: 'POST', path: '/dial/register/reconcile' } },
    body: JSON.stringify(cleanupBody),
  };

  const response = await admission(publicEvent);
  assert.equal(response.statusCode, 200);
  assert.equal(authCalls, 1, 'only public admission may call /auth/me');
  assert.equal(denialMutations, 1);
  assert.ok(privateEvent);

  const assertion = privateEvent[OPERATION_ADMISSION_ASSERTION_EVENT_FIELD];
  const replayPut = gatewayDynamo.puts.find((call) =>
    call.Item.pk === `operation-admission-assertion-jti:v1:${assertion.jti}`);
  assert.ok(replayPut, 'the private gateway records the jti through one conditional write');
  assert.equal(replayPut.ConditionExpression, 'attribute_not_exists(pk)');
  assert.equal(replayPut.Item.ttl, assertion.exp);
  assert.equal(replayPut.Item.value.exp, assertion.exp);

  const replay = await privateLambda(privateEvent, { invokedFunctionArn: AUDIENCE });
  assert.equal(replay.statusCode, 503);
  assert.deepEqual(unavailableBody(replay), {
    error: 'registration operation admission unavailable',
    reason: 'operation-admission-unavailable',
  });
  assert.equal(authCalls, 1);
  assert.equal(denialMutations, 1, 'replayed capability is rejected before registry mutation');
});
