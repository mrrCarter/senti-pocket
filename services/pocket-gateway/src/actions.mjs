// actions.mjs — governed writeback (SAFETY-CRITICAL). Relay lane. Aligned to PocketContracts v0.1.8
// (proposal canonical domain v3, receipt canonical domain v4). Per-field "// vX.Y.Z" tags below are historical
// "added-in" annotations, not the current domain.
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
 * Coerce a date input EXACTLY ONCE and return an IMMUTABLE primitive ISO snapshot, or null if not sane.
 * Defeats TOCTOU (a mutable/coercible object that passes a check then coerces differently later, or a Date
 * mutated during the live post) — callers use the returned string thereafter, never the original object.
 */
export function normalizeSaneDate(t) {
  if (t == null) return null;
  // Accept ONLY well-typed inputs; reject arbitrary coercible objects (a {valueOf} that flips value is exactly
  // the TOCTOU vector). string ISO / number epoch / Date instance only.
  if (typeof t !== 'string' && typeof t !== 'number' && !(t instanceof Date)) return null;
  const ms = t instanceof Date ? t.getTime() : new Date(t).getTime(); // capture once
  if (!Number.isFinite(ms) || ms < -SANE_MS_BOUND || ms > SANE_MS_BOUND) return null;
  return new Date(ms).toISOString(); // frozen primitive snapshot
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
export const ALLOWED_KINDS = new Set(['threadedReply', 'opinionRequest', 'humanMessage']);

/**
 * canonicalPayload is delimiter (\n)-separated, so any NON-TERMINAL field that could contain the
 * delimiter would let two different proposals produce identical bytes (hash ambiguity — Echo, 5f45364).
 * kind is an enum (safe) and targetSequence is an int (safe); targetSessionId is free-form-ish, so we
 * strict-validate it as a UUID (which cannot contain \n). renderedPreview is LAST, so newlines in it are safe.
 */
export const SESSION_ID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** safeEpochMillis mirror: finite epoch ms within +/- year-9999 bound, else "" (never traps). Shared by proposal + receipt. */
export function epochMs(t) {
  if (t == null) return '';
  const m = new Date(t).getTime();
  if (!Number.isFinite(m) || m < -SANE_MS_BOUND || m > SANE_MS_BOUND) return '';
  return String(m);
}

/**
 * The EXACT canonical bytes the proposal hash covers — MUST byte-match PocketContracts.swift v0.1.8 (domain v3).
 * INJECTION-PROOF length-prefixed lp(s)="<utf8ByteCount>:<s>". v3 binds id + createdAt(ms) + sourceQuestionId so
 * two same-CONTENT proposals with different ids/times get DISTINCT hashes (kills the confirm-swap).
 *   "pocket.actionproposal.v3\n" + lp(id)+lp(kind)+lp(targetSessionId)+lp(String(targetSequence))
 *   + lp(renderedPreview) + lp(createdAtMs) + lp(sourceQuestionId ?? "")
 */
export function canonicalPayload(p) {
  const lp = (s) => `${Buffer.byteLength(String(s), 'utf8')}:${s}`;
  const src = p.sourceQuestionId != null ? '1' + lp(p.sourceQuestionId) : '0'; // presence flag: nil != some("") (Pulse #231475)
  return 'pocket.actionproposal.v3\n'
    + lp(p.id) + lp(p.kind) + lp(p.targetSessionId) + lp(String(p.targetSequence))
    + lp(p.renderedPreview) + lp(epochMs(p.createdAt)) + src;
}

/** proposalHash = base64url(SHA-256(UTF-8(canonicalPayload))), '=' stripped — matches Swift computeHash. */
export function computeProposalHash(p) {
  return createHash('sha256').update(canonicalPayload(p), 'utf8').digest('base64')
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
  if (typeof p.id === 'string' && p.id.length > 128) problems.push('id exceeds 128 bytes');
  if (!p.targetSessionId) problems.push('no targetSessionId');
  else if (!SESSION_ID_RE.test(p.targetSessionId)) problems.push('targetSessionId is not a valid session UUID (delimiter/format guard)');
  else if (!Array.isArray(knownSessionIds) || knownSessionIds.length === 0) {
    problems.push('no known-session allowlist provided (fail-closed: refuse rather than trust any UUID)');
  } else if (!knownSessionIds.includes(p.targetSessionId)) {
    problems.push('targetSessionId is not a known session (possible model free-text / wrong-session)');
  }
  // humanMessage is TOP-LEVEL (no thread target): targetSequence is the sentinel 0, ENFORCED ==0 (not merely
  // skipped) so Node and Swift can never disagree on a producer bug — a seq!=0 humanMessage is rejected on BOTH
  // sides (Atlas mirror @9842cef: Swift isValidForConfirmation = kind==.humanMessage ? seq==0 : seq>0). Every other
  // kind keeps the >0 thread-target requirement. canonicalPayload is unchanged: lp(String(0))="1:0" byte-exact.
  if (p.kind === 'humanMessage') {
    if (p.targetSequence !== 0) problems.push('humanMessage targetSequence must be 0 (top-level sentinel)');
  } else if (!Number.isSafeInteger(p.targetSequence) || p.targetSequence <= 0) {
    problems.push('invalid targetSequence');
  }
  if (typeof p.renderedPreview !== 'string' || p.renderedPreview.length === 0) problems.push('empty renderedPreview');
  else if (Buffer.byteLength(p.renderedPreview, 'utf8') > 4096) problems.push('renderedPreview exceeds 4096 bytes');
  if (p.requiresConfirmation !== true) problems.push('requiresConfirmation must be true');
  const cms = typeof p.createdAt === 'number' ? p.createdAt : new Date(p.createdAt).getTime();
  if (!Number.isFinite(cms) || cms < -SANE_MS_BOUND || cms > SANE_MS_BOUND) problems.push('createdAt non-finite/out-of-range');
  if (!hashMatchesContent(p)) problems.push('proposalHash does not match content (tampered or malformed)');
  return problems;
}

function receipt(proposal, status, extra = {}) {
  return {
    id: proposal?.id ?? null,
    proposalId: proposal?.id ?? null,
    status,
    result: extra.result ?? null, // v0.1.8 ActionResultRef | null; set ONLY on .posted
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
 * EXACT bytes the gateway signs + the phone verifies — mirrors PocketContracts.swift v0.1.8
 * ActionReceipt.canonicalReceiptPayload() (domain v4) byte-for-byte. Length-prefixed lp(s)="<utf8count>:<s>".
 * v4 binds ALL fields (closes a field-substitution gap): id, proposalId, status, result (ActionResultRef
 * canonical token or "" — v4 replaces v2's resultingSequence), targetSessionId, confirmedProposalHash,
 * confirmedByHumanAtUnix, executedAtUnix|"", failureReason|"", signingKeyId|"".
 * Timestamps are CHECKED epoch-MILLISECONDS (epochMs here / Swift ActionReceipt.safeEpochMillis — never traps on
 * an extreme decoded date), NOT unix seconds and NOT ISO8601.
 */
/**
 * ActionResultRef canonical token — MUST byte-match PocketContracts.swift v0.1.8 ActionResultRef.canonicalToken().
 * action: lp("action")+lp(actionId)+lp(String(targetSequenceId))+cursor  (cursor = "1"+lp(c) if present else "0")
 * sequence: lp("sequence")+lp(String(sequenceId))
 * JS shape: {kind:'action',actionId,targetSequenceId,targetCursor?} | {kind:'sequence',sequenceId}
 */
export function actionResultCanonicalToken(ref) {
  const lp = (s) => `${Buffer.byteLength(String(s), 'utf8')}:${s}`;
  if (ref && ref.kind === 'action') {
    const cursor = ref.targetCursor != null ? '1' + lp(ref.targetCursor) : '0';
    return lp('action') + lp(ref.actionId) + lp(String(ref.targetSequenceId)) + cursor;
  }
  if (ref && ref.kind === 'sequence') {
    return lp('sequence') + lp(String(ref.sequenceId));
  }
  throw new Error('unknown ActionResultRef kind: ' + (ref && ref.kind));
}

export function canonicalReceiptPayload(r) {
  const lp = (s) => { const v = s == null ? '' : String(s); return `${Buffer.byteLength(v, 'utf8')}:${v}`; };
  return 'pocket.actionreceipt.v4\n'
    + lp(r.id)
    + lp(r.proposalId)
    + lp(r.status)
    + lp(r.result ? actionResultCanonicalToken(r.result) : '') // v4: ActionResultRef token replaces resultingSequence
    + lp(r.targetSessionId)
    + lp(r.confirmedProposalHash)
    + lp(epochMs(r.confirmedByHumanAt))
    + lp(epochMs(r.executedAt))
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

/** Positive safe integer, or a canonical ^[1-9][0-9]*$ string whose value is safe; else null. */
export function toSafeSequence(v) {
  if (typeof v === 'number') return Number.isSafeInteger(v) && v > 0 ? v : null;
  if (typeof v === 'string' && /^[1-9][0-9]*$/.test(v)) {
    const n = Number(v);
    return Number.isSafeInteger(n) && n > 0 ? n : null;
  }
  return null;
}

/**
 * Parse the STRUCTURED action result of a `sl session reply --json` post. A reply is a message-action
 * (UUID-identified), NOT a numeric sequence — the immediate output carries action.{id,targetSequenceId,targetCursor}.
 * Returns {actionId, targetSequenceId, targetCursor} or null (never text/regex scavenging).
 */
export function parseActionResult(out) {
  if (out == null) return null;
  let j;
  try { j = JSON.parse(out); } catch { return null; }
  const a = j && j.action;
  if (!a || typeof a.id !== 'string' || a.id.length === 0) return null;
  const tseq = toSafeSequence(a.targetSequenceId);
  if (tseq == null) return null;
  const cursor = (typeof a.targetCursor === 'string' && a.targetCursor.length > 0) ? a.targetCursor : null;
  return { actionId: a.id, targetSequenceId: tseq, targetCursor: cursor };
}

/**
 * Parse the STRUCTURED result of a `/human-message` post (humanMessage kind). The server records a top-level
 * `session_message` EVENT authored as human-<user>; the response is `{message:{id,cursor,senderId}, event:{sequenceId,agent}}`.
 * Returns {messageId, sequenceId, targetCursor, senderId} or null. messageId is the deterministic client-set id (=proposalHash),
 * sequenceId is the durable per-session sequence the message landed at (drives the ActionResultRef kind:'sequence').
 */
export function parseHumanMessageResult(out) {
  if (out == null) return null;
  let j;
  try { j = JSON.parse(out); } catch { return null; }
  const m = j && j.message;
  const ev = j && j.event;
  if (!m || typeof m.id !== 'string' || m.id.length === 0) return null;
  const seq = toSafeSequence(ev && ev.sequenceId);
  if (seq == null) return null; // no durable sequence => unidentifiable landing; never finalize on it
  const cursor = (typeof m.cursor === 'string' && m.cursor.length > 0) ? m.cursor : null;
  // message.senderId is PRIMARY — api L7416 sets it = normalize(agent.id) OR sender_id, so it's GUARANTEED populated;
  // event.agent.id is CORROBORATION (depends on the agent blob surviving storage). Fail-closed downstream if BOTH absent.
  const senderId = (typeof m.senderId === 'string' && m.senderId ? m.senderId : null)
    || (ev && ev.agent && typeof ev.agent.id === 'string' && ev.agent.id ? ev.agent.id : null);
  return { messageId: m.id, sequenceId: seq, targetCursor: cursor, senderId };
}

/**
 * Bounded read-back VERIFY that the reply action actually landed in the room: find the event
 * eventId=session-action-<actionId>, authored by us, threading under the exact target. Returns bool.
 * Never claim .posted on an unverifiable/mismatched action.
 */
export function verifyActionLanded(sessionId, parsed, { run, agent = 'claude-pocket-relay', attempts = 3 } = {}) {
  if (!run || !parsed) return false;
  const wantEventId = 'session-action-' + parsed.actionId;
  for (let i = 0; i < attempts; i++) {
    try { run(['session', 'sync', sessionId]); } catch { /* best-effort */ }
    let j;
    try { j = JSON.parse(run(['session', 'read', sessionId, '--remote', '--tail', '25', '--agent', agent, '--json'])); } catch { continue; }
    const hit = (j.events || []).find((e) => e && e.eventId === wantEventId); // EXACT action identity (no substring)
    if (hit) {
      const who = (hit.agent && hit.agent.id) || hit.agentId;
      const tseq = hit.payload && hit.payload.targetSequenceId;
      return who === agent && Number(tseq) === parsed.targetSequenceId;
    }
  }
  return false;
}

/**
 * Bounded read-back VERIFY that a humanMessage actually landed, authored by the HUMAN identity (human-mrrcarter).
 * A humanMessage is a top-level `session_message` event with eventId===messageId (the deterministic client id) — NOT a
 * `session-action-…`. Matching who===humanId closes Atlas's silent-false-fail #1: the read-back filters the SAME
 * identity the write authored under, so a landed human write is always found (never a false "unverified"). Returns bool.
 */
export function verifyHumanMessageLanded(sessionId, parsed, { run, attempts = 3 } = {}) {
  if (!run || !parsed || typeof parsed.messageId !== 'string') return false;
  // Match the re-read author against the identity the api ACTUALLY authored under — `parsed.senderId`, taken from the
  // POST response's message.senderId (primary) / event.agent.id (corroboration), the api's OWN truth — NOT a
  // predicted/replicated normalization of the caller. The
  // api authors human writes as human-<normalize(github_username||id)> and that rule can change; reading it back from the
  // POST response is drift-proof (a future normalization change can't silently break this). Fail-closed if the POST
  // reported no author (can't confirm identity).
  const author = (typeof parsed.senderId === 'string' && parsed.senderId) ? parsed.senderId : null;
  if (!author) return false;
  for (let i = 0; i < attempts; i++) {
    try { run(['session', 'sync', sessionId]); } catch { /* best-effort */ }
    let j;
    try { j = JSON.parse(run(['session', 'read', sessionId, '--remote', '--tail', '25', '--agent', author, '--json'])); } catch { continue; }
    const hit = (j.events || []).find((e) => e && e.eventId === parsed.messageId); // EXACT message identity
    if (hit) {
      const who = (hit.agent && hit.agent.id) || hit.agentId;
      return who === author; // re-read author == the POST-reported author (the api's truth on both hops)
    }
  }
  return false;
}

/**
 * Crash-recovery read-back: after a durable "in-flight" reservation whose emitted actionId was LOST to a crash
 * (post landed but the emitted marker was never persisted), find OUR already-landed action by the DETERMINISTIC
 * PROPOSAL IDENTITY — the idempotency key our post set (= computeProposalHash, which v3 binds to id+content+time),
 * authored by us under the exact target sequence. Matching the idempotency key (not the message body) means an
 * older, identical-CONTENT action carries a DIFFERENT key and can never be mis-finalized as this proposal (Echo P1).
 * Returns {actionId, targetSequenceId, targetCursor} or null.
 */
export function findLandedByProposal(sessionId, { proposal, run, agent = 'claude-pocket-relay', attempts = 2 } = {}) {
  if (!run || !proposal) return null;
  const wantSeq = proposal.targetSequence;
  const wantKey = computeProposalHash(proposal); // deterministic proposal identity — NOT the body
  for (let i = 0; i < attempts; i++) {
    try { run(['session', 'sync', sessionId]); } catch { /* best-effort */ }
    let j;
    try { j = JSON.parse(run(['session', 'read', sessionId, '--remote', '--tail', '50', '--agent', agent, '--json'])); } catch { continue; }
    for (const e of (j.events || [])) {
      if (!e || typeof e.eventId !== 'string' || !e.eventId.startsWith('session-action-')) continue;
      const who = (e.agent && e.agent.id) || e.agentId;
      const p = e.payload || {};
      const tok = e.idempotencyToken ?? p.idempotencyToken ?? p.idempotencyKey;
      if (who === agent && Number(p.targetSequenceId) === wantSeq && typeof tok === 'string' && tok === wantKey) {
        return { actionId: e.eventId.slice('session-action-'.length), targetSequenceId: Number(p.targetSequenceId), targetCursor: (typeof p.targetCursor === 'string' ? p.targetCursor : null) };
      }
    }
  }
  return null;
}

/**
 * Freeze a primitive snapshot of every authority-bearing proposal field in a SINGLE read each (a getter/Proxy
 * fires exactly once here). The value hashed+confirmed+posted MUST be identical, so nothing downstream re-reads
 * proposal.* (first-post content TOCTOU, Echo). createdAt is captured as an epoch-ms number.
 */
export function snapshotProposal(p) {
  if (!p || typeof p !== 'object') return null;
  const id = p.id, kind = p.kind, targetSessionId = p.targetSessionId, targetSequence = p.targetSequence,
    renderedPreview = p.renderedPreview, requiresConfirmation = p.requiresConfirmation,
    createdAt = p.createdAt, sourceQuestionId = p.sourceQuestionId, proposalHash = p.proposalHash;
  return Object.freeze({
    id: typeof id === 'string' ? id : null,
    kind: typeof kind === 'string' ? kind : null,
    targetSessionId: typeof targetSessionId === 'string' ? targetSessionId : null,
    targetSequence: typeof targetSequence === 'number' ? targetSequence : NaN,
    renderedPreview: typeof renderedPreview === 'string' ? renderedPreview : null,
    requiresConfirmation: requiresConfirmation === true,
    createdAt: new Date(createdAt).getTime(), // epoch-ms number (NaN if bad) — one coercion, frozen
    sourceQuestionId: sourceQuestionId == null ? null : (typeof sourceQuestionId === 'string' ? sourceQuestionId : null),
    proposalHash: typeof proposalHash === 'string' ? proposalHash : null,
  });
}

/** Structural bounds on an ActionResultRef before it can be signed into a .posted receipt. */
export function validateActionResultRef(ref) {
  if (!ref || typeof ref !== 'object') return false;
  if (ref.kind === 'action') {
    return typeof ref.actionId === 'string' && ref.actionId.length > 0 && ref.actionId.length <= 256
      && toSafeSequence(ref.targetSequenceId) != null
      && (ref.targetCursor == null || (typeof ref.targetCursor === 'string' && ref.targetCursor.length <= 256));
  }
  if (ref.kind === 'sequence') return toSafeSequence(ref.sequenceId) != null;
  return false;
}

/**
 * Execute a confirmed governed write. All I/O injectable so the safety logic is unit-tested with no live post.
 * @param proposal      ActionProposal (v0.1.2, carries proposalHash)
 * @param confirmation  { proposalId, confirmedProposalHash, confirmedAt } from the explicit human confirm
 * @param opts          { run, store(Map), online, knownSessionIds, agent, now }
 * @returns ActionReceipt
 */
export async function executeAction(proposal, confirmation, opts = {}) {
  // NOTE: the default Map is single-instance. Production (multi-Lambda) MUST inject a distributed atomic store
  // (e.g. DynamoDB conditional-put keyed by proposal.id) so idempotency + single-consume hold across instances.
  const store = opts.store || new Map();
  const now = opts.now || new Date().toISOString();
  const agent = opts.agent || 'claude-pocket-relay';
  const online = opts.online !== false;
  const run = opts.run || ((args) => execFileSync('sl', args, { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 }));

  // FROZEN snapshot: read every authority-bearing proposal field EXACTLY once; hash/bind/post ONLY from it, so a
  // getter/Proxy/mutation cannot make the posted content differ from the confirmed content (first-post TOCTOU, Echo).
  const snap = snapshotProposal(proposal);
  if (!snap) return receipt(null, 'failed', { failureReason: 'proposal missing', confirmedByHumanAt: confirmation?.confirmedAt ?? now });

  // Authoring mode (keyed off the FROZEN snapshot, never the mutable proposal): a `humanMessage` is a TOP-LEVEL human
  // write (human-mrrcarter via /human-message, the user's Bearer token authorizes the identity — no gateway confused
  // deputy); every other kind is an agent threaded reply via the CLI. The read-back filters the SAME identity the write
  // authored under (closes Atlas silent-false-fail #1). Every governed-write invariant below is IDENTICAL for both modes.
  const isHuman = snap.kind === 'humanMessage';
  const readbackId = isHuman ? (opts.humanId || 'human-mrrcarter') : agent;

  // Idempotency: only a TERMINAL .posted is single-use; a stored pending must allow a later online flush.
  const prior = snap.id ? store.get(snap.id) : undefined;
  if (prior && prior.status === 'posted') return prior;
  // A post for this id that ALREADY executed leaves an EMITTED marker (reserved before the external write). It must
  // NEVER be re-posted, even if last time's read-back could not confirm landing — a retry re-verifies only (Echo P0 atomicity).
  const priorEmitted = (prior && prior.__emitted) ? prior.__emitted : null;

  // 1) strict validation of the SNAPSHOT (kind, known target, safe seq, preview bounds, sane createdAt, hash-integrity)
  const problems = validateProposal(snap, { knownSessionIds: opts.knownSessionIds });
  if (problems.length) {
    return receipt(snap, 'failed', { failureReason: 'invalid proposal: ' + problems.join('; '), confirmedByHumanAt: confirmation?.confirmedAt ?? now });
  }

  // 2) confirmation bound to the EXACT snapshot hash (content hashed == content posted == content confirmed)
  const live = computeProposalHash(snap);
  const bound = confirmation
    && confirmation.proposalId === snap.id
    && confirmation.confirmedProposalHash === live
    && snap.proposalHash === live;
  if (!bound) {
    return receipt(snap, 'failed', {
      failureReason: 'confirmation missing or hash mismatch (stale/replayed/tampered/wrong-proposal)',
      confirmedByHumanAt: confirmation?.confirmedAt ?? now,
    });
  }

  // Normalize confirmedAt to an IMMUTABLE snapshot BEFORE any receipt is built/stored (TOCTOU + Swift
  // date-sanity): a pending OR posted receipt with a non-sane confirmedByHumanAt is structurally invalid.
  const confirmedAtSnap = normalizeSaneDate(confirmation.confirmedAt);
  if (!confirmedAtSnap) {
    return receipt(snap, 'failed', { failureReason: 'confirmedAt missing/non-finite/out-of-range (no receipt stored)', confirmedProposalHash: live });
  }

  // 3) offline => honest pending; NEVER "sent". Stored so a later flush is single (idempotent by id).
  // Skipped once a post was already emitted for this id: going offline can't un-happen a landed write, and a
  // pending receipt must not clobber the emitted marker (that would re-enable a re-post on the next online retry).
  if (!online && !priorEmitted) {
    const r = receipt(snap, 'pendingConnectivity', { confirmedProposalHash: live, confirmedByHumanAt: confirmedAtSnap });
    store.set(snap.id, r);
    return r;
  }

  // 4) PREFLIGHT signing credentials BEFORE any online side effect (Echo (B)): the key must be a USABLE
  // Ed25519 key and keyId a bounded non-blank string. A malformed/wrong-type key must fail with ZERO posts —
  // never perform the post and then discover the credentials can't sign a valid .posted.
  const keyIdOk = typeof opts.signingKeyId === 'string' && opts.signingKeyId.trim().length > 0 && opts.signingKeyId.length <= 256;
  let signingKeyObj = null;
  try { signingKeyObj = loadEd25519Private(opts.signingKey); } catch { signingKeyObj = null; }
  if (!keyIdOk || !signingKeyObj) {
    return receipt(snap, 'failed', { failureReason: 'gateway signing credentials missing/invalid: a private Ed25519 key + bounded non-blank keyId are required before writeback', confirmedProposalHash: live, confirmedByHumanAt: confirmedAtSnap });
  }
  // date sanity BEFORE posting: normalize `now` to an IMMUTABLE snapshot (confirmedAt already snapped). If the
  // server timestamp isn't sane we do NOT post — Node must never post+sign a receipt Swift hasSaneDates rejects.
  const nowSnap = normalizeSaneDate(now);
  if (!nowSnap) {
    return receipt(snap, 'failed', { failureReason: 'server timestamp non-finite/out-of-range (no post attempted)', confirmedProposalHash: live, confirmedByHumanAt: confirmedAtSnap });
  }

  // Shared verify + finalize helpers (credentials are now known-valid). finalizePosted signs from the FROZEN snapshot,
  // never the caller's mutable `proposal`: a hostile getter that flips AFTER snapshot would otherwise sign a receipt
  // whose identity diverges from what was validated/confirmed/posted (hostile-getter TOCTOU on the signed artifact, Echo P1).
  const doVerify = (parsed) => opts.verifyReadback
    ? opts.verifyReadback(snap.targetSessionId, parsed, { run, agent: readbackId })
    : (isHuman
        ? verifyHumanMessageLanded(snap.targetSessionId, parsed, { run, humanId: readbackId })
        : verifyActionLanded(snap.targetSessionId, parsed, { run, agent: readbackId }));
  const finalizePosted = (parsed, executedAtSnap) => {
    const result = isHuman
      ? { kind: 'sequence', sequenceId: parsed.sequenceId }
      : { kind: 'action', actionId: parsed.actionId, targetSequenceId: parsed.targetSequenceId, targetCursor: parsed.targetCursor };
    if (!validateActionResultRef(result)) {
      return receipt(snap, 'failed', { failureReason: 'malformed action result ref (structural bounds)', confirmedProposalHash: live, confirmedByHumanAt: confirmedAtSnap });
    }
    const r = signReceipt(
      receipt(snap, 'posted', { result, confirmedProposalHash: live, executedAt: executedAtSnap, confirmedByHumanAt: confirmedAtSnap }),
      signingKeyObj, opts.signingKeyId,
    );
    store.set(snap.id, r);
    return r;
  };

  // EMITTED-RETRY (exactly-once, Echo P0 atomicity): a governed post for this id ALREADY executed (reserved before
  // the external write). NEVER re-post — only re-verify. Closes the dup-post window where a read-back miss or a
  // reentrant call would otherwise re-run run(reply). Freshness is intentionally skipped: the write already happened.
  if (priorEmitted) {
    if (priorEmitted.parsed && doVerify(priorEmitted.parsed)) return finalizePosted(priorEmitted.parsed, priorEmitted.executedAt);
    return store.get(snap.id) || receipt(snap, 'failed', { failureReason: 'prior post emitted; not re-posted (read-back unverified or unidentifiable)', confirmedProposalHash: live, confirmedByHumanAt: confirmedAtSnap });
  }

  // server-time FRESHNESS (Echo P0): the gateway clock is authority; client confirmedAt is telemetry. Reject a
  // confirmation older than freshnessSeconds or beyond a small forward skew. FINITE-GUARD the bounds — a caller-supplied
  // NaN/negative/garbage window would otherwise make BOTH comparisons false and let a years-old/future confirm post.
  const nowMs = new Date(nowSnap).getTime();
  const confMs = new Date(confirmedAtSnap).getTime();
  const fSec = Number.isFinite(opts.freshnessSeconds) && opts.freshnessSeconds >= 0 ? opts.freshnessSeconds : 300;
  const sSec = Number.isFinite(opts.clockSkewSeconds) && opts.clockSkewSeconds >= 0 ? opts.clockSkewSeconds : 60;
  const maxAgeMs = fSec * 1000;
  const skewMs = sSec * 1000;
  if (!Number.isFinite(confMs) || !Number.isFinite(nowMs) || confMs < nowMs - maxAgeMs || confMs > nowMs + skewMs) {
    return receipt(snap, 'failed', { failureReason: 'confirmation outside server-time freshness window (stale or future)', confirmedProposalHash: live, confirmedByHumanAt: confirmedAtSnap });
  }

  // RESERVE the id BEFORE the external post (Echo P0 atomicity): the protocol was get -> run(reply) -> set, so a
  // concurrent/reentrant call — or a post-then-read-back-miss retry — could re-run run(reply) and double-post. Persist
  // a reservation now; any re-entry takes the EMITTED-RETRY path above and re-verifies instead of re-posting.
  // PROD store MUST make this a conditional put-if-absent (DynamoDB) with a short TTL (self-heal a crash-before-post)
  // for true cross-Lambda atomicity — the default single-instance Map is documented at the top of executeAction.
  const reserve = (parsed) => store.set(snap.id, {
    ...receipt(snap, 'failed', {
      failureReason: parsed ? 'post emitted; awaiting read-back verification' : 'post in progress (reserved before external write)',
      confirmedProposalHash: live, confirmedByHumanAt: confirmedAtSnap,
    }),
    __emitted: { parsed: parsed || null, executedAt: nowSnap },
  });
  reserve(null);

  // execute the real Senti post (credentials + dates validated -> a .posted is always signable + Swift-sane).
  // Only immutable snapshots (nowSnap/confirmedAtSnap) flow into the receipt — never the caller's mutable inputs.
  try {
    // --idempotency-key = the proposal hash (deterministic, unique per proposal): gives server-side dedup AND lets a
    // crash-recovery read-back bind to THIS exact proposal, not merely matching content (Echo P1).
    let parsed;
    if (isHuman) {
      // humanMessage: TOP-LEVEL human write via the api /human-message (server authors as human-mrrcarter). clientId =
      // the deterministic proposal hash so server-side idempotency AND the read-back bind to THIS exact proposal. The
      // user's Bearer token authorizes the human identity — the gateway's own agent creds are NOT used (no confused deputy).
      const out = await opts.postHumanMessage(snap.targetSessionId, snap.renderedPreview, { clientId: live, token: opts.userToken });
      parsed = parseHumanMessageResult(out); // {messageId, sequenceId, senderId} — top-level, no thread target
      if (!parsed) {
        // Unidentifiable landing (no durable sequence): it MAY have landed, so keep a block-re-post marker.
        const r = { ...receipt(snap, 'failed', { failureReason: 'human-message post returned no structured result (no durable sequence)', confirmedProposalHash: live, confirmedByHumanAt: confirmedAtSnap }), __emitted: { parsed: null, executedAt: nowSnap } };
        store.set(snap.id, r);
        return r;
      }
    } else {
      const out = run(['session', 'reply', snap.targetSessionId, String(snap.targetSequence), snap.renderedPreview, '--agent', agent, '--idempotency-key', live, '--json']);
      parsed = parseActionResult(out); // {actionId, targetSequenceId, targetCursor} — a reply is a UUID action, not a numeric seq
      if (!parsed || parsed.targetSequenceId !== snap.targetSequence) {
        // The post returned but is unidentifiable, or landed under the WRONG sequence: it may have landed, so KEEP a
        // block-re-post marker (parsed:null => never re-posted, never finalized) while reporting the SPECIFIC reason.
        const why = !parsed ? 'post returned no structured action result' : 'posted action threads under a different target sequence than the proposal';
        const r = { ...receipt(snap, 'failed', { failureReason: why, confirmedProposalHash: live, confirmedByHumanAt: confirmedAtSnap }), __emitted: { parsed: null, executedAt: nowSnap } };
        store.set(snap.id, r);
        return r;
      }
    }
    // upgrade the reservation to carry the actionId so a retry can re-verify + finalize (still never re-posts).
    reserve(parsed);
    // bounded read-back VERIFY the action actually landed (authored by us, under the target). Injectable for tests.
    if (!doVerify(parsed)) return store.get(snap.id); // marker persists; a retry re-verifies, never re-posts
    return finalizePosted(parsed, nowSnap);
  } catch (e) {
    // The external post THREW: the outcome is AMBIGUOUS — the reply may have committed remotely before the error.
    // Do NOT decide it here. Clear only our per-request reserve and return `ambiguous:true`; the caller PRESERVES the
    // durable in-flight/unknown state so a retry RECONCILES (read-back) instead of blindly re-posting (Echo P0).
    store.delete(snap.id);
    const r = receipt(snap, 'failed', { failureReason: 'ambiguous send outcome (post may have committed): ' + String(e?.message ?? e).slice(0, 200), confirmedProposalHash: live, confirmedByHumanAt: confirmedAtSnap });
    r.ambiguous = true;
    return r;
  }
}
