// dial-registry.mjs — the "Pocket rings Carter" DEVICE REGISTRY + deterministic dispatch PAYLOAD wire. Relay lane.
//
// DIAL-ME split (agreed with warden, room 6cf7e861): warden owns POST /dial (dispatch via deps.pushBackend) + the
// VOICE-GO consent bar; RELAY owns the device-token BINDING that his pushBackend resolves against, and the payload the
// phone decodes. This module is that half:
//   - POST /dial/register: the phone registers its VoIP token for a session it belongs to (onVoipToken(hex) seam,
//     forge PR #40). Membership-gated, humanId taken from the VERIFIED token (never the body) — a caller can only bind
//     a device under their OWN identity, which is what makes warden's /dial secure (it authorizes by ctx.humanId and
//     his pushBackend resolves the token registered for THAT humanId+session; register + dial + resolve share one key).
//   - buildDialPayload / computeDialId: the DETERMINISTIC wire the deploy's pushBackend emits to APNs -> forge decode()
//     reads {id, who, priority}. Deterministic (injected clock) so a dialId is stable + a payload is testable.
//
// AUTHORS NOTHING, holds NO signing key: /dial only RINGS a device. The answered-call Q&A is the existing /answer +
// /brief (grounding-first); a spoken VOICE-GO -> post is the existing GOVERNED humanMessage write (Carter-consent-only,
// warden's bar), unchanged. FAIL-CLOSED + HONEST: no deviceRegistry wired -> 501; a bad/oversized token -> 400; a
// non-member session -> 403. Zero-dep; injected deviceRegistry (deploy wires Dynamo) + now (deterministic/testable).
//
// deviceRegistry contract (deploy wires it; this module CALLS register, the deploy's pushBackend CALLS lookup):
//   register({humanId, sessionId, voipToken, platform, registeredAt}) -> Promise<{deviceCount?:number}>   // idempotent upsert
//   lookup({humanId, sessionId}) -> Promise<Array<{voipToken, platform}>>                                  // used OUTSIDE the gateway

import { createHash } from 'node:crypto';

export const DIAL_LIMITS = Object.freeze({
  VOIP_TOKEN: 512,   // APNs device token hex / FCM token — generously bounded
  MESSAGE: 4096,     // matches warden's /dial message bound (kept in sync)
  CONTEXT: 2048,     // matches warden's /dial context bound (post-scrub)
  WHO: 128,
});
// Priority set kept in SYNC with warden's /dial validate (low|medium|high|urgent). buildDialPayload defaults to medium.
export const DIAL_PRIORITIES = Object.freeze(['low', 'medium', 'high', 'urgent']);
export const DIAL_PLATFORMS = Object.freeze(['apns', 'fcm']);

const utf8 = (s) => Buffer.byteLength(String(s ?? ''), 'utf8');
const b64url = (buf) => Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

/**
 * Deterministic dial id: 'dial_' + 16 base64url chars of SHA-256 over LENGTH-PREFIXED (humanId|sessionId|message|nowMs).
 * Length-prefixing (utf8count:value) makes the join unambiguous — ("a","bc") and ("ab","c") can never collide.
 */
export function computeDialId(humanId, sessionId, message, nowMs) {
  const lp = (s) => { const v = String(s ?? ''); return `${utf8(v)}:${v}`; };
  const h = createHash('sha256').update(`${lp(humanId)}|${lp(sessionId)}|${lp(message)}|${lp(String(nowMs))}`, 'utf8').digest();
  return 'dial_' + b64url(h).slice(0, 16);
}

/** Validate + normalize a device registration body. Returns {ok:true, value} | {ok:false, status, error}. */
export function validateRegistration(body) {
  const b = body && typeof body === 'object' ? body : {};
  const voipToken = typeof b.voipToken === 'string' ? b.voipToken.trim() : '';
  const sessionId = typeof b.sessionId === 'string' ? b.sessionId.trim() : '';
  const platform = (typeof b.platform === 'string' ? b.platform.trim().toLowerCase() : '') || 'apns';
  if (!voipToken) return { ok: false, status: 400, error: 'voipToken required' };
  if (utf8(voipToken) > DIAL_LIMITS.VOIP_TOKEN) return { ok: false, status: 413, error: `voipToken exceeds ${DIAL_LIMITS.VOIP_TOKEN} bytes` };
  if (!sessionId) return { ok: false, status: 400, error: 'sessionId required' };
  if (!DIAL_PLATFORMS.includes(platform)) return { ok: false, status: 400, error: `platform must be one of ${DIAL_PLATFORMS.join(', ')}` };
  return { ok: true, value: { voipToken, sessionId, platform } };
}

// ── dialPayloadV1 — the versioned, bounded APNs ring wire (spec v0.6 @ C:\tmp\dialPayloadV1-spec, Pulse SPEC +1) ──
// PushKit VoIP caps the ENTIRE push at 5120 bytes; we target our serialized payload at 5120 minus an envelope reserve.
export const DIAL_PUSHKIT_CAP = 5120;               // Apple PushKit VoIP total-payload hard cap (bytes)
const DIAL_ENVELOPE_RESERVE = 256;                  // headroom for the APNs aps envelope + framing wrapping our JSON
export const DIAL_PAYLOAD_MAX_BYTES = DIAL_PUSHKIT_CAP - DIAL_ENVELOPE_RESERVE; // 4864: budget our serialized payload fits under
export const DIAL_KINDS = Object.freeze(['go', 'decisionYours', 'pickOption', 'info', 'checkpointReady']);
const DIAL_ID_MAX = 128, DIAL_CALLER_MAX = 128; // identity byte-bound + display codepoint-bound. options + evidenceSeqs are NEVER capped/truncated (R1: complete or LEAN).
// Reject Unicode Cc controls in an opaque identity: C0 (< 0x20) + DEL (0x7f) + C1 (0x80-0x9f). charCodeAt avoids control-char regex literals.
const hasControlChar = (s) => { for (let i = 0; i < s.length; i += 1) { const c = s.charCodeAt(i); if (c < 0x20 || (c >= 0x7f && c <= 0x9f)) return true; } return false; };

/** Opaque identity validator (id/sessionId/checkpointId): NON-BLANK (not whitespace-only), UTF-8 <= max, no Cc controls. Throws (fail-closed); value returned UNALTERED (never trimmed/truncated). */
function assertOpaqueId(name, v) {
  if (typeof v !== 'string' || v.trim().length === 0) throw new Error(`dial: ${name} required (opaque, non-blank)`);
  if (utf8(v) > DIAL_ID_MAX) throw new Error(`dial: ${name} exceeds ${DIAL_ID_MAX} bytes`);
  if (hasControlChar(v)) throw new Error(`dial: ${name} has control chars`);
  return v; // unaltered — an opaque value's own spaces/casing are preserved
}
/** Optional opaque id: absent -> undefined; PRESENT-but-invalid -> throws (fail-closed; never silently omit identity). */
function optOpaqueId(name, v) { return (v === undefined || v === null) ? undefined : assertOpaqueId(name, v); }
/** Display string (callerName/who): codepoint-safe bound + safe fallback. Never splits a surrogate pair (R4). Display is not identity -> never fail-closed. */
const boundDisplay = (v, max, fallback) => { const s = typeof v === 'string' ? v.trim() : ''; if (!s) return fallback; const cp = [...s]; return cp.length <= max ? s : cp.slice(0, max).join(''); };
/** evidenceSeqs: every element MUST be a POSITIVE SAFE integer (fail-closed on unsafe/negative/non-int); de-duped + SORTED ASC. COMPLETE — never capped (R1); over-budget -> the ladder emits LEAN. */
const normSeqs = (v) => {
  if (!Array.isArray(v)) return [];
  for (const n of v) if (!Number.isSafeInteger(n) || n <= 0) throw new Error('dial: evidenceSeq must be a positive safe integer (int64 beyond JS-safe range needs a versioned string wire, not numeric corruption)');
  return [...new Set(v)].sort((a, b) => a - b);
};
/** pickOption labels: every label MUST be a non-empty string (fail-closed). COMPLETE + UNALTERED — never capped/truncated (R1, atomic unit); over-budget -> LEAN. */
const normOptions = (v) => {
  if (!Array.isArray(v)) return [];
  return v.map((x) => { if (typeof x !== 'string' || x.trim().length === 0) throw new Error('dial: every pickOption label must be a non-empty string'); return x; });
};
const serializedBytes = (obj) => Buffer.byteLength(JSON.stringify(obj), 'utf8');

/**
 * Build the DialPayloadV1 the phone decodes. CORE (v/id/kind/priority/callerName/who/sessionId/checkpointId?/fetch/ts)
 * is always present + bounded (always fits). GOVERNED content (message/options/context/evidenceSeqs/confidence) is
 * included only when the whole payload fits DIAL_PAYLOAD_MAX_BYTES; else the deterministic RICH->LEAN ladder sheds it:
 *   fits -> fetch=false (complete, renderable)  |  drop confidence (non-governed) -> still fetch=false  |
 *   else fetch=true LEAN: ALL governed content dropped, core-only; phone hydrates via the authenticated GET (no partial-speak).
 * Identity is OPAQUE + FAIL-CLOSED (throws on blank/overbound/control; never truncated). A pickOption with no options is
 * malformed -> throws. `id` override (opaque) is used verbatim (signal-originated); absent -> computeDialId (legacy /dial).
 * @param {{humanId?, sessionId, message?, context?, priority?, who?, id?, kind?, callerName?, options?, checkpointId?, evidenceSeqs?, confidence?}} f
 * @param {number} nowMs  injected clock (deterministic)
 */
export function buildDialPayload(f = {}, nowMs = 0) {
  const sessionId = assertOpaqueId('sessionId', typeof f.sessionId === 'string' ? f.sessionId : '');
  const checkpointId = optOpaqueId('checkpointId', f.checkpointId); // present-but-invalid throws (never silently omitted)
  // R2: message is REQUIRED (a fetch=false payload must carry a validated question). The FULL message rides the payload;
  // the ladder sheds it WHOLE (LEAN) if over budget; NEVER truncated (spec D).
  const message = typeof f.message === 'string' ? f.message : '';
  if (message.trim().length === 0) throw new Error('dial: message required');
  const priority = DIAL_PRIORITIES.includes(f.priority) ? f.priority : 'medium';
  const who = boundDisplay(f.who, DIAL_LIMITS.WHO, 'senti-pocket');
  // R2: kind ABSENT -> "info" (documented legacy default); PRESENT-but-invalid -> fail closed.
  let kind;
  if (f.kind === undefined || f.kind === null) kind = 'info';
  else if (DIAL_KINDS.includes(f.kind)) kind = f.kind;
  else throw new Error('dial: unknown kind (present-but-invalid fails closed)');
  const callerName = boundDisplay(f.callerName, DIAL_CALLER_MAX, 'Senti needs you');
  const id = f.id !== undefined ? assertOpaqueId('id', f.id) : computeDialId(f.humanId, sessionId, message, nowMs);
  const context = typeof f.context === 'string' && f.context.length ? f.context : undefined; // governed — ladder drops it WHOLE if over budget, never truncated (spec D)
  const options = kind === 'pickOption' ? normOptions(f.options) : [];
  if (kind === 'pickOption' && options.length === 0) throw new Error('dial: pickOption requires >=1 option (atomic with the question)');
  const evidenceSeqs = normSeqs(f.evidenceSeqs);
  const confidence = typeof f.confidence === 'number' && Number.isFinite(f.confidence) ? Math.max(0, Math.min(1, f.confidence)) : undefined;
  const ts = new Date(nowMs).toISOString();

  const core = { v: 1, id, kind, priority, callerName, who, sessionId, ...(checkpointId ? { checkpointId } : {}), fetch: false, ts };
  const governed = {
    ...(message ? { message } : {}),
    ...(options.length ? { options } : {}),
    ...(context ? { context } : {}),
    ...(evidenceSeqs.length ? { evidenceSeqs } : {}),
  };
  // RICH: core + governed + confidence.
  let rich = { ...core, ...governed, ...(confidence !== undefined ? { confidence } : {}) };
  if (serializedBytes(rich) <= DIAL_PAYLOAD_MAX_BYTES) return rich;
  // Drop confidence (NON-governed, debug-only) — stays fetch=false.
  rich = { ...core, ...governed };
  if (serializedBytes(rich) <= DIAL_PAYLOAD_MAX_BYTES) return rich;
  // LEAN: fetch=true, ALL governed content shed; core-only. The phone hydrates via the authenticated GET (no partial-speak).
  return { ...core, fetch: true };
}

/**
 * The /dial/register handler logic over an injected deviceRegistry. Pure of transport: returns {status, body} so the
 * handlers.mjs wire is a thin adapter (auth + scope check, then call this). Kept OUT of handlers.mjs to avoid colliding
 * with warden's concurrent /dial route edits — the wire is a 3-line addition alongside his route.
 * @param {{ deviceRegistry?: {register:Function, lookup?:Function}, now?: ()=>number }} deps
 */
export function createDialRegistry({ deviceRegistry, now } = {}) {
  const clock = typeof now === 'function' ? now : () => Date.now();
  return {
    /**
     * @param {{ humanId:string, body:object, isMember:(sessionId:string)=>Promise<boolean> }} args
     * @returns {Promise<{status:number, body:object}>}
     */
    async register({ humanId, body, isMember } = {}) {
      const v = validateRegistration(body);
      if (!v.ok) return { status: v.status, body: { error: v.error } };
      if (!deviceRegistry || typeof deviceRegistry.register !== 'function') {
        return { status: 501, body: { error: 'dial registry not configured', reason: 'dial-not-configured' } };
      }
      let member = false;
      try { member = await isMember(v.value.sessionId); }
      catch { return { status: 500, body: { error: 'authorization lookup failed' } }; }
      if (!member) return { status: 403, body: { error: 'not a known session for this user' } };
      let res;
      try {
        res = await deviceRegistry.register({
          humanId, sessionId: v.value.sessionId, voipToken: v.value.voipToken, platform: v.value.platform,
          registeredAt: new Date(clock()).toISOString(),
        });
      } catch { return { status: 502, body: { error: 'registry write failed', reason: 'registry-write-failed' } }; }
      return {
        status: 200,
        body: { registered: true, sessionId: v.value.sessionId, platform: v.value.platform, deviceCount: (res && Number.isFinite(res.deviceCount)) ? res.deviceCount : undefined },
      };
    },
    buildPayload: (fields) => buildDialPayload(fields, clock()),
    now: clock,
  };
}

/**
 * The registry-backed pushBackend IMPL that warden's POST /dial calls. Matches his exact contract:
 *   pushBackend({message, context, priority, sessionId, humanId}) -> {dispatched, dialId?, reason?}
 * It RESOLVES the device(s) from the registry my /dial/register populates, builds the deterministic payload, and fans
 * out to the injected APNs sender. Honest + fail-closed at every gap (never a fake dispatch):
 *   no registry -> dial-not-configured | lookup throws -> registry-lookup-failed | 0 devices -> no-device-token
 *   (== warden's /dial test expectation) | no apnsSend -> push-transport-not-configured | all sends fail -> all-deliveries-failed
 * dialId is computeDialId (so warden's out.dialId is deterministic + consistent). The REAL APNs network call is the
 * injected apnsSend (deploy wires the VoIP cert) — this module never fakes delivery; `dispatched` is true ONLY when at
 * least one device actually acked.
 * @param {{ deviceRegistry?: {lookup:Function}, apnsSend?: (a:{voipToken,platform,payload})=>Promise<{delivered:boolean}>, now?: ()=>number, maxDevices?: number }} deps
 * @returns {(input:object)=>Promise<{dispatched:boolean, dialId?:string, reason?:string, delivered?:number, devices?:number}>}
 */
export function createDialPushBackend({ deviceRegistry, apnsSend, now, maxDevices = 20 } = {}) {
  const clock = typeof now === 'function' ? now : () => Date.now();
  const cap = Number.isInteger(maxDevices) && maxDevices > 0 ? maxDevices : 20;
  return async function pushBackend({ message, context, priority, sessionId, humanId } = {}) {
    if (!deviceRegistry || typeof deviceRegistry.lookup !== 'function') return { dispatched: false, reason: 'dial-not-configured' };
    let devices;
    try { devices = await deviceRegistry.lookup({ humanId, sessionId }); }
    catch { return { dispatched: false, reason: 'registry-lookup-failed' }; }
    // Dedupe by voipToken so a re-login that left two records for the same device rings it ONCE, not twice. Belt-and-
    // suspenders: the deviceRegistry SHOULD upsert, but a ring must never double even if lookup returns a duplicate.
    const seenTokens = new Set();
    devices = (Array.isArray(devices) ? devices : []).filter((d) =>
      d && typeof d.voipToken === 'string' && d.voipToken && !seenTokens.has(d.voipToken) && seenTokens.add(d.voipToken),
    ).slice(0, cap);
    if (devices.length === 0) return { dispatched: false, reason: 'no-device-token' };
    if (typeof apnsSend !== 'function') return { dispatched: false, reason: 'push-transport-not-configured' };
    let payload;
    try { payload = buildDialPayload({ humanId, sessionId, message, context, priority }, clock()); }
    catch { return { dispatched: false, reason: 'invalid-dial-payload' }; } // fail-closed: blank/overbound/control identity never rings
    // Fan out; dispatched iff AT LEAST ONE device acked. Per-device failure is isolated (one dead token never fails the ring).
    let delivered = 0;
    for (const d of devices) {
      try { const r = await apnsSend({ voipToken: d.voipToken, platform: d.platform || 'apns', payload }); if (r && r.delivered) delivered += 1; }
      catch { /* isolated: continue to the next device */ }
    }
    return delivered > 0
      ? { dispatched: true, dialId: payload.id, delivered, devices: devices.length }
      : { dispatched: false, reason: 'all-deliveries-failed', dialId: payload.id, devices: devices.length };
  };
}

/** Injection-safe device-record key: humanId is length-prefixed so ("a","b:c") and ("a:b","c") can never collide. */
const DEVICE_KEY = (humanId, sessionId) => `dial:dev:${String(humanId ?? '').length}:${humanId ?? ''}:${sessionId ?? ''}`;

/**
 * A deps.deviceRegistry backed by the gateway's own {get,put,delete} store — ZERO new infra (it rides the existing
 * DynamoDB table the gateway already uses), so a deploy can wire /dial/register with nothing but the store it already
 * has. v1 stores ONE device per (humanId, sessionId): register is an ATOMIC put (race-free, latest device wins — no
 * lost-update, no lock needed) and lookup a single get. Multi-device-per-session is a v2 nicety; createDialPushBackend
 * already fans out to a device LIST, so a future multi-device registry drops in with NO pushBackend change. A deploy
 * that wants a dedicated device table can inject its own deps.deviceRegistry instead — this is only the default.
 * @param {{ store: {get:Function, put:Function}, now?: ()=>number }} cfg
 */
export function createStoreDeviceRegistry({ store, now = () => Date.now() } = {}) {
  if (!store || typeof store.get !== 'function' || typeof store.put !== 'function') {
    throw new Error('createStoreDeviceRegistry requires a { get, put } store');
  }
  const clock = typeof now === 'function' ? now : () => Date.now();
  return {
    async register({ humanId, sessionId, voipToken, platform, registeredAt } = {}) {
      // atomic full-item put: no read-modify-write, so two concurrent registers for the same (human,session) can't lose
      // an update (last-writer-wins is the intended v1 single-device semantics, not a race bug).
      await store.put(DEVICE_KEY(humanId, sessionId), {
        voipToken, platform: platform || 'apns', registeredAt: registeredAt || new Date(clock()).toISOString(),
      });
      return { deviceCount: 1 };
    },
    async lookup({ humanId, sessionId } = {}) {
      const d = await store.get(DEVICE_KEY(humanId, sessionId));
      return d && typeof d.voipToken === 'string' && d.voipToken ? [{ voipToken: d.voipToken, platform: d.platform || 'apns' }] : [];
    },
  };
}
