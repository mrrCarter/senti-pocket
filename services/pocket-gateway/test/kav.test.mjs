// kav.test.mjs — the committed Node<->Swift known-answer vector (Echo #233248 P1e). The phone pins the RAW base64url
// Ed25519 public key and MUST verify these exact committed bytes; this proves the Node side. Swift consumes the same
// test/fixtures/pocket_kav_v1.json (pinned -text) and verifies identically.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createPublicKey, createHash } from 'node:crypto';
import { verifyBundle } from '../src/bundle.mjs';
import { verifyReceipt } from '../src/actions.mjs';

const RAW = readFileSync(new URL('./fixtures/pocket_kav_v1.json', import.meta.url));
const KAV = JSON.parse(RAW.toString('utf8'));
// reconstruct the verify key from ONLY the raw base64url (exactly what the phone stores) — no PEM.
const pub = createPublicKey({ key: { kty: 'OKP', crv: 'Ed25519', x: KAV.publicKeyRawBase64url }, format: 'jwk' });

test('committed KAV fixture is stable (regenerate only intentionally)', () => {
  assert.equal(KAV.schema, 'pocket_kav_v1');
  assert.equal(KAV.signingKeyId, 'kav-key');
  assert.equal(typeof KAV.publicKeyRawBase64url, 'string');
  assert.ok(createHash('sha256').update(RAW).digest('hex').length === 64);
});

test('committed KAV: bundle signature verifies with the RAW base64url key', () => {
  assert.equal(verifyBundle(KAV.bundle, pub), true);
  assert.equal(verifyBundle({ ...KAV.bundle, checkpointId: 'TAMPERED' }, pub), false, 'tamper breaks the bundle sig');
});

test('committed KAV: receipt signature verifies with the RAW base64url key', () => {
  assert.equal(verifyReceipt(KAV.receipt, pub), true);
  assert.equal(verifyReceipt({ ...KAV.receipt, result: { ...KAV.receipt.result, actionId: 'evil' } }, pub), false, 'tamper breaks the receipt sig');
});
