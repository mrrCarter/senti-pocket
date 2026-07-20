// app.test.mjs — production composition MUST fail boot on missing config/deps (Echo P0), and wire up when complete.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync } from 'node:crypto';
import { createProdGateway, createLambda } from '../src/app.mjs';

// Pocket-gateway is SENTI-native (B3): no AIdenID issuer/audience/resource/site or JWKS — auth is GET /auth/me.
const FULL_ENV = {
  DDB_TABLE: 'pocket-gateway',
  SIGNING_KEY_ID: 'kms-key-1',
  GATEWAY_PUBLIC_URL: 'https://pocket-api.sentinelayer.com',
  SENTI_API_BASE_URL: 'https://api.sentinelayer.com',
};
const FULL_DEPS = { dynamoClient: {}, signingKey: generateKeyPairSync('ed25519').privateKey, knownSessionIdsFor: async () => [], fetch: async () => ({ ok: true, status: 200, text: async () => '{}' }) };

test('createProdGateway FAILS BOOT on any missing production binding', () => {
  assert.throws(() => createProdGateway({}, FULL_DEPS), /prod config missing/);
  for (const k of Object.keys(FULL_ENV)) {
    const env = { ...FULL_ENV }; delete env[k];
    assert.throws(() => createProdGateway(env, FULL_DEPS), /prod config missing/, 'missing ' + k + ' must fail boot');
  }
});

test('createProdGateway FAILS BOOT on missing/empty deps', () => {
  assert.throws(() => createProdGateway(FULL_ENV, {}), /prod deps missing/);
  assert.throws(() => createProdGateway(FULL_ENV, { ...FULL_DEPS, dynamoClient: undefined }), /prod deps missing/, 'missing dynamoClient fails boot');
  assert.throws(() => createProdGateway(FULL_ENV, { ...FULL_DEPS, knownSessionIdsFor: undefined }), /prod deps missing/);
  assert.throws(() => createProdGateway(FULL_ENV, { ...FULL_DEPS, fetch: undefined }), /prod deps missing/, 'missing fetch fails boot (human-write client needs it)');
});

// Regression guard for the prod humanMessage `undefined dep -> TypeError` gap: the human-write client is a BOOT
// INVARIANT — boot cannot succeed without SENTI_API_BASE_URL + fetch, which are exactly what construct + wire it.
test('createProdGateway REQUIRES the human-write config so deps.postHumanMessage is never undefined', () => {
  const noBase = { ...FULL_ENV }; delete noBase.SENTI_API_BASE_URL;
  assert.throws(() => createProdGateway(noBase, FULL_DEPS), /prod config missing: SENTI_API_BASE_URL/);
  assert.throws(() => createProdGateway(FULL_ENV, { ...FULL_DEPS, fetch: undefined }), /prod deps missing/);
  assert.equal(typeof createProdGateway(FULL_ENV, FULL_DEPS).handle, 'function'); // both present => boots => client wired
});

test('createProdGateway + createLambda boot with complete config', () => {
  const gw = createProdGateway(FULL_ENV, FULL_DEPS);
  assert.equal(typeof gw.handle, 'function');
  assert.equal(typeof createLambda(FULL_ENV, FULL_DEPS), 'function');
});
