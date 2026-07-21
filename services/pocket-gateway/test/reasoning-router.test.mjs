// reasoning-router.test.mjs — grounding-first routing (Warden honesty bar #2).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { routeAnswer } from '../src/reasoning-router.mjs';

const topics = [{ label: 'token parser fix', evidenceId: 'ev_1' }, { label: 'AUTH-1C canary', evidenceId: 'ev_2' }];

test('grounded + confident -> answered, citing ONLY grounded evidence', () => {
  const r = routeAnswer({
    groundedEvidenceIds: ['ev_1', 'ev_2'],
    llmAnswer: { text: 'Relay fixed the token parser.', evidenceIds: ['ev_1'], llmConfidence: 0.9 },
    nearestTopics: topics,
  });
  assert.equal(r.status, 'answered');
  assert.deepEqual(r.answer.evidenceIds, ['ev_1']);
});

test('THE honesty gate: high LLM confidence but NO grounding -> NOT answered', () => {
  const r = routeAnswer({
    groundedEvidenceIds: [],                                   // retrieval found nothing
    llmAnswer: { text: 'Absolutely, the deploy shipped.', evidenceIds: [], llmConfidence: 0.99 }, // confidently wrong
    nearestTopics: topics,
  });
  assert.notEqual(r.status, 'answered');                       // confident-wrong must NOT be answered
  assert.equal(r.status, 'unavailable');
  assert.deepEqual(r.unavailable.nearestTopics, topics);
});

test('hallucinated citation (claimed id NOT in grounding) is dropped', () => {
  const r = routeAnswer({
    groundedEvidenceIds: ['ev_1'],
    llmAnswer: { text: 'It was in ev_9.', evidenceIds: ['ev_9'], llmConfidence: 0.95 }, // ev_9 not retrieved
    nearestTopics: topics,
  });
  // No surviving grounded citation, but grounding exists -> clarify (not answered on a hallucinated cite)
  assert.equal(r.status, 'clarify');
  assert.ok(r.clarify.prompt.length > 0);
});

test('no grounded citation + some grounding -> clarify; + no grounding -> unavailable', () => {
  assert.equal(routeAnswer({ groundedEvidenceIds: ['ev_1'], llmAnswer: { evidenceIds: [] }, nearestTopics: topics }).status, 'clarify');
  const u = routeAnswer({ groundedEvidenceIds: [], llmAnswer: { evidenceIds: [] }, nearestTopics: [] });
  assert.equal(u.status, 'unavailable');
  assert.deepEqual(u.unavailable.nearestTopics, []);
});

test('grounded but low confidence + real alternatives -> clarify (secondary tiebreaker)', () => {
  const r = routeAnswer({
    groundedEvidenceIds: ['ev_1', 'ev_2'],
    llmAnswer: { text: 'maybe ev_1', evidenceIds: ['ev_1'], llmConfidence: 0.3 },
    nearestTopics: topics,
  });
  assert.equal(r.status, 'clarify');
});

test('grounded + low confidence but NO alternatives -> still answered (grounding is primary)', () => {
  const r = routeAnswer({
    groundedEvidenceIds: ['ev_1'],
    llmAnswer: { text: 'ev_1 fix', evidenceIds: ['ev_1'], llmConfidence: 0.2 },
    nearestTopics: [{ label: 'token parser fix', evidenceId: 'ev_1' }], // only one topic, no ambiguity
  });
  assert.equal(r.status, 'answered');
});
