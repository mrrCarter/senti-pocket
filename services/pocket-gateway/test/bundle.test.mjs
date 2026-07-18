// bundle.test.mjs — Ed25519 PocketBundle sign/verify + tamper detection. Run: node --test
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  canonicalBundlePayload, dedupEvidence,
  buildBundle, verifyBundle, buildSignedBundle, generateSigningKeypair, CONTRACTS_VERSION,
} from '../src/bundle.mjs';

const RAW = {
  checkpointId: 'cp_954233b7_000012',
  sessionId: '954233b7-1822-42bc-9cfe-1eb95eb0357a',
  startSequence: 230100,
  endSequence: 230180,
};
const EV1 = { id: 'ev_1', sessionId: RAW.sessionId, sequence: 230141, agentId: 'claude-pocket-relay', snippet: 'parser fixed', ts: '2026-07-18T10:35:00Z' };
const EV2 = { id: 'ev_2', sessionId: RAW.sessionId, sequence: 230160, agentId: 'claude-warden', snippet: 'STRONG PASS', ts: '2026-07-18T10:36:34Z' };
const SUMMARY = {
  checkpointId: RAW.checkpointId,
  headline: 'Canary cleared review; stack merge-blocked on billing.',
  summaryBaselineSchema: 'checkpoint_summary_sections_v1',
  grade: 'A-',
  perAgent: [
    { agentId: 'claude-pocket-relay', summary: 'Proved extraction.', evidence: [EV1] },
    { agentId: 'claude-warden', summary: 'STRONG PASS.', evidence: [EV2] },
  ],
  risks: ['Actions suspended -> nothing merges.'],
  blockers: ['Carter gate: billing -> CI.'],
};

test('canonicalBundlePayload is deterministic + domain-tagged pocket.bundle.v1', () => {
  const b = buildBundle(RAW, SUMMARY, { signingKeyId: 'k1', createdAt: '2026-07-18T10:40:00Z' });
  assert.ok(canonicalBundlePayload(b).startsWith('pocket.bundle.v1\n'));
  assert.equal(canonicalBundlePayload(b), canonicalBundlePayload({ ...b }), 'stable');
});

test('dedupEvidence removes dupes and sorts by sequence', () => {
  const out = dedupEvidence([EV2, EV1, { ...EV1 }]);
  assert.deepEqual(out.map((e) => e.id), ['ev_1', 'ev_2']);
});

test('buildBundle produces the frozen PocketBundle shape', () => {
  const b = buildBundle(RAW, SUMMARY, { signingKeyId: 'k1', createdAt: '2026-07-18T10:40:00Z' });
  assert.deepEqual(
    Object.keys(b).sort(),
    ['checkpointId', 'contractsVersion', 'createdAt', 'evidence', 'sequenceEnd', 'sequenceStart', 'sessionId', 'signature', 'signingKeyId', 'summary'],
  );
  assert.equal(b.contractsVersion, CONTRACTS_VERSION);
  assert.equal(b.sequenceStart, 230100);
  assert.equal(b.evidence.length, 2, 'evidence deduped from perAgent');
  assert.equal(b.signature, '', 'unsigned draft has empty signature');
});

test('sign + verify round-trips with the matching key', () => {
  const { publicKey, privateKey } = generateSigningKeypair();
  const signed = buildSignedBundle(RAW, SUMMARY, privateKey, { signingKeyId: 'pocket-gateway-test' });
  assert.ok(signed.signature.length > 0, 'signature present');
  assert.equal(signed.signingKeyId, 'pocket-gateway-test');
  assert.equal(verifyBundle(signed, publicKey), true, 'valid signature verifies');
});

test('verify FAILS when the summary is tampered', () => {
  const { publicKey, privateKey } = generateSigningKeypair();
  const signed = buildSignedBundle(RAW, SUMMARY, privateKey);
  const tampered = structuredClone(signed);
  tampered.summary.headline = 'ATTACKER REWROTE THE BRIEFING';
  assert.equal(verifyBundle(tampered, publicKey), false, 'tampered summary must fail verification');
});

test('verify FAILS when an evidence sequence is tampered', () => {
  const { publicKey, privateKey } = generateSigningKeypair();
  const signed = buildSignedBundle(RAW, SUMMARY, privateKey);
  const tampered = structuredClone(signed);
  tampered.evidence[0].sequence = 999999;
  assert.equal(verifyBundle(tampered, publicKey), false);
});

test('verify FAILS with a wrong public key', () => {
  const { privateKey } = generateSigningKeypair();
  const other = generateSigningKeypair();
  const signed = buildSignedBundle(RAW, SUMMARY, privateKey);
  assert.equal(verifyBundle(signed, other.publicKey), false);
});

test('verify FAILS on an unsigned / empty-signature bundle', () => {
  const { publicKey } = generateSigningKeypair();
  const draft = buildBundle(RAW, SUMMARY);
  assert.equal(verifyBundle(draft, publicKey), false);
});

test('signingKeyId is bound (tampering it breaks verification)', () => {
  const { publicKey, privateKey } = generateSigningKeypair();
  const signed = buildSignedBundle(RAW, SUMMARY, privateKey, { signingKeyId: 'real-key' });
  const tampered = { ...signed, signingKeyId: 'swapped-key' };
  assert.equal(verifyBundle(tampered, publicKey), false, 'signingKeyId is inside the signed bytes');
});
