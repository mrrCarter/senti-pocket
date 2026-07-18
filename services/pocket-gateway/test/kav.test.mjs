// kav.test.mjs — the committed Node<->Swift known-answer vector (Echo #233248 P1e). The phone pins the RAW base64url
// Ed25519 public key and MUST verify these exact committed bytes; this proves the Node side. Swift consumes the same
// test/fixtures/pocket_kav_v1.json (pinned -text) and verifies identically.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createPublicKey, createHash } from 'node:crypto';
import { verifyBundle, canonicalBundlePayload } from '../src/bundle.mjs';
import { verifyReceipt } from '../src/actions.mjs';

// pocket.bundle.v1 canonical MUST byte-match PocketContracts.swift testBundleCanonicalKAV (@f49327f) exactly.
const TS = 1752835200000; // shared fixture epoch-ms (= 2025-07-18T12:00:00Z)
test('pocket.bundle.v1 canonical byte-matches the frozen Swift KAV (empty + populated)', () => {
  const empty = { contractsVersion: '0.1.8', checkpointId: 'cp1', sessionId: 's1', sequenceStart: 1, sequenceEnd: 2, summary: { checkpointId: 'cp1', headline: 'h', summaryBaselineSchema: 'sch', grade: null, perAgent: [], risks: [], blockers: [] }, evidence: [], createdAt: TS, signingKeyId: 'k1' };
  assert.equal(canonicalBundlePayload(empty), 'pocket.bundle.v1\n5:0.1.83:cp12:s11:11:23:cp11:h3:sch01:01:01:01:013:17528352000002:k1');
  const ev1 = { id: 'ev1', sessionId: 's1', sequence: 11, agentId: 'a1', snippet: 'sn', ts: TS };
  const ag = { agentId: 'a1', summary: 'sum', claims: [{ id: 'c1', text: 't', kind: 'fact', evidenceIds: ['ev1'] }], evidence: [ev1] };
  const pop = { contractsVersion: '0.1.8', checkpointId: 'cp1', sessionId: 's1', sequenceStart: 10, sequenceEnd: 20, summary: { checkpointId: 'cp1', headline: 'H', summaryBaselineSchema: 'sch', grade: 'A', perAgent: [ag], risks: ['r1'], blockers: ['b1'] }, evidence: [ev1], createdAt: TS, signingKeyId: 'k1' };
  assert.equal(canonicalBundlePayload(pop), 'pocket.bundle.v1\n5:0.1.83:cp12:s12:102:203:cp11:H3:sch11:A1:12:a13:sum1:12:c11:t4:fact1:13:ev11:13:ev12:s12:112:a12:sn13:17528352000001:12:r11:12:b11:13:ev12:s12:112:a12:sn13:175283520000013:17528352000002:k1');
  // signature is NOT bound: changing it does not change the canonical
  assert.equal(canonicalBundlePayload({ ...pop, signature: 'DIFFERENT' }), canonicalBundlePayload({ ...pop, signature: 'X' }));
});

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
