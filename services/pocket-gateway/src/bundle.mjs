// bundle.mjs — build, Ed25519-sign, and verify a PocketBundle (PocketContracts v0.1).
// The phone caches a PocketBundle and MUST verify its signature before briefing from it.
// Signature covers the whole bundle EXCEPT the `signature` field itself (so signingKeyId is bound too).
import { sign as edSign, verify as edVerify, generateKeyPairSync, createPrivateKey, createPublicKey } from 'node:crypto';

export const CONTRACTS_VERSION = '0.1.0';

/** Deterministic JSON: recursively sorted object keys, no incidental whitespace. Signer + verifier must agree byte-for-byte. */
export function stableStringify(v) {
  if (v === null || typeof v !== 'object') return JSON.stringify(v);
  if (Array.isArray(v)) return '[' + v.map(stableStringify).join(',') + ']';
  const keys = Object.keys(v).sort();
  return '{' + keys.map((k) => JSON.stringify(k) + ':' + stableStringify(v[k])).join(',') + '}';
}

/** The exact bytes that are signed/verified: the bundle minus its own `signature` field. */
export function canonicalBundleBytes(bundle) {
  const { signature, ...signed } = bundle;
  return Buffer.from(stableStringify(signed), 'utf8');
}

/** Dedup EvidenceRefs by id, ordered by source sequence (bounded, stable UI order). */
export function dedupEvidence(refs) {
  const seen = new Map();
  for (const r of refs || []) if (r && r.id && !seen.has(r.id)) seen.set(r.id, r);
  return [...seen.values()].sort((a, b) => Number(a.sequence) - Number(b.sequence));
}

/** Build an UNSIGNED PocketBundle draft from a RawCheckpoint + CheckpointSummary. `signature` is empty until signed. */
export function buildBundle(rawCheckpoint, summary, opts = {}) {
  const evidence = dedupEvidence((summary.perAgent || []).flatMap((a) => a.evidence || []));
  return {
    contractsVersion: opts.contractsVersion || CONTRACTS_VERSION,
    checkpointId: rawCheckpoint.checkpointId,
    sessionId: rawCheckpoint.sessionId,
    sequenceStart: rawCheckpoint.startSequence,
    sequenceEnd: rawCheckpoint.endSequence,
    summary,
    evidence,
    createdAt: opts.createdAt || new Date().toISOString(),
    signature: '',
    signingKeyId: opts.signingKeyId || 'pocket-gateway-dev-key',
  };
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
