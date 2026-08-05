import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  SentiTargetMembershipCredentialRejectedError,
  SentiTargetMembershipInvalidTargetError,
  SentiTargetMembershipRateLimitedError,
  SentiTargetMembershipUnavailableError,
  createSentiTargetMembershipResolver,
} from '../src/senti-target-membership.mjs';

const BASE = 'https://api.example.com';
const SESSION = 'folder/target-α';
const AUTHORIZATION = 'Bearer token.A_1';
const CONTRACT_HEADERS = Object.freeze({
  'content-type': 'application/json',
  'cache-control': 'private, no-store',
  pragma: 'no-cache',
});

const response = (status, body = '', headers = {}) => new Response(body, {
  status,
  headers: { ...CONTRACT_HEADERS, ...headers },
});

const membershipResponse = (sessionId = SESSION, membershipRole = 'viewer', overrides = {}) => response(
  200,
  JSON.stringify({ sessionId, membershipRole, ...(overrides.extra || {}) }),
  overrides.headers,
);

test('issues one exact no-cache GET under the original bearer and accepts every frozen API role', async () => {
  for (const role of ['owner', 'admin', 'contributor', 'viewer']) {
    const calls = [];
    const resolver = createSentiTargetMembershipResolver({
      apiBaseUrl: `${BASE}/`,
      fetch: async (url, options) => { calls.push({ url, options }); return membershipResponse(SESSION, role); },
    });
    const result = await resolver({ sessionId: SESSION, authorization: AUTHORIZATION });
    assert.deepEqual(result, { sessionId: SESSION, membershipRole: role });
    assert.equal(Object.isFrozen(result), true);
    assert.equal(calls.length, 1);
    assert.equal(calls[0].url, `${BASE}/api/v1/sessions/folder%2Ftarget-%CE%B1/membership`);
    assert.equal(calls[0].options.method, 'GET');
    assert.equal(calls[0].options.headers.authorization, AUTHORIZATION);
    assert.equal(calls[0].options.headers.accept, 'application/json');
    assert.equal(calls[0].options.headers['accept-encoding'], 'identity');
    assert.equal(calls[0].options.headers['cache-control'], 'no-store');
    assert.equal(calls[0].options.headers.pragma, 'no-cache');
    assert.equal(calls[0].options.cache, 'no-store');
    assert.equal(calls[0].options.redirect, 'error');
    assert.ok(calls[0].options.signal instanceof AbortSignal);
  }
});

test('constructor rejects any non-production origin or unsafe bound', () => {
  const fetch = async () => response(404);
  for (const apiBaseUrl of [undefined, '', 'http://api.example.com', 'https://u:p@api.example.com', 'https://api.example.com/v1', 'https://api.example.com?x=1', 'https://api.example.com#x']) {
    assert.throws(() => createSentiTargetMembershipResolver({ fetch, apiBaseUrl }), /HTTPS origin/);
  }
  assert.throws(() => createSentiTargetMembershipResolver({ apiBaseUrl: BASE }), /fetch is required/);
  for (const config of [
    { timeoutMs: 0 },
    { maxResponseBytes: -1 },
    { positiveTtlMs: -1 },
    { negativeTtlMs: 1.5 },
    { maxCacheEntries: 0 },
    { maxInFlight: 0 },
  ]) {
    assert.throws(() => createSentiTargetMembershipResolver({ fetch, apiBaseUrl: BASE, ...config }));
  }
});

test('rejects malformed target or bearer before fetch and never includes either secret in errors', async () => {
  let calls = 0;
  const resolver = createSentiTargetMembershipResolver({
    apiBaseUrl: BASE,
    fetch: async () => { calls += 1; return response(404); },
  });
  for (const sessionId of ['', ' target', 'target ', '.', '..', 'x\u0000y', 'x'.repeat(65), 'x'.repeat(1_000_000), '\ud800']) {
    await assert.rejects(
      resolver({ sessionId, authorization: AUTHORIZATION }),
      SentiTargetMembershipInvalidTargetError,
    );
  }
  await assert.rejects(
    resolver({ sessionId: 'private-session-secret ', authorization: AUTHORIZATION }),
    (error) => error instanceof SentiTargetMembershipInvalidTargetError &&
      !String(error).includes('private-session-secret'),
  );
  for (const authorization of ['', 'Basic secret', 'Bearer two words', 'Bearer token\r\nX: y', `Bearer ${'a'.repeat(1_000_000)}`]) {
    await assert.rejects(
      resolver({ sessionId: 'private-target', authorization }),
      (error) => error instanceof SentiTargetMembershipCredentialRejectedError &&
        !String(error).includes('private-target') && !String(error).includes('secret'),
    );
  }
  assert.equal(calls, 0);
});

test('only exact 200 schema/echo/role and response policy are accepted', async () => {
  const badResponses = [
    () => response(200, 'null'),
    () => response(200, '[]'),
    () => response(200, JSON.stringify({ sessionId: SESSION })),
    () => response(200, JSON.stringify({ sessionId: SESSION, membershipRole: 'viewer', extra: true })),
    () => response(200, JSON.stringify({ sessionId: 'other', membershipRole: 'viewer' })),
    () => response(200, JSON.stringify({ sessionId: SESSION, membershipRole: 'Viewer' })),
    () => response(200, JSON.stringify({ sessionId: SESSION, membershipRole: 'editor' })),
    () => response(200, '{'),
    () => membershipResponse(SESSION, 'viewer', { headers: { 'content-type': 'text/plain' } }),
    () => membershipResponse(SESSION, 'viewer', { headers: { 'cache-control': 'private' } }),
    () => membershipResponse(SESSION, 'viewer', { headers: { pragma: 'cache' } }),
    () => membershipResponse(SESSION, 'viewer', { headers: { 'content-encoding': 'gzip' } }),
  ];
  for (const makeResponse of badResponses) {
    const resolver = createSentiTargetMembershipResolver({ fetch: async () => makeResponse(), apiBaseUrl: BASE });
    await assert.rejects(
      resolver({ sessionId: SESSION, authorization: AUTHORIZATION }),
      SentiTargetMembershipUnavailableError,
    );
  }
});

test('every pre-reader policy, length, and body-shape rejection releases the upstream body', async () => {
  const badHeaders = [
    { 'content-type': 'text/plain' },
    { 'cache-control': 'private' },
    { pragma: 'cache' },
    { 'content-encoding': 'gzip' },
    { 'content-length': '01' },
    { 'content-length': '999999' },
  ];
  for (const headers of badHeaders) {
    let cancels = 0;
    let readerRequests = 0;
    const resolver = createSentiTargetMembershipResolver({
      apiBaseUrl: BASE,
      fetch: async () => ({
        status: 200,
        headers: new Headers({ ...CONTRACT_HEADERS, ...headers }),
        body: {
          cancel() { cancels += 1; return Promise.resolve(); },
          getReader() { readerRequests += 1; throw new Error('must reject before reading'); },
        },
      }),
    });
    await assert.rejects(
      resolver({ sessionId: SESSION, authorization: AUTHORIZATION }),
      SentiTargetMembershipUnavailableError,
    );
    assert.equal(readerRequests, 0);
    assert.equal(cancels, 1);
  }

  for (const bodyFactory of [
    (cancel) => ({ cancel }),
    (cancel) => ({ cancel, getReader() { throw new Error('reader acquisition failed'); } }),
  ]) {
    let cancels = 0;
    const resolver = createSentiTargetMembershipResolver({
      apiBaseUrl: BASE,
      fetch: async () => ({
        status: 200,
        headers: new Headers(CONTRACT_HEADERS),
        body: bodyFactory(() => { cancels += 1; return Promise.resolve(); }),
      }),
    });
    await assert.rejects(
      resolver({ sessionId: SESSION, authorization: AUTHORIZATION }),
      SentiTargetMembershipUnavailableError,
    );
    assert.equal(cancels, 1);
  }

  let bodyCancels = 0;
  let readerCancels = 0;
  let releases = 0;
  const invalidReaderResolver = createSentiTargetMembershipResolver({
    apiBaseUrl: BASE,
    fetch: async () => ({
      status: 200,
      headers: new Headers(CONTRACT_HEADERS),
      body: {
        cancel() { bodyCancels += 1; return Promise.resolve(); },
        getReader: () => ({
          cancel() { readerCancels += 1; return Promise.resolve(); },
          releaseLock() { releases += 1; },
        }),
      },
    }),
  });
  await assert.rejects(
    invalidReaderResolver({ sessionId: SESSION, authorization: AUTHORIZATION }),
    SentiTargetMembershipUnavailableError,
  );
  assert.equal(readerCancels, 1);
  assert.equal(releases, 1);
  assert.equal(bodyCancels, 1);

  let malformedStatusCancels = 0;
  const malformedStatusResolver = createSentiTargetMembershipResolver({
    apiBaseUrl: BASE,
    fetch: async () => ({
      status: '200',
      headers: new Headers(CONTRACT_HEADERS),
      body: { cancel() { malformedStatusCancels += 1; return Promise.resolve(); } },
    }),
  });
  await assert.rejects(
    malformedStatusResolver({ sessionId: SESSION, authorization: AUTHORIZATION }),
    SentiTargetMembershipUnavailableError,
  );
  assert.equal(malformedStatusCancels, 1);

  let hostileHeaderCancels = 0;
  const hostileHeaderResolver = createSentiTargetMembershipResolver({
    apiBaseUrl: BASE,
    fetch: async () => ({
      status: 200,
      get headers() { throw new Error('raw-header-secret'); },
      body: { cancel() { hostileHeaderCancels += 1; return Promise.resolve(); } },
    }),
  });
  await assert.rejects(
    hostileHeaderResolver({ sessionId: SESSION, authorization: AUTHORIZATION }),
    (error) => error instanceof SentiTargetMembershipUnavailableError && !String(error).includes('raw-header-secret'),
  );
  assert.equal(hostileHeaderCancels, 1);
});

test('200 body reader is byte-bounded, counts multibyte UTF-8, and cancels over-cap streams', async () => {
  const exact = JSON.stringify({ sessionId: SESSION, membershipRole: 'viewer' });
  const exactBytes = new TextEncoder().encode(exact);
  const exactResolver = createSentiTargetMembershipResolver({
    apiBaseUrl: BASE,
    maxResponseBytes: exactBytes.byteLength,
    fetch: async () => response(200, exact),
  });
  assert.equal((await exactResolver({ sessionId: SESSION, authorization: AUTHORIZATION })).membershipRole, 'viewer');

  let declaredCancelled = 0;
  const declaredBody = { cancel() { declaredCancelled += 1; return Promise.resolve(); } };
  const declaredResolver = createSentiTargetMembershipResolver({
    apiBaseUrl: BASE,
    maxResponseBytes: 32,
    fetch: async () => ({ status: 200, headers: new Headers({ ...CONTRACT_HEADERS, 'content-length': '33' }), body: declaredBody }),
  });
  await assert.rejects(declaredResolver({ sessionId: SESSION, authorization: AUTHORIZATION }), SentiTargetMembershipUnavailableError);
  assert.equal(declaredCancelled, 1, 'declared oversize is cancelled before a read');

  let streamCancelled = 0;
  const reader = {
    reads: 0,
    async read() {
      this.reads += 1;
      return this.reads === 1 ? { done: false, value: new Uint8Array(33) } : { done: true, value: undefined };
    },
    cancel() { streamCancelled += 1; return Promise.resolve(); },
    releaseLock() {},
  };
  const streamResolver = createSentiTargetMembershipResolver({
    apiBaseUrl: BASE,
    maxResponseBytes: 32,
    fetch: async () => ({ status: 200, headers: new Headers(CONTRACT_HEADERS), body: { getReader: () => reader } }),
  });
  await assert.rejects(streamResolver({ sessionId: SESSION, authorization: AUTHORIZATION }), SentiTargetMembershipUnavailableError);
  assert.ok(streamCancelled >= 1);
});

test('invalid UTF-8 and stream read failures are sanitized unavailable errors', async () => {
  for (const body of [
    new ReadableStream({ start(controller) { controller.enqueue(Uint8Array.of(0xff)); controller.close(); } }),
    new ReadableStream({ pull() { throw new Error('raw-stream-secret'); } }),
  ]) {
    const resolver = createSentiTargetMembershipResolver({
      apiBaseUrl: BASE,
      fetch: async () => ({ status: 200, headers: new Headers(CONTRACT_HEADERS), body }),
    });
    await assert.rejects(
      resolver({ sessionId: SESSION, authorization: AUTHORIZATION }),
      (error) => error instanceof SentiTargetMembershipUnavailableError && !String(error).includes('raw-stream-secret'),
    );
  }
});

test('404 alone is a cached null decision; its body is never parsed', async () => {
  let clock = 100;
  let calls = 0;
  let cancels = 0;
  const resolver = createSentiTargetMembershipResolver({
    apiBaseUrl: BASE,
    negativeTtlMs: 10,
    now: () => clock,
    fetch: async () => {
      calls += 1;
      return {
        status: 404,
        headers: new Headers(CONTRACT_HEADERS),
        body: { cancel() { cancels += 1; return Promise.resolve(); }, getReader() { throw new Error('must not parse'); } },
      };
    },
  });
  assert.equal(await resolver({ sessionId: SESSION, authorization: AUTHORIZATION }), null);
  assert.equal(await resolver({ sessionId: SESSION, authorization: AUTHORIZATION }), null);
  assert.equal(calls, 1);
  clock = 111;
  assert.equal(await resolver({ sessionId: SESSION, authorization: AUTHORIZATION }), null);
  assert.equal(calls, 2);
  assert.equal(cancels, 2);
});

test('a policy-invalid 404 is cancelled, rejected, and never negative-cached', async () => {
  let calls = 0;
  let cancels = 0;
  const resolver = createSentiTargetMembershipResolver({
    apiBaseUrl: BASE,
    fetch: async () => {
      calls += 1;
      return {
        status: 404,
        headers: new Headers({ ...CONTRACT_HEADERS, 'cache-control': 'private' }),
        body: { cancel() { cancels += 1; return Promise.resolve(); } },
      };
    },
  });
  await assert.rejects(
    resolver({ sessionId: SESSION, authorization: AUTHORIZATION }),
    SentiTargetMembershipUnavailableError,
  );
  await assert.rejects(
    resolver({ sessionId: SESSION, authorization: AUTHORIZATION }),
    SentiTargetMembershipUnavailableError,
  );
  assert.equal(calls, 2);
  assert.equal(cancels, 2);
});

test('401/403, 429, and outages are typed and never cached', async () => {
  for (const status of [401, 403]) {
    let calls = 0;
    const resolver = createSentiTargetMembershipResolver({
      apiBaseUrl: BASE,
      fetch: async () => { calls += 1; return response(status); },
    });
    await assert.rejects(resolver({ sessionId: SESSION, authorization: AUTHORIZATION }), SentiTargetMembershipCredentialRejectedError);
    await assert.rejects(resolver({ sessionId: SESSION, authorization: AUTHORIZATION }), SentiTargetMembershipCredentialRejectedError);
    assert.equal(calls, 2);
  }

  let rateCalls = 0;
  const limited = createSentiTargetMembershipResolver({
    apiBaseUrl: BASE,
    fetch: async () => { rateCalls += 1; return response(429, '', { 'retry-after': '99999' }); },
  });
  await assert.rejects(
    limited({ sessionId: SESSION, authorization: AUTHORIZATION }),
    (error) => error instanceof SentiTargetMembershipRateLimitedError && error.retryAfterSeconds === 3600,
  );
  await assert.rejects(limited({ sessionId: SESSION, authorization: AUTHORIZATION }), SentiTargetMembershipRateLimitedError);
  assert.equal(rateCalls, 2);

  for (const outcome of [() => response(500), () => response(302), () => { throw new Error('transport-secret'); }]) {
    const resolver = createSentiTargetMembershipResolver({ apiBaseUrl: BASE, fetch: async () => outcome() });
    await assert.rejects(
      resolver({ sessionId: SESSION, authorization: AUTHORIZATION }),
      (error) => error instanceof SentiTargetMembershipUnavailableError && !String(error).includes('secret'),
    );
  }
});

test('deadline aborts a hanging fetch without exposing transport details', async () => {
  const resolver = createSentiTargetMembershipResolver({
    apiBaseUrl: BASE,
    timeoutMs: 5,
    fetch: async (_url, { signal }) => new Promise((resolve, reject) => {
      signal.addEventListener('abort', () => reject(new Error('deadline-transport-secret')), { once: true });
    }),
  });
  await assert.rejects(
    resolver({ sessionId: SESSION, authorization: AUTHORIZATION }),
    (error) => error instanceof SentiTargetMembershipUnavailableError && !String(error).includes('secret'),
  );

  let cancelled = 0;
  const bodyResolver = createSentiTargetMembershipResolver({
    apiBaseUrl: BASE,
    timeoutMs: 5,
    fetch: async () => ({
      status: 200,
      headers: new Headers(CONTRACT_HEADERS),
      body: {
        getReader: () => ({
          read: () => new Promise(() => {}),
          cancel: () => { cancelled += 1; return Promise.resolve(); },
          releaseLock() {},
        }),
      },
    }),
  });
  const keepEventLoopAlive = setInterval(() => {}, 50);
  try {
    await assert.rejects(
      bodyResolver({ sessionId: SESSION, authorization: AUTHORIZATION }),
      SentiTargetMembershipUnavailableError,
    );
  } finally {
    clearInterval(keepEventLoopAlive);
  }
  assert.ok(cancelled >= 1, 'the same deadline also cancels a body stalled after response headers');
});

test('positive cache isolates exact credential+target, expires, and evicts by bounded LRU', async () => {
  let clock = 100;
  let calls = 0;
  const resolver = createSentiTargetMembershipResolver({
    apiBaseUrl: BASE,
    positiveTtlMs: 10,
    maxCacheEntries: 2,
    now: () => clock,
    fetch: async (url) => {
      calls += 1;
      const sessionId = decodeURIComponent(String(url).split('/sessions/')[1].split('/membership')[0]);
      return membershipResponse(sessionId, 'admin');
    },
  });
  const lookup = (sessionId, token = AUTHORIZATION) => resolver({ sessionId, authorization: token });
  await lookup('target-a');
  await lookup('target-a');
  assert.equal(calls, 1);
  await lookup('target-a', 'Bearer token.B_2');
  assert.equal(calls, 2, 'credential B cannot reuse credential A decision');
  await lookup('target-a'); // touch A as most recent
  await lookup('target-c'); // evicts token B
  assert.equal(calls, 3);
  await lookup('target-a', 'Bearer token.B_2');
  assert.equal(calls, 4);
  clock = 111;
  await lookup('target-a');
  assert.equal(calls, 5, 'positive decision expires at the configured bound');
});

test('same-key calls dedupe, unique in-flight cap fails closed, and failed promises are removed', async () => {
  let release;
  let calls = 0;
  const resolver = createSentiTargetMembershipResolver({
    apiBaseUrl: BASE,
    maxInFlight: 1,
    fetch: async () => {
      calls += 1;
      return new Promise((resolve) => { release = () => resolve(membershipResponse(SESSION, 'owner')); });
    },
  });
  const first = resolver({ sessionId: SESSION, authorization: AUTHORIZATION });
  const duplicate = resolver({ sessionId: SESSION, authorization: AUTHORIZATION });
  await assert.rejects(
    resolver({ sessionId: 'other-target', authorization: AUTHORIZATION }),
    SentiTargetMembershipUnavailableError,
  );
  assert.equal(calls, 1);
  release();
  const [a, b] = await Promise.all([first, duplicate]);
  assert.deepEqual(a, b);
  assert.equal(calls, 1);

  let attempts = 0;
  const recovering = createSentiTargetMembershipResolver({
    apiBaseUrl: BASE,
    fetch: async () => {
      attempts += 1;
      if (attempts === 1) throw new Error('first failure');
      return membershipResponse(SESSION, 'viewer');
    },
  });
  await assert.rejects(recovering({ sessionId: SESSION, authorization: AUTHORIZATION }), SentiTargetMembershipUnavailableError);
  assert.equal((await recovering({ sessionId: SESSION, authorization: AUTHORIZATION })).membershipRole, 'viewer');
  assert.equal(attempts, 2);
});

test('backward clock clears decisions; invalid clock fails before fetch', async () => {
  let clock = 100;
  let calls = 0;
  const resolver = createSentiTargetMembershipResolver({
    apiBaseUrl: BASE,
    now: () => clock,
    fetch: async () => { calls += 1; return membershipResponse(); },
  });
  await resolver({ sessionId: SESSION, authorization: AUTHORIZATION });
  clock = 90;
  await resolver({ sessionId: SESSION, authorization: AUTHORIZATION });
  assert.equal(calls, 2);
  clock = Number.NaN;
  await assert.rejects(resolver({ sessionId: SESSION, authorization: AUTHORIZATION }), SentiTargetMembershipUnavailableError);
  assert.equal(calls, 2);
});
