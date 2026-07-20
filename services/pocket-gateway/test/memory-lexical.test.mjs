// memory-lexical.test.mjs — BM25 lexical ranker + end-to-end retrieval composition (brick 2).
import test from 'node:test';
import assert from 'node:assert/strict';

import { tokenize, buildBM25Index } from '../src/memory/lexical.mjs';
import { denseExactScan, retrieveGrounding } from '../src/memory/retrieval.mjs';

test('tokenize: lowercase, split on non-alphanumeric, drop empties', () => {
  assert.deepEqual(tokenize('Relay fixed the token-parser!'), ['relay', 'fixed', 'the', 'token', 'parser']);
  assert.deepEqual(tokenize(''), []);
  assert.deepEqual(tokenize(null), []);
});

test('BM25: ranks the doc with the query term highest; rarer term outweighs common', () => {
  const idx = buildBM25Index([
    { id: 'd1', text: 'the parser was fixed by relay' },
    { id: 'd2', text: 'the the the the common words only' },
    { id: 'd3', text: 'relay shipped the scale head today' },
  ]);
  const hits = idx.search('parser');
  assert.equal(hits[0].id, 'd1'); // only d1 has "parser"
  const relayHits = idx.search('relay');
  assert.ok(relayHits.find((h) => h.id === 'd1') && relayHits.find((h) => h.id === 'd3')); // both mention relay
  // "the" is in every doc -> low IDF -> a query of only "the" ranks weakly/empty-ish (idf ~ log(1+0.5/3.5))
  assert.ok(idx.search('parser')[0].score > 0);
});

test('BM25: empty query / empty corpus -> [] (no crash)', () => {
  assert.deepEqual(buildBM25Index([]).search('anything'), []);
  assert.deepEqual(buildBM25Index([{ id: 'a', text: 'x' }]).search(''), []);
});

// --- end-to-end: BM25 lexical + dense exact-scan -> RRF -> grounding (the moat's retrieval, functional) ---
test('retrieval end-to-end: lexical(BM25) + dense(exact) fuse into a grounded subset', () => {
  const docs = [
    { id: 'obs1', text: 'relay fixed the token parser bug', vector: [9, 0, 1] },
    { id: 'obs2', text: 'warden gated the scale head', vector: [0, 9, 1] },
    { id: 'obs3', text: 'the parser change shipped to prod', vector: [7, 0, 2] },
  ];
  const bm25 = buildBM25Index(docs);
  const lexicalRanked = bm25.search('parser'); // obs1 + obs3 mention parser
  const dense = denseExactScan([10, 0, 0], docs.map((d) => ({ id: d.id, vector: d.vector }))); // near obs1/obs3
  const grounding = retrieveGrounding({ lexicalRanked, dense, topK: 2 });
  assert.equal(grounding.length, 2);
  assert.ok(grounding.includes('obs1')); // strong in both lexical + dense -> top of the fused grounding
});
