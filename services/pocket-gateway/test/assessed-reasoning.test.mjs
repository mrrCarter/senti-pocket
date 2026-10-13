import { test } from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync } from 'node:crypto';
import { createAssessedReasoningBackend, selectAssessmentEvidence } from '../src/assessed-reasoning.mjs';
import { signBundle } from '../src/bundle.mjs';
import { createGemmaBackend } from '../src/gemma-backend.mjs';

const key = generateKeyPairSync('ed25519').privateKey;
const signed = (over = {}) => signBundle({ sessionId: 'sid-a', checkpointId: 'cp-1',
  contractsVersion: '0.1.8', sequenceStart: 1, sequenceEnd: 2, createdAt: '2026-10-12T12:00:00Z',
  signingKeyId: 'fixture-key', summary: { checkpointId: 'cp-1', headline: 'Source reports',
    perAgent: [], risks: [], blockers: [] }, evidence: [
  { id: 'ev-1', sequence: 1, snippet: 'Agent reports PR opened; deployment is blocked.' },
  { id: 'ev-2', sequence: 2, snippet: 'Owner approval is still required.' },
].map((e) => ({ ...e, sessionId: 'sid-a', agentId: 'agent-1', ts: '2026-10-12T12:00:00Z' })), ...over }, key);
const bundle = signed();
const input = { bundle, question: 'What needs my approval?', groundedEvidenceIds: ['ev-1', 'ev-2'] };
const answer = { text: 'Approval is still required.', evidenceIds: ['ev-2'] };
const passing = async ({ contextHash, candidateHash, candidate }) => ({ contextHash, candidateHash,
  verdicts: candidate.map((_, index) => ({ index, support: 'supported', supportScore: 0.9 })) });
const make = (extra = {}) => createAssessedReasoningBackend({ reason: async () => answer,
  brief: async () => ({ segments: [answer] }), assess: passing, ...extra });

test('acceptance binds context/draft, keeps assessment epistemically honest and exposes coverage', async () => {
  const r = await make({ requiredEvidenceFor: () => ['ev-2'] }).reason(input);
  assert.equal(r.text, answer.text);
  assert.equal(r.assessment.status, 'evaluated');
  assert.equal(r.assessment.semanticSupport, 'model-assessed');
  assert.equal(r.assessment.coverage.requiredCovered, 1);
  assert.equal(r.assessment.coverage.citedEvidence, 1);
  assert.equal(r.llmConfidence, null, 'no invented calibrated confidence');
  assert.match(r.assessment.contextHash, /^[a-f0-9]{64}$/);
});

test('real citation with unsupported prose is rejected; draft retries are bounded', async () => {
  let attempts = 0;
  const r = await make({ reason: async () => { attempts++; return { text: 'Everything is deployed.', evidenceIds: ['ev-1'] }; },
    assess: async (x) => ({ ...await passing(x), verdicts: [{ index: 0, support: 'unsupported', supportScore: 0.99 }] }) }).reason(input);
  assert.equal(r.text, '');
  assert.deepEqual(r.evidenceIds, []);
  assert.equal(r.assessment.status, 'inconclusive');
  assert.equal(r.assessment.reason, 'support-not-established');
  assert.equal(attempts, 2);
});

test('every spoken segment requires an assessment; duplicate indices do not prove coverage', async () => {
  const r = await make({ brief: async () => ({ segments: [answer, { ...answer, text: 'Another claim.' }] }),
    assess: async (x) => ({ ...await passing(x), verdicts: [
      { index: 0, support: 'supported', supportScore: 1 }, { index: 0, support: 'supported', supportScore: 1 },
    ] }) }).brief(input);
  assert.deepEqual(r.segments, []);
  assert.equal(r.assessment.reason, 'invalid-assessment');
});

test('stale/wrong hashes and non-finite support ratings cannot pass', async () => {
  for (const bad of ['context', 'candidate', 'nan']) {
    const r = await make({ assess: async (x) => ({ ...await passing(x),
      ...(bad === 'context' ? { contextHash: 'old-context' } : {}),
      ...(bad === 'candidate' ? { candidateHash: 'old-draft' } : {}),
      ...(bad === 'nan' ? { verdicts: [{ index: 0, support: 'supported', supportScore: NaN }] } : {}),
    }) }).reason(input);
    assert.equal(r.text, '', bad);
    assert.equal(r.assessment.reason, 'invalid-assessment');
  }
});

test('unknown citations and alternative spoken text stop before the assessor', async () => {
  let calls = 0;
  for (const draft of [{ ...answer, evidenceIds: ['fabricated-id'] },
    { ...answer, taggedText: '[warm] Everything is deployed.' }]) {
    const r = await make({ reason: async () => draft, assess: async (x) => { calls++; return passing(x); } }).reason(input);
    assert.equal(r.text, '');
  }
  assert.equal(calls, 0);
});

test('missing critical evidence generates deterministic feedback and a corrected second draft', async () => {
  let calls = 0;
  let feedback;
  const r = await make({ requiredEvidenceFor: () => ['ev-2'], reason: async (x) => {
    calls++;
    if (calls === 1) return { text: 'A PR was opened.', evidenceIds: ['ev-1'] };
    feedback = x.assessmentFeedback;
    return answer;
  } }).reason(input);
  assert.equal(r.assessment.status, 'evaluated');
  assert.equal(r.assessment.attempts, 2);
  assert.deepEqual(feedback.missingEvidenceIds, ['ev-2']);
  assert.equal(feedback.reason, 'required-evidence-not-covered');
});

test('missing/budget-exceeding required sources and explicit empty retrieval stop without drafting', async () => {
  let calls = 0;
  for (const cfg of [{ requiredEvidenceFor: () => ['ghost'] },
    { requiredEvidenceFor: () => ['ev-1', 'ev-2'], maxEvidence: 1 }]) {
    const r = await make({ ...cfg, reason: async () => { calls++; return answer; } }).reason(input);
    assert.equal(r.text, '');
  }
  const empty = await make({ reason: async () => { calls++; return answer; } }).reason({ ...input, groundedEvidenceIds: [] });
  assert.equal(empty.assessment.reason, 'no-evidence');
  assert.equal(calls, 0);
});

test('selection prioritizes required sources and reports selection gaps rather than full-checkpoint coverage', async () => {
  const s = selectAssessmentEvidence(bundle, input.groundedEvidenceIds, ['ev-2'], 1);
  assert.deepEqual(s.selected.map((e) => e.id), ['ev-2']);
  const r = await make({ maxEvidence: 1, requiredEvidenceFor: () => ['ev-2'] }).reason(input);
  assert.equal(r.assessment.coverage.omittedEvidence, 1);
  assert.equal(r.assessment.coverage.availableEvidence, 2);
});

test('assessor outage and timeout return no generated prose; AbortSignal is passed to adapters', async () => {
  const failed = await make({ assess: async () => { throw new Error('provider unavailable'); } }).reason(input);
  assert.equal(failed.assessment.status, 'unavailable');
  assert.equal(failed.text, '');
  let signal;
  const timed = await make({ timeoutMs: 10, assess: async (x) => { signal = x.signal; return new Promise(() => {}); } }).reason(input);
  assert.equal(timed.assessment.reason, 'assessor-unavailable');
  assert.equal(signal.aborted, true);
  assert.deepEqual(timed.evidenceIds, []);
});

test('draft/assessor cannot rewrite checkpoint snapshots; caller input stays unchanged', async () => {
  const r = await make({ reason: async (x) => {
    assert.throws(() => { x.bundle.evidence[0].snippet = 'rewritten'; }, TypeError);
    return answer;
  }, assess: async (x) => {
    assert.throws(() => { x.candidate[0].text = 'rewritten'; }, TypeError);
    assert.throws(() => { x.context.evidence[0].snippet = 'rewritten'; }, TypeError);
    return passing(x);
  } }).reason(input);
  assert.equal(r.text, answer.text);
  assert.equal(bundle.evidence[0].snippet, 'Agent reports PR opened; deployment is blocked.');
});

test('configuration bounds prevent infinite retry/timeout budgets', () => {
  for (const cfg of [{ maxAttempts: Infinity }, { maxAttempts: 4 }, { timeoutMs: 0 },
    { timeoutMs: 60_001 }, { minSupportScore: NaN }, { maxEvidence: 25 }]) assert.throws(() => make(cfg), /policy/);
});

test('context binds the complete signed canonical bundle, not just selected excerpts', async () => {
  const original = await make().reason(input);
  for (const over of [{ sequenceEnd: 3 }, { signingKeyId: 'different-key' },
    { summary: { ...bundle.summary, headline: 'Later corrected report' } },
    { createdAt: '2026-10-12T12:01:00Z' }]) {
    const r = await make().reason({ ...input, bundle: signed(over) });
    assert.equal(r.assessment.status, 'evaluated');
    assert.notEqual(r.assessment.contextHash, original.assessment.contextHash);
    assert.notEqual(r.assessment.bundleCanonicalHash, original.assessment.bundleCanonicalHash);
  }
  const version = await make().reason({ ...input, bundle: { ...bundle, contractsVersion: 'unknown-version' } });
  assert.equal(version.assessment.reason, 'invalid-signed-bundle');
});

test('Gemma and assessor see exactly the same bounded excerpts and required-first selection', async () => {
  const long = 'A'.repeat(280) + 'HIDDEN-CORRECTION-OUTSIDE-BUDGET';
  const largeBundle = signed({ evidence: [{ ...bundle.evidence[0], snippet: long }, bundle.evidence[1]] });
  let prompt, assessed;
  const gemma = createGemmaBackend({ baseUrl: 'http://fixture.invalid/v1', fetch: async (_, init) => {
    prompt = JSON.parse(init.body).messages[1].content;
    return { ok: true, json: async () => ({ choices: [{ message: { content: JSON.stringify(answer) } }] }) };
  } });
  const r = await make({ reason: gemma.reason, requiredEvidenceFor: () => ['ev-2'], assess: async (x) => {
    assessed = x.context;
    return passing(x);
  } }).reason({ ...input, bundle: largeBundle });
  assert.equal(r.assessment.status, 'evaluated');
  assert.equal(assessed.evidence[0].id, 'ev-2');
  assert.equal(assessed.evidence[1].snippet, 'A'.repeat(280));
  assert.equal(prompt.includes('HIDDEN-CORRECTION'), false);
  assert.equal(JSON.stringify(assessed.evidence).includes('HIDDEN-CORRECTION'), false);
  assert.equal(prompt.indexOf('[ev-2]') < prompt.indexOf('[ev-1]'), true);
  assert.equal(assessed.evidence[1].snippetTruncated, true);
  assert.equal(r.assessment.coverage.truncatedEvidence, 1);
  assert.equal(assessed.evidence[0].agentId, 'agent-1');
  assert.equal(assessed.evidence[0].ts, '2026-10-12T12:00:00Z');
});
