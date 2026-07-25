// need-detector.test.mjs — Stage-1 cheap pattern gate. Locks: every need-pattern admits; benign chat does NOT;
// case-insensitivity; the anti-false-NEGATIVE bias (admit generously, Stage-2 filters); the tail scan (shapes,
// window, seqs). Stage-1 NEVER classifies or rings — it only answers "admit to Stage-2?".
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { matchNeedPatterns, scanTailForNeed, NEED_PATTERN_LABELS } from '../src/need-detector.mjs';

test('each need-pattern admits a representative message', () => {
  const cases = {
    'mention-carter':   '@human-mrrcarter can you weigh in?',
    'need-carter':      'we really need Carter to unblock this',
    'your-call':        'this one is your call',
    'decision-yours':   'the decision is yours',
    'go-request':       'green head, tests pass — GO?',
    'pick-option':      'do we ship option A or option B',
    'choose-between':   'we have to choose between the two adapters',
    'checkpoint-ready': 'the milestone checkpoint ready for review',
    'greenlight':       'just need the green light to merge',
  };
  for (const [label, text] of Object.entries(cases)) {
    const r = matchNeedPatterns(text);
    assert.equal(r.hit, true, `"${text}" should hit`);
    assert.ok(r.matched.includes(label), `"${text}" should match ${label}, got ${r.matched.join(',')}`);
  }
});

test('benign engineering chatter does NOT admit (kills tail noise)', () => {
  for (const text of [
    'the parser is fixed and all 405 tests pass',
    'pushed the branch, PR is up for review',
    'good call on the refactor, merging now',
    'the deploy went out and metrics look healthy',
    'let me know if the build is good?',   // "good?" must NOT trip the go? pattern
  ]) {
    assert.deepEqual(matchNeedPatterns(text), { hit: false, matched: [] }, `"${text}" should NOT hit`);
  }
});

test('case-insensitive across all forms', () => {
  assert.equal(matchNeedPatterns('@CARTER your CALL — GO?').hit, true);
  assert.equal(matchNeedPatterns('OPTION C or the other one').matched.includes('pick-option'), true);
  assert.equal(matchNeedPatterns('CHECKPOINT-READY').matched.includes('checkpoint-ready'), true);
});

test('all three Carter mention forms match mention-carter', () => {
  for (const m of ['@carter', '@mrrcarter', '@human-mrrcarter']) {
    assert.ok(matchNeedPatterns(`hey ${m} thoughts?`).matched.includes('mention-carter'), `${m} should match`);
  }
});

test('bare "go" (no ?) does not hit; "go?" does — narrow to a real proceed-ask', () => {
  assert.equal(matchNeedPatterns('we should go with the first plan').hit, false);
  assert.equal(matchNeedPatterns('ready to ship — go?').matched.includes('go-request'), true);
});

test('a message can match MULTIPLE patterns (all labels returned)', () => {
  const r = matchNeedPatterns('@carter your call — option A or option B, go?');
  assert.ok(r.matched.includes('mention-carter'));
  assert.ok(r.matched.includes('your-call'));
  assert.ok(r.matched.includes('pick-option'));
  assert.ok(r.matched.includes('go-request'));
});

test('non-string / empty input is fail-safe (no hit, no throw)', () => {
  assert.deepEqual(matchNeedPatterns(''), { hit: false, matched: [] });
  assert.deepEqual(matchNeedPatterns(null), { hit: false, matched: [] });
  assert.deepEqual(matchNeedPatterns(undefined), { hit: false, matched: [] });
  assert.deepEqual(matchNeedPatterns({}), { hit: false, matched: [] });
});

test('bounded scan does not crash on a very long blob and still matches early content', () => {
  const text = '@carter need you — ' + 'x'.repeat(200000);
  const r = matchNeedPatterns(text);
  assert.equal(r.hit, true);
  assert.ok(r.matched.includes('mention-carter'));
});

test('scanTailForNeed: hits carry seq + matched, across senti-event / {text} / string shapes', () => {
  const tail = [
    { sequenceId: 100, payload: { message: 'parser fixed, tests green' } }, // benign
    { sequenceId: 101, payload: { message: 'the decision is yours @carter' } }, // hit
    { text: 'go?', sequenceId: 102 }, // {text} shape, hit
    'nothing to see here', // string shape, benign
  ];
  const r = scanTailForNeed(tail);
  assert.equal(r.hit, true);
  assert.equal(r.hits.length, 2);
  assert.deepEqual(r.hits[0], { seq: 101, matched: ['mention-carter', 'decision-yours'] }); // matched is in PATTERN-declaration order
  assert.equal(r.hits[1].seq, 102);
  assert.ok(r.hits[1].matched.includes('go-request'));
});

test('scanTailForNeed: only the last `max` messages are scanned (old needs cannot dominate)', () => {
  const tail = [{ sequenceId: 1, payload: { message: '@carter your call' } }, // OLD hit, outside the window
    ...Array.from({ length: 5 }, (_, i) => ({ sequenceId: 10 + i, payload: { message: 'routine update ' + i } }))];
  const r = scanTailForNeed(tail, { max: 5 }); // window = last 5 -> excludes seq 1
  assert.equal(r.hit, false, 'the old @carter need is outside the last-5 window');
});

test('scanTailForNeed: empty / non-array tail -> no hit', () => {
  assert.deepEqual(scanTailForNeed([]), { hit: false, hits: [] });
  assert.deepEqual(scanTailForNeed(null), { hit: false, hits: [] });
});

test('NEED_PATTERN_LABELS is exported and non-empty (for Stage-2 context + logging)', () => {
  assert.ok(Array.isArray(NEED_PATTERN_LABELS) && NEED_PATTERN_LABELS.length >= 8);
  assert.ok(NEED_PATTERN_LABELS.includes('mention-carter'));
});
