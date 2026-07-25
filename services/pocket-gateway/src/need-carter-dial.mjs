// need-carter-dial.mjs — RELAY's half of ring-the-owner (Carter #314703): map the shared NeedCarterSignal onto
// the /dial wire. This is the JS mirror of the SHIPPED Swift contract
// (packages/PocketContracts/Sources/PocketContracts/NeedCarterSignal.swift @ atlas/reasoning-seam) — ONE typed
// signal, three binders (relay gateway / atlas app / forge device). Both trigger paths produce a NeedCarterSignal:
//   • EXPLICIT — an agent/Claude/ChatGPT calls `sl ring-owner "<q>"` / the MCP tool -> relay dispatches it.
//   • MAGICAL — the NeedCarterDetector reads the chat tail (cheap pattern gate -> LLM confirm) and emits a signal
//     ONLY when Carter is genuinely needed (no false rings). requestedBy = "detector".
//
// This module is PURE mapping (no I/O, no transport): it turns a NeedCarterSignal into the input warden's POST /dial
// pushBackend already speaks ({ humanId, sessionId, message, context, priority }) so the magical/explicit path rings
// through the EXISTING dial substrate with NO change to his route. It parity-mirrors the Swift dialFields() +
// dialPriority + callerName + ringConfidenceFloor EXACTLY (locked by need-carter-dial.test.mjs against the same
// vectors as NeedCarterSignalTests.swift) — the KAV/byte-parity discipline for a cross-language wire.
//
// SECURITY (confused-deputy / who-gets-rung): the ring TARGET humanId is supplied by the CALLER (from the verified
// auth context at dispatch), NEVER taken from the signal. A signal's requestedBy is a DISPLAY field (an agent id),
// not the human to ring — letting the signal choose the target would let any caller ring anyone. mapSignalToPushInput
// REQUIRES humanId and never reads it from the signal.
//
// ANTI-FALSE-RING: a signal rings only if confidence >= RING_CONFIDENCE_FLOOR (parity with Swift clearsRingFloor).
// The explicit path sets confidence 1.0 (a human/agent asked directly); the magical path sets the LLM-confirm
// confidence and a weak "maybe needed" is suppressed here (reason 'below-ring-floor'), never rung.
//
// FAIL-CLOSED: a malformed signal maps to { ring:false, reason:'invalid-signal' } — never a partial/garbage ring.
//
// KNOWN CROSS-LANE SEAMS (flagged to atlas/warden, tracked for ratification — this module is robust to both today):
//   (a) NeedCarterKind rides Swift's SYNTHESIZED enum Codable -> a JS-hostile/version-fragile wire shape
//       {"pickOption":{"_0":[...]}}. parseSignalKind accepts BOTH that shape AND a stable explicit
//       {kind|slug, options} shape, so a future custom-Codable ratification changes NOTHING here but the tests.
//   (b) dial-id source: Swift dialFields() uses signal.id; my buildDialPayload computes computeDialId(...). Today's
//       path dispatches through the existing pushBackend (id = computeDialId); mapSignalToDialFields exposes
//       dialId=signal.id for the FOLLOW-UP that threads signal.id + callerName onto the wire (coordinated w/ warden).
import { DIAL_PRIORITIES, DIAL_LIMITS } from './dial-registry.mjs';

/** A ring fires only when the detected need clears this confidence floor (parity: NeedCarterSignal.ringConfidenceFloor). */
export const RING_CONFIDENCE_FLOOR = 0.6;

/** The 5 signal kinds — the Codable CASE NAMES (the keys Swift's synthesized Codable puts on the wire). */
export const NEED_CARTER_KINDS = Object.freeze(['go', 'decisionYours', 'pickOption', 'info', 'checkpointReady']);

// kebab slugs — parity with Swift NeedCarterKind.slug (for logging + the Stage-1 pattern gate). Distinct from the
// Codable case name (camelCase); NEVER use the kebab form on the wire.
const KEBAB = Object.freeze({ go: 'go', decisionYours: 'decision-yours', pickOption: 'pick-option', info: 'info', checkpointReady: 'checkpoint-ready' });
/** @param {string} slug camelCase case name @returns {string} the kebab logging slug */
export function kebabSlug(slug) { return KEBAB[slug] || 'unknown'; }

/** Parity with Swift NeedCarterKind.dialPriority: decisionYours -> "high"; every other kind -> "medium". */
export function dialPriorityForKind(slug) { return slug === 'decisionYours' ? 'high' : 'medium'; }

// callerName parity with Swift NeedCarterSignal.callerName(kind:requestedBy:). Separator is " · " (MIDDLE DOT),
// byte-exact with the Swift source. A valid signal always carries a non-empty requestedBy; the 'an agent' fallback
// only guards a malformed/empty one (parity vectors always supply it, so it never fires under test).
const SEP = ' · ';
/** @param {string} slug @param {string} requestedBy @returns {string} the ring caller display, byte-parity with Swift */
export function callerNameForKind(slug, requestedBy) {
  const by = typeof requestedBy === 'string' && requestedBy.length > 0 ? requestedBy : 'an agent';
  switch (slug) {
    case 'info':            return `Senti${SEP}update from ${by}`;
    case 'checkpointReady': return `Senti${SEP}checkpoint ready`;
    case 'decisionYours':   return `Senti${SEP}${by} needs your decision`;
    case 'pickOption':      return `Senti${SEP}${by} needs you to choose`;
    case 'go':              return `Senti${SEP}${by} needs a GO`;
    default:                return `Senti${SEP}update from ${by}`;
  }
}

/** pickOption labels: strings only, bounded count + length (defense against an oversized/typed-wrong wire). */
function normalizeOptions(v) {
  return Array.isArray(v) ? v.filter((x) => typeof x === 'string').slice(0, 8).map((x) => x.slice(0, 128)) : [];
}

/**
 * Normalize a wire `kind` into { slug, options }. Accepts (fail-closed, returns null on anything unknown):
 *   • a bare string:                    "go"                              (forward-compat / convenience)
 *   • the stable explicit shape:        { kind|slug: "pickOption", options: [...] }   (seam (a) target)
 *   • Swift's synthesized enum Codable:  { "pickOption": { "_0": [...] } } | { "go": {} }   (today's wire)
 * @returns {{slug:string, options:string[]}|null}
 */
export function parseSignalKind(wireKind) {
  if (typeof wireKind === 'string') {
    return NEED_CARTER_KINDS.includes(wireKind) ? { slug: wireKind, options: [] } : null;
  }
  if (!wireKind || typeof wireKind !== 'object') return null;
  // Stable explicit shape first (a ratified custom Codable would use this).
  const explicit = typeof wireKind.kind === 'string' ? wireKind.kind : (typeof wireKind.slug === 'string' ? wireKind.slug : null);
  if (explicit) {
    return NEED_CARTER_KINDS.includes(explicit) ? { slug: explicit, options: explicit === 'pickOption' ? normalizeOptions(wireKind.options) : [] } : null;
  }
  // Swift synthesized shape: exactly ONE key that is a known case name.
  const keys = Object.keys(wireKind).filter((k) => NEED_CARTER_KINDS.includes(k));
  if (keys.length === 1) {
    const slug = keys[0];
    const payload = wireKind[slug];
    return { slug, options: slug === 'pickOption' ? normalizeOptions(payload && payload._0) : [] };
  }
  return null;
}

/**
 * Inverse of parseSignalKind: emit the wire shape Swift's synthesized Codable DECODES today
 * ({"pickOption":{"_0":[...]}} | {"go":{}}). Used by the magical path (JS produces the signal the Swift app decodes).
 * Tracks seam (a): if NeedCarterKind gets a custom Codable, only this fn + parseSignalKind change.
 * @param {{slug:string, options?:string[]}|string} kind @returns {object|null}
 */
export function encodeSignalKind(kind) {
  const norm = typeof kind === 'string' ? parseSignalKind(kind) : (kind && NEED_CARTER_KINDS.includes(kind.slug) ? { slug: kind.slug, options: normalizeOptions(kind.options) } : null);
  if (!norm) return null;
  return norm.slug === 'pickOption' ? { pickOption: { _0: norm.options } } : { [norm.slug]: {} };
}

/**
 * Validate + normalize an incoming NeedCarterSignal (wire JSON already parsed to a JS object). Fail-closed: any
 * missing/mistyped load-bearing field -> { ok:false, error }. Bounds mirror DIAL_LIMITS so a normalized signal is
 * safe to hand to the dial wire. createdAt is carried OPAQUE (see seam note: Swift's default Date Codable is a
 * 2001-epoch Double, not ISO — the mapper does not interpret it).
 * @returns {{ok:true, value:object}|{ok:false, error:string}}
 */
export function normalizeSignal(signal) {
  const s = signal && typeof signal === 'object' ? signal : {};
  const id = typeof s.id === 'string' ? s.id.trim() : '';
  if (!id) return { ok: false, error: 'signal.id required' };
  const kind = parseSignalKind(s.kind);
  if (!kind) return { ok: false, error: 'signal.kind unrecognized' };
  const question = typeof s.question === 'string' ? s.question : '';
  if (question.trim().length === 0) return { ok: false, error: 'signal.question required' };
  const ctxRaw = s.context && typeof s.context === 'object' ? s.context : {};
  const sessionId = typeof ctxRaw.sessionId === 'string' ? ctxRaw.sessionId.trim() : '';
  if (!sessionId) return { ok: false, error: 'signal.context.sessionId required' };
  const checkpointId = typeof ctxRaw.checkpointId === 'string' && ctxRaw.checkpointId.length > 0 ? ctxRaw.checkpointId : undefined;
  const whatWeNeed = typeof ctxRaw.whatWeNeed === 'string' ? ctxRaw.whatWeNeed : '';
  const confidence = typeof s.confidence === 'number' && Number.isFinite(s.confidence) ? Math.max(0, Math.min(1, s.confidence)) : 0; // fail-closed: no/NaN confidence -> 0 (won't clear the floor)
  const evidenceSeqs = Array.isArray(s.evidenceSeqs) ? s.evidenceSeqs.filter((n) => Number.isInteger(n)).slice(0, 64) : [];
  const requestedBy = typeof s.requestedBy === 'string' && s.requestedBy.length > 0 ? s.requestedBy.slice(0, DIAL_LIMITS.WHO) : '';
  return {
    ok: true,
    value: {
      id,
      kind,
      question: question.slice(0, DIAL_LIMITS.MESSAGE),
      context: { sessionId, checkpointId, whatWeNeed: whatWeNeed.slice(0, DIAL_LIMITS.CONTEXT) },
      confidence,
      evidenceSeqs,
      requestedBy,
      createdAt: s.createdAt, // opaque
    },
  };
}

/** True iff the signal is valid AND clears the ring floor (parity: NeedCarterSignal.clearsRingFloor). Fail-closed: invalid -> false. */
export function signalClearsRingFloor(signal) {
  const n = normalizeSignal(signal);
  return n.ok && n.value.confidence >= RING_CONFIDENCE_FLOOR;
}

/**
 * Map a signal DOWN to forge's DialRequest fields — byte-parity with Swift NeedCarterSignal.dialFields():
 *   { dialId: signal.id, message: question, callerName: <kind-shaped>, priority: kind.dialPriority }
 * This is the richer mapping used by the FOLLOW-UP that threads signal.id + callerName onto the wire (seam (b)).
 * @returns {{ok:true, value:{dialId:string, message:string, callerName:string, priority:string}}|{ok:false, error:string}}
 */
export function mapSignalToDialFields(signal) {
  const n = normalizeSignal(signal);
  if (!n.ok) return n;
  const v = n.value;
  return {
    ok: true,
    value: {
      dialId: v.id,
      message: v.question,
      callerName: callerNameForKind(v.kind.slug, v.requestedBy),
      priority: dialPriorityForKind(v.kind.slug),
    },
  };
}

/**
 * Map a signal to the input warden's POST /dial pushBackend ALREADY speaks
 * ({ humanId, sessionId, message, context, priority }), so the ring dispatches through the EXISTING substrate today.
 *
 * @param {object} signal  a NeedCarterSignal (wire-parsed)
 * @param {{ humanId: string }} auth  the ring TARGET, from the VERIFIED auth context — NEVER from the signal.
 * @returns {{ring:true, input:object, dialFields:object, kind:object, confidence:number, evidenceSeqs:number[]}
 *          |{ring:false, reason:'missing-target-human'|'invalid-signal'|'below-ring-floor', error?:string}}
 */
export function mapSignalToPushInput(signal, { humanId } = {}) {
  // SECURITY: the human whose phone rings is fixed by the caller's verified identity, never the payload.
  if (typeof humanId !== 'string' || humanId.trim().length === 0) return { ring: false, reason: 'missing-target-human' };
  const n = normalizeSignal(signal);
  if (!n.ok) return { ring: false, reason: 'invalid-signal', error: n.error };
  const v = n.value;
  // ANTI-FALSE-RING: below the floor never rings (magical path's weak "maybe needed" is suppressed here).
  if (v.confidence < RING_CONFIDENCE_FLOOR) return { ring: false, reason: 'below-ring-floor' };
  const priority = dialPriorityForKind(v.kind.slug);
  const input = {
    humanId: humanId.trim(),
    sessionId: v.context.sessionId,
    message: v.question,          // spoken on pickup (== dialFields.message)
    context: v.context.whatWeNeed, // the "what we need" lead-in (warden's /dial bounds/scrubs downstream)
    priority: DIAL_PRIORITIES.includes(priority) ? priority : 'medium',
  };
  return {
    ring: true,
    input,
    dialFields: mapSignalToDialFields(signal).value, // for the follow-up who/id passthrough
    kind: v.kind,
    confidence: v.confidence,
    evidenceSeqs: v.evidenceSeqs, // audit + Pocket "jump to evidenceSeqs"
  };
}
