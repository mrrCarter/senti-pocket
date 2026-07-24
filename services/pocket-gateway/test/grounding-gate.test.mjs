// grounding-gate.test.mjs — the single audited honesty boundary. Proves keepGrounded is byte-identical to every prior
// inline form it replaced (routeAnswer + gemma-backend reason/brief), so the consolidation changed NO behavior.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { keepGrounded, groundingIdsFromBundle, isGrounded } from '../src/grounding-gate.mjs';

test('keepGrounded: keeps ONLY grounded ids, drops hallucinated, deduped + first-seen order', () => {
  const grounded = new Set(['ev_1', 'ev_2', 'ev_3']);
  assert.deepEqual(keepGrounded(['ev_2', 'ev_hallucinated', 'ev_1', 'ev_2'], grounded), ['ev_2', 'ev_1']);
  assert.deepEqual(keepGrounded(['ghost'], grounded), [], 'all-hallucinated -> empty (=> unavailable downstream)');
  assert.deepEqual(keepGrounded([], grounded), []);
});

test('keepGrounded: an ARRAY grounding (routeAnswer form) is equivalent to a Set (gemma-backend form)', () => {
  const arr = ['ev_1', 'ev_2'];
  const claimed = ['ev_2', 'ev_x', 'ev_1'];
  assert.deepEqual(keepGrounded(claimed, arr), keepGrounded(claimed, new Set(arr)));
  assert.deepEqual(keepGrounded(claimed, arr), ['ev_2', 'ev_1']);
});

test('keepGrounded: byte-identical to the prior inline forms it replaced (behavior-preservation)', () => {
  const claimed = ['a', 'b', 'a', 'c', 'x'];
  const groundedArr = ['a', 'b', 'c'];
  // reasoning-router routeAnswer: [...new Set(claimed.filter(id => grounded.includes(id)))]
  assert.deepEqual(keepGrounded(claimed, groundedArr), [...new Set(claimed.filter((id) => groundedArr.includes(id)))]);
  // gemma-backend reason/brief: [...new Set((Array.isArray(x)?x:[]).filter(id => groundedSet.has(id)))]
  const gset = new Set(groundedArr);
  assert.deepEqual(keepGrounded(claimed, gset), [...new Set((Array.isArray(claimed) ? claimed : []).filter((id) => gset.has(id)))]);
});

test('keepGrounded: fail-closed on a non-array claimed / non-array grounding', () => {
  assert.deepEqual(keepGrounded(null, new Set(['a'])), []);
  assert.deepEqual(keepGrounded(undefined, ['a']), []);
  assert.deepEqual(keepGrounded(['a'], null), [], 'no grounding -> nothing survives (fail-closed)');
});

test('isGrounded: survives only with VISIBLE text (trim) AND >=1 grounded cite', () => {
  assert.equal(isGrounded({ text: 'a real segment', evidenceIds: ['ev_1'] }), true);
  assert.equal(isGrounded({ text: '   \n\t ', evidenceIds: ['ev_1'] }), false, 'whitespace-only text -> dropped (the alignment)');
  assert.equal(isGrounded({ text: '', evidenceIds: ['ev_1'] }), false, 'empty text -> dropped');
  assert.equal(isGrounded({ text: 'words', evidenceIds: [] }), false, 'no grounded cite -> dropped');
  assert.equal(isGrounded({ text: 'words' }), false);
  assert.equal(isGrounded(null), false);
});

test('groundingIdsFromBundle: real evidence ids only; empty/id-less/null dropped', () => {
  assert.deepEqual(groundingIdsFromBundle({ evidence: [{ id: 'ev_1' }, { id: '' }, { id: 'ev_2' }, {}, null, { id: 'ev_3' }] }), ['ev_1', 'ev_2', 'ev_3']);
  assert.deepEqual(groundingIdsFromBundle({}), []);
  assert.deepEqual(groundingIdsFromBundle(null), []);
});
