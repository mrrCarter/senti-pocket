// retrieval.mjs — memory-MVP retrieval core (the moat). Pure + deterministic; no I/O.
//
// At PERSONAL / agent-work scale the corpus is small (thousands of observations, not billions), so we
// EXACT-scan int8 vectors — no ANN/HNSW — for <10ms lookups at 100% recall (ENGRAM Thesis 1: personal
// memory is a small-data problem; approximate indexes trade away the recall that IS the product). We fuse
// a lexical ranking (FTS5 / BM25) with the dense ranking via Reciprocal Rank Fusion, then take the top-K
// as the RETRIEVED grounding subset.
//
// THE HONESTY SEAM (Atlas cross-audit, 2026-07-20): a memory-scale /answer MUST ground on THIS
// relevance-filtered retrieved subset, NOT the whole corpus. `retrieveGrounding()` is the function the
// gateway's grounding set must come from once memory needles across many sessions — otherwise
// "grounded == cited any id in the corpus" degrades to meaningless as the corpus grows.

/** Exact int8 dot-product similarity. `a`,`b` are Int8Array | number[] of (ideally) equal length. */
export function int8Dot(a, b) {
  const av = a || [];
  const bv = b || [];
  const n = Math.min(av.length, bv.length);
  let acc = 0;
  for (let i = 0; i < n; i += 1) acc += av[i] * bv[i];
  return acc;
}

/**
 * Exact dense scan: rank the corpus by int8 dot-product to the query. NO approximation.
 * @param {Int8Array|number[]} queryVector
 * @param {{id:string, vector:Int8Array|number[]}[]} corpus
 * @returns {{id:string, score:number}[]} sorted by score desc, deterministic id tie-break.
 */
export function denseExactScan(queryVector, corpus, { limit = 50 } = {}) {
  const scored = (Array.isArray(corpus) ? corpus : [])
    .filter((doc) => doc && doc.id != null)
    .map((doc) => ({ id: doc.id, score: int8Dot(queryVector, doc.vector) }));
  scored.sort((a, b) => b.score - a.score || String(a.id).localeCompare(String(b.id)));
  return scored.slice(0, Math.max(0, limit));
}

/**
 * Reciprocal Rank Fusion over N ranked lists. Each list is in rank order; items may be `{id}` or a bare id.
 * RRF score(id) = Σ_lists 1/(k + rank), rank 1-based (k=60 standard). Fuses heterogeneous rankers
 * (BM25 lexical + dense cosine) WITHOUT needing comparable score scales — only their orderings.
 * @returns {{id:string, score:number}[]} sorted desc, deterministic id tie-break.
 */
export function rrfFuse(rankedLists, { k = 60, limit = 50 } = {}) {
  const scores = new Map();
  for (const list of Array.isArray(rankedLists) ? rankedLists : []) {
    const items = Array.isArray(list) ? list : [];
    items.forEach((item, index) => {
      const id = item && typeof item === 'object' ? item.id : item;
      if (id == null) return;
      scores.set(id, (scores.get(id) || 0) + 1 / (k + index + 1));
    });
  }
  const fused = [...scores.entries()].map(([id, score]) => ({ id, score }));
  fused.sort((a, b) => b.score - a.score || String(a.id).localeCompare(String(b.id)));
  return fused.slice(0, Math.max(0, limit));
}

/**
 * The RETRIEVED grounding subset (Atlas honesty invariant): fuse the lexical ranking with the dense
 * exact-scan and return the top-K ids. THIS is what a memory-scale /answer grounds on —
 * relevance-filtered, never the whole corpus.
 * @param {{lexicalRanked?:{id:string}[]|string[], dense?:{id:string}[], k?:number, topK?:number}} args
 * @returns {string[]} the grounded id subset, best-first.
 */
export function retrieveGrounding({ lexicalRanked = [], dense = [], k = 60, topK = 12 } = {}) {
  return rrfFuse([lexicalRanked, dense], { k, limit: topK }).map((r) => r.id);
}
