// actions.mjs — governed writeback (SAFETY-CRITICAL). Relay lane. Aligned to PocketContracts v0.1.2.
// A dictated intent becomes a typed ActionProposal; deterministic code here owns target resolution,
// authorization, single-use confirmation binding, execution, idempotency, and the receipt.
// NOTHING a model emits drives a write directly. Offline => pendingConnectivity (never shown as "sent").
import { createHash, sign as edSign, verify as edVerify, createPrivateKey, createPublicKey, KeyObject } from 'node:crypto';
import { execFileSync } from 'node:child_process';

/** ~year 9999 in epoch ms — mirrors Swift safeEpochMillis bound so Node never signs a receipt Swift would reject. */
const SANE_MS_BOUND = 253402300800000;

/** A required timestamp is sane iff it is a finite epoch within +/- the year-9999 bound (mirror hasSaneDates). */
export function isSaneDate(t) {
  if (t == null) return false;
  const ms = new Date(t).getTime();
  return Number.isFinite(ms) && ms >= -SANE_MS_BOUND && ms <= SANE_MS_BOUND;
}

/**
 * Normalize ANY signing-key input to a usable Ed25519 PRIVATE KeyObject, or throw.
 * Rejects (Echo bypasses): public KeyObjects (.type==='public'), spoofed plain objects (not a KeyObject),
 * and non-ed25519 keys. createPrivateKey does NOT accept a KeyObject, so branch on the input shape.
 */
export function loadEd25519Private(raw) {
  if (!raw) throw new Error('missing signing key');
  let ko;
  if (raw instanceof KeyObject) {
    ko = raw;
  } else if (typeof raw === 'string' || Buffer.isBuffer(raw) || raw instanceof ArrayBuffer || ArrayBuffer.isView(raw)) {
    ko = createPrivateKey(raw); // key material -> private KeyObject (throws on garbage)
  } else {
    throw new Error('unrecognized signing key input (not key material or a KeyObject)');
  }
  if (ko.type !== 'private') throw new Error('signing key is not a private key');
  if (ko.asymmetricKeyType !== 'ed25519') throw new Error('signing key is not ed25519');
  return ko;
}

/** Sunday scope: the only writes allowed. No destructive/deploy/free-form tool kinds. */
export const ALLOWED_KINDS = new Set(['threadedReply', 'opinionRequest']);

/**
 * canonicalPayload is delimiter (\n)-separated, so any NON-TERMINAL field that could contain the
 * delimiter would let two different proposals produce identical bytes (hash ambiguity — Echo, 5f45364).
 * kind is an enum (safe) and targetSequence is an int (safe); targetSessionId is free-form-ish, so we
 * strict-validate it as a UUID (which cannot contain \n). renderedPreview is LAST, so newlines in it are safe.
 */
export const SESSION_ID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * The EXACT canonical bytes the hash covers — MUST byte-match PocketContracts.swift v0.1.3.
 * INJECTION-PROOF length-prefixed encoding (Echo review): lp(s) = "<utf8ByteCount>:<s>", so a delimiter
 * inside any field cannot shift field boundaries (the byte count is authoritative).
 *   "pocket.actionproposal.v2\n" + lp(kind) + lp(targetSessionId) + lp(String(targetSequence)) + lp(renderedPreview)
 */
export function canonicalPayload(kind, targetSessionId, targetSequence, renderedPreview) {
  const lp = (s) => `${Buffer.byteLength(String(s), 'utf8')}:${s}`;
  return 'pocket.actionproposal.v2\n' + lp(kind) + lp(targetSessionId) + lp(String(targetSequence)) + lp(renderedPreview);
}

/** proposalHash = base64url(SHA-256(UTF-8(canonicalPayload))), '=' stripped — matches Swift computeHash. */
export function computeProposalHash(p) {
  const payload = canonicalPayload(p?.kind, p?.targetSessionId, p?.targetSequence, p?.renderedPreview);
  return createHash('sha256').update(payload, 'utf8').digest('base64')
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/** Content-integrity: the stored proposalHash still matches the live content (invalidate-on-change). */
export function hashMatchesContent(p) {
  return typeof p?.proposalHash === 'string' && p.proposalHash === computeProposalHash(p);
}

/** Deterministic proposal validation. targetSessionId must be a KNOWN session (never trust model free-text). */
export function validateProposal(p, { knownSessionIds } = {}) {
  const problems = [];
  if (!p || typeof p !== 'object') return ['proposal missing'];
  if (!ALLOWED_KINDS.has(p.kind)) problems.push(`kind not allowed: ${p.kind}`);
  if (!p.id) problems.push('no proposal id');
  if (!p.targetSessionId) problems.push('no targetSessionId');
  else if (!SESSION_ID_RE.test(p.targetSessionId)) problems.push('targetSessionId is not a valid session UUID (delimiter/format guard)');
  else if (Array.isArray(knownSessionIds) && !knownSessionIds.includes(p.targetSessionId)) {
    problems.push('targetSessionId is not a known session (possible model free-text / wrong-session)');
  }
  if (!Number.isInteger(p.targetSequence) || p.targetSequence <= 0) problems.push('invalid targetSequence');
  if (typeof p.renderedPreview !== 'string' || p.renderedPreview.length === 0) problems.push('empty renderedPreview');
  if (p.requiresConfirmation !== true) problems.push('requiresConfirmation must be true');
  if (!hashMatchesContent(p)) problems.push('proposalHash does not match content (tampered or malformed)');
  return problems;
}

function receipt(proposal, status, extra = {}) {
  return {
    id: proposal?.id ?? null,
    proposalId: proposal?.id ?? null,
    status,
    resultingSequence: extra.resultingSequence ?? null,
    targetSessionId: proposal?.targetSessionId ?? null,
    confirmedProposalHash: extra.confirmedProposalHash ?? null, // v0.1.2: exactly the hash the human confirmed
    confirmedByHumanAt: extra.confirmedByHumanAt ?? null,
    executedAt: extra.executedAt ?? null,
    failureReason: extra.failureReason ?? null,
    signature: null,     // v0.1.3: set ONLY on a real .posted receipt (signReceipt); pending/failed stay unsigned
    signingKeyId: null,
  };
}

const b64url = (buf) => buf.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const b64urlDecode = (s) => Buffer.from(String(s).replace(/-/g, '+').replace(/_/g, '/'), 'base64');

/**
 * EXACT bytes the gateway signs + the phone verifies — mirrors PocketContracts.swift v0.1.5
 * ActionReceipt.canonicalReceiptPayload() (domain v2) byte-for-byte. Length-prefixed lp(s)="<utf8count>:<s>".
 * v2 binds ALL fields (closes a field-substitution gap): id, proposalId, status, resultingSequence|"",
 * targetSessionId, confirmedProposalHash, confirmedByHumanAtUnix, executedAtUnix|"", failureReason|"", signingKeyId|"".
 * Timestamps are Int(unix seconds) (Swift timeIntervalSince1970), NOT ISO8601.
 */
export function canonicalReceiptPayload(r) {
  const lp = (s) => { const v = s == null ? '' : String(s); return `${Buffer.byteLength(v, 'utf8')}:${v}`; };
  // safeEpochMillis mirror (v0.1.6 v3): epoch MILLISECONDS; absent/non-finite/out-of-range -> "" (non-trapping).
  const ms = (t) => {
    if (!t) return '';
    const m = new Date(t).getTime();
    if (!Number.isFinite(m) || m < -SANE_MS_BOUND || m > SANE_MS_BOUND) return '';
    return String(m);
  };
  return 'pocket.actionreceipt.v3\n'
    + lp(r.id)
    + lp(r.proposalId)
    + lp(r.status)
    + lp(r.resultingSequence == null ? '' : String(r.resultingSequence))
    + lp(r.targetSessionId)
    + lp(r.confirmedProposalHash)
    + lp(ms(r.confirmedByHumanAt))
    + lp(ms(r.executedAt))
    + lp(r.failureReason ?? '')
    + lp(r.signingKeyId ?? '');
}
export function canonicalReceiptBytes(r) { return Buffer.from(canonicalReceiptPayload(r), 'utf8'); }

/** Ed25519-sign a receipt with the gateway key. Only ever called on a real .posted receipt. Sig is base64url. */
export function signReceipt(r, privateKey, signingKeyId) {
  const key = typeof privateKey === 'string' ? createPrivateKey(privateKey) : privateKey;
  const withId = { ...r, signingKeyId: signingKeyId ?? r.signingKeyId ?? null };
  const sig = edSign(null, canonicalReceiptBytes(withId), key);
  return { ...withId, signature: b64url(sig) };
}

/** Verify a receipt's gateway signature. Only a .posted receipt with a real ed25519 sig verifies (SignatureState.verified). */
export function verifyReceipt(r, publicKey) {
  try {
    if (!r || r.status !== 'posted' || typeof r.signature !== 'string' || r.signature.length === 0) return false;
    const key = typeof publicKey === 'string' ? createPublicKey(publicKey) : publicKey;
    return edVerify(null, canonicalReceiptBytes(r), key, b64urlDecode(r.signature));
  } catch {
    return false;
  }
}

/** Best-effort parse of the resulting sequence from `sl session reply` output (JSON preferred). */
export function parseResultingSequence(out) {
  if (out == null) return null;
  try {
    const j = JSON.parse(out);
    const s = j.sequenceId ?? j.sequence ?? j.seq ?? j?.event?.sequenceId;
    if (Number.isFinite(Number(s))) return Number(s);
  } catch { /* not json */ }
  const m = String(out).match(/sequenceId["\s:=]+(\d{3,})/i);
  return m ? Number(m[1]) : null;
}

/**
 * Execute a confirmed governed write. All I/O injectable so the safety logic is unit-tested with no live post.
 * @param proposal      ActionProposal (v0.1.2, carries proposalHash)
 * @param confirmation  { proposalId, confirmedProposalHash, confirmedAt } from the explicit human confirm
 * @param opts          { run, store(Map), online, knownSessionIds, agent, now }
 * @returns ActionReceipt
 */
export function executeAction(proposal, confirmation, opts = {}) {
  const store = opts.store || new Map();
  const now = opts.now || new Date().toISOString();
  const agent = opts.agent || 'claude-pocket-relay';
  const online = opts.online !== false;
  const run = opts.run || ((args) => execFileSync('sl', args, { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 }));

  // Idempotency: only a TERMINAL .posted is single-use. A stored pendingConnectivity MUST allow a later
  // online flush to execute + replace it (single-use pending->posted flush semantics — Echo (C)).
  const prior = proposal ? store.get(proposal.id) : undefined;
  if (prior && prior.status === 'posted') return prior;

  // 1) deterministic validation (kind, known target, sequence, preview, hash-integrity)
  const problems = validateProposal(proposal, { knownSessionIds: opts.knownSessionIds });
  if (problems.length) {
    return receipt(proposal, 'failed', { failureReason: 'invalid proposal: ' + problems.join('; '), confirmedByHumanAt: confirmation?.confirmedAt ?? now });
  }

  // 2) single-use confirmation bound to the EXACT proposal hash (all three must agree: content, stored, confirmed)
  const live = computeProposalHash(proposal);
  const bound = confirmation
    && confirmation.proposalId === proposal.id
    && confirmation.confirmedProposalHash === live
    && proposal.proposalHash === live;
  if (!bound) {
    return receipt(proposal, 'failed', {
      failureReason: 'confirmation missing or hash mismatch (stale/replayed/tampered/wrong-proposal)',
      confirmedByHumanAt: confirmation?.confirmedAt ?? now,
    });
  }

  // 3) offline => honest pending; NEVER "sent". Stored so a later flush is single (idempotent by id).
  if (!online) {
    const r = receipt(proposal, 'pendingConnectivity', { confirmedProposalHash: live, confirmedByHumanAt: confirmation.confirmedAt });
    store.set(proposal.id, r);
    return r;
  }

  // 4) PREFLIGHT signing credentials BEFORE any online side effect (Echo (B)): the key must be a USABLE
  // Ed25519 key and keyId a bounded non-blank string. A malformed/wrong-type key must fail with ZERO posts —
  // never perform the post and then discover the credentials can't sign a valid .posted.
  const keyIdOk = typeof opts.signingKeyId === 'string' && opts.signingKeyId.trim().length > 0 && opts.signingKeyId.length <= 256;
  let signingKeyObj = null;
  try { signingKeyObj = loadEd25519Private(opts.signingKey); } catch { signingKeyObj = null; }
  if (!keyIdOk || !signingKeyObj) {
    return receipt(proposal, 'failed', { failureReason: 'gateway signing credentials missing/invalid: a private Ed25519 key + bounded non-blank keyId are required before writeback', confirmedProposalHash: live, confirmedByHumanAt: confirmation.confirmedAt });
  }
  // date sanity BEFORE posting: the .posted receipt's timestamps must pass Swift hasSaneDates, else the phone
  // would reject a receipt we already posted+signed (Node<->Swift parity, Echo).
  if (!isSaneDate(now) || !isSaneDate(confirmation.confirmedAt)) {
    return receipt(proposal, 'failed', { failureReason: 'non-finite/out-of-range timestamp would fail receipt date-sanity (no post attempted)', confirmedProposalHash: live, confirmedByHumanAt: confirmation.confirmedAt });
  }
  // execute the real Senti post via the existing CLI/MCP (credentials already validated -> a .posted is always signable)
  try {
    const out = run(['session', 'reply', proposal.targetSessionId, String(proposal.targetSequence), proposal.renderedPreview, '--agent', agent, '--json']);
    const resultingSequence = parseResultingSequence(out);
    if (resultingSequence == null) {
      // no verifiable sequence => do NOT claim posted; leave unstored so it can be retried
      return receipt(proposal, 'failed', { failureReason: 'post returned no verifiable resulting sequence', confirmedProposalHash: live, confirmedByHumanAt: confirmation.confirmedAt });
    }
    const r = signReceipt(
      receipt(proposal, 'posted', { resultingSequence, confirmedProposalHash: live, executedAt: now, confirmedByHumanAt: confirmation.confirmedAt }),
      signingKeyObj, opts.signingKeyId,
    );
    store.set(proposal.id, r);
    return r;
  } catch (e) {
    // transient failure: do NOT store (allow retry of the same proposal id later)
    return receipt(proposal, 'failed', { failureReason: String(e?.message ?? e).slice(0, 300), confirmedProposalHash: live, confirmedByHumanAt: confirmation.confirmedAt });
  }
}
