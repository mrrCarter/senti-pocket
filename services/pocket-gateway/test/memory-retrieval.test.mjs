// memory-retrieval.test.mjs — memory-MVP retrieval core (RRF-grounded, the moat).
import test from 'node:test';
import assert from 'node:assert/strict';

import { int8Dot, denseExactScan, rrfFuse, retrieveGrounding, scatterRecall } from '../src/memory/retrieval.mjs';

test('int8Dot: exact dot product + STRICT dim-equality (Warden finding 1: mixed dims throw, not silent mis-rank)', () => {
  assert.equal(int8Dot([1, 2, 3], [4, 5, 6]), 4 + 10 + 18);
  assert.throws(() => int8Dot([1, 2, 3, 9], [4, 5, 6]), /dimension mismatch/); // 512-d vs 256-d must NOT silently compare
  assert.throws(() => int8Dot(null, [1]), /dimension mismatch/);
});

test('denseExactScan: exact ranking, deterministic tie-break, limit, 100% recall of the true top', () => {
  const q = [10, 0, 0];
  const corpus = [
    { id: 'far', vector: [0, 10, 0] }, // dot 0
    { id: 'near', vector: [9, 1, 0] }, // dot 90 <- true top
    { id: 'mid', vector: [3, 0, 0] }, // dot 30
    { id: 'tieA', vector: [3, 0, 0] }, // dot 30, id tie-break after 'mid'
  ];
  const ranked = denseExactScan(q, corpus, { limit: 3 });
  assert.deepEqual(ranked.map((r) => r.id), ['near', 'mid', 'tieA']); // exact top found; 'mid'<'tieA' tie-break
  assert.equal(ranked[0].score, 90);
});

test('rrfFuse: a doc strong in BOTH rankers beats one strong in only one; accepts {id} or bare id', () => {
  const lexical = [{ id: 'both' }, { id: 'lexOnly' }, { id: 'x' }];
  const dense = ['both', 'denseOnly', 'y']; // bare ids
  const fused = rrfFuse([lexical, dense], { k: 60, limit: 10 });
  assert.equal(fused[0].id, 'both'); // present near-top in both lists -> highest fused score
  // 'both' scored from rank1 in both: 1/61 + 1/61; single-list items score once.
  assert.ok(fused.find((f) => f.id === 'lexOnly'));
  assert.ok(fused.find((f) => f.id === 'denseOnly'));
});

test('retrieveGrounding: returns the top-K RRF-fused id subset (relevance-filtered, not the corpus)', () => {
  const lexicalRanked = [{ id: 'a' }, { id: 'b' }, { id: 'c' }, { id: 'd' }];
  const dense = [{ id: 'c' }, { id: 'a' }, { id: 'e' }];
  const grounding = retrieveGrounding({ lexicalRanked, dense, topK: 3 });
  assert.equal(grounding.length, 3);
  assert.ok(grounding.includes('a') && grounding.includes('c')); // in both -> surface
});

// --- 8-Needle CI seed: a needle that's dense-relevant but LEXICALLY BURIED must still be retrieved ---
test('NEEDLE recall: a dense-relevant needle buried in the lexical ranking survives into the grounding top-K', () => {
  const q = [12, 0, 0];
  // The needle is the closest dense match, but lexical BM25 ranks it 6th (buried by keyword distractors).
  const corpus = [
    { id: 'needle', vector: [11, 0, 0] }, // dense dot 132 -> dense rank 1
    { id: 'd1', vector: [1, 5, 0] },
    { id: 'd2', vector: [0, 6, 0] },
    { id: 'd3', vector: [2, 4, 0] },
    { id: 'd4', vector: [1, 3, 0] },
    { id: 'd5', vector: [0, 2, 0] },
  ];
  const dense = denseExactScan(q, corpus, { limit: 50 });
  assert.equal(dense[0].id, 'needle'); // dense exact-scan finds it (100% recall)
  const lexicalRanked = [{ id: 'd1' }, { id: 'd2' }, { id: 'd3' }, { id: 'd4' }, { id: 'd5' }, { id: 'needle' }];
  const grounding = retrieveGrounding({ lexicalRanked, dense, topK: 3 });
  assert.ok(grounding.includes('needle'), 'needle must be recalled into the top-K despite being lexically buried');
});

// --- 8-Needle SCATTER CI gate (Warden finding 2): topK is a tuning gate — the grounding pool must hold
//     >=95% of DISPERSED needles, else it silently under-covers. This asserts the bar so topK can't drop below it.
test('8-Needle SCATTER gate: grounding topK holds >=95% of 8 dispersed needles', () => {
  const needles = ['n1', 'n2', 'n3', 'n4', 'n5', 'n6', 'n7', 'n8'];
  const dense = needles.map((id) => ({ id })); // dense (relevance) ranks the 8 needles high
  // lexical scatters the needles among keyword distractors (dx*) — the exact "dispersed" hazard.
  const lexicalRanked = ['dx1', 'n1', 'dx2', 'n2', 'dx3', 'n3', 'n4', 'dx4', 'n5', 'n6', 'dx5', 'n7', 'n8']
    .map((id) => ({ id }));
  const grounding = retrieveGrounding({ lexicalRanked, dense, topK: 12 });
  const recall = scatterRecall(grounding, needles);
  assert.ok(recall >= 0.95, `scatter-recall ${recall} < 0.95 at topK=12 -> raise topK or add a recall-floor`);
});

test('scatterRecall: fraction of needles in the grounding, empty-needles -> 1', () => {
  assert.equal(scatterRecall(['a', 'b', 'c'], ['a', 'c']), 1); // both present
  assert.equal(scatterRecall(['a', 'x'], ['a', 'b', 'c', 'd']), 0.25); // 1 of 4
  assert.equal(scatterRecall(['a'], []), 1); // no needles -> vacuously full recall
});
