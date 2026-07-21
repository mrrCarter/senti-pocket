// reasoning-router.mjs — GROUNDING-first routing for /answer (Warden honesty bar #2, 2026-07-20).
//
// The PRIMARY gate is RETRIEVAL GROUNDING — does real evidence from the VERIFIED checkpoint support the
// answer? — NOT the LLM's self-reported confidence (poorly calibrated; models are confidently wrong). LLM
// confidence is a secondary tiebreaker only. This keeps Carter's "reason, don't refuse" HONEST (grounded)
// instead of confidently-wrong. It also drops HALLUCINATED citations: an evidenceId the LLM claims but that
// is NOT in the retrieved grounding set is discarded — you can only cite evidence retrieval actually found.
import { keepGrounded } from './grounding-gate.mjs';

const normalizeTopics = (topics) =>
  (Array.isArray(topics) ? topics : [])
    .filter((t) => t && typeof t.label === 'string' && typeof t.evidenceId === 'string')
    .map((t) => ({ label: t.label, evidenceId: t.evidenceId }));

const buildClarify = (topics) => {
  const t = normalizeTopics(topics);
  return {
    prompt: t.length
      ? 'I have related context but not a direct answer — which did you mean?'
      : 'I could not ground that in this checkpoint — can you rephrase or narrow it?',
    options: t.slice(0, 4).map((x) => x.label),
  };
};

/**
 * Route an /answer response by GROUNDING first.
 * @param {{ groundedEvidenceIds: string[], llmAnswer: {text?, taggedText?, evidenceIds?: string[], llmConfidence?: number}, nearestTopics?: {label,evidenceId}[] }} input
 *   groundedEvidenceIds — evidence ids RETRIEVAL found relevant in the verified bundle (the grounding).
 *   llmAnswer.evidenceIds — ids the LLM claims to cite (intersected with grounding; hallucinated ones dropped).
 * @param {{ minConfidence?: number }} opts
 * @returns {{status:'answered'|'clarify'|'unavailable', answer?, clarify?, unavailable?}}
 */
export function routeAnswer(input, opts = {}) {
  const minConfidence = opts.minConfidence ?? 0.55; // secondary tiebreaker only
  const grounded = Array.isArray(input?.groundedEvidenceIds) ? input.groundedEvidenceIds : [];
  const llm = input?.llmAnswer || {};
  const claimed = Array.isArray(llm.evidenceIds) ? llm.evidenceIds : [];
  // Only citations that are ACTUALLY in the retrieved grounding survive (drop hallucinated ids) — the shared honesty gate.
  const citedGrounded = keepGrounded(claimed, grounded);
  const answerText = typeof llm.text === 'string' ? llm.text : '';

  // PRIMARY gate: grounding AND a non-empty answer. A grounded citation with EMPTY answer text is not an answer —
  // routing it .answered would show the user a citation with no words. (The parallel brief() path already drops
  // empty-text segments; /answer was missing the same guard.)
  if (citedGrounded.length === 0 || answerText.trim().length === 0) {
    return grounded.length > 0
      ? { status: 'clarify', clarify: buildClarify(input?.nearestTopics) }
      : { status: 'unavailable', unavailable: { nearestTopics: normalizeTopics(input?.nearestTopics) } };
  }

  // Grounded. Secondary tiebreaker: a grounded-but-low-confidence answer with real alternatives -> clarify,
  // rather than a confident-sounding pick among ambiguous options.
  const conf = typeof llm.llmConfidence === 'number' ? llm.llmConfidence : 1;
  if (conf < minConfidence && normalizeTopics(input?.nearestTopics).length > 1) {
    return { status: 'clarify', clarify: buildClarify(input?.nearestTopics) };
  }

  return {
    status: 'answered',
    answer: {
      text: typeof llm.text === 'string' ? llm.text : '',
      taggedText: typeof llm.taggedText === 'string' ? llm.taggedText : (typeof llm.text === 'string' ? llm.text : ''),
      evidenceIds: citedGrounded, // ONLY grounded citations cross the boundary
      llmConfidence: conf,
    },
  };
}
