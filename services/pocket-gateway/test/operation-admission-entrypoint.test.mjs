import assert from 'node:assert/strict';
import test from 'node:test';

import {
  OperationAdmissionBootstrapError,
  createOperationAdmissionBootstrap,
  loadPinnedRegistryHmacSecret,
} from '../deploy/operation-admission/bootstrap.mjs';
import {
  GATEWAY_INVOKE_TRANSPORT_OPTIONS,
  SHORT_AWS_TRANSPORT_OPTIONS,
  createOperationAdmissionAwsClients,
} from '../deploy/operation-admission/aws-clients.mjs';

const VERSION_ID = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const OTHER_VERSION_ID = 'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789';
const SECRET_ID = 'arn:aws:secretsmanager:us-east-1:123456789012:secret:registry-hmac-AbCdEf';
const HMAC_STRING = Buffer.alloc(32, 0x5a).toString('base64');

class FakeGetSecretValueCommand {
  constructor(input) {
    this.input = input;
  }
}

class FakeInvokeCommand {
  constructor(input) {
    this.input = input;
  }
}

class FakeGetCommand {
  constructor(input) {
    this.input = input;
  }
}

class FakePutCommand extends FakeGetCommand {}
class FakeDeleteCommand extends FakeGetCommand {}

function env(overrides = {}) {
  return {
    DEVICE_REGISTRY_HMAC_SECRET_ARN: SECRET_ID,
    DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID: VERSION_ID,
    GATEWAY_LAMBDA_VERSION_ARN:
      'arn:aws:lambda:us-east-1:123456789012:function:senti-pocket-gateway:42',
    GATEWAY_LAMBDA_VERSION: '42',
    OPERATION_ADMISSION_DDB_TABLE: 'senti-pocket-operation-admission',
    REGISTRY_OPERATION_ADMISSION_AUTH_MODE: 'senti_session_reusable_v1',
    SENTI_API_BASE_URL: 'https://api.sentinelayer.com',
    ...overrides,
  };
}

function bootstrapOptions(overrides = {}) {
  return {
    env: env(),
    fetch: async () => {
      throw new Error('not called');
    },
    secretsManagerClient: {
      async send() {
        return { VersionId: VERSION_ID, SecretString: HMAC_STRING };
      },
    },
    GetSecretValueCommand: FakeGetSecretValueCommand,
    dynamoDocumentClient: { send: async () => ({}) },
    dynamoCommands: {
      GetCommand: FakeGetCommand,
      PutCommand: FakePutCommand,
      DeleteCommand: FakeDeleteCommand,
    },
    lambdaClient: { send: async () => ({}) },
    InvokeCommand: FakeInvokeCommand,
    ...overrides,
  };
}

function assertSecretUnavailable(error) {
  assert.ok(error instanceof OperationAdmissionBootstrapError);
  assert.equal(error.code, 'operation-admission-secret-unavailable');
  assert.equal(error.cause, undefined);
  assert.equal(error.message, 'operation admission secret unavailable');
  return true;
}

function assertUnavailableResponse(response) {
  assert.deepEqual(response, {
    statusCode: 503,
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      error: 'registration operation admission unavailable',
      reason: 'operation-admission-unavailable',
    }),
    isBase64Encoded: false,
  });
}

test('requests the exact secret version and composes one cold-start singleton', async () => {
  const commands = [];
  let appCreations = 0;
  const seenEvents = [];
  const options = bootstrapOptions({
    secretsManagerClient: {
      async send(command) {
        commands.push(command);
        await Promise.resolve();
        return { VersionId: VERSION_ID, SecretString: HMAC_STRING };
      },
    },
    createApp(appEnv, dependencies) {
      appCreations += 1;
      assert.equal(appEnv.REGISTRY_OPERATION_ADMISSION_AUTH_MODE, 'senti_session_reusable_v1');
      assert.equal(dependencies.hmacKey, HMAC_STRING);
      assert.equal(dependencies.hmacKeyVersionId, VERSION_ID);
      assert.equal(typeof dependencies.dynamoClient.get, 'function');
      assert.equal(typeof dependencies.dynamoClient.put, 'function');
      assert.equal(typeof dependencies.dynamoClient.delete, 'function');
      assert.equal(typeof dependencies.invokeGateway, 'function');
      return async (event) => {
        seenEvents.push(event);
        return { statusCode: 200, body: event.body };
      };
    },
  });
  const handler = createOperationAdmissionBootstrap(options);

  const [first, second] = await Promise.all([
    handler({ body: 'one' }),
    handler({ body: 'two' }),
  ]);
  const third = await handler({ body: 'three' });

  assert.deepEqual(first, { statusCode: 200, body: 'one' });
  assert.deepEqual(second, { statusCode: 200, body: 'two' });
  assert.deepEqual(third, { statusCode: 200, body: 'three' });
  assert.equal(commands.length, 1);
  assert.ok(commands[0] instanceof FakeGetSecretValueCommand);
  assert.deepEqual(commands[0].input, { SecretId: SECRET_ID, VersionId: VERSION_ID });
  assert.equal(Object.hasOwn(commands[0].input, 'VersionStage'), false);
  assert.equal(appCreations, 1);
  assert.deepEqual(seenEvents, [{ body: 'one' }, { body: 'two' }, { body: 'three' }]);
});

test('snapshots only owned configuration before asynchronous cold-start work', async () => {
  const sourceEnv = env({ UNRELATED_CREDENTIAL: 'must-not-be-retained' });
  let request;
  let appEnv;
  const handler = createOperationAdmissionBootstrap(
    bootstrapOptions({
      env: sourceEnv,
      secretsManagerClient: {
        async send(command) {
          request = command.input;
          return { VersionId: VERSION_ID, SecretString: HMAC_STRING };
        },
      },
      createApp(receivedEnv) {
        appEnv = receivedEnv;
        return async () => ({ statusCode: 204 });
      },
    }),
  );
  sourceEnv.DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID = OTHER_VERSION_ID;
  sourceEnv.UNRELATED_CREDENTIAL = 'changed';

  assert.deepEqual(await handler({}), { statusCode: 204 });
  assert.deepEqual(request, { SecretId: SECRET_ID, VersionId: VERSION_ID });
  assert.equal(appEnv.DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID, VERSION_ID);
  assert.equal(
    appEnv.GATEWAY_LAMBDA_VERSION_ARN,
    'arn:aws:lambda:us-east-1:123456789012:function:senti-pocket-gateway:42',
  );
  assert.equal(appEnv.GATEWAY_LAMBDA_VERSION, '42');
  assert.equal(Object.hasOwn(appEnv, 'UNRELATED_CREDENTIAL'), false);
  assert.equal(Object.isFrozen(appEnv), true);
});

test('fails closed when Secrets Manager returns a different version', async () => {
  await assert.rejects(
    loadPinnedRegistryHmacSecret({
      env: env(),
      secretsManagerClient: {
        async send() {
          return { VersionId: OTHER_VERSION_ID, SecretString: HMAC_STRING };
        },
      },
      GetSecretValueCommand: FakeGetSecretValueCommand,
    }),
    assertSecretUnavailable,
  );
});

test('rejects malformed or ambiguous secret material without retaining it as a cause', async (t) => {
  const responses = [
    { VersionId: VERSION_ID },
    { VersionId: VERSION_ID, SecretString: HMAC_STRING, SecretBinary: Buffer.alloc(32) },
    { VersionId: VERSION_ID, SecretString: 'not canonical base64' },
    { VersionId: VERSION_ID, SecretString: Buffer.alloc(31).toString('base64') },
    { VersionId: VERSION_ID, SecretString: Buffer.alloc(1025).toString('base64') },
    { VersionId: VERSION_ID, SecretBinary: new Uint8Array(31) },
    { VersionId: VERSION_ID, SecretBinary: new Uint8Array(32) },
  ];

  for (const [index, response] of responses.entries()) {
    await t.test(`malformed response ${index + 1}`, async () => {
      await assert.rejects(
        loadPinnedRegistryHmacSecret({
          env: env(),
          secretsManagerClient: { send: async () => response },
          GetSecretValueCommand: FakeGetSecretValueCommand,
        }),
        assertSecretUnavailable,
      );
    });
  }
});

test('sanitizes a failed secret fetch, does not cache it, and retries the exact pin', async () => {
  let attempts = 0;
  const handler = createOperationAdmissionBootstrap(
    bootstrapOptions({
      secretsManagerClient: {
        async send(command) {
          attempts += 1;
          assert.deepEqual(command.input, { SecretId: SECRET_ID, VersionId: VERSION_ID });
          if (attempts === 1) throw new Error('transient SDK detail');
          return { VersionId: VERSION_ID, SecretString: HMAC_STRING };
        },
      },
      createApp() {
        return async () => ({ statusCode: 204 });
      },
    }),
  );

  const first = await handler({ body: 'Bearer must-never-leak' });
  assertUnavailableResponse(first);
  assert.ok(!first.body.includes('must-never-leak'));
  assert.deepEqual(await handler({}), { statusCode: 204 });
  assert.equal(attempts, 2);
});

test('non-reusable auth configuration fails closed without exposing configuration detail', async () => {
  const handler = createOperationAdmissionBootstrap(
    bootstrapOptions({
      env: env({ REGISTRY_OPERATION_ADMISSION_AUTH_MODE: 'dpop_v1' }),
    }),
  );

  assertUnavailableResponse(await handler({}));
});

test('missing or noncanonical attested gateway version fails closed before app composition', async () => {
  for (const gatewayVersion of [undefined, '', '0', '01', '$LATEST', 'live']) {
    let appCreations = 0;
    const handler = createOperationAdmissionBootstrap(
      bootstrapOptions({
        env: env({ GATEWAY_LAMBDA_VERSION: gatewayVersion }),
        createApp() {
          appCreations += 1;
          return async () => ({ statusCode: 204 });
        },
      }),
    );
    assertUnavailableResponse(await handler({}));
    assert.equal(appCreations, 0);
  }
});

test('mutable, malformed, or mismatched gateway target fails closed before app composition', async () => {
  for (const gatewayVersionArn of [
    undefined,
    '',
    'arn:aws:lambda:us-east-1:123456789012:function:senti-pocket-gateway',
    'arn:aws:lambda:us-east-1:123456789012:function:senti-pocket-gateway:live',
    'arn:aws:lambda:us-east-1:123456789012:function:senti-pocket-gateway:43',
  ]) {
    let appCreations = 0;
    const handler = createOperationAdmissionBootstrap(
      bootstrapOptions({
        env: env({ GATEWAY_LAMBDA_VERSION_ARN: gatewayVersionArn }),
        createApp() {
          appCreations += 1;
          return async () => ({ statusCode: 204 });
        },
      }),
    );
    assertUnavailableResponse(await handler({}));
    assert.equal(appCreations, 0);
  }
});

test('unexpected composed-app failures use the same sanitized 503 boundary', async () => {
  const handler = createOperationAdmissionBootstrap(
    bootstrapOptions({
      createApp() {
        return async () => {
          throw new Error('Bearer app-secret-must-never-leak');
        };
      },
    }),
  );

  const response = await handler({ body: 'private request body' });
  assertUnavailableResponse(response);
  assert.ok(!response.body.includes('app-secret'));
  assert.ok(!response.body.includes('private request body'));
});

test('aborts a hung cold-start dependency and returns the exact 503 before the request budget', async () => {
  let receivedSignal;
  const handler = createOperationAdmissionBootstrap(
    bootstrapOptions({
      requestDeadlineMs: 20,
      secretsManagerClient: {
        send(_command, options) {
          receivedSignal = options?.abortSignal;
          return new Promise((_resolve, reject) => {
            receivedSignal.addEventListener('abort', () => reject(receivedSignal.reason), { once: true });
          });
        },
      },
    }),
  );

  const startedAt = Date.now();
  assertUnavailableResponse(await handler({ body: 'must-not-leak' }));
  assert.ok(Date.now() - startedAt < 500, 'the app returns before the Lambda/API integration timeout');
  assert.ok(receivedSignal instanceof AbortSignal);
  assert.equal(receivedSignal.aborted, true);
});

test('does not cache a timed-out cold-start promise when a dependency ignores cancellation', async () => {
  let attempts = 0;
  const handler = createOperationAdmissionBootstrap(
    bootstrapOptions({
      requestDeadlineMs: 10,
      secretsManagerClient: {
        send() {
          attempts += 1;
          return new Promise(() => {});
        },
      },
    }),
  );

  assertUnavailableResponse(await handler({}));
  assertUnavailableResponse(await handler({}));
  assert.equal(attempts, 2);
});

test('uses Lambda remaining time minus response reserve and can fail before touching a dependency', async () => {
  let attempts = 0;
  const handler = createOperationAdmissionBootstrap(
    bootstrapOptions({
      secretsManagerClient: {
        async send() {
          attempts += 1;
          return { VersionId: VERSION_ID, SecretString: HMAC_STRING };
        },
      },
    }),
  );

  assertUnavailableResponse(await handler({}, { getRemainingTimeInMillis: () => 1_999 }));
  assert.equal(attempts, 0);
});

test('propagates one invocation deadline to fetch, Dynamo, and private Lambda transports', async () => {
  const signals = [];
  const transport = {
    async send(_command, options) {
      signals.push(options?.abortSignal);
      return {};
    },
  };
  let wrappedDynamo;
  let wrappedLambda;
  const handler = createOperationAdmissionBootstrap(
    bootstrapOptions({
      fetch: async (_url, init) => {
        signals.push(init?.signal);
        return {};
      },
      dynamoDocumentClient: transport,
      lambdaClient: transport,
      createDynamoAdapter(client) {
        wrappedDynamo = client;
        return { get: () => client.send({}), put: () => client.send({}), delete: () => client.send({}) };
      },
      createGatewayInvoker({ client }) {
        wrappedLambda = client;
        return () => client.send({});
      },
      createApp(_appEnv, dependencies) {
        return async () => {
          await dependencies.fetch('https://api.sentinelayer.com/api/v1/auth/me');
          await dependencies.dynamoClient.get({});
          await dependencies.invokeGateway({});
          return { statusCode: 204 };
        };
      },
    }),
  );

  assert.deepEqual(await handler({}), { statusCode: 204 });
  assert.notEqual(wrappedDynamo, transport);
  assert.notEqual(wrappedLambda, transport);
  assert.equal(signals.length, 3);
  assert.ok(signals.every((signal) => signal instanceof AbortSignal && !signal.aborted));
  await new Promise((resolve) => setTimeout(resolve, 5));
  assert.ok(signals.every((signal) => !signal.aborted), 'successful completion clears the outer timer');
});

test('production AWS clients use one attempt and explicit hard HTTP deadlines', async () => {
  const clients = createOperationAdmissionAwsClients();
  try {
    for (const client of [clients.rawDynamoClient, clients.secretsManagerClient]) {
      assert.equal(await client.config.maxAttempts(), 1);
      const transport = await client.config.requestHandler.configProvider;
      for (const [name, value] of Object.entries(SHORT_AWS_TRANSPORT_OPTIONS)) {
        assert.equal(transport[name], value);
      }
    }

    assert.equal(await clients.lambdaClient.config.maxAttempts(), 1);
    const invokeTransport = await clients.lambdaClient.config.requestHandler.configProvider;
    for (const [name, value] of Object.entries(GATEWAY_INVOKE_TRANSPORT_OPTIONS)) {
      assert.equal(invokeTransport[name], value);
    }
  } finally {
    clients.destroy();
  }
});
