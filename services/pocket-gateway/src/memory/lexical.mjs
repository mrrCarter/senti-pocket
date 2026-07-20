// lexical.mjs — memory-MVP lexical ranker (BM25), the lexical half of the retrieval (brick 2).
// Pairs with retrieval.mjs's dense int8 exact-scan; both feed retrieveGrounding()'s RRF fusion.
//
// EXACT BM25 over the in-memory corpus — no inverted-index service, no ANN — because at personal /
// agent-work scale the corpus is small (thousands of observations) and an exact pass is <10ms at 100%
// recall (ENGRAM Thesis 1). Standard Okapi BM25 (k1=1.2, b=0.75). Deterministic; id tie-break.

const DEFAULT_K1 = 1.2;
const DEFAULT_B = 0.75;

/** Lowercase, split on non-alphanumeric, drop empties. Deterministic + dependency-free. */
export function tokenize(text) {
  return String(text || '')
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter(Boolean);
}

/**
 * Build a BM25 index over `docs` = [{id, text}]. Returns { search(query, {limit}) -> [{id, score}] }.
 * IDF uses the BM25 form with a +1 so a term in every doc still scores > 0 (never negative).
 */
export function buildBM25Index(docs, { k1 = DEFAULT_K1, b = DEFAULT_B } = {}) {
  const corpus = (Array.isArray(docs) ? docs : []).filter((d) => d && d.id != null);
  const postings = corpus.map((d) => {
    const tokens = tokenize(d.text);
    const tf = new Map();
    for (const t of tokens) tf.set(t, (tf.get(t) || 0) + 1);
    return { id: d.id, tf, len: tokens.length };
  });
  const N = postings.length;
  const avgdl = N ? postings.reduce((s, p) => s + p.len, 0) / N : 0;
  // document frequency per term
  const df = new Map();
  for (const p of postings) for (const t of p.tf.keys()) df.set(t, (df.get(t) || 0) + 1);
  const idf = (t) => {
    const n = df.get(t) || 0;
    // BM25 idf with +1 inside the log -> strictly positive, never NaN/negative.
    return Math.log(1 + (N - n + 0.5) / (n + 0.5));
  };

  function search(query, { limit = 50 } = {}) {
    const qTerms = [...new Set(tokenize(query))];
    if (qTerms.length === 0 || N === 0) return [];
    const scored = postings.map((p) => {
      let score = 0;
      for (const t of qTerms) {
        const f = p.tf.get(t);
        if (!f) continue;
        const denom = f + k1 * (1 - b + (b * p.len) / (avgdl || 1));
        score += idf(t) * ((f * (k1 + 1)) / denom);
      }
      return { id: p.id, score };
    });
    return scored
      .filter((s) => s.score > 0)
      .sort((a, b2) => b2.score - a.score || String(a.id).localeCompare(String(b2.id)))
      .slice(0, Math.max(0, limit));
  }

  return { search, size: N };
}
