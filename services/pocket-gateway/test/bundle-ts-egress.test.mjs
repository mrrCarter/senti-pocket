// bundle-ts-egress.test.mjs — projectEvidenceRef.ts is the ONE phone-visible string the egress projection normalizes
// rather than scrubs: a STRUCTURED timestamp coerced to a canonical ISO instant (or '' if unparseable). This (a) closes
// the lone gap where a non-date secret could ride to the phone in the raw JSON `ts` field while the SIGNED canonical
// (msB/epoch-millis) zeroed it out, and (b) keeps the displayed ts consistent with the signed epoch. Crucially the fix
// leaves the SIGNED bytes byte-identical, so no Node<->Swift canonical-parity risk.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { projectEvidenceRef, canonicalBundlePayload } from '../src/bundle.mjs';

test('ts: a non-date secret is normalized to "" — never egresses as raw prose', () => {
  const secret = 'sk-' + 'A'.repeat(40) + ' credential leak';
  assert.equal(projectEvidenceRef({ id: 'e', ts: secret }).ts, '', 'a non-parseable ts must not carry prose to the phone');
  assert.equal(projectEvidenceRef({ id: 'e', ts: 'correct horse battery staple' }).ts, '', 'natural-language (scrub-invisible) prose is also blocked');
});

test('ts: a valid timestamp is preserved as a canonical ISO instant', () => {
  assert.equal(projectEvidenceRef({ id: 'e', ts: '2026-07-21T13:00:00.000Z' }).ts, '2026-07-21T13:00:00.000Z');
  assert.equal(projectEvidenceRef({ id: 'e', ts: new Date(0) }).ts, '1970-01-01T00:00:00.000Z', 'Date object -> ISO');
  assert.equal(projectEvidenceRef({ id: 'e', ts: '2026-07-21' }).ts, '2026-07-21T00:00:00.000Z', 'non-ISO date string -> canonical ISO');
  assert.equal(projectEvidenceRef({ id: 'e' }).ts, '', 'absent ts -> ""');
});

test('the fix leaves the SIGNED canonical byte-identical (ts binds via epoch-millis, not the raw string)', () => {
  const base = {
    contractsVersion: 'pocket.bundle.v1', checkpointId: 'c', sessionId: 's', sequenceStart: 1, sequenceEnd: 2,
    summary: { checkpointId: 'c', headline: 'h', summaryBaselineSchema: 'x', grade: null, perAgent: [], risks: [], blockers: [] },
    evidence: [{ id: 'e', sessionId: 's', sequence: 1, agentId: 'a', snippet: 'snip', ts: '2026-07-21T13:00:00.000Z' }],
    createdAt: '2026-07-21T13:00:00.000Z', signingKeyId: 'k',
  };
  const clone = () => JSON.parse(JSON.stringify(base));
  // projecting a valid ts (ISO -> same ISO) does not move the signed bytes
  const projected = clone(); projected.evidence[0].ts = projectEvidenceRef(base.evidence[0]).ts;
  assert.equal(canonicalBundlePayload(projected), canonicalBundlePayload(base), 'projecting a valid ts is canonical-invariant');
  // a non-date secret ts and a "" ts canonicalize IDENTICALLY -> the secret was never in the signed bytes; the fix only
  // stops it from riding in the (previously raw-bounded) JSON field.
  const withSecret = clone(); withSecret.evidence[0].ts = 'not-a-date-SECRET-sk-AAAAAAAAAAAA';
  const withEmpty = clone(); withEmpty.evidence[0].ts = '';
  assert.equal(canonicalBundlePayload(withSecret), canonicalBundlePayload(withEmpty), 'a non-date ts contributes "" to the signed canonical');
  assert.ok(!canonicalBundlePayload(withSecret).includes('SECRET'), 'the secret is absent from the signed bytes (epoch-coerced)');
});
