// bundle.mjs — build, Ed25519-sign, and verify a PocketBundle (PocketContracts v0.1).
// The phone caches a PocketBundle and MUST verify its signature before briefing from it.
// Signature covers the whole bundle EXCEPT the `signature` field itself (so signingKeyId is bound too).
import { sign as edSign, verify as edVerify, generateKeyPairSync, createPrivateKey, createPublicKey } from 'node:crypto';
import { scrubText } from './scrub.mjs';

export const CONTRACTS_VERSION = '0.1.8';
/** Max UTF-8 bytes for any single phone-visible evidence snippet (bounded egress). */
export const MAX_EVIDENCE_SNIPPET_BYTES = 2048;
/** Max UTF-8 bytes for the entire signed bundle body (defense against a pathological summary). This is the AUTHORITATIVE
 *  PRODUCE CEILING — the gateway NEVER signs a bundle whose canonical exceeds this. */
export const MAX_BUNDLE_BYTES = 512 * 1024;
/**
 * SINGLE SOURCE OF TRUTH for the whole-graph consume budget (warden's parity ask): the phone's
 * PocketBundle.maxTotalElements / maxTotalBytes MUST be pinned to EXACTLY these so any bundle this gateway signs is
 * accepted by the consumer. Both comfortably exceed the 512KB produce ceiling (a real ≤512KB bundle of genuine
 * evidence/claims — each element well over 26 bytes — carries far fewer than 20000 elements).
 */
export const BUNDLE_BUDGET = Object.freeze({ maxTotalElements: 20000, maxTotalBytes: 1024 * 1024 });

// ---- pocket.bundle.v1 canonical — MUST byte-match PocketContracts.swift canonicalBundlePayload() (@b25347a) ----
// Length+count-prefixed, presence-flagged grade, CHECKED epoch-millis dates, binds ALL fields except `signature`.
// Same discipline as canonicalReceiptPayload v4 / ActionProposal v3: injection-proof AND cross-language deterministic
// (Swift's Date round-trip loses raw-JSON date spellings, so dates are epoch-millis, never re-serialized JSON).
const BUNDLE_MS_BOUND = 253402300800000; // ~year 9999 in epoch ms (mirrors Swift ActionReceipt.safeEpochMillis bound)
const lpB = (s) => `${Buffer.byteLength(String(s ?? ''), 'utf8')}:${s ?? ''}`;
const iB = (n) => lpB(String(n));
const bundleEpochMs = (d) => { if (d == null) return ''; const m = new Date(d).getTime(); return (Number.isFinite(m) && m >= -BUNDLE_MS_BOUND && m <= BUNDLE_MS_BOUND) ? String(m) : ''; };
const msB = (d) => lpB(bundleEpochMs(d));
const optB = (s) => (s != null ? '1' + lpB(s) : '0');
const arrB = (xs, f) => lpB(String((xs || []).length)) + (xs || []).map(f).join('');
const evB = (e) => lpB(e.id) + lpB(e.sessionId) + iB(e.sequence) + lpB(e.agentId) + lpB(e.snippet) + msB(e.ts);
const claimB = (c) => lpB(c.id) + lpB(c.text) + lpB(c.kind) + arrB(c.evidenceIds, lpB);
const agentB = (a) => lpB(a.agentId) + lpB(a.summary) + arrB(a.claims, claimB) + arrB(a.evidence, evB);

/** The exact canonical string the bundle signature covers — byte-identical to Swift canonicalBundlePayload(). */
export function canonicalBundlePayload(b) {
  const s = b.summary || {};
  const summaryCanon = lpB(s.checkpointId) + lpB(s.headline) + lpB(s.summaryBaselineSchema) + optB(s.grade)
    + arrB(s.perAgent, agentB) + arrB(s.risks, lpB) + arrB(s.blockers, lpB);
  return 'pocket.bundle.v1\n'
    + lpB(b.contractsVersion) + lpB(b.checkpointId) + lpB(b.sessionId) + iB(b.sequenceStart) + iB(b.sequenceEnd)
    + summaryCanon
    + arrB(b.evidence, evB)
    + msB(b.createdAt) + lpB(b.signingKeyId);
}
/** The exact bytes that are signed/verified (pocket.bundle.v1; binds every field except `signature`). */
export function canonicalBundleBytes(bundle) { return Buffer.from(canonicalBundlePayload(bundle), 'utf8'); }

/** Dedup EvidenceRefs by id, ordered by source sequence (bounded, stable UI order). */
export function dedupEvidence(refs) {
  const seen = new Map();
  for (const r of refs || []) if (r && r.id && !seen.has(r.id)) seen.set(r.id, r);
  return [...seen.values()].sort((a, b) => Number(a.sequence) - Number(b.sequence));
}

/** UTF-8 byte length + bounded/scrubbed string helpers (final egress projection is best-effort + minimizing). */
const b8 = (s) => Buffer.byteLength(String(s ?? ''), 'utf8');
/**
 * PROSE truncation: scalar-safe (NEVER splits a UTF-8 code point) and CAP-INCLUSIVE (the 3-byte '…' is reserved WITHIN
 * maxBytes, so the result is ALWAYS <= maxBytes). Use ONLY for prose — never for identity/citation ids (see scrubId).
 */
const boundStr = (v, maxBytes) => {
  const s = String(v ?? '');
  if (b8(s) <= maxBytes) return s;
  const budget = Math.max(0, maxBytes - 3); // reserve 3 bytes for the '…'
  let out = '', used = 0;
  for (const ch of s) { const cb = Buffer.byteLength(ch, 'utf8'); if (used + cb > budget) break; out += ch; used += cb; }
  return out + '…';
};
const scrubStr = (v, maxBytes) => boundStr(scrubText(String(v ?? '')).text, maxBytes);
/**
 * IDENTITY/citation ids: scrubbed for secrets but NEVER length-truncated — truncating an id could collapse two distinct
 * ids that share a prefix (a silent identity forgery). An over-cap id survives to validateBundleIngress, which REJECTS
 * it (preserving identity, fail-closed at sign) rather than mangling it.
 */
const scrubId = (v) => scrubText(String(v ?? '')).text;

/**
 * Per-field caps for the projected, phone-visible CheckpointSummary. `id`/`evId`/snippet are pinned to the FROZEN
 * ingress minimums (PocketInference/InferenceTypes.swift GroundedInferenceRequest: checkpoint/session 1...256,
 * evidence id/agent 1...128, snippet 1...8000) so egress is ALWAYS ⊆ the frozen ingress contract (the phone can never
 * reject a bundle this gateway signs). snippet stays at the STRICTER egress cap 2048 (< frozen 8000 = safe). The
 * remaining caps (perAgent/evidence/risks/blockers/headline/summary) are deliberate BUNDLE/egress bounds, distinct
 * from the inference-request 1...32 (a different type).
 */
export const SUMMARY_CAPS = Object.freeze({
  id: 256, evId: 128, str: 512, headline: 4096, summary: 8192, snippet: MAX_EVIDENCE_SNIPPET_BYTES,
  perAgent: 200, evidence: 256, risks: 100, blockers: 100,
});

/** Project one EvidenceRef to ONLY the frozen scalar fields: unknown keys dropped, types enforced, strings scrubbed+bounded. */
export function projectEvidenceRef(r) {
  if (!r || typeof r !== 'object') return null;
  return {
    id: scrubId(r.id),                 // identity: never truncated (ingress rejects over-cap)
    sessionId: scrubId(r.sessionId),   // identity
    sequence: Number.isSafeInteger(r.sequence) && r.sequence > 0 ? r.sequence : 0,
    agentId: scrubId(r.agentId),       // identity
    snippet: scrubStr(r.snippet, SUMMARY_CAPS.snippet), // prose: scalar-safe bounded
    ts: typeof r.ts === 'string' ? boundStr(r.ts, SUMMARY_CAPS.str) : (r.ts instanceof Date ? r.ts.toISOString() : ''),
  };
}

const CLAIM_KINDS = new Set(['fact', 'inference', 'recommendation']);
/** Project one Claim to the frozen schema {id,text,kind,evidenceIds[]}; unknown kind => inference (fail-safe). */
function projectClaim(c) {
  if (!c || typeof c !== 'object') return null;
  return {
    id: scrubId(c.id), // identity: never truncated
    text: scrubStr(c.text, SUMMARY_CAPS.summary), // prose
    kind: CLAIM_KINDS.has(c.kind) ? c.kind : 'inference',
    evidenceIds: Array.isArray(c.evidenceIds) ? c.evidenceIds.slice(0, SUMMARY_CAPS.evidence).map((x) => scrubId(x)) : [], // citation identity
  };
}

/** Project one AgentSummary to the frozen schema (agentId, summary, claims[], evidence[]); unknown keys dropped. */
function projectAgentSummary(a) {
  if (!a || typeof a !== 'object') return null;
  const evidence = Array.isArray(a.evidence) ? a.evidence.slice(0, SUMMARY_CAPS.evidence).map(projectEvidenceRef).filter(Boolean) : [];
  const claims = Array.isArray(a.claims) ? a.claims.slice(0, SUMMARY_CAPS.evidence).map(projectClaim).filter(Boolean) : [];
  return { agentId: scrubId(a.agentId), summary: scrubStr(a.summary, SUMMARY_CAPS.summary), claims, evidence };
}

/**
 * STRICT projection of a caller-supplied CheckpointSummary onto the FROZEN PocketContracts v0.1 schema (Echo P0
 * minimal egress): ONLY known keys survive, types are enforced, strings/arrays are recursively bounded + scrubbed.
 * An unexpected key (e.g. summary.rawEvents) can NEVER cross to the phone or be signed.
 */
export function projectSummary(summary) {
  const s = summary && typeof summary === 'object' ? summary : {};
  return {
    checkpointId: scrubId(s.checkpointId), // identity
    headline: scrubStr(s.headline, SUMMARY_CAPS.headline),
    summaryBaselineSchema: scrubStr(s.summaryBaselineSchema, SUMMARY_CAPS.str),
    grade: s.grade == null ? null : scrubStr(s.grade, SUMMARY_CAPS.str),
    perAgent: Array.isArray(s.perAgent) ? s.perAgent.slice(0, SUMMARY_CAPS.perAgent).map(projectAgentSummary).filter(Boolean) : [],
    risks: Array.isArray(s.risks) ? s.risks.slice(0, SUMMARY_CAPS.risks).map((x) => scrubStr(x, SUMMARY_CAPS.str)) : [],
    blockers: Array.isArray(s.blockers) ? s.blockers.slice(0, SUMMARY_CAPS.blockers).map((x) => scrubStr(x, SUMMARY_CAPS.str)) : [],
  };
}

/**
 * Build an UNSIGNED PocketBundle draft from a RawCheckpoint + CheckpointSummary. `signature` is empty until signed.
 * MINIMAL EGRESS (Echo P0): the summary is STRICTLY projected onto the frozen schema (unknown keys dropped, sizes
 * bounded, values scrubbed) and the evidence set is derived ONLY from projected scalar fields — nothing else crosses.
 * Raw room events never cross (summary + bounded evidence only). Best-effort scrub, not a secret-free guarantee.
 * Throws if the projected+signed body would exceed MAX_BUNDLE_BYTES.
 */
export function buildBundle(rawCheckpoint, summary, opts = {}) {
  const projected = projectSummary(summary);
  const evidence = dedupEvidence(projected.perAgent.flatMap((a) => a.evidence || []));
  const bundle = {
    contractsVersion: opts.contractsVersion || CONTRACTS_VERSION,
    checkpointId: rawCheckpoint.checkpointId,
    sessionId: rawCheckpoint.sessionId,
    sequenceStart: rawCheckpoint.startSequence,
    sequenceEnd: rawCheckpoint.endSequence,
    summary: projected,
    evidence,
    createdAt: opts.createdAt || new Date().toISOString(),
    signature: '',
    signingKeyId: opts.signingKeyId || 'pocket-gateway-dev-key',
  };
  assertBundleSemantics(bundle); // FAIL-CLOSED: never SIGN a semantically-invalid bundle (warden bundle-KAV gate)
  const bodyBytes = canonicalBundleBytes(bundle).length; // signature stripped; the exact bytes that get signed
  if (bodyBytes > MAX_BUNDLE_BYTES) throw new Error(`bundle exceeds MAX_BUNDLE_BYTES (${bodyBytes} > ${MAX_BUNDLE_BYTES})`);
  return bundle;
}

/** Throw unless the bundle passes the FULL consume-side ingress gate (bounds + semantics). */
export function assertBundleIngress(b) {
  const { ok, errors } = validateBundleIngress(b);
  if (!ok) throw new Error(`bundle ingress validation failed: ${errors.join('; ')}`);
}

/** Sign a bundle draft with an Ed25519 private key (KeyObject or PEM). Returns a new signed bundle. */
export function signBundle(draft, privateKey, signingKeyId) {
  const key = typeof privateKey === 'string' ? createPrivateKey(privateKey) : privateKey;
  const toSign = { ...draft, signature: '' };
  if (signingKeyId) toSign.signingKeyId = signingKeyId;
  // FAIL-CLOSED: never crypto-sign a bundle the consume gate / phone would reject (Pulse: gateway must not sign what
  // its own ingress validator rejects). This runs the FULL ingress (bounds + semantics) over the exact bytes to sign.
  assertBundleIngress(toSign);
  const sig = edSign(null, canonicalBundleBytes(toSign), key); // Ed25519 => algorithm is null
  return { ...toSign, signature: sig.toString('base64') };
}

/** Verify a signed bundle against an Ed25519 public key (KeyObject or PEM). Returns boolean; never throws on bad input. */
export function verifyBundle(bundle, publicKey) {
  try {
    if (!bundle || typeof bundle.signature !== 'string' || bundle.signature.length === 0) return false;
    const key = typeof publicKey === 'string' ? createPublicKey(publicKey) : publicKey;
    const sig = Buffer.from(bundle.signature, 'base64');
    if (sig.length === 0) return false;
    return edVerify(null, canonicalBundleBytes(bundle), key, sig);
  } catch {
    return false;
  }
}

// ---- pre-sign SEMANTIC validity (warden bundle-KAV gate) + cross-language date guard (Pulse caution 2) ----
// Crypto-authenticity is NOT sufficient: even a trusted-key-signed bundle is REJECTED if it is semantically invalid.
// buildBundle enforces this FAIL-CLOSED so the gateway can never SIGN a bundle the phone's verify/consume path rejects.

/**
 * Strict cross-language epoch-ms guard. A bundle date is safe ONLY if Node and Swift compute the SAME integer epoch-ms
 * from it. Accepts an integer-ms number, a Date (integer ms), or an ISO-8601 string with AT MOST millisecond precision
 * (`.SSS`) and an EXPLICIT timezone. Rejects sub-ms strings (4+ fractional digits — Swift's ISO8601 parser returns nil
 * where Node returns a rounded ms => DIVERGENCE), timezone-less strings (ambiguous), non-finite/non-integer, and |ms|
 * beyond BUNDLE_MS_BOUND (~year 9999, mirrors Swift safeEpochMillis). Returns the integer ms, else null.
 */
export function canonicalEpochMs(d) {
  if (typeof d === 'number') return Number.isInteger(d) && Math.abs(d) <= BUNDLE_MS_BOUND ? d : null;
  if (d instanceof Date) { const m = d.getTime(); return Number.isInteger(m) && Math.abs(m) <= BUNDLE_MS_BOUND ? m : null; }
  if (typeof d === 'string') {
    if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?(Z|[+-]\d{2}:\d{2})$/.test(d)) return null; // ms-precision + explicit tz only
    const m = new Date(d).getTime();
    return Number.isFinite(m) && Number.isInteger(m) && Math.abs(m) <= BUNDLE_MS_BOUND ? m : null;
  }
  return null;
}

/**
 * SEMANTIC validity of a PocketBundle — the warden bundle-KAV gate criteria, enforced PRE-SIGN. Returns {ok,errors}.
 * A trusted-key-signed bundle must STILL be rejected if any hold: wrong version/schema, inverted sequence range,
 * mismatched checkpoint/session ids, duplicate/foreign evidence, uncited fact/inference claims, or invalid/sub-ms
 * dates. (`recommendation` claims may be uncited; evidence `ts` may be empty but, if present, must be canonical.)
 */
export function validateBundleSemantics(b) {
  const errors = [];
  const push = (m) => errors.push(m);
  if (!b || typeof b !== 'object') return { ok: false, errors: ['bundle: not an object'] };
  if (b.contractsVersion !== CONTRACTS_VERSION) push(`contractsVersion: expected ${CONTRACTS_VERSION}, got ${JSON.stringify(b.contractsVersion)}`);
  if (!b.checkpointId) push('checkpointId: empty');
  if (!b.sessionId) push('sessionId: empty');
  const s0 = b.sequenceStart, s1 = b.sequenceEnd;
  // frozen GroundedInferenceRequest: sequenceStart > 0 && sequenceEnd >= sequenceStart (POSITIVE, non-inverted).
  if (!Number.isSafeInteger(s0) || !Number.isSafeInteger(s1) || s0 <= 0 || s1 <= 0) push('sequence: must be positive integers');
  else if (s1 < s0) push(`sequence: inverted range (${s0} > ${s1})`);
  if (canonicalEpochMs(b.createdAt) == null) push(`createdAt: not an exact epoch-ms (${JSON.stringify(b.createdAt)})`);
  const sum = b.summary && typeof b.summary === 'object' ? b.summary : {};
  if (sum.checkpointId && b.checkpointId && sum.checkpointId !== b.checkpointId) push('summary.checkpointId != bundle.checkpointId');
  // Canonical identity of an EvidenceRef (frozen scalar fields; ts normalized to exact epoch-ms) — used to reject a
  // same-id / different-content clash between the top-level set and a per-agent list (Pulse's semantic adversary 2).
  const evSig = (e) => JSON.stringify([e.id, e.sessionId ?? '', e.sequence ?? null, e.agentId ?? '', e.snippet ?? '', canonicalEpochMs(e.ts)]);
  const evIds = new Set();
  const evById = new Map();
  for (const e of Array.isArray(b.evidence) ? b.evidence : []) {
    if (!e || !e.id) { push('evidence: missing id'); continue; }
    if (evIds.has(e.id)) push(`evidence: duplicate id ${e.id}`);
    evIds.add(e.id);
    evById.set(e.id, evSig(e));
    if (b.sessionId && e.sessionId && e.sessionId !== b.sessionId) push(`evidence ${e.id}: foreign sessionId`);
    if (e.ts != null && e.ts !== '' && canonicalEpochMs(e.ts) == null) push(`evidence ${e.id}: ts not an exact epoch-ms (${JSON.stringify(e.ts)})`);
  }
  // Every claim/briefing link resolves ONLY against the canonical TOP-LEVEL evidence set (that is what the phone's UI
  // resolves). Per-agent evidence must be PRESENT in top-level AND byte-identical to it — a same-id/different-content
  // clash is an ambiguous evidence identity and is rejected even if the bundle is correctly signed.
  for (const a of Array.isArray(sum.perAgent) ? sum.perAgent : []) {
    for (const ae of Array.isArray(a.evidence) ? a.evidence : []) {
      if (!ae || !ae.id) continue;
      if (!evIds.has(ae.id)) push(`agent ${a.agentId}: evidence ${ae.id} not in top-level evidence`);
      else if (evById.get(ae.id) !== evSig(ae)) push(`agent ${a.agentId}: conflicting evidence identity ${ae.id} (per-agent content != top-level)`);
    }
    for (const c of Array.isArray(a.claims) ? a.claims : []) {
      const cited = Array.isArray(c.evidenceIds) ? c.evidenceIds : [];
      if ((c.kind === 'fact' || c.kind === 'inference') && cited.length === 0) push(`claim ${c.id} (${c.kind}): uncited`);
      for (const id of cited) if (!evIds.has(id)) push(`claim ${c.id}: cites foreign evidence ${id}`);
    }
  }
  return { ok: errors.length === 0, errors };
}

/** Throw unless the bundle is semantically valid (fail-closed PRE-SIGN guard used by buildBundle). */
export function assertBundleSemantics(b) {
  const { ok, errors } = validateBundleSemantics(b);
  if (!ok) throw new Error(`bundle semantic validation failed: ${errors.join('; ')}`);
}

/**
 * Full CONSUME-side ingress validation of an UNTRUSTED PocketBundle (warden bundle-KAV bounded-ingress, seq 234672).
 * The numeric bounds MIRROR the FROZEN GroundedInferenceRequest minimums (PocketInference/InferenceTypes.swift): ids
 * checkpoint/session 1...256, evidence id/agent 1...128, snippet 1...8000, positive+non-inverted range, evidence 1..N
 * with each sequence in-range + same session + unique. Reject BEFORE trust: empty required scalars, non-positive/
 * out-of-range sequences, duplicate NESTED ids, non-array collections, oversized strings/arrays — THEN the semantic
 * checks. This is the Node ground-truth reference for the Swift decode-ingress gate. NOT wired into buildBundle
 * (produce bounds by projection, which is ⊆ these). Returns {ok, errors}. (The bundle max-count caps here are the
 * deliberate BUNDLE bounds, distinct from the inference-request 1...32.)
 */
export function validateBundleIngress(bundle) {
  const errors = [];
  const push = (m) => errors.push(m);
  const b = bundle;
  if (!b || typeof b !== 'object') return { ok: false, errors: ['bundle: not an object'] };
  const SNIPPET_MAX = 8000; // frozen ingress max (egress is stricter at 2048)
  // total-work budget (warden #2 DoS guard) — the SINGLE SOURCE OF TRUTH BUNDLE_BUDGET, which the phone pins to exactly
  // (warden parity ask). Both sides use the SAME numbers, and both comfortably exceed the 512KB produce ceiling, so any
  // bundle this gateway signs is accepted by the consumer (egress ⊆ consume) — while a pathological graph fails fast.
  const BUDGET = { elements: BUNDLE_BUDGET.maxTotalElements, bytes: BUNDLE_BUDGET.maxTotalBytes };
  let elems = 0, bytes = 0;
  const reqStr = (v, label, cap) => {
    if (typeof v !== 'string' || v.length === 0) push(`${label}: empty/non-string required field`);
    else if (b8(v) > cap) push(`${label}: exceeds ${cap} bytes`);
  };
  // ids are trimmed + non-blank (the frozen contract trims via .whitespacesAndNewlines then requires non-empty) — warden #3.
  const reqId = (v, label, cap) => {
    reqStr(v, label, cap);
    if (typeof v === 'string' && v.length > 0 && v.trim().length === 0) push(`${label}: blank/whitespace-only id`);
  };
  const arrOf = (v, label) => { if (v == null) return []; if (!Array.isArray(v)) { push(`${label}: must be an array`); return []; } return v; };
  const optStr = (v, label, cap) => { if (v == null) return; if (typeof v !== 'string') push(`${label}: must be a string`); else if (b8(v) > cap) push(`${label}: exceeds ${cap} bytes`); };
  const acct = (v) => { if (typeof v === 'string') bytes += b8(v); elems += 1; };
  reqId(b.checkpointId, 'checkpointId', SUMMARY_CAPS.id);
  reqId(b.sessionId, 'sessionId', SUMMARY_CAPS.id);
  reqId(b.signingKeyId, 'signingKeyId', SUMMARY_CAPS.id); // not in the inference type; bounded defensively
  const s0 = b.sequenceStart, s1 = b.sequenceEnd;
  const rangeOk = Number.isSafeInteger(s0) && Number.isSafeInteger(s1) && s0 > 0 && s1 >= s0;
  if (!rangeOk) push('sequence: range must be positive and non-inverted (start>0, end>=start)');
  const sum = b.summary && typeof b.summary === 'object' ? b.summary : {};
  const topEv = arrOf(b.evidence, 'evidence');
  if (topEv.length < 1) push('evidence: must contain >= 1 entry');
  if (topEv.length > SUMMARY_CAPS.evidence) push(`evidence: exceeds ${SUMMARY_CAPS.evidence}`);
  if (arrOf(sum.perAgent, 'summary.perAgent').length > SUMMARY_CAPS.perAgent) push(`perAgent: exceeds ${SUMMARY_CAPS.perAgent}`);
  if (arrOf(sum.risks, 'summary.risks').length > SUMMARY_CAPS.risks) push(`risks: exceeds ${SUMMARY_CAPS.risks}`);
  if (arrOf(sum.blockers, 'summary.blockers').length > SUMMARY_CAPS.blockers) push(`blockers: exceeds ${SUMMARY_CAPS.blockers}`);
  // completeness (Echo/warden ced1a57 #1): bound the remaining label/prose/signature fields + every risk/blocker string.
  optStr(b.signature, 'signature', 512);
  optStr(sum.headline, 'summary.headline', SUMMARY_CAPS.headline);
  optStr(sum.summaryBaselineSchema, 'summary.summaryBaselineSchema', SUMMARY_CAPS.str);
  optStr(sum.grade, 'summary.grade', SUMMARY_CAPS.str);
  for (const r of arrOf(sum.risks, 'summary.risks')) { optStr(r, 'summary.risks[]', SUMMARY_CAPS.str); acct(r); }
  for (const bl of arrOf(sum.blockers, 'summary.blockers')) { optStr(bl, 'summary.blockers[]', SUMMARY_CAPS.str); acct(bl); }
  // account the top-level + summary SCALAR fields too (conservative superset — so my element count is never LESS than
  // the consumer's, keeping my sign-path budget at-least-as-strict as the phone's => produce ⊆ consume at the boundary).
  for (const v of [b.contractsVersion, b.checkpointId, b.sessionId, b.signingKeyId, b.signature, sum.checkpointId, sum.headline, sum.summaryBaselineSchema, sum.grade]) acct(v);
  // FAIL-FAST pre-pass (Pulse #3): a cheap element estimate from array LENGTHS ONLY (no per-field byte work); reject a
  // grossly over-budget graph BEFORE the deep walk/canonicalization. (Transport bytes are already capped pre-parse in handlers.)
  {
    let est = topEv.length + (Array.isArray(sum.risks) ? sum.risks.length : 0) + (Array.isArray(sum.blockers) ? sum.blockers.length : 0);
    if (Array.isArray(sum.perAgent)) for (const a of sum.perAgent) {
      est += 1 + (Array.isArray(a && a.evidence) ? a.evidence.length : 0);
      if (Array.isArray(a && a.claims)) for (const c of a.claims) est += 1 + (Array.isArray(c && c.evidenceIds) ? c.evidenceIds.length : 0);
      if (est > BUDGET.elements) break;
    }
    if (est > BUDGET.elements) return { ok: false, errors: [`total elements ~${est} exceed budget ${BUDGET.elements} (fail-fast)`] };
  }
  const chkEv = (e, where, ownerAgentId) => {
    reqId(e && e.id, `${where}.id`, SUMMARY_CAPS.evId);
    reqId(e && e.agentId, `${where}.agentId`, SUMMARY_CAPS.evId);
    reqStr(e && e.snippet, `${where}.snippet`, SNIPPET_MAX);
    if (!e || !Number.isSafeInteger(e.sequence) || e.sequence <= 0) push(`${where}.sequence: not a positive integer`);
    else if (rangeOk && (e.sequence < s0 || e.sequence > s1)) push(`${where}.sequence ${e.sequence} outside checkpoint range [${s0},${s1}]`);
    if (e && b.sessionId && e.sessionId !== b.sessionId) push(`${where}: sessionId != bundle sessionId`);
    // nested evidence must belong to its containing agent (warden #3 identity)
    if (e && ownerAgentId != null && e.agentId !== ownerAgentId) push(`${where}: agentId != containing agent ${ownerAgentId}`);
    if (e) { acct(e.id); acct(e.agentId); acct(e.snippet); }
  };
  for (const e of topEv) chkEv(e, `evidence ${e && e.id}`);
  const agentIds = new Set();
  for (const a of arrOf(sum.perAgent, 'summary.perAgent')) {
    reqId(a && a.agentId, 'agent.agentId', SUMMARY_CAPS.evId);
    optStr(a && a.summary, 'agent.summary', SUMMARY_CAPS.summary);
    if (a && a.agentId) { if (agentIds.has(a.agentId)) push(`duplicate agent id ${a.agentId}`); agentIds.add(a.agentId); }
    acct(a && a.agentId); acct(a && a.summary);
    const nestedIds = new Set();
    for (const e of arrOf(a && a.evidence, 'agent.evidence')) {
      chkEv(e, `agent ${a && a.agentId} evidence ${e && e.id}`, a && a.agentId);
      if (e && e.id) { if (nestedIds.has(e.id)) push(`agent ${a.agentId}: duplicate nested evidence id ${e.id}`); nestedIds.add(e.id); }
    }
    const claims = arrOf(a && a.claims, 'agent.claims');
    if (claims.length > SUMMARY_CAPS.evidence) push(`agent ${a && a.agentId}: claims exceeds ${SUMMARY_CAPS.evidence}`);
    const claimIds = new Set();
    for (const c of claims) {
      reqId(c && c.id, 'claim.id', SUMMARY_CAPS.str);
      reqStr(c && c.text, 'claim.text', SUMMARY_CAPS.summary);
      const cites = arrOf(c && c.evidenceIds, 'claim.evidenceIds');
      if (cites.length > SUMMARY_CAPS.evidence) push(`claim ${c && c.id}: evidenceIds exceeds ${SUMMARY_CAPS.evidence}`);
      const citeSet = new Set(); // unique citation ids per claim (warden #3)
      for (const id of cites) { if (citeSet.has(id)) push(`claim ${c && c.id}: duplicate citation id ${id}`); citeSet.add(id); acct(id); }
      if (c && c.id) { if (claimIds.has(c.id)) push(`agent ${a.agentId}: duplicate claim id ${c.id}`); claimIds.add(c.id); }
      acct(c && c.id); acct(c && c.text);
    }
  }
  if (elems > BUDGET.elements) push(`total elements ${elems} exceed budget ${BUDGET.elements}`);
  if (bytes > BUDGET.bytes) push(`total bytes ${bytes} exceed budget ${BUDGET.bytes}`);
  for (const e of validateBundleSemantics(b).errors) push(e); // then the semantic-graph checks (ranges/ids/citations/dates)
  return { ok: errors.length === 0, errors };
}

/**
 * Reference TRUST-ANCHOR verify (mirrors the Swift verifiesSignature P1 fix): verify a bundle ONLY against the PINNED
 * key its signingKeyId selects from `trustStore` (signingKeyId -> RAW base64url Ed25519 pubkey — exactly what the phone
 * pins). A caller-supplied key is NEVER trusted; an empty or unknown signingKeyId is REJECTED (no pinned key => no
 * trust). Reference/test utility (the gateway SIGNS, the phone VERIFIES) that proves the signingKeyId->pinned-key
 * selection on the Node side and documents the exact reject order for the Swift mirror.
 */
export function verifyBundleWithTrustStore(bundle, trustStore) {
  try {
    const kid = bundle && typeof bundle.signingKeyId === 'string' ? bundle.signingKeyId : '';
    if (!kid) return false;                                                    // no key id => cannot select a pinned key
    const rawPub = trustStore && Object.prototype.hasOwnProperty.call(trustStore, kid) ? trustStore[kid] : null;
    if (typeof rawPub !== 'string' || rawPub.length === 0) return false;       // unknown signingKeyId => not a trusted anchor
    const key = createPublicKey({ key: { kty: 'OKP', crv: 'Ed25519', x: rawPub }, format: 'jwk' });
    return verifyBundle(bundle, key);                                          // ed25519 over the PINNED key only
  } catch { return false; }
}

// The Phase-A demo trust anchor, PINNED as an internal FROZEN constant (RAW base64url Ed25519 pubkey), non-caller-
// injectable by design. This is the REAL random Phase-A demo pubkey from warden/bundle-kav-fix @a459b33: the matching
// private key was ephemeral (regenerated once to sign the positive + negative KAV, then discarded) and is NOT committed
// or derivable, so a bundle cannot be forged under this key. verify resolves the pinned key FROM signingKeyId and
// rejects any unknown id BEFORE crypto.
const PHASE_A_DEMO_TRUST = Object.freeze({ 'pocket-demo-phase-a': 'tbiyPLuRcBXqYRHazuik4y5mVG_5B__8vO6ov48GhmE' });

/**
 * Verify a bundle against the INTERNAL, non-injectable Phase-A demo anchor — the production-correct posture and the
 * Node mirror of the Swift PocketTrustAnchor.phaseADemo fix: the pinned key is a fixed constant resolved FROM the
 * bundle's signingKeyId, NEVER a caller-supplied key (this function takes no trust-store parameter, so a caller can
 * neither pin their own key nor self-sign a bypass). Rejects any signingKeyId not in the pinned set. Demo/Phase-A only.
 */
export function verifyBundlePhaseADemo(bundle) {
  return verifyBundleWithTrustStore(bundle, PHASE_A_DEMO_TRUST);
}

/** Convenience: build + sign in one step. */
export function buildSignedBundle(rawCheckpoint, summary, privateKey, opts = {}) {
  return signBundle(buildBundle(rawCheckpoint, summary, opts), privateKey, opts.signingKeyId);
}

/** Dev/test Ed25519 keypair (prod loads the private key from a secret). */
export function generateSigningKeypair() {
  return generateKeyPairSync('ed25519');
}
