// bundle.test.mjs — Ed25519 PocketBundle sign/verify + tamper detection. Run: node --test
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  canonicalBundlePayload, dedupEvidence, canonicalEpochMs, validateBundleSemantics, validateBundleIngress,
  buildBundle, verifyBundle, buildSignedBundle, signBundle, generateSigningKeypair, CONTRACTS_VERSION, projectEvidenceRef,
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

// ---- Pulse caution 2: millisecond-alignment mirrored as PRE-SIGN validation (+/- half-ms + negative boundary) ----
const MS_BOUND = 253402300800000; // ~year 9999 epoch-ms; mirrors BUNDLE_MS_BOUND / Swift safeEpochMillis
test('canonicalEpochMs: exact-ms accepted; sub-ms/ambiguous/out-of-bound rejected (+/- half-ms + negative)', () => {
  // integer-ms number + Date round-trip
  assert.equal(canonicalEpochMs(1752835200000), 1752835200000);
  assert.equal(canonicalEpochMs(new Date(1752835200000)), 1752835200000);
  // ms-precision ISO with EXPLICIT tz (Z + numeric offset) accepted
  assert.equal(canonicalEpochMs('2026-07-18T00:00:00.000Z'), Date.parse('2026-07-18T00:00:00.000Z'));
  assert.equal(canonicalEpochMs('2026-07-18T00:00:00.999Z'), Date.parse('2026-07-18T00:00:00.999Z'));
  assert.equal(canonicalEpochMs('2026-07-18T00:00:00+00:00'), Date.parse('2026-07-18T00:00:00+00:00'));
  // +/- HALF-MS: a fractional-ms NUMBER and a sub-ms (4-frac-digit) STRING both diverge cross-language -> rejected
  assert.equal(canonicalEpochMs(1752835200000.5), null, 'fractional-ms number rejected');
  assert.equal(canonicalEpochMs('2026-07-18T00:00:00.0005Z'), null, 'sub-ms string rejected');
  // ambiguous timezone-less string rejected
  assert.equal(canonicalEpochMs('2026-07-18T00:00:00'), null, 'no timezone rejected');
  assert.equal(canonicalEpochMs('2026-07-18T00:00:00.000'), null, 'no timezone (with ms) rejected');
  // NEGATIVE (pre-1970) in-bound accepted; both bounds accepted; beyond either bound rejected
  assert.equal(canonicalEpochMs(new Date('1969-12-31T23:59:59.000Z')), -1000, 'in-bound negative accepted');
  assert.equal(canonicalEpochMs(MS_BOUND), MS_BOUND, 'upper bound accepted');
  assert.equal(canonicalEpochMs(-MS_BOUND), -MS_BOUND, 'lower bound accepted');
  assert.equal(canonicalEpochMs(MS_BOUND + 1), null, 'beyond upper bound rejected');
  assert.equal(canonicalEpochMs(-MS_BOUND - 1), null, 'beyond lower bound rejected');
  // junk / non-finite
  assert.equal(canonicalEpochMs('not-a-date'), null);
  assert.equal(canonicalEpochMs(NaN), null);
  assert.equal(canonicalEpochMs(null), null);
});

test('validateBundleSemantics: accepts a well-formed bundle, flags each violation class', () => {
  const good = buildBundle(RAW, SUMMARY, { signingKeyId: 'k1', createdAt: '2026-07-18T10:40:00Z' });
  assert.deepEqual(validateBundleSemantics(good).errors, [], 'clean bundle has no violations');
  assert.match(validateBundleSemantics({ ...good, contractsVersion: '9.9.9' }).errors.join(), /contractsVersion/);
  assert.match(validateBundleSemantics({ ...good, sequenceStart: 500, sequenceEnd: 100 }).errors.join(), /inverted range/);
  assert.match(validateBundleSemantics({ ...good, summary: { ...good.summary, checkpointId: 'other' } }).errors.join(), /summary\.checkpointId/);
  assert.match(validateBundleSemantics({ ...good, evidence: [good.evidence[0], good.evidence[0]] }).errors.join(), /duplicate id/);
  assert.match(validateBundleSemantics({ ...good, evidence: [{ ...good.evidence[0], sessionId: 'evil' }] }).errors.join(), /foreign sessionId/);
  assert.match(validateBundleSemantics({ ...good, createdAt: '2026-07-18T10:40:00.0005Z' }).errors.join(), /createdAt/);
});

test('validateBundleSemantics: rejects a same-id/different-content evidence clash (top-level vs per-agent)', () => {
  const good = buildBundle(RAW, SUMMARY, { signingKeyId: 'k1', createdAt: '2026-07-18T10:40:00Z' });
  // per-agent evidence reuses a top-level id but with different content => ambiguous identity, must be rejected.
  const clash = { ...good, summary: { ...good.summary,
    perAgent: [{ agentId: 'a', summary: 's', claims: [], evidence: [{ ...good.evidence[0], snippet: 'DIFFERENT CONTENT' }] }] } };
  assert.match(validateBundleSemantics(clash).errors.join(), /conflicting evidence identity/);
  // a fact citing per-agent-only evidence (not in top-level) is also rejected (resolves against top-level only).
  const nestedOnly = { ...good, evidence: [good.evidence[0]], summary: { ...good.summary,
    perAgent: [{ agentId: 'a', summary: 's', claims: [{ id: 'c1', text: 't', kind: 'fact', evidenceIds: ['nested_only'] }],
      evidence: [{ id: 'nested_only', sessionId: RAW.sessionId, sequence: 9, agentId: 'a', snippet: 'x', ts: '2026-07-18T10:00:00Z' }] }] } };
  const errs = validateBundleSemantics(nestedOnly).errors.join();
  assert.match(errs, /not in top-level evidence/);
  assert.match(errs, /cites foreign evidence/);
});

test('buildBundle FAILS CLOSED on an inverted sequence range', () => {
  assert.throws(
    () => buildBundle({ checkpointId: 'cp', sessionId: 's', startSequence: 300, endSequence: 100 },
      { checkpointId: 'cp', headline: 'h', summaryBaselineSchema: 'v1', perAgent: [], risks: [], blockers: [] }),
    /inverted range/,
  );
});

test('buildBundle FAILS CLOSED on an uncited fact claim', () => {
  const summary = { checkpointId: 'cp', headline: 'h', summaryBaselineSchema: 'v1', risks: [], blockers: [],
    perAgent: [{ agentId: 'a', summary: 's', claims: [{ id: 'c1', text: 't', kind: 'fact', evidenceIds: [] }], evidence: [] }] };
  assert.throws(() => buildBundle({ checkpointId: 'cp', sessionId: 's', startSequence: 1, endSequence: 2 }, summary), /uncited/);
});

// ---- bounded-ingress consume-side reference (warden bundle-KAV #3, seq 234672) ----
test('validateBundleIngress: accepts a clean bundle; rejects empty/oversized/duplicate-nested/non-positive', () => {
  const good = buildBundle(RAW, SUMMARY, { signingKeyId: 'k1', createdAt: '2026-07-18T10:40:00Z' });
  assert.deepEqual(validateBundleIngress(good).errors, [], 'clean bundle passes ingress');
  assert.match(validateBundleIngress({ ...good, evidence: [{ ...good.evidence[0], snippet: '' }] }).errors.join(), /snippet: empty/);
  assert.match(validateBundleIngress({ ...good, evidence: [{ ...good.evidence[0], sequence: 0 }] }).errors.join(), /not a positive integer/);
  assert.match(validateBundleIngress({ ...good, evidence: [{ ...good.evidence[0], snippet: 'x'.repeat(9000) }] }).errors.join(), /snippet: exceeds/);
  assert.match(validateBundleIngress({ ...good, signingKeyId: '' }).errors.join(), /signingKeyId: empty/);
  // frozen ingress additions: non-array collection, evidence out-of-range, empty top-level evidence
  assert.match(validateBundleIngress({ ...good, evidence: 'not-an-array' }).errors.join(), /evidence: must be an array/);
  assert.match(validateBundleIngress({ ...good, evidence: [{ ...good.evidence[0], sequence: 999999 }] }).errors.join(), /outside checkpoint range/);
  assert.match(validateBundleIngress({ ...good, evidence: [] }).errors.join(), /must contain >= 1 entry/);
  const dupNest = { ...good, summary: { ...good.summary,
    perAgent: [{ agentId: 'a', summary: 's', claims: [], evidence: [good.evidence[0], good.evidence[0]] }] } };
  assert.match(validateBundleIngress(dupNest).errors.join(), /duplicate nested evidence id/);
  const emptyAgent = { ...good, summary: { ...good.summary, perAgent: [{ agentId: '', summary: 's', claims: [], evidence: [] }] } };
  assert.match(validateBundleIngress(emptyAgent).errors.join(), /agent\.agentId: empty/);
});

test('validateBundleIngress: bounds all remaining label/prose/signature fields (completeness — Echo ced1a57 #1)', () => {
  const good = buildBundle(RAW, SUMMARY, { signingKeyId: 'k1', createdAt: '2026-07-18T10:40:00Z' });
  assert.match(validateBundleIngress({ ...good, signature: 'x'.repeat(600) }).errors.join(), /signature: exceeds/);
  assert.match(validateBundleIngress({ ...good, summary: { ...good.summary, grade: 'x'.repeat(600) } }).errors.join(), /grade: exceeds/);
  assert.match(validateBundleIngress({ ...good, summary: { ...good.summary, risks: ['x'.repeat(600)] } }).errors.join(), /risks\[\]: exceeds/);
  assert.match(validateBundleIngress({ ...good, summary: { ...good.summary, headline: 'x'.repeat(5000) } }).errors.join(), /headline: exceeds/);
});

test('validateBundleIngress: identity integrity (Echo/warden a459b33 #3)', () => {
  const good = buildBundle(RAW, SUMMARY, { signingKeyId: 'k1', createdAt: '2026-07-18T10:40:00Z' });
  const dupAgent = { ...good, summary: { ...good.summary, perAgent: [
    { agentId: 'x', summary: 's', claims: [], evidence: [] }, { agentId: 'x', summary: 's', claims: [], evidence: [] }] } };
  assert.match(validateBundleIngress(dupAgent).errors.join(), /duplicate agent id x/);
  const misbound = { ...good, summary: { ...good.summary, perAgent: [
    { agentId: 'x', summary: 's', claims: [], evidence: [{ ...good.evidence[0], agentId: 'y' }] }] } };
  assert.match(validateBundleIngress(misbound).errors.join(), /agentId != containing agent x/);
  const dupCite = { ...good, summary: { ...good.summary, perAgent: [
    { agentId: 'x', summary: 's', evidence: [good.evidence[0]],
      claims: [{ id: 'c', text: 't', kind: 'fact', evidenceIds: [good.evidence[0].id, good.evidence[0].id] }] }] } };
  assert.match(validateBundleIngress(dupCite).errors.join(), /duplicate citation id/);
  assert.match(validateBundleIngress({ ...good, checkpointId: '   ' }).errors.join(), /blank\/whitespace-only id/);
});

test('validateBundleIngress: total-work budget rejects a pathological graph — element (5000, fail-fast) + byte (warden #2 DoS)', () => {
  const good = buildBundle(RAW, SUMMARY, { signingKeyId: 'k1', createdAt: '2026-07-18T10:40:00Z' });
  // ELEMENT budget = shared BUNDLE_BUDGET.maxTotalElements (20000): 200 agents x 105 claims ~= 21200 > 20000, fail-fast
  const manyClaims = Array.from({ length: 200 }, (_, i) => ({ agentId: 'ag' + i, summary: 's', evidence: [],
    claims: Array.from({ length: 105 }, (_, j) => ({ id: `c${i}-${j}`, text: 't', kind: 'recommendation', evidenceIds: [] })) }));
  assert.match(validateBundleIngress({ ...good, summary: { ...good.summary, perAgent: manyClaims } }).errors.join(), /exceed budget 20000/);
  // BYTE budget = 1MB: 300 agents x 8000-byte summaries ~= 2.4MB > 1MB
  const bigBytes = Array.from({ length: 300 }, (_, i) => ({ agentId: 'agent-' + i, summary: 'x'.repeat(8000), claims: [], evidence: [] }));
  assert.match(validateBundleIngress({ ...good, summary: { ...good.summary, perAgent: bigBytes } }).errors.join(), /total bytes .* exceed budget/);
});

test('consumer parity: a gateway-produced bundle stays within the FROZEN per-field caps (accepted by VerifiedBundle + inference)', () => {
  const signed = buildSignedBundle(RAW, SUMMARY, generateSigningKeypair().privateKey, { signingKeyId: 'gw' });
  assert.ok(Buffer.byteLength(signed.checkpointId, 'utf8') <= 256 && Buffer.byteLength(signed.sessionId, 'utf8') <= 256);
  for (const e of signed.evidence) {
    assert.ok(Buffer.byteLength(e.id, 'utf8') <= 128, 'evidence id <= 128');
    assert.ok(Buffer.byteLength(e.agentId, 'utf8') <= 128, 'evidence agentId <= 128');
    assert.ok(Buffer.byteLength(e.snippet, 'utf8') <= 8000, 'snippet <= 8000');
  }
  assert.deepEqual(validateBundleIngress(signed).errors, [], 'gateway bundle passes the Node consumer gate');
});

test('signBundle FAILS CLOSED at the 512KiB ceiling on the DIRECT fixture-signer path — egress ⊆ phone (warden F2)', () => {
  const { privateKey } = generateSigningKeypair();
  // hand-built draft like sign-app-fixture.mjs (bypasses buildBundle): passes ingress (<20000 elems, <1MiB Node-bytes)
  // but its canonical > 512KiB. Node byte-accounting omits repeated evidence.sessionId that Swift counts, so a >512KiB
  // bundle could exceed the phone's 1MiB budget — the signBundle ceiling stops it BEFORE crypto, so it never reaches the phone.
  const perAgent = Array.from({ length: 100 }, (_, i) => ({ agentId: 'ag' + i, summary: 'x'.repeat(6000), claims: [], evidence: [] }));
  const draft = {
    contractsVersion: CONTRACTS_VERSION, checkpointId: 'cp', sessionId: 's', sequenceStart: 1, sequenceEnd: 2,
    summary: { checkpointId: 'cp', headline: 'h', summaryBaselineSchema: 'v1', grade: null, perAgent, risks: [], blockers: [] },
    evidence: [{ id: 'e1', sessionId: 's', sequence: 1, agentId: 'ag0', snippet: 'x', ts: '2026-07-18T10:00:00Z' }],
    createdAt: '2026-07-18T10:40:00Z', signingKeyId: 'k', signature: '',
  };
  assert.throws(() => signBundle(draft, privateKey, 'k'), /MAX_BUNDLE_BYTES/);
});

// ---- Pulse's two exact counterexamples on the sign path (must fail CLOSED, never sign what the phone rejects) ----
test('buildSignedBundle FAILS CLOSED: cannot sign a bundle its own ingress gate rejects (evidence=[])', () => {
  const { privateKey } = generateSigningKeypair();
  const summary = { checkpointId: 'cp', headline: 'h', summaryBaselineSchema: 'v1', perAgent: [], risks: [], blockers: [] };
  assert.throws(
    () => buildSignedBundle({ checkpointId: 'cp', sessionId: 's', startSequence: 1, endSequence: 2 }, summary, privateKey),
    /ingress validation failed[\s\S]*>= 1 entry/,
  );
});

test('buildSignedBundle FAILS CLOSED: over-cap identity id is REJECTED, never truncated (no prefix collision)', () => {
  const { privateKey } = generateSigningKeypair();
  const longId = '€'.repeat(100); // 300 UTF-8 bytes > frozen 128-byte evId cap
  const summary = { checkpointId: 'cp', headline: 'h', summaryBaselineSchema: 'v1', risks: [], blockers: [],
    perAgent: [{ agentId: 'a', summary: 's', claims: [],
      evidence: [{ id: longId, sessionId: 's', sequence: 1, agentId: 'a', snippet: 'x', ts: '2026-07-18T10:00:00Z' }] }] };
  const draft = buildBundle({ checkpointId: 'cp', sessionId: 's', startSequence: 1, endSequence: 2 }, summary);
  assert.equal(draft.evidence[0].id, longId, 'identity id is PRESERVED at full length, not truncated to a colliding prefix');
  assert.throws(
    () => buildSignedBundle({ checkpointId: 'cp', sessionId: 's', startSequence: 1, endSequence: 2 }, summary, privateKey),
    /ingress validation failed[\s\S]*exceeds 128 bytes/,
  );
});

test('identity ids use scrubIdSafe: a hash-shaped id passes VERBATIM (grounding intact); a secret-prefixed id still redacts', () => {
  const hashId = 'a'.repeat(64); // 64-hex: scrubText's entropy catch-all WOULD redact this; scrubIdSafe must NOT
  const summary = {
    checkpointId: hashId, headline: 'h', summaryBaselineSchema: 'v1', risks: [], blockers: [],
    perAgent: [{ agentId: 'claude-pocket-relay', summary: 's', claims: [],
      evidence: [{ id: 'ev_' + hashId, sessionId: hashId, sequence: 1, agentId: 'claude-pocket-relay', snippet: 'x', ts: '2026-07-18T10:00:00Z' }] }],
  };
  const draft = buildBundle({ checkpointId: hashId, sessionId: hashId, startSequence: 1, endSequence: 2 }, summary);
  // hash-shaped ids pass through VERBATIM -> no [REDACTED] collapse, grounding-citation matching stays intact
  assert.equal(draft.checkpointId, hashId, 'top-level checkpointId verbatim');
  assert.equal(draft.sessionId, hashId, 'top-level sessionId verbatim (scrubId symmetry)');
  assert.equal(draft.evidence[0].id, 'ev_' + hashId, 'evidence id verbatim');
  assert.equal(draft.evidence[0].sessionId, hashId, 'evidence sessionId verbatim');
  assert.ok(!JSON.stringify(draft).includes('[REDACTED'), 'no id was entropy-redacted');
  // a secret-PREFIXED value in an id field is STILL redacted (the defense-in-depth scrubIdSafe keeps over the charset shortcut)
  const secretId = 'sk-' + 'z'.repeat(24);
  const summary2 = {
    checkpointId: secretId, headline: 'h', summaryBaselineSchema: 'v1', risks: [], blockers: [],
    perAgent: [{ agentId: 'a', summary: 's', claims: [],
      evidence: [{ id: 'ev_1', sessionId: 's', sequence: 1, agentId: 'a', snippet: 'x', ts: '2026-07-18T10:00:00Z' }] }],
  };
  const draft2 = buildBundle({ checkpointId: secretId, sessionId: 's', startSequence: 1, endSequence: 2 }, summary2);
  assert.ok(draft2.checkpointId.includes('[REDACTED'), 'a secret-prefixed id is redacted, not passed verbatim');
});

test('prose truncation is scalar-safe + cap-inclusive (never splits a code point; result <= cap)', () => {
  const ev = projectEvidenceRef({ id: 'e', sessionId: 's', sequence: 1, agentId: 'a', snippet: '€'.repeat(2000), ts: '' }); // 6000 bytes
  assert.ok(Buffer.byteLength(ev.snippet, 'utf8') <= 2048, 'result within cap (ellipsis reserved inside)');
  assert.ok(ev.snippet.endsWith('…'), 'ellipsis appended');
  assert.equal(Buffer.from(ev.snippet, 'utf8').toString('utf8'), ev.snippet, 'no split code point / replacement char');
});
