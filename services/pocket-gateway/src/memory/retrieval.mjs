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

/**
 * Exact int8 dot-product similarity. STRICT dimension equality (Warden adversarial finding 1):
 * a raw int8 dot MAGNITUDE grows with dimension (more terms), so silently comparing mixed dims (e.g.
 * Matryoshka 512-d global vs 256-d chunk in one index) ranks by dimensionality, not relevance — a
 * silent recall-rot, no error. Invariant: ONE embedding dim per index. Throw loudly on mismatch.
 * `a`,`b` are Int8Array | number[] of EQUAL length.
 */
export function int8Dot(a, b) {
  const av = a || [];
  const bv = b || [];
  if (av.length !== bv.length) {
    throw new Error(
      `int8Dot: dimension mismatch (${av.length} vs ${bv.length}) — one embedding dim per index; ` +
        'Matryoshka dims (512/256/…) must not share an index. Cosine-normalize + fix the dim upstream.',
    );
  }
  let acc = 0;
  for (let i = 0; i < av.length; i += 1) acc += av[i] * bv[i];
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
 *
 * ⚠ `topK` is a TUNING GATE, not a free constant (Warden adversarial finding 2): it is the pre-rerank
 * grounding POOL, and the 8-Needle SCATTER eval requires that pool to hold >=95% of dispersed relevant
 * items. If a query has many high-ranking lexical matches, dispersed needles can get pushed past top-K
 * and the "grounded" guarantee silently under-covers. So `topK` MUST be validated against
 * Needle-Scatter recall in CI (raise it, or add a recall-floor, if it drops needles). `scatterRecall()`
 * below is the check; the 8-Needle CI harness asserts it >=0.95 so topK can never silently fall below bar.
 * @param {{lexicalRanked?:{id:string}[]|string[], dense?:{id:string}[], k?:number, topK?:number}} args
 * @returns {string[]} the grounded id subset, best-first.
 */
export function retrieveGrounding({ lexicalRanked = [], dense = [], k = 60, topK = 12 } = {}) {
  return rrfFuse([lexicalRanked, dense], { k, limit: topK }).map((r) => r.id);
}

/**
 * Needle-Scatter recall = |grounding ∩ needles| / |needles| — the fraction of DISPERSED relevant items
 * that survived into the grounding pool. The 8-Needle CI gate asserts this >= 0.95 for the chosen topK
 * (Warden finding 2); a drop means raise topK or add a recall-floor. `needleIds` = the known-relevant set.
 */
export function scatterRecall(groundingIds, needleIds) {
  const need = new Set(Array.isArray(needleIds) ? needleIds : []);
  if (need.size === 0) return 1;
  const got = new Set(Array.isArray(groundingIds) ? groundingIds : []);
  let hit = 0;
  for (const id of need) if (got.has(id)) hit += 1;
  return hit / need.size;
}
