import assert from 'node:assert/strict';
import {
  generateKeyPairSync,
  sign as cryptoSign,
  verify as cryptoVerify,
} from 'node:crypto';
import { EventEmitter } from 'node:events';
import {
  connect as realHttp2Connect,
  createServer as createHttp2Server,
  sensitiveHeaders as http2SensitiveHeaders,
} from 'node:http2';
import test from 'node:test';

import {
  APNS_PROVIDER_TOKEN_TTL_MS,
  APNS_VOIP_MAX_PAYLOAD_BYTES,
  ApnsVoipTransportError,
  createApnsVoipTransport,
} from '../src/apns-voip-transport.mjs';
import { createDialPushBackend } from '../src/dial-registry.mjs';

const TEAM_ID = 'ABCDE12345';
const KEY_ID = 'FGHIJ67890';
const BUNDLE_ID = 'com.plexaura.sentipocket.app';
const DEVICE_TOKEN = 'AABBCCDDEEFF00112233445566778899';
const NOW = Date.parse('2026-08-05T07:00:00.000Z');
const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });

class FakeStream extends EventEmitter {
  constructor(plan, record) {
    super();
    this.plan = plan;
    this.record = record;
  }

  end(body) {
    if (this.plan.throwOnEnd) throw new Error(this.plan.throwOnEnd);
    this.record.body = body;
    if (this.plan.never) return;
    queueMicrotask(() => {
      if (this.plan.error) {
        this.emit('error', new Error(this.plan.error));
        return;
      }
      const headers = { ':status': this.plan.status ?? 200 };
      if (Object.hasOwn(this.plan, 'apnsId')) headers['apns-id'] = this.plan.apnsId;
      if (Object.hasOwn(this.plan, 'retryAfter')) headers['retry-after'] = this.plan.retryAfter;
      this.emit('response', headers);
      let responseBody;
      if (Object.hasOwn(this.plan, 'body')) responseBody = this.plan.body;
      else if (this.plan.reason !== undefined) {
        responseBody = JSON.stringify({ reason: this.plan.reason, ...(this.plan.timestamp === undefined ? {} : { timestamp: this.plan.timestamp }) });
      }
      if (responseBody !== undefined) {
        const bytes = Buffer.isBuffer(responseBody) ? responseBody : Buffer.from(responseBody, 'utf8');
        const splitAt = this.plan.splitAt;
        if (Number.isInteger(splitAt) && splitAt > 0 && splitAt < bytes.byteLength) {
          this.emit('data', bytes.subarray(0, splitAt));
          this.emit('data', bytes.subarray(splitAt));
        } else {
          this.emit('data', bytes);
        }
      }
      if (this.plan.abortAfterResponse) {
        this.emit('aborted');
        return;
      }
      this.emit('end');
      this.emit('close');
    });
  }

  close(code) {
    this.record.cancelCode = code;
    queueMicrotask(() => this.emit('close'));
  }

  destroy() {
    this.record.destroyed = true;
    queueMicrotask(() => this.emit('close'));
  }
}

class FakeSession extends EventEmitter {
  constructor(plans) {
    super();
    this.plans = plans;
    this.requests = [];
    this.closed = false;
    this.destroyed = false;
    this.closeCalls = 0;
    this.destroyCalls = 0;
  }

  request(headers) {
    const plan = this.plans.shift() ?? {};
    if (plan.throwRequest) throw new Error(plan.throwRequest);
    const record = { headers, body: undefined };
    this.requests.push(record);
    return new FakeStream(plan, record);
  }

  close() {
    this.closeCalls += 1;
    this.closed = true;
  }

  destroy() {
    this.destroyCalls += 1;
    this.destroyed = true;
  }
}

function makeHarness(plans = []) {
  const remainingPlans = [...plans];
  const connections = [];
  const sessions = [];
  return {
    connections,
    sessions,
    connect(origin, options) {
      connections.push({ origin, options });
      const session = new FakeSession(remainingPlans);
      sessions.push(session);
      return session;
    },
  };
}

function makeTransport({ plans = [{}], now = NOW, ...overrides } = {}) {
  const harness = overrides.harness ?? makeHarness(plans);
  delete overrides.harness;
  const clock = typeof now === 'function' ? now : () => now;
  const transport = createApnsVoipTransport({
    teamId: TEAM_ID,
    keyId: KEY_ID,
    privateKey,
    bundleId: BUNDLE_ID,
    environment: 'development',
    clock,
    connect: harness.connect.bind(harness),
    ...overrides,
  });
  return { transport, harness };
}

function dialPayload(overrides = {}) {
  return {
    id: 'dial_0123456789abcdef0123456789abcdef',
    kind: 'info',
    message: 'Ship it?',
    aps: {},
    ...overrides,
  };
}

function payloadWithExactBytes(targetBytes) {
  const payload = { id: 'd', aps: {}, pad: '' };
  const baseBytes = Buffer.byteLength(JSON.stringify(payload), 'utf8');
  assert.ok(targetBytes >= baseBytes);
  payload.pad = 'x'.repeat(targetBytes - baseBytes);
  assert.equal(Buffer.byteLength(JSON.stringify(payload), 'utf8'), targetBytes);
  return payload;
}

function decodeProviderToken(authorization) {
  assert.match(authorization, /^bearer [A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/);
  const jwt = authorization.slice('bearer '.length);
  const parts = jwt.split('.');
  return {
    jwt,
    signingInput: `${parts[0]}.${parts[1]}`,
    header: JSON.parse(Buffer.from(parts[0], 'base64url').toString('utf8')),
    claims: JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8')),
    signature: Buffer.from(parts[2], 'base64url'),
  };
}

async function waitFor(predicate) {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setImmediate(resolve));
  }
  assert.fail('condition did not become true');
}

test('constructor rejects incomplete identity, unsafe endpoints, non-P-256 material, and unbounded deadlines', () => {
  const valid = {
    teamId: TEAM_ID,
    keyId: KEY_ID,
    privateKey,
    bundleId: BUNDLE_ID,
    environment: 'development',
  };
  const { privateKey: ed25519Key } = generateKeyPairSync('ed25519');
  const invalid = [
    { teamId: 'abcde12345' },
    { keyId: 'SHORT' },
    { privateKey: publicKey },
    { privateKey: ed25519Key },
    { privateKey: 'raw-key-text-is-not-a-KeyObject' },
    { bundleId: 'not-a-bundle' },
    { environment: 'https://attacker.invalid' },
    { environment: 'sandbox' },
    { requestTimeoutMs: 0 },
    { requestTimeoutMs: 60_001 },
    { connect: null },
    { onResult: true },
  ];
  for (const override of invalid) {
    assert.throws(
      () => createApnsVoipTransport({ ...valid, ...override }),
      (error) => error instanceof ApnsVoipTransportError && error.code === 'apns-configuration-invalid' && !error.cause,
    );
  }
});

test('sends byte-identical final payload to the fixed sandbox host with exact VoIP headers and a valid ES256 JWT', async () => {
  const responseId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const { transport, harness } = makeTransport({ plans: [{ status: 200, apnsId: responseId }] });
  const payload = dialPayload({ message: 'Spacing stays exact', aps: { 'content-available': 1 } });
  const expectedBody = JSON.stringify(payload);

  const result = await transport.send({ voipToken: DEVICE_TOKEN, platform: 'apns', payload });

  assert.deepEqual(result, { delivered: true, status: 200, apnsId: responseId });
  assert.deepEqual(harness.connections, [{
    origin: 'https://api.sandbox.push.apple.com',
    options: { minVersion: 'TLSv1.2', peerMaxConcurrentStreams: 1 },
  }]);
  const request = harness.sessions[0].requests[0];
  assert.equal(request.headers[':method'], 'POST');
  assert.equal(request.headers[':path'], `/3/device/${DEVICE_TOKEN.toLowerCase()}`);
  assert.equal(request.headers['apns-topic'], `${BUNDLE_ID}.voip`);
  assert.equal(request.headers['apns-push-type'], 'voip');
  assert.equal(request.headers['apns-priority'], '10');
  assert.equal(request.headers['apns-expiration'], '0');
  assert.equal(request.headers['content-type'], 'application/json');
  assert.equal(request.headers['content-length'], String(Buffer.byteLength(expectedBody)));
  assert.deepEqual(request.headers[http2SensitiveHeaders], ['authorization', ':path']);
  assert.match(request.headers['apns-id'], /^[0-9a-f-]{36}$/);
  assert.equal(request.body.toString('utf8'), expectedBody);

  const token = decodeProviderToken(request.headers.authorization);
  assert.deepEqual(token.header, { alg: 'ES256', kid: KEY_ID });
  assert.deepEqual(token.claims, { iss: TEAM_ID, iat: Math.floor(NOW / 1_000) });
  assert.equal(token.signature.byteLength, 64, 'Apple ES256 requires IEEE-P1363 R||S, not DER');
  assert.equal(token.jwt.includes('='), false, 'all JWT segments are unpadded base64url');
  assert.equal(cryptoVerify(
    'sha256',
    Buffer.from(token.signingInput, 'ascii'),
    { key: publicKey, dsaEncoding: 'ieee-p1363' },
    token.signature,
  ), true);
});

test('production selects only the fixed production host and a warm transport pools one HTTP/2 session', async () => {
  const harness = makeHarness([{ status: 200 }, { status: 200 }]);
  const { transport } = makeTransport({ harness, environment: 'production' });
  await transport.send({ voipToken: DEVICE_TOKEN, platform: 'apns', payload: dialPayload() });
  await transport.send({ voipToken: DEVICE_TOKEN, platform: 'apns', payload: dialPayload({ id: 'dial_second' }) });
  assert.equal(harness.connections.length, 1);
  assert.equal(harness.connections[0].origin, 'https://api.push.apple.com');
  assert.equal(harness.sessions[0].requests.length, 2);
});

test('cold concurrent fanout respects Apple token-auth stream admission before peer SETTINGS arrive', async () => {
  const server = createHttp2Server({ settings: { maxConcurrentStreams: 1 } });
  let received = 0;
  let active = 0;
  let maxActive = 0;
  let receivedSensitiveHeaders = [];
  server.on('stream', (stream, headers) => {
    received += 1;
    if (received === 1) receivedSensitiveHeaders = headers[http2SensitiveHeaders] ?? [];
    active += 1;
    maxActive = Math.max(maxActive, active);
    stream.on('error', () => {});
    setTimeout(() => {
      active -= 1;
      stream.respond({ ':status': 200 });
      stream.end();
    }, 5);
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const address = server.address();
  assert.ok(address && typeof address === 'object');
  const localOrigin = `http://127.0.0.1:${address.port}`;
  const connections = [];
  const { transport } = makeTransport({
    requestTimeoutMs: 5_000,
    connect(origin, options) {
      connections.push({ origin, options });
      return realHttp2Connect(localOrigin, options);
    },
  });

  try {
    const results = await Promise.all(Array.from({ length: 20 }, (_, index) => transport.send({
      voipToken: DEVICE_TOKEN,
      platform: 'apns',
      payload: dialPayload({ id: `dial_cold_${index}` }),
    })));
    assert.equal(results.filter((result) => result.delivered).length, 20);
    assert.equal(received, 20);
    assert.equal(maxActive, 1);
    assert.equal(receivedSensitiveHeaders.includes('authorization'), true);
    assert.equal(receivedSensitiveHeaders.includes(':path'), true);
    assert.deepEqual(connections, [{
      origin: 'https://api.sandbox.push.apple.com',
      options: { minVersion: 'TLSv1.2', peerMaxConcurrentStreams: 1 },
    }]);
  } finally {
    transport.close();
    await new Promise((resolve) => server.close(resolve));
  }
});

test('provider JWT is single-flight, cached before 50 minutes, and refreshed at the exact boundary', async () => {
  let now = NOW;
  let signCalls = 0;
  let releaseSigner;
  const signerGate = new Promise((resolve) => { releaseSigner = resolve; });
  const signer = async (...args) => {
    signCalls += 1;
    if (signCalls === 1) await signerGate;
    return cryptoSign(...args);
  };
  const harness = makeHarness([{ status: 200 }, { status: 200 }, { status: 200 }, { status: 200 }]);
  const { transport } = makeTransport({ harness, now: () => now, signer });

  const first = transport.send({ voipToken: DEVICE_TOKEN, platform: 'apns', payload: dialPayload({ id: 'dial_a' }) });
  const concurrent = transport.send({ voipToken: DEVICE_TOKEN, platform: 'apns', payload: dialPayload({ id: 'dial_b' }) });
  await waitFor(() => signCalls === 1);
  releaseSigner();
  await Promise.all([first, concurrent]);
  assert.equal(signCalls, 1, 'concurrent first sends share provider-token generation');
  assert.equal(harness.connections.length, 1, 'concurrent first sends share the lazy HTTP/2 session');
  const initialAuthorization = harness.sessions[0].requests[0].headers.authorization;
  assert.equal(harness.sessions[0].requests[1].headers.authorization, initialAuthorization);

  now += APNS_PROVIDER_TOKEN_TTL_MS - 1;
  await transport.send({ voipToken: DEVICE_TOKEN, platform: 'apns', payload: dialPayload({ id: 'dial_c' }) });
  assert.equal(signCalls, 1);
  assert.equal(harness.sessions[0].requests[2].headers.authorization, initialAuthorization);

  now += 1;
  await transport.send({ voipToken: DEVICE_TOKEN, platform: 'apns', payload: dialPayload({ id: 'dial_d' }) });
  assert.equal(signCalls, 2);
  assert.notEqual(harness.sessions[0].requests[3].headers.authorization, initialAuthorization);
});

test('a backward clock fails closed before another APNs request', async () => {
  let now = NOW;
  const { transport, harness } = makeTransport({ plans: [{ status: 200 }], now: () => now });
  await transport.send({ voipToken: DEVICE_TOKEN, platform: 'apns', payload: dialPayload() });
  now -= 1;
  await assert.rejects(
    transport.send({ voipToken: DEVICE_TOKEN, platform: 'apns', payload: dialPayload({ id: 'dial_late' }) }),
    (error) => error instanceof ApnsVoipTransportError && error.code === 'apns-clock-invalid' && !error.cause,
  );
  assert.equal(harness.sessions[0].requests.length, 1);
});

test('serializes before awaiting, preserves caller bytes, and enforces the exact 5120-byte ceiling', async () => {
  let releaseSigner;
  const gate = new Promise((resolve) => { releaseSigner = resolve; });
  const signer = async (...args) => {
    await gate;
    return cryptoSign(...args);
  };
  const harness = makeHarness([{ status: 200 }, { status: 200 }]);
  const { transport } = makeTransport({ harness, signer });
  const payload = payloadWithExactBytes(APNS_VOIP_MAX_PAYLOAD_BYTES);
  const originalBody = JSON.stringify(payload);
  const send = transport.send({ voipToken: DEVICE_TOKEN, platform: 'apns', payload });
  payload.id = 'mutated-after-call';
  payload.pad = 'mutated';
  releaseSigner();
  await send;
  assert.equal(harness.sessions[0].requests[0].body.byteLength, APNS_VOIP_MAX_PAYLOAD_BYTES);
  assert.equal(harness.sessions[0].requests[0].body.toString('utf8'), originalBody);

  await assert.rejects(
    transport.send({
      voipToken: DEVICE_TOKEN,
      platform: 'apns',
      payload: payloadWithExactBytes(APNS_VOIP_MAX_PAYLOAD_BYTES + 1),
    }),
    (error) => error.code === 'apns-request-invalid' && !error.cause,
  );
  assert.equal(harness.sessions[0].requests.length, 1, 'oversized bytes never reach HTTP/2');
});

test('rejects malformed tokens and non-final payloads without retaining secrets; FCM never touches APNs', async () => {
  const secret = 'must-never-escape';
  let connectCalls = 0;
  const { transport } = makeTransport({
    connect() {
      connectCalls += 1;
      return new FakeSession([]);
    },
  });
  const circular = dialPayload();
  circular.self = circular;
  const hostile = { aps: {} };
  Object.defineProperty(hostile, 'id', {
    enumerable: true,
    get() { throw new Error(secret); },
  });
  const invalid = [
    { voipToken: secret, platform: 'apns', payload: dialPayload() },
    { voipToken: 'abc', platform: 'apns', payload: dialPayload() },
    { voipToken: DEVICE_TOKEN, platform: 'apns', payload: { id: 'dial_no_aps' } },
    { voipToken: DEVICE_TOKEN, platform: 'apns', payload: { aps: {} } },
    { voipToken: DEVICE_TOKEN, platform: 'apns', payload: { id: 'dial_bad_aps', aps: [] } },
    { voipToken: DEVICE_TOKEN, platform: 'apns', payload: circular },
    { voipToken: DEVICE_TOKEN, platform: 'apns', payload: hostile },
    { voipToken: DEVICE_TOKEN, platform: 'apns', payload: { id: 'dial_bigint', aps: {}, value: 1n } },
  ];
  for (const input of invalid) {
    await assert.rejects(
      transport.send(input),
      (error) => error instanceof ApnsVoipTransportError &&
        error.code === 'apns-request-invalid' &&
        !String(error).includes(secret) && !error.cause,
    );
  }
  const fcm = await transport.send({ voipToken: secret, platform: 'fcm', payload: { private: secret } });
  assert.deepEqual(fcm, { delivered: false, reason: 'unsupported-platform', disposition: 'permanent' });
  assert.equal(connectCalls, 0);
});

test('classifies definitive Apple responses without replaying or mutating registry authority', async () => {
  const unregisteredAt = NOW - 60_000;
  const plans = [
    { status: 400, reason: 'BadDeviceToken' },
    { status: 400, reason: 'DeviceTokenNotForTopic' },
    { status: 410, reason: 'Unregistered', timestamp: unregisteredAt },
    { status: 410, reason: 'ExpiredToken', timestamp: unregisteredAt },
    { status: 429, reason: 'TooManyRequests', retryAfter: '120' },
    { status: 500, reason: 'InternalServerError' },
    { status: 503, reason: 'ServiceUnavailable', retryAfter: '15' },
  ];
  const { transport, harness } = makeTransport({ plans });
  const results = [];
  for (let index = 0; index < plans.length; index += 1) {
    results.push(await transport.send({
      voipToken: DEVICE_TOKEN,
      platform: 'apns',
      payload: dialPayload({ id: `dial_${index}` }),
    }));
  }
  assert.deepEqual(results.map(({ apnsId, ...result }) => result), [
    { delivered: false, status: 400, reason: 'BadDeviceToken', disposition: 'permanent' },
    { delivered: false, status: 400, reason: 'DeviceTokenNotForTopic', disposition: 'permanent' },
    { delivered: false, status: 410, reason: 'Unregistered', disposition: 'permanent', unregisteredAt: new Date(unregisteredAt).toISOString() },
    { delivered: false, status: 410, reason: 'ExpiredToken', disposition: 'permanent', unregisteredAt: new Date(unregisteredAt).toISOString() },
    { delivered: false, status: 429, reason: 'TooManyRequests', disposition: 'retryable-negative-ack', retryAfterSeconds: 120 },
    { delivered: false, status: 500, reason: 'InternalServerError', disposition: 'retryable-negative-ack', retryAfterSeconds: 900 },
    { delivered: false, status: 503, reason: 'ServiceUnavailable', disposition: 'retryable-negative-ack', retryAfterSeconds: 900 },
  ]);
  assert.equal(harness.sessions[0].requests.length, plans.length, 'explicit negative acks never loop internally');
});

test('UnrelatedKeyIdInToken retires the authenticated connection before later work', async () => {
  const harness = makeHarness([
    { status: 403, reason: 'UnrelatedKeyIdInToken' },
    { status: 200 },
  ]);
  const { transport } = makeTransport({ harness });
  const rejected = await transport.send({
    voipToken: DEVICE_TOKEN,
    platform: 'apns',
    payload: dialPayload({ id: 'dial_unrelated_key' }),
  });
  assert.equal(rejected.reason, 'UnrelatedKeyIdInToken');
  assert.equal(rejected.disposition, 'permanent');
  assert.equal(harness.sessions[0].destroyCalls, 1);

  const recovered = await transport.send({
    voipToken: DEVICE_TOKEN,
    platform: 'apns',
    payload: dialPayload({ id: 'dial_after_unrelated_key' }),
  });
  assert.equal(recovered.delivered, true);
  assert.equal(harness.sessions.length, 2);
});

test('refreshes once only for an explicit ExpiredProviderToken negative acknowledgement', async () => {
  let signCalls = 0;
  const signer = async () => {
    signCalls += 1;
    return Buffer.alloc(64, signCalls);
  };
  const { transport, harness } = makeTransport({
    plans: [{ status: 403, reason: 'ExpiredProviderToken' }, { status: 200 }],
    signer,
  });
  const result = await transport.send({ voipToken: DEVICE_TOKEN, platform: 'apns', payload: dialPayload() });
  assert.equal(result.delivered, true);
  assert.equal(signCalls, 2);
  assert.equal(harness.sessions[0].requests.length, 2);
  assert.notEqual(
    harness.sessions[0].requests[0].headers.authorization,
    harness.sessions[0].requests[1].headers.authorization,
  );

  const secondHarness = makeHarness([
    { status: 403, reason: 'ExpiredProviderToken' },
    { status: 403, reason: 'ExpiredProviderToken' },
  ]);
  const second = makeTransport({ harness: secondHarness, signer: async () => Buffer.alloc(64, 7) }).transport;
  const rejected = await second.send({ voipToken: DEVICE_TOKEN, platform: 'apns', payload: dialPayload() });
  assert.equal(rejected.reason, 'ExpiredProviderToken');
  assert.equal(secondHarness.sessions[0].requests.length, 2, 'a second expired-token response is returned, never replayed again');
});

test('stream failures and request deadlines are ambiguous, sanitized, and never automatically replayed', async () => {
  const secret = 'network-secret-bearing-error';
  const payloadSecret = 'private-dial-body';
  const events = [];
  const { transport, harness } = makeTransport({
    plans: [{ error: secret }],
    onResult: (event) => events.push(event),
  });
  const result = await transport.send({
    voipToken: DEVICE_TOKEN,
    platform: 'apns',
    payload: dialPayload({ message: payloadSecret }),
  });
  assert.equal(result.delivered, false);
  assert.equal(result.disposition, 'ambiguous');
  assert.equal(result.reason, 'transport-outcome-unknown');
  assert.equal(harness.sessions[0].requests.length, 1);
  const telemetry = JSON.stringify(events);
  assert.equal(telemetry.includes(secret), false);
  assert.equal(telemetry.includes(payloadSecret), false);
  assert.equal(telemetry.includes(DEVICE_TOKEN.toLowerCase()), false);
  assert.equal(telemetry.includes('bearer '), false);

  const timeoutHarness = makeHarness([{ never: true }, { status: 200 }]);
  const timeoutTransport = makeTransport({ harness: timeoutHarness, requestTimeoutMs: 10 }).transport;
  const timedOut = await timeoutTransport.send({ voipToken: DEVICE_TOKEN, platform: 'apns', payload: dialPayload() });
  assert.equal(timedOut.disposition, 'ambiguous');
  assert.equal(timeoutHarness.sessions[0].requests.length, 1, 'timeout does not replay a possibly accepted VoIP ring');
  assert.notEqual(timeoutHarness.sessions[0].requests[0].cancelCode, undefined);
  assert.equal(timeoutHarness.sessions[0].destroyCalls, 1, 'a timed-out connecting session is retired and destroyed');
  const recovered = await timeoutTransport.send({
    voipToken: DEVICE_TOKEN,
    platform: 'apns',
    payload: dialPayload({ id: 'dial_after_timeout' }),
  });
  assert.equal(recovered.delivered, true);
  assert.equal(timeoutHarness.sessions.length, 2, 'later work cannot reuse the timed-out session');
});

test('the end-to-end deadline bounds provider signing before any connection is opened', async () => {
  let deadlineNow = 0;
  let fireDeadline;
  let connectCalls = 0;
  const { transport } = makeTransport({
    requestTimeoutMs: 25,
    signer: () => new Promise(() => {}),
    deadlineClock: () => deadlineNow,
    setTimer(callback, delay) {
      assert.equal(delay, 25);
      fireDeadline = callback;
      return { deadline: true };
    },
    clearTimer() {},
    connect() {
      connectCalls += 1;
      return new FakeSession([]);
    },
  });
  const pending = transport.send({
    voipToken: DEVICE_TOKEN,
    platform: 'apns',
    payload: dialPayload({ id: 'dial_signer_deadline' }),
  });
  await waitFor(() => typeof fireDeadline === 'function');
  deadlineNow = 25;
  fireDeadline();

  const result = await pending;
  assert.equal(result.disposition, 'not-sent');
  assert.equal(result.reason, 'request-deadline-exceeded');
  assert.equal(connectCalls, 0);
  transport.close();
});

test('connection failure and shutdown during signing remain provably not-sent', async () => {
  const connectSecret = 'private-connect-failure';
  let connectCalls = 0;
  const connectFailure = makeTransport({
    connect() {
      connectCalls += 1;
      throw new Error(connectSecret);
    },
  }).transport;
  const unavailable = await connectFailure.send({
    voipToken: DEVICE_TOKEN,
    platform: 'apns',
    payload: dialPayload({ id: 'dial_connect_failure' }),
  });
  assert.equal(unavailable.disposition, 'not-sent');
  assert.equal(unavailable.reason, 'connection-unavailable');
  assert.equal(JSON.stringify(unavailable).includes(connectSecret), false);
  assert.equal(connectCalls, 1);

  let signCalls = 0;
  let releaseSigner;
  const signerGate = new Promise((resolve) => { releaseSigner = resolve; });
  const held = makeTransport({
    signer: async (...args) => {
      signCalls += 1;
      await signerGate;
      return cryptoSign(...args);
    },
  });
  const pending = held.transport.send({
    voipToken: DEVICE_TOKEN,
    platform: 'apns',
    payload: dialPayload({ id: 'dial_closed_while_signing' }),
  });
  await waitFor(() => signCalls === 1);
  held.transport.close();
  releaseSigner();
  const closed = await pending;
  assert.equal(closed.disposition, 'not-sent');
  assert.equal(closed.reason, 'transport-closed');
  assert.equal(held.harness.connections.length, 0);
});

test('GOAWAY retires the pooled session, while close cancels active work and permanently seals the transport', async () => {
  const harness = makeHarness([{ status: 200 }, { status: 200 }, { never: true }]);
  const { transport } = makeTransport({ harness, requestTimeoutMs: 1_000 });
  await transport.send({ voipToken: DEVICE_TOKEN, platform: 'apns', payload: dialPayload({ id: 'dial_first' }) });
  harness.sessions[0].emit('goaway');
  await transport.send({ voipToken: DEVICE_TOKEN, platform: 'apns', payload: dialPayload({ id: 'dial_second' }) });
  assert.equal(harness.sessions.length, 2);
  assert.equal(harness.sessions[0].closeCalls, 1);

  const pending = transport.send({ voipToken: DEVICE_TOKEN, platform: 'apns', payload: dialPayload({ id: 'dial_pending' }) });
  await waitFor(() => harness.sessions[1].requests.length === 2);
  transport.close();
  assert.equal((await pending).disposition, 'ambiguous');
  assert.equal(harness.sessions[1].destroyCalls, 1);
  await assert.rejects(
    transport.send({ voipToken: DEVICE_TOKEN, platform: 'apns', payload: dialPayload() }),
    (error) => error.code === 'apns-transport-closed',
  );
});

test('close also cancels and destroys an in-flight stream on a GOAWAY-retired session', async () => {
  const harness = makeHarness([{ never: true }]);
  const { transport } = makeTransport({ harness, requestTimeoutMs: 1_000 });
  const pending = transport.send({
    voipToken: DEVICE_TOKEN,
    platform: 'apns',
    payload: dialPayload({ id: 'dial_retired_pending' }),
  });
  await waitFor(() => harness.sessions[0]?.requests.length === 1);
  harness.sessions[0].emit('goaway');
  assert.equal(harness.sessions[0].destroyCalls, 0, 'GOAWAY lets the already-open stream finish before shutdown');

  transport.close();

  assert.equal((await pending).disposition, 'ambiguous');
  assert.equal(harness.sessions[0].destroyCalls, 1, 'transport shutdown covers retired sessions, not only the current pool');
});

test('synchronous request/end failures are typed by wire certainty, retire the pool, and never replay', async () => {
  for (const scenario of [
    { plan: { throwRequest: 'private-request-error' }, disposition: 'not-sent', reason: 'request-not-sent' },
    { plan: { throwOnEnd: 'private-write-error' }, disposition: 'ambiguous', reason: 'transport-outcome-unknown' },
  ]) {
    const firstPlan = scenario.plan;
    const harness = makeHarness([firstPlan, { status: 200 }]);
    const { transport } = makeTransport({ harness });
    const first = await transport.send({
      voipToken: DEVICE_TOKEN,
      platform: 'apns',
      payload: dialPayload({ id: 'dial_ambiguous_sync_failure' }),
    });
    assert.equal(first.disposition, scenario.disposition);
    assert.equal(first.reason, scenario.reason);
    assert.equal(harness.sessions.length, 1, 'the failed request is not automatically replayed');
    assert.equal(harness.sessions[0].destroyCalls, 1, 'the failed session is retired and destroyed');

    const second = await transport.send({
      voipToken: DEVICE_TOKEN,
      platform: 'apns',
      payload: dialPayload({ id: 'dial_after_sync_failure' }),
    });
    assert.equal(second.delivered, true);
    assert.equal(harness.sessions.length, 2, 'a later independent send gets a fresh session');
  }
});

test('unexpected session error or close settles active sends and rotates later work to a fresh session', async () => {
  for (const terminalEvent of ['error', 'close']) {
    const harness = makeHarness([{ never: true }, { status: 200 }]);
    const { transport } = makeTransport({ harness, requestTimeoutMs: 1_000 });
    const pending = transport.send({
      voipToken: DEVICE_TOKEN,
      platform: 'apns',
      payload: dialPayload({ id: `dial_session_${terminalEvent}` }),
    });
    await waitFor(() => harness.sessions[0]?.requests.length === 1);
    if (terminalEvent === 'error') harness.sessions[0].emit('error', new Error('private-session-error'));
    else harness.sessions[0].emit('close');
    assert.equal((await pending).disposition, 'ambiguous');

    const recovered = await transport.send({
      voipToken: DEVICE_TOKEN,
      platform: 'apns',
      payload: dialPayload({ id: `dial_after_session_${terminalEvent}` }),
    });
    assert.equal(recovered.delivered, true);
    assert.equal(harness.sessions.length, 2);
  }
});

test('malformed and oversized APNs responses fail closed without exposing raw response data', async () => {
  const secret = 'apple-response-secret';
  const { transport } = makeTransport({ plans: [
    { status: 200, body: '{}' },
    { status: 400, body: `{not-json-${secret}` },
    { status: 400, body: Buffer.alloc(4_097, 0x61) },
    { status: 'not-a-status', body: secret },
  ] });
  const results = [];
  for (let index = 0; index < 4; index += 1) {
    results.push(await transport.send({
      voipToken: DEVICE_TOKEN,
      platform: 'apns',
      payload: dialPayload({ id: `dial_malformed_${index}` }),
    }));
  }
  assert.deepEqual(results.map(({ apnsId, ...result }) => result), [
    { delivered: false, reason: 'malformed-response', disposition: 'ambiguous' },
    { delivered: false, status: 400, reason: 'malformed-response', disposition: 'permanent' },
    { delivered: false, status: 400, reason: 'malformed-response', disposition: 'permanent' },
    { delivered: false, reason: 'malformed-response', disposition: 'ambiguous' },
  ]);
  assert.equal(JSON.stringify(results).includes(secret), false);
});

test('the real gateway sender seam rings APNs and rejects an FCM route without network access', async () => {
  const harness = makeHarness([{ status: 200 }]);
  const { transport } = makeTransport({ harness });
  const apnsRegistry = {
    async lookup() { return [{ voipToken: DEVICE_TOKEN, platform: 'apns' }]; },
  };
  const apnsBackend = createDialPushBackend({
    deviceRegistry: apnsRegistry,
    apnsSend: transport.send,
    now: () => NOW,
  });
  const dispatched = await apnsBackend({ message: 'Ring Carter', sessionId: 'sess-1', humanId: 'u1' });
  assert.equal(dispatched.dispatched, true);
  assert.equal(harness.sessions[0].requests.length, 1);
  const wire = JSON.parse(harness.sessions[0].requests[0].body.toString('utf8'));
  assert.equal(wire.id, dispatched.dialId);
  assert.deepEqual(wire.aps, {});

  const fcmRegistry = {
    async lookup() { return [{ voipToken: 'not-even-an-apns-token', platform: 'fcm' }]; },
  };
  const fcmBackend = createDialPushBackend({
    deviceRegistry: fcmRegistry,
    apnsSend: transport.send,
    now: () => NOW,
  });
  const rejected = await fcmBackend({ message: 'Never cross providers', sessionId: 'sess-1', humanId: 'u1' });
  assert.equal(rejected.dispatched, false);
  assert.equal(rejected.reason, 'all-deliveries-failed');
  assert.equal(harness.sessions[0].requests.length, 1, 'FCM route never opened an APNs stream');
});
