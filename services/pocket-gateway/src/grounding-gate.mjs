// grounding-gate.mjs — THE single audited honesty boundary for grounding.
//
// The "no fabrication" guarantee of /answer + /brief rests on ONE operation: a cited evidence id may cross to the phone
// ONLY if it is in the grounding set retrieval found in the VERIFIED (signature-checked) bundle. Any id the LLM claims
// but that is NOT grounded is DROPPED (hallucination), and if nothing survives the answer/brief degrades to
// clarify/unavailable — never a fabricated citation. That intersection was duplicated verbatim across reasoning-router
// (routeAnswer), gemma-backend (reason + brief), and brief-pipeline. Consolidating it here removes the drift risk on the
// most safety-critical logic we have: there is now ONE place to read, test, and audit the grounding gate. Pure, no I/O.

/**
 * The grounding ids retrieval found in the VERIFIED bundle — the ONLY ids a citation may reference. Derived from the
 * bundle's projected evidence (each already anchored to a real checkpoint event). Empty/id-less evidence is dropped.
 */
export function groundingIdsFromBundle(bundle) {
  return (Array.isArray(bundle?.evidence) ? bundle.evidence : []).map((e) => e && e.id).filter(Boolean);
}

/**
 * THE honesty gate. Intersect the LLM's CLAIMED citation ids with the grounding set, keeping only real grounded ids —
 * deduped, first-occurrence order preserved. `grounded` may be a Set or an array (id list). A hallucinated id (not in
 * the grounding) is dropped; the result is exactly the citations that are provably backed by the verified bundle.
 * Byte-identical to the prior inline forms: routeAnswer's `[...new Set(claimed.filter(id => grounded.includes(id)))]`
 * and gemma-backend's `[...new Set(p.evidenceIds.filter(id => grounded.has(id)))]`.
 * @param {string[]} claimed  ids the LLM claims to cite
 * @param {Set<string>|string[]} grounded  the grounding set (verified-bundle ids)
 * @returns {string[]} the grounded, deduped subset (order-preserving)
 */
export function keepGrounded(claimed, grounded) {
  const set = grounded instanceof Set ? grounded : new Set(Array.isArray(grounded) ? grounded : []);
  return [...new Set((Array.isArray(claimed) ? claimed : []).filter((id) => set.has(id)))];
}

/**
 * A drafted/briefed SEGMENT survives the honesty gate only with VISIBLE text (non-whitespace) AND at least one grounded
 * citation. A whitespace-only "segment" carries no words for the phone, so it is dropped — the same strictness
 * routeAnswer applies to /answer text (`answerText.trim().length === 0`) and brief-pipeline applies to its segments.
 */
export function isGrounded(seg) {
  return !!seg && typeof seg.text === 'string' && seg.text.trim().length > 0
    && Array.isArray(seg.evidenceIds) && seg.evidenceIds.length > 0;
}
