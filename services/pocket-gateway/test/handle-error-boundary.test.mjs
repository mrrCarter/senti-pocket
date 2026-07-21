// handle-error-boundary.test.mjs — handle() is the gateway contract boundary; an unexpected handler throw must become a
// clean 500 (no stack/detail leaked), never a runtime crash / adapter-specific 5xx.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createGateway } from '../src/handlers.mjs';

const authed = (extra = {}) => createGateway({
  verifyToken: async (h) => (h && h.authorization ? { humanId: 'u', scopes: ['sessions:read'] } : null),
  ...extra,
});

test('an unexpected async handler error -> clean 500, no internal detail leaked', async () => {
  const gw = authed({ bundleStore: { listForHuman: async () => { throw new Error('db exploded: SECRET_CONN_STRING'); } } });
  const res = await gw.handle({ method: 'GET', path: '/sync', headers: { authorization: 'Bearer t' } });
  assert.equal(res.status, 500);
  const body = typeof res.body === 'string' ? JSON.parse(res.body) : res.body;
  assert.equal(body.error, 'internal error');
  assert.ok(!JSON.stringify(body).includes('SECRET_CONN_STRING'), 'internal error detail must NOT leak to the client');
});

test('a synchronous throw in a handler is also caught (500, not a rejected promise)', async () => {
  const gw = authed({ bundleStore: { listForHuman: () => { throw new Error('sync boom'); } } });
  const res = await gw.handle({ method: 'GET', path: '/sync', headers: { authorization: 'Bearer t' } });
  assert.equal(res.status, 500);
});

test('normal routes unaffected by the error boundary', async () => {
  const gw = authed();
  assert.equal((await gw.handle({ method: 'GET', path: '/health' })).status, 200);                                   // pre-auth health
  assert.equal((await gw.handle({ method: 'GET', path: '/sync', headers: {} })).status, 401);                        // no token
  assert.equal((await gw.handle({ method: 'GET', path: '/nope', headers: { authorization: 'Bearer t' } })).status, 404); // authed, no route
});
