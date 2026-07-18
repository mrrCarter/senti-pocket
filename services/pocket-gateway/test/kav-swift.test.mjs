// kav-swift.test.mjs — cross-language KAV pinned to warden's bundle-KAV FIXED HEAD (warden/bundle-kav-fix @5329b7f,
// packages/PocketContracts/Fixtures/bundle_kav.json). Proves the Node gateway's pocket.bundle.v1 canonical is
// byte-identical to the Swift `canonicalBytesUtf8`, that Node re-signs the demo key IDENTICALLY, and that the pinned
// public key verifies the frozen signature. This is the permanent regression oracle for the Relay Node-KAV byte-match
// warden's gate criterion requires. Demo key only (Phase-A, from a PUBLIC seed phrase; NO private key committed).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHash, createPrivateKey, createPublicKey, sign as edSign } from 'node:crypto';
import {
  canonicalBundlePayload, canonicalBundleBytes, verifyBundle,
  validateBundleSemantics, verifyBundleWithTrustStore, verifyBundlePhaseADemo,
} from '../src/bundle.mjs';

const FX = JSON.parse(readFileSync(new URL('./fixtures/pocket_bundle_kav_swift.json', import.meta.url), 'utf8'));
const wb = FX.bundle;

// Field-name bridge ONLY: the Swift contract stores createdAtEpochMillis / tsEpochMillis (integer millis); my Node
// canonical reads createdAt / ts and reduces them to the SAME integer millis via msB(). Pure shape adaptation, no
// value change — the emitted canonical bytes are identical either way.
const mapEv = (e) => ({ ...e, ts: e.tsEpochMillis });
const mapped = {
  ...wb,
  createdAt: wb.createdAtEpochMillis,
  evidence: wb.evidence.map(mapEv),
  summary: { ...wb.summary, perAgent: wb.summary.perAgent.map((a) => ({ ...a, evidence: a.evidence.map(mapEv) })) },
};

test('Swift-KAV: Node canonicalBundlePayload byte-matches canonicalBytesUtf8 + sha256 (fixed head @5329b7f)', () => {
  assert.equal(canonicalBundlePayload(mapped), FX.kav.canonicalBytesUtf8, 'canonical string is byte-identical to Swift');
  assert.equal(createHash('sha256').update(canonicalBundleBytes(mapped)).digest('hex'), FX.kav.canonicalSha256Hex, 'sha256 matches');
});

test('Swift-KAV: the frozen signature verifies under the PINNED public key over the Node canonical', () => {
  const pub = createPublicKey({ key: { kty: 'OKP', crv: 'Ed25519', x: FX.demoKey.publicKeyBase64url }, format: 'jwk' });
  const sigStd = Buffer.from(FX.kav.signatureBase64url, 'base64url').toString('base64');
  assert.equal(verifyBundle({ ...mapped, signature: sigStd }, pub), true, 'verified-on-good');
  assert.equal(verifyBundle({ ...mapped, summary: { ...mapped.summary, headline: 'demo EVIL' }, signature: sigStd }, pub), false, 'tamper => fail');
});

test('Swift-KAV: Node reproduces the demo pubkey AND the exact signature from the PUBLIC seed phrase', () => {
  const seed = createHash('sha256').update(Buffer.from(FX.demoKey.seedPhrase, 'utf8')).digest();
  const pkcs8 = Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), seed]);
  const priv = createPrivateKey({ key: pkcs8, format: 'der', type: 'pkcs8' });
  assert.equal(createPublicKey(priv).export({ format: 'jwk' }).x, FX.demoKey.publicKeyBase64url, 'pubkey reproduced');
  assert.equal(edSign(null, canonicalBundleBytes(mapped), priv).toString('base64url'), FX.kav.signatureBase64url, 'signature reproduced byte-for-byte');
});

test('Swift-KAV: signingKeyId selects the pinned key; unknown id rejected; bundle is semantically valid', () => {
  const sigStd = Buffer.from(FX.kav.signatureBase64url, 'base64url').toString('base64');
  const trust = { [wb.signingKeyId]: FX.demoKey.publicKeyBase64url };
  assert.equal(verifyBundleWithTrustStore({ ...mapped, signature: sigStd }, trust), true, 'id selects pinned key');
  assert.equal(verifyBundleWithTrustStore({ ...mapped, signature: sigStd, signingKeyId: 'attacker' }, trust), false, 'unknown id => reject');
  assert.deepEqual(validateBundleSemantics(mapped).errors, [], 'semantically valid');
});

test('Swift-KAV: internal non-injectable Phase-A anchor verifies the demo bundle (mirrors Swift .phaseADemo)', () => {
  const sigStd = Buffer.from(FX.kav.signatureBase64url, 'base64url').toString('base64');
  // no caller can inject a key: verifyBundlePhaseADemo takes NO trust-store param. Verifying the real KAV under it
  // also drift-guards the pinned constant against the fixture's demo pubkey (fails if either changes).
  assert.equal(verifyBundlePhaseADemo({ ...mapped, signature: sigStd }), true, 'internal pinned anchor verifies');
  assert.equal(verifyBundlePhaseADemo({ ...mapped, signature: sigStd, signingKeyId: 'attacker' }), false, 'unknown id => reject');
  assert.equal(verifyBundlePhaseADemo({ ...mapped, summary: { ...mapped.summary, headline: 'demo EVIL' }, signature: sigStd }), false, 'tamper => reject');
});
