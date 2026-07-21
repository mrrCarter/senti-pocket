// kav-swift.test.mjs — cross-language KAV pinned to warden's bundle-KAV CONVERGED HEAD (warden/bundle-kav-fix @a459b33,
// packages/PocketContracts/Tests/PocketContractsTests/Fixtures/{bundle_kav,bundle_kav_negative}.json). Proves the Node
// gateway's pocket.bundle.v1 canonical is byte-identical to the Swift `canonicalBytesUtf8`, that the pinned public key
// verifies the committed POSITIVE signature, and — via the NEGATIVE KAV — that a crypto-valid but semantically-invalid
// bundle is REJECTED by the Node semantic gate (the gate is live, not dead code behind crypto). Real random ed25519
// keypair: only the PUBLIC key + signatures are committed; the private key is NOT committed or derivable.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHash, createPublicKey, sign as edSign } from 'node:crypto';
import {
  canonicalBundlePayload, canonicalBundleBytes, verifyBundle,
  validateBundleSemantics, verifyBundleWithTrustStore, verifyBundlePhaseADemo, generateSigningKeypair,
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
const sigStd = Buffer.from(FX.kav.signatureBase64url, 'base64url').toString('base64');
const pub = createPublicKey({ key: { kty: 'OKP', crv: 'Ed25519', x: FX.demoKey.publicKeyBase64url }, format: 'jwk' });

// NEGATIVE KAV: same pinned key, a genuinely valid signature, but an INVERTED sequence range. Its `bundle` JSON is
// abbreviated to the changed field(s), so reconstruct the full bundle from the positive one (only the range differs).
const NEG = JSON.parse(readFileSync(new URL('./fixtures/pocket_bundle_kav_negative_swift.json', import.meta.url), 'utf8'));
const mappedNeg = { ...mapped, sequenceStart: NEG.bundle.sequenceStart, sequenceEnd: NEG.bundle.sequenceEnd };
const negSigStd = Buffer.from(NEG.kav.signatureBase64url, 'base64url').toString('base64');

test('Swift-KAV: Node canonicalBundlePayload byte-matches canonicalBytesUtf8 + sha256 (fixed head @ced1a57)', () => {
  assert.equal(canonicalBundlePayload(mapped), FX.kav.canonicalBytesUtf8, 'canonical string is byte-identical to Swift');
  assert.equal(createHash('sha256').update(canonicalBundleBytes(mapped)).digest('hex'), FX.kav.canonicalSha256Hex, 'sha256 matches');
});

test('Swift-KAV: the committed signature verifies under the PINNED public key over the Node canonical', () => {
  assert.equal(verifyBundle({ ...mapped, signature: sigStd }, pub), true, 'verified-on-good');
  assert.equal(verifyBundle({ ...mapped, summary: { ...mapped.summary, headline: 'demo EVIL' }, signature: sigStd }, pub), false, 'tamper => fail');
});

test('Swift-KAV: a throwaway WRONG-key signature does NOT verify under the pinned public key', () => {
  // the private key is not committed/derivable; a forger can only sign with a DIFFERENT key, which must be rejected.
  const { privateKey } = generateSigningKeypair();
  const wrongSig = edSign(null, canonicalBundleBytes(mapped), privateKey).toString('base64');
  assert.equal(verifyBundle({ ...mapped, signature: wrongSig }, pub), false, 'wrong-key signature rejected under the pinned key');
});

test('Swift-KAV: signingKeyId selects the pinned key; unknown id rejected; bundle is semantically valid', () => {
  const trust = { [wb.signingKeyId]: FX.demoKey.publicKeyBase64url };
  assert.equal(verifyBundleWithTrustStore({ ...mapped, signature: sigStd }, trust), true, 'id selects pinned key');
  assert.equal(verifyBundleWithTrustStore({ ...mapped, signature: sigStd, signingKeyId: 'attacker' }, trust), false, 'unknown id => reject');
  assert.deepEqual(validateBundleSemantics(mapped).errors, [], 'semantically valid');
});

test('Swift-KAV: internal non-injectable Phase-A anchor verifies the demo bundle (mirrors Swift .phaseADemo)', () => {
  // no caller can inject a key: verifyBundlePhaseADemo takes NO trust-store param. Verifying the real KAV under it
  // also drift-guards the pinned constant against the fixture's demo pubkey (fails if either changes).
  assert.equal(verifyBundlePhaseADemo({ ...mapped, signature: sigStd }), true, 'internal pinned anchor verifies');
  assert.equal(verifyBundlePhaseADemo({ ...mapped, signature: sigStd, signingKeyId: 'attacker' }), false, 'unknown id => reject');
  assert.equal(verifyBundlePhaseADemo({ ...mapped, summary: { ...mapped.summary, headline: 'demo EVIL' }, signature: sigStd }), false, 'tamper => reject');
});

test('Swift-KAV NEGATIVE: crypto-valid but the SEMANTIC gate REJECTS it (gate is live, not dead code behind crypto)', () => {
  // canonical of the inverted-range bundle byte-matches the negative fixture...
  assert.equal(canonicalBundlePayload(mappedNeg), NEG.kav.canonicalBytesUtf8, 'negative canonical byte-matches Swift');
  // ...and its ed25519 signature GENUINELY VERIFIES under the SAME pinned key (crypto is authentic)...
  assert.equal(verifyBundle({ ...mappedNeg, signature: negSigStd }, pub), true, 'signature verifies under the pinned key (crypto authentic)');
  // ...yet the semantic gate MUST reject it for the inverted sequence range (crypto-verified != semantically-valid).
  const sem = validateBundleSemantics(mappedNeg);
  assert.equal(sem.ok, false, 'semantic gate rejects a crypto-valid bundle');
  assert.ok(sem.errors.some((e) => /inverted range/.test(e)), 'rejected for the inverted sequence range');
});
