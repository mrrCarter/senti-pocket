import assert from 'node:assert/strict';
import test from 'node:test';

import {
  LAMBDA_INVOKE_MAX_REQUEST_BYTES,
  LAMBDA_INVOKE_MAX_RESPONSE_BYTES,
  LambdaInvokeAdapterError,
  createLambdaInvokeAdapter,
} from '../src/lambda-invoke-adapter.mjs';

const GATEWAY_VERSION = '42';
const GATEWAY_VERSION_ARN =
  `arn:aws:lambda:us-east-1:123456789012:function:senti-pocket-gateway:${GATEWAY_VERSION}`;
const PRIVATE_BODY = '{"accepted":true,"spacing": "preserved"}\n';

class FakeInvokeCommand {
  constructor(input) {
    this.input = input;
  }
}

function encoded(value) {
  return Buffer.from(JSON.stringify(value), 'utf8');
}

function validLambdaResponse(overrides = {}) {
  return {
    StatusCode: 200,
    ExecutedVersion: '42',
    Payload: encoded({
      statusCode: 202,
      headers: { 'content-type': 'application/json' },
      body: PRIVATE_BODY,
      isBase64Encoded: false,
    }),
    ...overrides,
  };
}

function makeAdapter(send, overrides = {}) {
  const commands = [];
  const client = {
    async send(command) {
      commands.push(command);
      return send(command);
    },
  };
  return {
    commands,
    invoke: createLambdaInvokeAdapter({
      client,
      InvokeCommand: FakeInvokeCommand,
      gatewayVersionArn: GATEWAY_VERSION_ARN,
      expectedExecutedVersion: GATEWAY_VERSION,
      ...overrides,
    }),
  };
}

function isSanitizedInvokeError(error) {
  return error instanceof LambdaInvokeAdapterError &&
    error.code === 'gateway-invoke-unavailable' &&
    error.message === 'private gateway invocation unavailable' &&
    error.cause === undefined;
}

test('invokes one immutable numeric version synchronously with no log tail and preserves body strings', async () => {
  const expected = {
    statusCode: 202,
    headers: { 'content-type': 'application/json' },
    body: PRIVATE_BODY,
    isBase64Encoded: false,
  };
  const { invoke, commands } = makeAdapter(async () => validLambdaResponse({ Payload: encoded(expected) }));
  const event = {
    version: '2.0',
    rawPath: '/dial/register',
    headers: { authorization: 'Bearer reusable-secret' },
    body: '{ "voipToken" : "unchanged\\nbody" }',
    isBase64Encoded: false,
  };
  const originalBody = event.body;

  const result = await invoke(event);

  assert.deepEqual(result, expected);
  assert.equal(result.body, PRIVATE_BODY);
  assert.equal(event.body, originalBody, 'the caller event is never mutated');
  assert.equal(commands.length, 1);
  assert.ok(commands[0] instanceof FakeInvokeCommand);
  assert.deepEqual(Object.keys(commands[0].input).sort(), [
    'FunctionName',
    'InvocationType',
    'LogType',
    'Payload',
  ]);
  assert.equal(commands[0].input.FunctionName, GATEWAY_VERSION_ARN);
  assert.equal(commands[0].input.InvocationType, 'RequestResponse');
  assert.equal(commands[0].input.LogType, 'None');
  assert.ok(!Object.hasOwn(commands[0].input, 'Qualifier'));
  assert.ok(!Object.hasOwn(commands[0].input, 'ClientContext'));
  const forwarded = JSON.parse(Buffer.from(commands[0].input.Payload).toString('utf8'));
  assert.equal(forwarded.body, originalBody);
  assert.equal(forwarded.isBase64Encoded, false);
  assert.deepEqual(forwarded, event);
  assert.equal(LAMBDA_INVOKE_MAX_REQUEST_BYTES, 512 * 1024);
  assert.equal(LAMBDA_INVOKE_MAX_RESPONSE_BYTES, 256 * 1024);
});

test('accepts ArrayBuffer views only when AWS reports the exact attested executed version', async () => {
  const payload = encoded({ statusCode: 200, body: '{}' });
  const dataView = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
  const { invoke } = makeAdapter(async () => ({
    StatusCode: 200,
    ExecutedVersion: GATEWAY_VERSION,
    Payload: dataView,
  }));
  assert.deepEqual(await invoke({ body: 'exact' }), { statusCode: 200, body: '{}' });
});

test('snapshots ExecutedVersion exactly once before validating it', async () => {
  let reads = 0;
  const response = { StatusCode: 200, Payload: encoded({ statusCode: 200, body: '{}' }) };
  Object.defineProperty(response, 'ExecutedVersion', {
    enumerable: true,
    get() {
      reads += 1;
      return reads === 1 ? '42' : '$LATEST';
    },
  });
  const { invoke } = makeAdapter(async () => response);
  assert.deepEqual(await invoke({ body: 'exact' }), { statusCode: 200, body: '{}' });
  assert.equal(reads, 1);
});

test('constructor accepts only a matching qualified numeric version ARN and complete SDK dependencies', () => {
  const valid = {
    client: { send: async () => validLambdaResponse() },
    InvokeCommand: FakeInvokeCommand,
    gatewayVersionArn: GATEWAY_VERSION_ARN,
    expectedExecutedVersion: GATEWAY_VERSION,
  };
  for (const gatewayVersionArn of [
    '',
    'arn:aws:lambda:us-east-1:123456789012:function:senti-pocket-gateway',
    'arn:aws:lambda:us-east-1:123456789012:function:senti-pocket-gateway:live',
    'arn:aws:lambda:us-east-1:123456789012:function:senti-pocket-gateway:$LATEST',
    'arn:aws:lambda:us-east-1:123456789012:function:senti-pocket-gateway:0',
    'arn:aws:lambda:us-east-1:123456789012:function:senti-pocket-gateway:01',
    'arn:aws:s3:us-east-1:123456789012:function:senti-pocket-gateway:42',
    'arn:aws:lambda:us-east-1:not-account:function:senti-pocket-gateway:42',
    'arn:other:lambda:us-east-1:123456789012:function:senti-pocket-gateway:42',
  ]) {
    assert.throws(
      () => createLambdaInvokeAdapter({ ...valid, gatewayVersionArn }),
      /qualified numeric Lambda version ARN/,
    );
  }
  assert.throws(() => createLambdaInvokeAdapter({ ...valid, client: null }), /client with send/);
  assert.throws(() => createLambdaInvokeAdapter({ ...valid, InvokeCommand: null }), /InvokeCommand/);
  for (const expectedExecutedVersion of [undefined, '', '0', '01', '$LATEST', 'live', 42]) {
    assert.throws(
      () => createLambdaInvokeAdapter({ ...valid, expectedExecutedVersion }),
      /expectedExecutedVersion/,
    );
  }
  assert.throws(
    () => createLambdaInvokeAdapter({ ...valid, expectedExecutedVersion: '43' }),
    /must end with expectedExecutedVersion/,
  );
  assert.throws(() => createLambdaInvokeAdapter({ ...valid, maxRequestBytes: 0 }), /maxRequestBytes/);
  assert.throws(() => createLambdaInvokeAdapter({ ...valid, maxResponseBytes: 1.5 }), /maxResponseBytes/);
});

test('malformed AWS invoke responses fail closed with one sanitized typed error', async () => {
  const secret = 'Bearer must-never-leak';
  const statusGetter = {};
  Object.defineProperty(statusGetter, 'StatusCode', {
    enumerable: true,
    get() { throw new Error(secret); },
  });
  const payloadGetter = { StatusCode: 200 };
  Object.defineProperty(payloadGetter, 'Payload', {
    enumerable: true,
    get() { throw new Error(secret); },
  });
  const malformed = [
    null,
    [],
    {},
    { StatusCode: 201, Payload: encoded({ statusCode: 200, body: '{}' }) },
    { ...validLambdaResponse(), FunctionError: undefined },
    { ...validLambdaResponse(), FunctionError: `Unhandled ${secret}` },
    { ...validLambdaResponse(), LogResult: undefined },
    { ...validLambdaResponse(), LogResult: Buffer.from(secret).toString('base64') },
    { ...validLambdaResponse(), ExecutedVersion: '$LATEST' },
    { ...validLambdaResponse(), ExecutedVersion: 'live' },
    { ...validLambdaResponse(), ExecutedVersion: '0' },
    { ...validLambdaResponse(), ExecutedVersion: '01' },
    { ...validLambdaResponse(), ExecutedVersion: 42 },
    { ...validLambdaResponse(), ExecutedVersion: '43' },
    { StatusCode: 200, Payload: encoded({ statusCode: 200, body: '{}' }) },
    { StatusCode: 200, ExecutedVersion: GATEWAY_VERSION, Payload: Buffer.alloc(0) },
    { StatusCode: 200, ExecutedVersion: GATEWAY_VERSION, Payload: secret },
    { StatusCode: 200, ExecutedVersion: GATEWAY_VERSION, Payload: encoded(null) },
    { StatusCode: 200, ExecutedVersion: GATEWAY_VERSION, Payload: encoded([]) },
    { StatusCode: 200, ExecutedVersion: GATEWAY_VERSION, Payload: encoded('not-an-object') },
    { StatusCode: 200, ExecutedVersion: GATEWAY_VERSION, Payload: Buffer.from('{not-json', 'utf8') },
    { StatusCode: 200, ExecutedVersion: GATEWAY_VERSION, Payload: Buffer.from([0xff]) },
    { StatusCode: 200, ExecutedVersion: GATEWAY_VERSION, Payload: new ArrayBuffer(8) },
    statusGetter,
    payloadGetter,
  ];

  for (const response of malformed) {
    const { invoke } = makeAdapter(async () => response);
    await assert.rejects(invoke({ body: secret }), isSanitizedInvokeError);
  }

  const { invoke: oversized } = makeAdapter(
    async () => ({ StatusCode: 200, Payload: Buffer.alloc(33, 0x61) }),
    { maxResponseBytes: 32 },
  );
  await assert.rejects(oversized({ body: secret }), isSanitizedInvokeError);
});

test('SDK and InvokeCommand failures are sanitized without retaining their causes', async () => {
  const secret = 'private-payload-secret';
  const { invoke } = makeAdapter(async () => { throw new Error(secret); });
  await assert.rejects(invoke({ body: secret }), isSanitizedInvokeError);

  class ThrowingInvokeCommand {
    constructor() { throw new Error(secret); }
  }
  const throwingCommand = createLambdaInvokeAdapter({
    client: { send: async () => { throw new Error('must not send'); } },
    InvokeCommand: ThrowingInvokeCommand,
    gatewayVersionArn: GATEWAY_VERSION_ARN,
    expectedExecutedVersion: GATEWAY_VERSION,
  });
  await assert.rejects(throwingCommand({ body: secret }), isSanitizedInvokeError);
});

test('unserializable and oversized request events fail before the AWS client is called', async () => {
  let sendCalls = 0;
  const { invoke } = makeAdapter(
    async () => {
      sendCalls += 1;
      return validLambdaResponse();
    },
    { maxRequestBytes: 64 },
  );
  const circular = {};
  circular.self = circular;
  for (const event of [undefined, circular, { value: 1n }, { body: 'x'.repeat(128) }]) {
    await assert.rejects(invoke(event), isSanitizedInvokeError);
  }
  assert.equal(sendCalls, 0);
});
