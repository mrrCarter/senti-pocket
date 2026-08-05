import { test } from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync } from 'node:crypto';

import { createLambda } from '../src/app.mjs';
import { OPERATION_ADMISSION_ASSERTION_SCHEMA } from '../src/operation-admission-assertion.mjs';
import {
  lambdaHandler,
  OPERATION_ADMISSION_ATTESTATION_REQUEST_SCHEMA,
} from '../src/lambda.mjs';

const INVOKED_FUNCTION_ARN =
  'arn:aws:lambda:us-east-1:123456789012:function:senti-pocket-gateway:42';
const HMAC_SECRET_ARN =
  'arn:aws:secretsmanager:us-east-1:123456789012:secret:senti-pocket-registry-hmac-AbCdEf';
const HMAC_SECRET_VERSION_ID = '0123456789abcdef0123456789abcdef';

function fixture() {
  const calls = {
    fetch: 0,
    knownSessions: 0,
    get: 0,
    put: 0,
    delete: 0,
    transactWrite: 0,
    registry: 0,
  };
  const env = {
    DDB_TABLE: 'pocket-gateway',
    SIGNING_KEY_ID: 'kms-key-1',
    GATEWAY_PUBLIC_URL: 'https://pocket-api.sentinelayer.com',
    SENTI_API_BASE_URL: 'https://api.sentinelayer.com',
    DEVICE_REGISTRY_MODE: 'v2',
    DEVICE_REGISTRY_V1_PURGED: '1',
    DEVICE_REGISTRY_CLIENT_V2_READY: '1',
    DEVICE_REGISTRY_OUTCOME_PROTOCOL_READY: '1',
    DEVICE_REGISTRY_OWNER_CONTINUITY_READY: '1',
    DEVICE_REGISTRY_HMAC_KEY_B64: Buffer.alloc(32, 0x51).toString('base64'),
    DEVICE_REGISTRY_HMAC_SECRET_ARN: HMAC_SECRET_ARN,
    DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID: HMAC_SECRET_VERSION_ID,
    AWS_LAMBDA_FUNCTION_VERSION: '42',
    UNRELATED_PRIVATE_ENV: 'must-never-egress',
  };
  const dynamoClient = {
    async get() { calls.get += 1; return {}; },
    async put() { calls.put += 1; return {}; },
    async delete() { calls.delete += 1; return {}; },
    async transactWrite() { calls.transactWrite += 1; return {}; },
  };
  const deviceRegistry = {
    protocolVersion: 2,
    operationOutcomeVersion: 1,
    async registrationContext() { calls.registry += 1; return {}; },
    async register() { calls.registry += 1; },
    async reconcileRegistration() { calls.registry += 1; return null; },
    async denyRegistration() { calls.registry += 1; return {}; },
    async unregister() { calls.registry += 1; return {}; },
    async lookup() { calls.registry += 1; return []; },
  };
  const deps = {
    dynamoClient,
    deviceRegistry,
    signingKey: generateKeyPairSync('ed25519').privateKey,
    async knownSessionIdsFor() { calls.knownSessions += 1; return []; },
    async fetch() {
      calls.fetch += 1;
      throw new Error('attestation must not authenticate or call an application backend');
    },
  };
  return { calls, env, handler: createLambda(env, deps) };
}

function exactControlEvent() {
  // Inherited HTTP accessors prove the control event returns before request normalization. They are deliberately not
  // own keys: the accepted wire object still owns exactly the one `schema` field.
  const event = Object.create({
    get requestContext() { throw new Error('HTTP normalization ran'); },
    get httpMethod() { throw new Error('HTTP normalization ran'); },
    get headers() { throw new Error('HTTP normalization ran'); },
    get body() { throw new Error('HTTP normalization ran'); },
  });
  Object.defineProperty(event, 'schema', {
    configurable: false,
    enumerable: true,
    value: OPERATION_ADMISSION_ATTESTATION_REQUEST_SCHEMA,
    writable: false,
  });
  return event;
}

test('createLambda returns the exact frozen runtime attestation allowlist before auth/store/HTTP work', async () => {
  const { calls, env, handler } = fixture();

  env.AWS_LAMBDA_FUNCTION_VERSION = '999';
  env.DEVICE_REGISTRY_HMAC_SECRET_ARN = 'arn:changed';
  env.DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID = 'changed';
  env.DEVICE_REGISTRY_CLIENT_V2_READY = '0';

  const result = await handler(exactControlEvent(), { invokedFunctionArn: INVOKED_FUNCTION_ARN });

  assert.deepEqual(result, {
    schema: 'senti.gateway.operation-admission-attestation.response.v1',
    capability: 'registry-v2-operation-admission-capable',
    invoked_function_arn: INVOKED_FUNCTION_ARN,
    function_version: '42',
    registry_mode: 'v2',
    v1_purged: '1',
    client_ready: '1',
    outcome_ready: '1',
    owner_ready: '1',
    hmac_secret_arn: HMAC_SECRET_ARN,
    hmac_secret_version_id: HMAC_SECRET_VERSION_ID,
    assertion_schema: OPERATION_ADMISSION_ASSERTION_SCHEMA,
  });
  assert.equal(Object.isFrozen(result), true);
  assert.deepEqual(Object.keys(result), [
    'schema',
    'capability',
    'invoked_function_arn',
    'function_version',
    'registry_mode',
    'v1_purged',
    'client_ready',
    'outcome_ready',
    'owner_ready',
    'hmac_secret_arn',
    'hmac_secret_version_id',
    'assertion_schema',
  ]);
  assert.doesNotMatch(JSON.stringify(result), /must-never-egress|UVFRUVFR|authorization|body/i);
  assert.deepEqual(calls, {
    fetch: 0,
    knownSessions: 0,
    get: 0,
    put: 0,
    delete: 0,
    transactWrite: 0,
    registry: 0,
  });
});

test('attestation schema collisions with any extra own key fail instead of falling through as HTTP', async () => {
  const { calls, handler } = fixture();
  const event = { schema: OPERATION_ADMISSION_ATTESTATION_REQUEST_SCHEMA };
  Object.defineProperty(event, 'hiddenHttpPayload', { value: { rawPath: '/dial/register' } });

  await assert.rejects(
    handler(event, { invokedFunctionArn: INVOKED_FUNCTION_ARN }),
    /attestation request must contain only schema/,
  );
  assert.deepEqual(calls, {
    fetch: 0,
    knownSessions: 0,
    get: 0,
    put: 0,
    delete: 0,
    transactWrite: 0,
    registry: 0,
  });
});

test('attestation rejects an alias, a mismatched numeric version, and a changed function ARN', async () => {
  await assert.rejects(
    fixture().handler(exactControlEvent(), {
      invokedFunctionArn: 'arn:aws:lambda:us-east-1:123456789012:function:senti-pocket-gateway:live',
    }),
    /exact invoked ARN.*immutable numeric Lambda version/,
  );
  await assert.rejects(
    fixture().handler(exactControlEvent(), {
      invokedFunctionArn: 'arn:aws:lambda:us-east-1:123456789012:function:senti-pocket-gateway:41',
    }),
    /exact invoked ARN.*immutable numeric Lambda version/,
  );

  const { handler } = fixture();
  await handler(exactControlEvent(), { invokedFunctionArn: INVOKED_FUNCTION_ARN });
  await assert.rejects(
    handler(exactControlEvent(), {
      invokedFunctionArn: 'arn:aws:lambda:us-east-1:123456789012:function:different-gateway:42',
    }),
    /invoked-function ARN changed within one Lambda environment/,
  );
});

test('only the exact top-level control schema is intercepted', async () => {
  let handled;
  let attestations = 0;
  const handler = lambdaHandler({
    async handle(request) {
      handled = request;
      return { status: 200, body: { normalHttp: true } };
    },
  }, {
    operationAdmissionAttestation() {
      attestations += 1;
      return { impossible: true };
    },
  });

  const result = await handler({
    requestContext: { http: { method: 'POST', path: '/ordinary' } },
    headers: {},
    body: { schema: OPERATION_ADMISSION_ATTESTATION_REQUEST_SCHEMA },
  });
  assert.equal(result.statusCode, 200);
  assert.equal(handled.path, '/ordinary');
  assert.equal(attestations, 0);
});
