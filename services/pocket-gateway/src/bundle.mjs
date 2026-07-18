// bundle.mjs — build, Ed25519-sign, and verify a PocketBundle (PocketContracts v0.1).
// The phone caches a PocketBundle and MUST verify its signature before briefing from it.
// Signature covers the whole bundle EXCEPT the `signature` field itself (so signingKeyId is bound too).
import { sign as edSign, verify as edVerify, generateKeyPairSync, createPrivateKey, createPublicKey } from 'node:crypto';
import { scrubText } from './scrub.mjs';

export const CONTRACTS_VERSION = '0.1.8';
/** Max UTF-8 bytes for any single phone-visible evidence snippet (bounded egress). */
export const MAX_EVIDENCE_SNIPPET_BYTES = 2048;
/** Max UTF-8 bytes for the entire signed bundle body (defense against a pathological summary). */
export const MAX_BUNDLE_BYTES = 512 * 1024;

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
const boundStr = (v, maxBytes) => { const s = String(v ?? ''); return b8(s) > maxBytes ? Buffer.from(s, 'utf8').subarray(0, maxBytes).toString('utf8') + '…' : s; };
const scrubStr = (v, maxBytes) => boundStr(scrubText(String(v ?? '')).text, maxBytes);

/** Per-field caps for the projected, phone-visible CheckpointSummary (frozen PocketContracts v0.1 schema). */
export const SUMMARY_CAPS = Object.freeze({
  str: 512, headline: 4096, summary: 8192, snippet: MAX_EVIDENCE_SNIPPET_BYTES,
  perAgent: 200, evidence: 256, risks: 100, blockers: 100,
});

/** Project one EvidenceRef to ONLY the frozen scalar fields: unknown keys dropped, types enforced, strings scrubbed+bounded. */
export function projectEvidenceRef(r) {
  if (!r || typeof r !== 'object') return null;
  return {
    id: scrubStr(r.id, SUMMARY_CAPS.str),
    sessionId: scrubStr(r.sessionId, SUMMARY_CAPS.str),
    sequence: Number.isSafeInteger(r.sequence) && r.sequence > 0 ? r.sequence : 0,
    agentId: scrubStr(r.agentId, SUMMARY_CAPS.str),
    snippet: scrubStr(r.snippet, SUMMARY_CAPS.snippet),
    ts: typeof r.ts === 'string' ? boundStr(r.ts, SUMMARY_CAPS.str) : (r.ts instanceof Date ? r.ts.toISOString() : ''),
  };
}

const CLAIM_KINDS = new Set(['fact', 'inference', 'recommendation']);
/** Project one Claim to the frozen schema {id,text,kind,evidenceIds[]}; unknown kind => inference (fail-safe). */
function projectClaim(c) {
  if (!c || typeof c !== 'object') return null;
  return {
    id: scrubStr(c.id, SUMMARY_CAPS.str),
    text: scrubStr(c.text, SUMMARY_CAPS.summary),
    kind: CLAIM_KINDS.has(c.kind) ? c.kind : 'inference',
    evidenceIds: Array.isArray(c.evidenceIds) ? c.evidenceIds.slice(0, SUMMARY_CAPS.evidence).map((x) => scrubStr(x, SUMMARY_CAPS.str)) : [],
  };
}

/** Project one AgentSummary to the frozen schema (agentId, summary, claims[], evidence[]); unknown keys dropped. */
function projectAgentSummary(a) {
  if (!a || typeof a !== 'object') return null;
  const evidence = Array.isArray(a.evidence) ? a.evidence.slice(0, SUMMARY_CAPS.evidence).map(projectEvidenceRef).filter(Boolean) : [];
  const claims = Array.isArray(a.claims) ? a.claims.slice(0, SUMMARY_CAPS.evidence).map(projectClaim).filter(Boolean) : [];
  return { agentId: scrubStr(a.agentId, SUMMARY_CAPS.str), summary: scrubStr(a.summary, SUMMARY_CAPS.summary), claims, evidence };
}

/**
 * STRICT projection of a caller-supplied CheckpointSummary onto the FROZEN PocketContracts v0.1 schema (Echo P0
 * minimal egress): ONLY known keys survive, types are enforced, strings/arrays are recursively bounded + scrubbed.
 * An unexpected key (e.g. summary.rawEvents) can NEVER cross to the phone or be signed.
 */
export function projectSummary(summary) {
  const s = summary && typeof summary === 'object' ? summary : {};
  return {
    checkpointId: scrubStr(s.checkpointId, SUMMARY_CAPS.str),
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
  const bodyBytes = canonicalBundleBytes(bundle).length; // signature stripped; the exact bytes that get signed
  if (bodyBytes > MAX_BUNDLE_BYTES) throw new Error(`bundle exceeds MAX_BUNDLE_BYTES (${bodyBytes} > ${MAX_BUNDLE_BYTES})`);
  return bundle;
}

/** Sign a bundle draft with an Ed25519 private key (KeyObject or PEM). Returns a new signed bundle. */
export function signBundle(draft, privateKey, signingKeyId) {
  const key = typeof privateKey === 'string' ? createPrivateKey(privateKey) : privateKey;
  const toSign = { ...draft, signature: '' };
  if (signingKeyId) toSign.signingKeyId = signingKeyId;
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

/** Convenience: build + sign in one step. */
export function buildSignedBundle(rawCheckpoint, summary, privateKey, opts = {}) {
  return signBundle(buildBundle(rawCheckpoint, summary, opts), privateKey, opts.signingKeyId);
}

/** Dev/test Ed25519 keypair (prod loads the private key from a secret). */
export function generateSigningKeypair() {
  return generateKeyPairSync('ed25519');
}
