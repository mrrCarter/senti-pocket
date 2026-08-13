import assert from 'node:assert/strict';
import { KeyObject, generateKeyPairSync } from 'node:crypto';
import test from 'node:test';

import {
  GatewayBootstrapError,
  createGatewayBootstrap,
  createGatewayMetricEmitter,
  loadPinnedSecretString,
} from '../deploy/gateway/bootstrap.mjs';
import {
  GATEWAY_AWS_TRANSPORT_OPTIONS,
  createGatewayAwsClients,
} from '../deploy/gateway/aws-clients.mjs';

const VERSION_ID = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const OTHER_VERSION_ID = 'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789';
const SIGNING_ARN =
  'arn:aws:secretsmanager:us-east-1:123456789012:secret:gateway-signing-AbCdEf';
const HMAC_ARN =
  'arn:aws:secretsmanager:us-east-1:123456789012:secret:registry-hmac-GhIjKl';
const APNS_ARN =
  'arn:aws:secretsmanager:us-east-1:123456789012:secret:apns-development-MnOpQr';
const SIGNING_PEM = generateKeyPairSync('ed25519').privateKey.export({
  format: 'pem',
  type: 'pkcs8',
});
const APNS_PEM = generateKeyPairSync('ec', { namedCurve: 'P-256' }).privateKey.export({
  format: 'pem',
  type: 'pkcs8',
});
const HMAC_SECRET = Buffer.alloc(32, 0x5a).toString('base64');

class FakeGetSecretValueCommand {
  constructor(input) {
    this.input = input;
  }
}
class FakeGetCommand { constructor(input) { this.input = input; } }
class FakePutCommand extends FakeGetCommand {}
class FakeDeleteCommand extends FakeGetCommand {}
class FakeTransactWriteCommand extends FakeGetCommand {}

function fullEnv(overrides = {}) {
  return {
    APNS_VOIP_ENABLED: '0',
    AWS_LAMBDA_FUNCTION_VERSION: '42',
    DDB_TABLE: 'senti-pocket-gateway',
    DEVICE_REGISTRY_CLIENT_V2_READY: '1',
    DEVICE_REGISTRY_HMAC_SECRET_ARN: HMAC_ARN,
    DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID: VERSION_ID,
    DEVICE_REGISTRY_MODE: 'v2',
    DEVICE_REGISTRY_OUTCOME_PROTOCOL_READY: '1',
    DEVICE_REGISTRY_OWNER_CONTINUITY_READY: '1',
    DEVICE_REGISTRY_V1_PURGED: '1',
    GATEWAY_PUBLIC_URL: 'https://pocket-api.example.com',
    SENTI_API_BASE_URL: 'https://api.example.com',
    SIGNING_KEY_ID: 'gateway-signing-v1',
    SIGNING_KEY_SECRET_ARN: SIGNING_ARN,
    SIGNING_KEY_SECRET_VERSION_ID: VERSION_ID,
    ...overrides,
  };
}

function secretFor(secretId) {
  if (secretId === SIGNING_ARN) return SIGNING_PEM;
  if (secretId === HMAC_ARN) return HMAC_SECRET;
  if (secretId === APNS_ARN) return APNS_PEM;
  throw new Error('unexpected test secret id');
}

function bootstrapOptions(overrides = {}) {
  return {
    env: fullEnv(),
    fetch: async () => ({ ok: true }),
    secretsManagerClient: {
      async send(command) {
        return {
          VersionId: VERSION_ID,
          SecretString: secretFor(command.input.SecretId),
        };
      },
    },
    GetSecretValueCommand: FakeGetSecretValueCommand,
    dynamoDocumentClient: { send: async () => ({}) },
    dynamoCommands: {
      GetCommand: FakeGetCommand,
      PutCommand: FakePutCommand,
      DeleteCommand: FakeDeleteCommand,
      TransactWriteCommand: FakeTransactWriteCommand,
    },
    ...overrides,
  };
}

function assertUnavailable(response) {
  assert.deepEqual(response, {
    statusCode: 503,
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      error: 'pocket gateway unavailable',
      reason: 'gateway-unavailable',
    }),
    isBase64Encoded: false,
  });
}

function assertSecretUnavailable(error) {
  assert.ok(error instanceof GatewayBootstrapError);
  assert.equal(error.code, 'gateway-secret-unavailable');
  assert.equal(error.message, 'gateway secret unavailable');
  assert.equal(error.cause, undefined);
  return true;
}

test('APNs defaults off, performs no APNs secret read, and composes one production cold-start singleton', async () => {
  const commands = [];
  const events = [];
  let appCreations = 0;
  let composedEnv;
  let composedDeps;
  const sourceEnv = fullEnv({
    APNS_VOIP_ENABLED: undefined,
    APNS_PRIVATE_KEY_SECRET_ARN: APNS_ARN,
    APNS_PRIVATE_KEY_SECRET_VERSION_ID: VERSION_ID,
    UNRELATED_CREDENTIAL: 'must-not-be-retained',
  });
  const handler = createGatewayBootstrap(bootstrapOptions({
    env: sourceEnv,
    secretsManagerClient: {
      async send(command) {
        commands.push(command);
        await Promise.resolve();
        return { VersionId: VERSION_ID, SecretString: secretFor(command.input.SecretId) };
      },
    },
    createGatewayHandler(appEnv, dependencies) {
      appCreations += 1;
      composedEnv = appEnv;
      composedDeps = dependencies;
      return async (event) => {
        events.push(event);
        return { statusCode: 204, marker: event.marker };
      };
    },
  }));

  sourceEnv.SIGNING_KEY_SECRET_VERSION_ID = OTHER_VERSION_ID;
  const [first, second] = await Promise.all([
    handler({ marker: 'one' }),
    handler({ marker: 'two' }),
  ]);
  const third = await handler({ marker: 'three' });

  assert.deepEqual(first, { statusCode: 204, marker: 'one' });
  assert.deepEqual(second, { statusCode: 204, marker: 'two' });
  assert.deepEqual(third, { statusCode: 204, marker: 'three' });
  assert.equal(appCreations, 1);
  assert.deepEqual(events.map((event) => event.marker), ['one', 'two', 'three']);
  assert.deepEqual(
    commands.map((command) => command.input),
    [
      { SecretId: SIGNING_ARN, VersionId: VERSION_ID },
      { SecretId: HMAC_ARN, VersionId: VERSION_ID },
    ],
  );
  assert.ok(commands.every((command) => !Object.hasOwn(command.input, 'VersionStage')));
  assert.ok(composedDeps.signingKey instanceof KeyObject);
  assert.equal(composedDeps.signingKey.asymmetricKeyType, 'ed25519');
  assert.equal(composedEnv.DEVICE_REGISTRY_HMAC_KEY_B64, HMAC_SECRET);
  assert.equal(composedEnv.SIGNING_KEY_SECRET_VERSION_ID, VERSION_ID);
  assert.equal(Object.hasOwn(composedEnv, 'UNRELATED_CREDENTIAL'), false);
  assert.equal(Object.hasOwn(composedDeps, 'apnsSend'), false);
  assert.equal(Object.hasOwn(composedDeps, 'knownSessionIdsFor'), false);
});

test('bootstrap composes without a legacy membership adapter and forwards only the authoritative fetch boundary', async () => {
  let reads = 0;
  let composedDeps;
  const fetch = async () => ({ ok: true });
  const handler = createGatewayBootstrap(bootstrapOptions({
    fetch,
    secretsManagerClient: {
      async send(command) {
        reads += 1;
        return { VersionId: VERSION_ID, SecretString: secretFor(command.input.SecretId) };
      },
    },
    createGatewayHandler(_appEnv, dependencies) {
      composedDeps = dependencies;
      return async () => ({ statusCode: 204 });
    },
  }));

  assert.deepEqual(await handler({ body: 'private' }), { statusCode: 204 });
  assert.equal(reads, 2);
  assert.equal(composedDeps.fetch, fetch);
  assert.equal(Object.hasOwn(composedDeps, 'knownSessionIdsFor'), false);
});

test('enabled APNs reads the exact third secret version and injects only the existing transport send function', async () => {
  const commands = [];
  const metrics = [];
  let transportOptions;
  let composedDeps;
  const send = async () => ({ delivered: true });
  const handler = createGatewayBootstrap(bootstrapOptions({
    env: fullEnv({
      APNS_VOIP_ENABLED: '1',
      APNS_TEAM_ID: 'ABCDE12345',
      APNS_KEY_ID: 'FGHIJ67890',
      APNS_BUNDLE_ID: 'com.plexaura.sentipocket.app',
      APNS_VOIP_ENVIRONMENT: 'development',
      APNS_PRIVATE_KEY_SECRET_ARN: APNS_ARN,
      APNS_PRIVATE_KEY_SECRET_VERSION_ID: VERSION_ID,
    }),
    secretsManagerClient: {
      async send(command) {
        commands.push(command);
        return { VersionId: VERSION_ID, SecretString: secretFor(command.input.SecretId) };
      },
    },
    createApnsTransport(options) {
      transportOptions = options;
      return { send, close() {} };
    },
    emitMetric(event) { metrics.push(event); },
    createGatewayHandler(_appEnv, dependencies) {
      composedDeps = dependencies;
      return async () => ({ statusCode: 204 });
    },
  }));

  assert.deepEqual(await handler({}), { statusCode: 204 });
  assert.deepEqual(
    commands.map((command) => command.input),
    [
      { SecretId: SIGNING_ARN, VersionId: VERSION_ID },
      { SecretId: HMAC_ARN, VersionId: VERSION_ID },
      { SecretId: APNS_ARN, VersionId: VERSION_ID },
    ],
  );
  assert.deepEqual(
    {
      teamId: transportOptions.teamId,
      keyId: transportOptions.keyId,
      bundleId: transportOptions.bundleId,
      environment: transportOptions.environment,
    },
    {
      teamId: 'ABCDE12345',
      keyId: 'FGHIJ67890',
      bundleId: 'com.plexaura.sentipocket.app',
      environment: 'development',
    },
  );
  assert.ok(transportOptions.privateKey instanceof KeyObject);
  assert.equal(transportOptions.privateKey.asymmetricKeyType, 'ec');
  assert.equal(transportOptions.privateKey.asymmetricKeyDetails.namedCurve, 'prime256v1');
  assert.equal(composedDeps.apnsSend, send);

  transportOptions.onResult({
    delivered: true,
    disposition: 'accepted',
    environment: 'development',
    apnsId: 'must-not-be-forwarded',
  });
  transportOptions.onResult({
    delivered: false,
    disposition: 'ambiguous',
    environment: 'development',
    reason: 'must-not-be-forwarded',
  });
  assert.deepEqual(metrics, [
    { metric: 'apns_accepted', disposition: 'accepted', environment: 'development' },
    { metric: 'apns_ambiguous', disposition: 'ambiguous', environment: 'development' },
  ]);
});

test('Registry V1 plus enabled APNs keeps the optional secret results in their named slots', async () => {
  const commands = [];
  let receivedPrivateKey;
  let composedEnv;
  const handler = createGatewayBootstrap(bootstrapOptions({
    env: fullEnv({
      DEVICE_REGISTRY_MODE: 'v1',
      APNS_VOIP_ENABLED: '1',
      APNS_TEAM_ID: 'ABCDE12345',
      APNS_KEY_ID: 'FGHIJ67890',
      APNS_BUNDLE_ID: 'com.plexaura.sentipocket.app',
      APNS_VOIP_ENVIRONMENT: 'development',
      APNS_PRIVATE_KEY_SECRET_ARN: APNS_ARN,
      APNS_PRIVATE_KEY_SECRET_VERSION_ID: VERSION_ID,
    }),
    secretsManagerClient: {
      async send(command) {
        commands.push(command.input);
        return { VersionId: VERSION_ID, SecretString: secretFor(command.input.SecretId) };
      },
    },
    createApnsTransport({ privateKey }) {
      receivedPrivateKey = privateKey;
      return { send: async () => ({ delivered: true }) };
    },
    createGatewayHandler(appEnv) {
      composedEnv = appEnv;
      return async () => ({ statusCode: 204 });
    },
  }));

  assert.deepEqual(await handler({}), { statusCode: 204 });
  assert.deepEqual(commands, [
    { SecretId: SIGNING_ARN, VersionId: VERSION_ID },
    { SecretId: APNS_ARN, VersionId: VERSION_ID },
  ]);
  assert.equal(receivedPrivateKey.asymmetricKeyType, 'ec');
  assert.equal(Object.hasOwn(composedEnv, 'DEVICE_REGISTRY_HMAC_KEY_B64'), false);
});

test('APNs configuration is ignored while disabled and fails before every secret read when enabled malformed', async () => {
  let reads = 0;
  const disabled = createGatewayBootstrap(bootstrapOptions({
    env: fullEnv({
      APNS_VOIP_ENABLED: '0',
      APNS_TEAM_ID: 'bad',
      APNS_PRIVATE_KEY_SECRET_ARN: 'not-an-arn',
    }),
    secretsManagerClient: {
      async send(command) {
        reads += 1;
        return { VersionId: VERSION_ID, SecretString: secretFor(command.input.SecretId) };
      },
    },
    createGatewayHandler() { return async () => ({ statusCode: 204 }); },
  }));
  assert.deepEqual(await disabled({}), { statusCode: 204 });
  assert.equal(reads, 2);

  for (const overrides of [
    { APNS_VOIP_ENABLED: 'yes' },
    { APNS_VOIP_ENABLED: '1', APNS_TEAM_ID: 'bad' },
    { APNS_VOIP_ENABLED: '1', APNS_TEAM_ID: 'ABCDE12345', APNS_KEY_ID: 'bad' },
  ]) {
    reads = 0;
    const metrics = [];
    const handler = createGatewayBootstrap(bootstrapOptions({
      env: fullEnv(overrides),
      secretsManagerClient: { async send() { reads += 1; throw new Error('not reached'); } },
      emitMetric(event) { metrics.push(event); },
    }));
    assertUnavailable(await handler({ private: 'must-not-leak' }));
    assert.equal(reads, 0);
    assert.deepEqual(metrics, [{ metric: 'gateway_bootstrap_failure' }]);
  }
});

test('pinned secret reads reject version drift, SecretBinary, malformed responses, and oversized values', async (t) => {
  const responses = [
    { VersionId: OTHER_VERSION_ID, SecretString: SIGNING_PEM },
    { VersionId: VERSION_ID, SecretString: SIGNING_PEM, SecretBinary: Buffer.from('x') },
    { VersionId: VERSION_ID, SecretBinary: Buffer.from('x') },
    { VersionId: VERSION_ID, SecretString: 'x'.repeat(65) },
    null,
  ];
  for (const [index, response] of responses.entries()) {
    await t.test(`rejected response ${index + 1}`, async () => {
      await assert.rejects(
        loadPinnedSecretString({
          secretsManagerClient: { async send() { return response; } },
          GetSecretValueCommand: FakeGetSecretValueCommand,
          secretArn: SIGNING_ARN,
          versionId: VERSION_ID,
          minBytes: 64,
          maxBytes: 64,
        }),
        assertSecretUnavailable,
      );
    });
  }
});

test('non-P256 APNs material fails closed without exposing key, request, or SDK detail', async () => {
  const metrics = [];
  let appCreations = 0;
  const handler = createGatewayBootstrap(bootstrapOptions({
    env: fullEnv({
      APNS_VOIP_ENABLED: '1',
      APNS_TEAM_ID: 'ABCDE12345',
      APNS_KEY_ID: 'FGHIJ67890',
      APNS_BUNDLE_ID: 'com.plexaura.sentipocket.app',
      APNS_VOIP_ENVIRONMENT: 'development',
      APNS_PRIVATE_KEY_SECRET_ARN: APNS_ARN,
      APNS_PRIVATE_KEY_SECRET_VERSION_ID: VERSION_ID,
    }),
    secretsManagerClient: {
      async send(command) {
        return {
          VersionId: VERSION_ID,
          SecretString: command.input.SecretId === APNS_ARN ? SIGNING_PEM : secretFor(command.input.SecretId),
        };
      },
    },
    emitMetric(event) { metrics.push(event); },
    createGatewayHandler() { appCreations += 1; return async () => ({ statusCode: 204 }); },
  }));

  const response = await handler({ authorization: 'Bearer must-not-leak' });
  assertUnavailable(response);
  assert.equal(appCreations, 0);
  assert.deepEqual(metrics, [{ metric: 'gateway_bootstrap_failure' }]);
  assert.ok(!JSON.stringify(response).includes('Bearer'));
  assert.ok(!JSON.stringify(response).includes('PRIVATE KEY'));
  assert.ok(!JSON.stringify(response).includes(APNS_ARN));
});

test('failed initialization is not cached and a later invocation retries the same immutable pin', async () => {
  let attempts = 0;
  const commands = [];
  const handler = createGatewayBootstrap(bootstrapOptions({
    env: fullEnv({ DEVICE_REGISTRY_MODE: 'v1' }),
    secretsManagerClient: {
      async send(command) {
        attempts += 1;
        commands.push(command.input);
        if (attempts === 1) throw new Error('transient SDK detail');
        return { VersionId: VERSION_ID, SecretString: SIGNING_PEM };
      },
    },
    emitMetric() {},
    createGatewayHandler() { return async () => ({ statusCode: 204 }); },
  }));

  assertUnavailable(await handler({}));
  assert.deepEqual(await handler({}), { statusCode: 204 });
  assert.equal(attempts, 2);
  assert.deepEqual(commands, [
    { SecretId: SIGNING_ARN, VersionId: VERSION_ID },
    { SecretId: SIGNING_ARN, VersionId: VERSION_ID },
  ]);
});

test('metric output is a strict low-cardinality allowlist', () => {
  const lines = [];
  const emit = createGatewayMetricEmitter({
    write(line) { lines.push(line); },
    now: () => Date.parse('2026-08-05T11:00:00.000Z'),
  });
  emit({
    metric: 'apns_ambiguous',
    disposition: 'ambiguous',
    environment: 'development',
    voipToken: 'secret-token',
    apnsId: 'high-cardinality',
    reason: 'raw-reason',
    payload: { private: true },
  });
  emit({ metric: 'attacker-controlled', disposition: 'ambiguous' });

  assert.equal(lines.length, 1);
  assert.deepEqual(JSON.parse(lines[0]), {
    event: 'senti_pocket_gateway_metric',
    metric: 'apns_ambiguous',
    timestamp: '2026-08-05T11:00:00.000Z',
    disposition: 'ambiguous',
    apnsEnvironment: 'development',
  });
  assert.ok(!lines[0].includes('secret-token'));
  assert.ok(!lines[0].includes('high-cardinality'));
  assert.ok(!lines[0].includes('raw-reason'));
});

test('production AWS clients use one attempt and explicit hard HTTP deadlines', async () => {
  const clients = createGatewayAwsClients();
  try {
    for (const client of [clients.rawDynamoClient, clients.secretsManagerClient]) {
      assert.equal(await client.config.maxAttempts(), 1);
      const transport = await client.config.requestHandler.configProvider;
      for (const [name, value] of Object.entries(GATEWAY_AWS_TRANSPORT_OPTIONS)) {
        assert.equal(transport[name], value);
      }
    }
  } finally {
    clients.destroy();
  }
});
