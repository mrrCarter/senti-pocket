// senti-session-verifier.test.mjs — B3 native-door verifyToken. Fully hermetic (injected fetch); NO live api calls.
// Gate: validate via api (holds no secret), fail-closed on 401/403/non-200/error, cache SUCCESS only (hashed key), token
// forwarded verbatim + never leaked.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createSentiSessionVerifier } from '../src/senti-session-verifier.mjs';

function fakeFetch(handler) {
  const calls = [];
  const fetch = async (url, init) => { calls.push({ url, init }); return handler(url, init, calls.length); };
  return { fetch, calls };
}
const meOk = (id) => ({ ok: true, status: 200, json: async () => ({ id, email: 'x@example.com' }) });
const httpStatus = (s) => ({ ok: s >= 200 && s < 300, status: s, json: async () => ({ error: 'no' }) });

test('valid SENTI bearer -> GET /auth/me -> {humanId, principal, scopes}', async () => {
  const { fetch, calls } = fakeFetch(() => meOk('user_42'));
  const verify = createSentiSessionVerifier({ fetch, apiBaseUrl: 'https://api.example.com/' }); // trailing slash trimmed
  const ctx = await verify({ authorization: 'Bearer SENTI_TOK' });
  assert.equal(calls[0].url, 'https://api.example.com/api/v1/auth/me');
  assert.equal(calls[0].init.method, 'GET');
  assert.equal(calls[0].init.headers.authorization, 'Bearer SENTI_TOK'); // caller token forwarded verbatim
  assert.equal(ctx.humanId, 'user_42');
  assert.equal(ctx.principal, 'pocket.principal.senti.v1\n7:user_42'); // distinct namespace + length-prefixed
  assert.deepEqual(ctx.scopes, ['sessions:read', 'sessions:write', 'pocket:voice', 'pocket:dial']);
});

test('fail-closed: 401 -> null and NOT cached (a revoked token keeps failing)', async () => {
  const { fetch, calls } = fakeFetch(() => httpStatus(401));
  const verify = createSentiSessionVerifier({ fetch, apiBaseUrl: 'https://a' });
  assert.equal(await verify({ authorization: 'Bearer BAD' }), null);
  assert.equal(await verify({ authorization: 'Bearer BAD' }), null);
  assert.equal(calls.length, 2, 'a failure is never cached -> re-validated every call');
});

test('fail-closed: 403 / 5xx / network error / non-JSON / missing id -> null', async () => {
  const mk = (fetch) => createSentiSessionVerifier({ fetch, apiBaseUrl: 'https://a' });
  assert.equal(await mk(fakeFetch(() => httpStatus(403)).fetch)({ authorization: 'Bearer x' }), null);
  assert.equal(await mk(fakeFetch(() => httpStatus(500)).fetch)({ authorization: 'Bearer x' }), null);
  assert.equal(await mk(async () => { throw new Error('ECONNREFUSED'); })({ authorization: 'Bearer x' }), null);
  assert.equal(await mk(async () => ({ ok: true, status: 200, json: async () => { throw new Error('bad'); } }))({ authorization: 'Bearer x' }), null);
  assert.equal(await mk(async () => ({ ok: true, status: 200, json: async () => ({ email: 'no-id' }) }))({ authorization: 'Bearer x' }), null);
});

test('no bearer -> null (fail-closed), never calls the api', async () => {
  const { fetch, calls } = fakeFetch(() => meOk('u'));
  const verify = createSentiSessionVerifier({ fetch, apiBaseUrl: 'https://a' });
  assert.equal(await verify({}), null);
  assert.equal(await verify(null), null);
  assert.equal(calls.length, 0);
});

test('caches a SUCCESSFUL validation within TTL; re-validates after it lapses', async () => {
  let t = 1000;
  const { fetch, calls } = fakeFetch(() => meOk('user_9'));
  const verify = createSentiSessionVerifier({ fetch, apiBaseUrl: 'https://a', cacheTtlMs: 100, now: () => t });
  await verify({ authorization: 'Bearer T' });
  await verify({ authorization: 'Bearer T' });
  assert.equal(calls.length, 1, 'second call within TTL served from cache');
  t += 200; // past TTL
  await verify({ authorization: 'Bearer T' });
  assert.equal(calls.length, 2, 'past TTL -> re-validated against the api');
});

test('different tokens validate + cache independently (hashed key)', async () => {
  const { fetch, calls } = fakeFetch((_u, init) => meOk(init.headers.authorization === 'Bearer A' ? 'ua' : 'ub'));
  const verify = createSentiSessionVerifier({ fetch, apiBaseUrl: 'https://a' });
  assert.equal((await verify({ authorization: 'Bearer A' })).humanId, 'ua');
  assert.equal((await verify({ authorization: 'Bearer B' })).humanId, 'ub');
  assert.equal(calls.length, 2);
});

test('cache is size-bounded: at capacity the OLDEST positive is evicted (re-validates)', async () => {
  const { fetch, calls } = fakeFetch((_u, init) => meOk('u_' + init.headers.authorization));
  const verify = createSentiSessionVerifier({ fetch, apiBaseUrl: 'https://a', maxCacheEntries: 2, now: () => 1000 });
  await verify({ authorization: 'Bearer A' });                 // cache {A}
  await verify({ authorization: 'Bearer B' });                 // cache {A,B}
  await verify({ authorization: 'Bearer C' });                 // at cap -> evict oldest (A) -> cache {B,C}
  assert.equal(calls.length, 3);
  await verify({ authorization: 'Bearer B' });                 // still cached
  assert.equal(calls.length, 3, 'B not evicted -> served from cache');
  await verify({ authorization: 'Bearer A' });                 // A was evicted -> re-validated
  assert.equal(calls.length, 4, 'A evicted -> re-fetched');
});

test('the returned identity is deeply FROZEN (cached by-ref; no downstream mutation can poison the cache) — Warden note 1', async () => {
  const { fetch } = fakeFetch(() => meOk('user_frozen'));
  const verify = createSentiSessionVerifier({ fetch, apiBaseUrl: 'https://a', now: () => 1000 });
  const ctx = await verify({ authorization: 'Bearer T' });
  assert.ok(Object.isFrozen(ctx), 'result object frozen');
  assert.ok(Object.isFrozen(ctx.scopes), 'scopes array frozen');
  assert.ok(Object.isFrozen(ctx.tokenClaims), 'tokenClaims frozen');
  assert.throws(() => ctx.scopes.push('sessions:admin'), TypeError, 'in-place scope mutation is rejected');
  // the cached entry stays unpoisoned: a second (cached) hit still has the original scopes
  const ctx2 = await verify({ authorization: 'Bearer T' });
  assert.deepEqual(ctx2.scopes, ['sessions:read', 'sessions:write', 'pocket:voice', 'pocket:dial']);
});

test('factory requires fetch + apiBaseUrl', () => {
  assert.throws(() => createSentiSessionVerifier({ apiBaseUrl: 'https://a' }), /fetch is required/);
  assert.throws(() => createSentiSessionVerifier({ fetch: async () => {} }), /apiBaseUrl is required/);
});
