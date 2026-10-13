// Opt-in Jev/other-assessor seam. This module makes no network calls and grants no action or dial authority.
// Citation membership is deterministic; semantic support is an assessor's judgment, not an independent proof.
import { createHash } from 'node:crypto';
import { splitTagged } from './audio-tags.mjs';
import { canonicalBundleBytes, validateBundleIngress } from './bundle.mjs';
import { projectReasoningEvidence, REASONING_EVIDENCE_LIMIT } from './reasoning-evidence.mjs';

export const ASSESSMENT_SCHEMA = 'pocket.assessment.v1';
const bytes = (s) => Buffer.byteLength(s, 'utf8');
const digest = (value) => createHash('sha256').update(JSON.stringify(value)).digest('hex');
const frozen = (value) => {
  if (value && typeof value === 'object') {
    Object.values(value).forEach(frozen);
    Object.freeze(value);
  }
  return value;
};
const bounded = (s, max) => typeof s === 'string' && bytes(s) <= max;
const LOCAL_REASON_CODES = new Set(['invalid-signed-bundle', 'invalid-evidence-context', 'missing-required-evidence',
  'required-evidence-exceeds-budget', 'evidence-context-too-large', 'no-evidence', 'invalid-candidate',
  'spoken-text-mismatch', 'candidate-too-large']);

// Trusted selection policy supplies required evidence; model-generated urgency may not alter this policy.
export function selectAssessmentEvidence(bundle, groundedEvidenceIds, requiredEvidenceIds = [], maxEvidence = REASONING_EVIDENCE_LIMIT) {
  const available = bundle?.evidence;
  if (!Array.isArray(available) || available.length > 256 || !Array.isArray(requiredEvidenceIds)
    || requiredEvidenceIds.length > 256 || !Number.isInteger(maxEvidence) || maxEvidence < 1 || maxEvidence > REASONING_EVIDENCE_LIMIT) {
    throw new Error('invalid-evidence-context');
  }
  const allowed = new Set(Array.isArray(groundedEvidenceIds) ? groundedEvidenceIds : available.map((e) => e?.id));
  const byId = new Map();
  for (const e of available) {
    if (!bounded(e?.id, 256) || !e.id || byId.has(e.id) || !bounded(e.snippet, 4096)
      || !e.snippet.trim() || !Number.isSafeInteger(e.sequence) || e.sequence <= 0) throw new Error('invalid-evidence-context');
    if (allowed.has(e.id)) byId.set(e.id, e);
  }
  const required = [...new Set(requiredEvidenceIds)];
  if (required.some((id) => typeof id !== 'string' || !byId.has(id))) throw new Error('missing-required-evidence');
  if (required.length > maxEvidence) throw new Error('required-evidence-exceeds-budget');
  const ids = [...new Set([...required, ...byId.keys()])].slice(0, maxEvidence);
  const selected = projectReasoningEvidence([...byId.values()], ids);
  if (bytes(JSON.stringify(selected)) > 65_536) throw new Error('evidence-context-too-large');
  return frozen({ selected, required, availableCount: byId.size,
    truncatedCount: selected.filter((e) => e.snippetTruncated).length });
}

function normalizeCandidate(raw, mode, selectedIds) {
  const parts = mode === 'answer' ? [raw] : raw?.segments;
  if (!Array.isArray(parts) || !parts.length || parts.length > 24) throw new Error('invalid-candidate');
  const allowed = new Set(selectedIds);
  const candidate = parts.map((s) => {
    if (!bounded(s?.text, 4096) || !s.text.trim() || !Array.isArray(s.evidenceIds)
      || s.evidenceIds.length > 64 || !s.evidenceIds.length
      || s.evidenceIds.some((id) => typeof id !== 'string' || !allowed.has(id))) throw new Error('invalid-candidate');
    const text = splitTagged(s.text).plain;
    const taggedText = s.taggedText === undefined ? s.text : s.taggedText;
    // Evaluate the words that will actually be displayed AND spoken, preventing an alternate TTS payload.
    if (!bounded(taggedText, 4096) || splitTagged(taggedText).plain !== text || !text) throw new Error('spoken-text-mismatch');
    return { text, taggedText, evidenceIds: [...new Set(s.evidenceIds)] };
  });
  if (bytes(JSON.stringify(candidate)) > 32_768) throw new Error('candidate-too-large');
  return frozen(candidate);
}

function checkVerdict(raw, binding, candidate, minSupportScore) {
  if (raw?.contextHash !== binding.contextHash || raw?.candidateHash !== binding.candidateHash
    || !Array.isArray(raw.verdicts) || raw.verdicts.length !== candidate.length) return 'invalid-assessment';
  const seen = new Set();
  for (const v of raw.verdicts) {
    if (!Number.isInteger(v?.index) || v.index < 0 || v.index >= candidate.length || seen.has(v.index)
      || !['supported', 'unsupported', 'inconclusive'].includes(v.support)
      || !Number.isFinite(v.supportScore) || v.supportScore < 0 || v.supportScore > 1) return 'invalid-assessment';
    seen.add(v.index);
    if (v.support !== 'supported' || v.supportScore < minSupportScore) return 'support-not-established';
  }
  return null;
}

// A timeout bounds the caller's wait; injected adapters must honor AbortSignal to cancel their own compute/I/O.
async function withinBudget(fn, input, remainingMs) {
  if (remainingMs <= 0) throw new Error('assessment-timeout');
  const controller = new AbortController();
  let timer;
  try {
    return await Promise.race([
      Promise.resolve().then(() => fn({ ...input, signal: controller.signal })),
      new Promise((_, reject) => { timer = setTimeout(() => { controller.abort(); reject(new Error('assessment-timeout')); }, remainingMs); }),
    ]);
  } finally { clearTimeout(timer); controller.abort(); }
}

/**
 * assess({context,candidate,contextHash,candidateHash,signal}) -> same hashes plus
 * verdicts:[{index,support:'supported'|'unsupported'|'inconclusive',supportScore:0..1}].
 * The score is an uncalibrated provider rating. It never changes authorization or the ring-confidence floor.
 * requiredEvidenceFor is deploy-owned policy, never a field accepted from the HTTP body.
 */
export function createAssessedReasoningBackend({ reason, brief, assess, requiredEvidenceFor = () => [],
  maxAttempts = 2, timeoutMs = 10_000, maxEvidence = 24, minSupportScore = 0.8 } = {}) {
  if (typeof assess !== 'function' || (typeof reason !== 'function' && typeof brief !== 'function')
    || typeof requiredEvidenceFor !== 'function') throw new Error('assessed reasoning requires draft and assessment adapters');
  if (!Number.isInteger(maxAttempts) || maxAttempts < 1 || maxAttempts > 3
    || !Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 60_000
    || !Number.isInteger(maxEvidence) || maxEvidence < 1 || maxEvidence > REASONING_EVIDENCE_LIMIT
    || !Number.isFinite(minSupportScore) || minSupportScore < 0 || minSupportScore > 1) throw new Error('invalid-assessment-policy');

  async function evaluate(mode, input = {}) {
    const started = Date.now();
    let selection, context, contextHash, candidateHash, candidate, reasonCode, attempts = 0, confidence = null, nearestTopics = [];
    let status = 'inconclusive';
    try {
      // Providers receive an immutable snapshot; neither draft nor assessment may rewrite caller evidence.
      input = frozen(structuredClone(input));
      // Gateway callers already sign/verify this bundle. This check is structural, not trust-anchor verification.
      if (!validateBundleIngress(input.bundle).ok || !bounded(input.bundle.signature, 512)
        || Buffer.from(input.bundle.signature || '', 'base64').length !== 64) throw new Error('invalid-signed-bundle');
      if (!bounded(input.bundle?.sessionId, 256) || !input.bundle.sessionId
        || !bounded(input.bundle?.checkpointId, 256) || !input.bundle.checkpointId
        || (mode === 'answer' && (!bounded(input.question, 4096) || !input.question.trim()))) throw new Error('invalid-evidence-context');
      const policyInput = frozen({ mode, sessionId: input.bundle.sessionId, checkpointId: input.bundle.checkpointId,
        question: mode === 'answer' ? input.question : '' });
      selection = selectAssessmentEvidence(input.bundle, input.groundedEvidenceIds, requiredEvidenceFor(policyInput), maxEvidence);
      const bundleBinding = { canonicalHash: createHash('sha256').update(canonicalBundleBytes(input.bundle)).digest('hex'),
        contractsVersion: input.bundle.contractsVersion, sequenceStart: input.bundle.sequenceStart,
        sequenceEnd: input.bundle.sequenceEnd, signingKeyId: input.bundle.signingKeyId,
        signature: input.bundle.signature, createdAt: input.bundle.createdAt };
      context = frozen({ ...policyInput, bundleBinding, evidence: selection.selected, requiredEvidenceIds: selection.required });
      contextHash = digest(context);
      if (!selection.selected.length) throw new Error('no-evidence');
      let feedback;
      for (let n = 0; n < maxAttempts; n++) {
        attempts++;
        const draft = mode === 'answer' ? reason : brief;
        let raw;
        try {
          raw = await withinBudget(draft, { ...input, groundedEvidenceIds: selection.selected.map((e) => e.id),
            reasoningEvidence: selection.selected, assessmentFeedback: feedback }, timeoutMs - (Date.now() - started));
        } catch { status = 'unavailable'; reasonCode = 'draft-unavailable'; break; }
        try { candidate = normalizeCandidate(raw, mode, selection.selected.map((e) => e.id)); }
        catch (err) { reasonCode = err.message; feedback = frozen({ reason: reasonCode, requiredEvidenceIds: selection.required }); continue; }
        confidence = Number.isFinite(raw?.llmConfidence) && raw.llmConfidence >= 0 && raw.llmConfidence <= 1 ? raw.llmConfidence : null;
        nearestTopics = Array.isArray(raw?.nearestTopics) ? raw.nearestTopics.filter((t) => bounded(t?.label, 256)
          && selection.selected.some((e) => e.id === t.evidenceId)).slice(0, 8).map((t) => ({ label: t.label, evidenceId: t.evidenceId })) : [];
        const cited = new Set(candidate.flatMap((s) => s.evidenceIds));
        const missing = selection.required.filter((id) => !cited.has(id));
        if (missing.length) {
          reasonCode = 'required-evidence-not-covered';
          feedback = frozen({ reason: reasonCode, requiredEvidenceIds: selection.required, missingEvidenceIds: missing });
          continue;
        }
        candidateHash = digest(candidate);
        const binding = { contextHash, candidateHash };
        let result;
        try { result = await withinBudget(assess, { context, candidate, ...binding }, timeoutMs - (Date.now() - started)); }
        catch { status = 'unavailable'; reasonCode = 'assessor-unavailable'; break; }
        reasonCode = checkVerdict(result, binding, candidate, minSupportScore);
        if (!reasonCode) { status = 'evaluated'; break; }
        feedback = frozen({ reason: reasonCode, requiredEvidenceIds: selection.required });
      }
    } catch (err) { reasonCode = LOCAL_REASON_CODES.has(err?.message) ? err.message : 'context-preparation-failed'; }
    const accepted = status === 'evaluated';
    const citedIds = accepted ? [...new Set(candidate.flatMap((s) => s.evidenceIds))] : [];
    const assessment = frozen({ schema: ASSESSMENT_SCHEMA, status, reason: reasonCode || 'model-assessed-support', attempts,
      semanticSupport: accepted ? 'model-assessed' : 'not-established', contextHash: contextHash || null,
      candidateHash: candidateHash || null, bundleCanonicalHash: context?.bundleBinding.canonicalHash || null,
      coverage: { availableEvidence: selection?.availableCount || 0,
        selectedEvidence: selection?.selected.length || 0, omittedEvidence: (selection?.availableCount || 0) - (selection?.selected.length || 0),
        citedEvidence: citedIds.length, truncatedEvidence: selection?.truncatedCount || 0, requiredEvidence: selection?.required.length || 0,
        requiredCovered: accepted ? selection.required.length : 0 } });
    // A failed assessment never returns the generated prose. Callers may present cached, signed evidence separately.
    return mode === 'answer'
      ? { ...(accepted ? candidate[0] : { text: '', evidenceIds: [] }), llmConfidence: accepted ? confidence : null,
        nearestTopics: accepted ? nearestTopics : [], assessment }
      : { segments: accepted ? candidate : [], assessment };
  }
  return {
    ...(typeof reason === 'function' ? { reason: (input) => evaluate('answer', input) } : {}),
    ...(typeof brief === 'function' ? { brief: (input) => evaluate('brief', input) } : {}),
  };
}
