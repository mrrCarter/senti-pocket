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
import {
  DEVICE_REGISTRATION_VERSION,
  DeviceRegistryV2Error,
  validateDeviceRegistrationV2,
  validateDeviceUnregistrationV2,
} from './device-registry-v2.mjs';

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
export const DIAL_BINDING_VERSION = 2;
export const DIAL_KINDS = Object.freeze(['go', 'decisionYours', 'pickOption', 'info', 'checkpointReady']);
// WRITE-KINDS carry a GOVERNED decision (the question/options a caller must act on). Per Warden's push-model security
// call, their governed content is NEVER placed in the APNs push (visible to Apple + the notification layer) — a write-kind
// is ALWAYS a LEAN doorbell, hydrated via the authed GET /dial?id=. RICH (governed-in-push) is reserved for the
// LOW-SENSITIVITY info/checkpointReady kinds. (decisionYours/pickOption/go = the three write-decision kinds.)
export const DIAL_WRITE_KINDS = Object.freeze(new Set(['decisionYours', 'pickOption', 'go']));
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
/** Optional opaque id: ONLY undefined is absent; a PRESENT value (incl null) -> assertOpaqueId (fail-closed; never silently omit identity). */
function optOpaqueId(name, v) { return v === undefined ? undefined : assertOpaqueId(name, v); }
/** Display string (callerName/who): codepoint-safe bound + safe fallback. Never splits a surrogate pair (R4). Display is not identity -> never fail-closed. */
const boundDisplay = (v, max, fallback) => { const s = typeof v === 'string' ? v.trim() : ''; if (!s) return fallback; const cp = [...s]; return cp.length <= max ? s : cp.slice(0, max).join(''); };
/** evidenceSeqs: every element MUST be a POSITIVE SAFE integer (fail-closed on unsafe/negative/non-int); de-duped + SORTED ASC. COMPLETE — never capped (R1); over-budget -> the ladder emits LEAN. */
const normSeqs = (v) => {
  if (v === undefined) return []; // ONLY absent (undefined) -> []
  if (!Array.isArray(v)) throw new Error('dial: evidenceSeqs must be an array (present-but-invalid fails closed)'); // R5: present null/string/object must not silently omit
  for (const n of v) if (!Number.isSafeInteger(n) || n <= 0) throw new Error('dial: evidenceSeq must be a positive safe integer (int64 beyond JS-safe range needs a versioned string wire, not numeric corruption)');
  return [...new Set(v)].sort((a, b) => a - b);
};
/** pickOption labels: every label MUST be a non-empty string (fail-closed). COMPLETE + UNALTERED — never capped/truncated (R1, atomic unit); over-budget -> LEAN. */
const normOptions = (v) => {
  if (v === undefined) return []; // ONLY absent (undefined) -> [] (the pickOption-requires-options check throws downstream)
  if (!Array.isArray(v)) throw new Error('dial: options must be an array (present-but-invalid fails closed)'); // R5: present null/string/object fails closed
  return v.map((x) => { if (typeof x !== 'string' || x.trim().length === 0) throw new Error('dial: every pickOption label must be a non-empty string'); return x; });
};
const normBinding = (v) => {
  if (v === undefined) return undefined;
  if (!v || typeof v !== 'object' || Array.isArray(v) ||
      Object.keys(v).some((key) => !['v', 'id', 'revision'].includes(key))) {
    throw new Error('dial: invalid binding envelope');
  }
  if (v.v !== DIAL_BINDING_VERSION ||
      typeof v.id !== 'string' || !/^bind_[0-9a-f]{32}$/.test(v.id) ||
      !Number.isSafeInteger(v.revision) || v.revision <= 0) {
    throw new Error('dial: invalid binding envelope');
  }
  return { v: DIAL_BINDING_VERSION, id: v.id, revision: v.revision };
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
 * A Registry V2 delivery supplies `binding`; that changes the outer payload version to 2 and places the exact binding
 * envelope in CORE before the byte ladder runs. Legacy callers omit it and retain the byte-identical V1 fixture.
 * @param {{humanId?, sessionId, message?, context?, priority?, who?, id?, kind?, callerName?, options?, checkpointId?, evidenceSeqs?, confidence?, binding?}} f
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
  const binding = normBinding(f.binding);
  const ts = new Date(nowMs).toISOString();

  const core = {
    v: binding ? DIAL_BINDING_VERSION : 1,
    id,
    kind,
    priority,
    callerName,
    who,
    sessionId,
    ...(checkpointId ? { checkpointId } : {}),
    ...(binding ? { binding } : {}),
    fetch: false,
    ts,
  };
  // SECURITY (Warden push-model doorbell): a WRITE-KIND (decisionYours/pickOption/go) carries a governed decision the
  // push must not reveal — even post-scrub, "approve the wire to acct Y?" leaks a pending action to Apple/the notification
  // layer. So a write-kind is ALWAYS a LEAN doorbell: ALL governed content (message/options/context/evidenceSeqs/confidence)
  // is shed and hydrated only via the authed, membership-gated GET /dial?id=. This is unbypassable — the policy lives in the
  // wire builder keyed on kind, not on any caller flag. RICH (governed-in-push) stays available for info/checkpointReady only.
  // (Validation above still runs first, so a malformed write-kind still fails closed before it is shed to LEAN.)
  if (DIAL_WRITE_KINDS.has(kind)) {
    const lean = { ...core, fetch: true };
    if (serializedBytes(lean) > DIAL_PAYLOAD_MAX_BYTES) throw new Error('dial: core payload exceeds PushKit budget');
    return lean;
  }
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
  const lean = { ...core, fetch: true };
  if (serializedBytes(lean) > DIAL_PAYLOAD_MAX_BYTES) throw new Error('dial: core payload exceeds PushKit budget');
  return lean;
}

/**
 * Build the FINAL PKPushPayload.dictionaryPayload that createDialPushBackend passes to apnsSend: dial DTO fields stay at
 * the TOP LEVEL and the APNs `aps` envelope is a SIBLING — never nest the DTO under payload/data. SentiCallKit reads
 * `dict["id"]`/who/callerName/… at top level and ignores `aps`; nesting would make every ring decline. The live backend
 * calls this builder immediately before every transport invocation, and the transport must serialize the returned object
 * verbatim without wrapping, extending, or rebuilding it. The optional `aps` argument supports direct construction/tests;
 * the complete dictionary is always measured against Apple's 5,120-byte VoIP cap.
 * @param {object} payload  the bare DialPayloadV1 from buildDialPayload
 * @param {object} [aps]     APNs `aps` envelope fields, merged over the default (its content is decode-irrelevant)
 * @returns {object} the dictionaryPayload delivered to the device: { ...payload (TOP-LEVEL), aps }
 */
export function buildVoipPushDictionary(payload, aps = {}) {
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) throw new Error('buildVoipPushDictionary: payload object required');
  if (typeof payload.id !== 'string' || payload.id.length === 0) throw new Error('buildVoipPushDictionary: payload.id (top-level identity) required — a nested/blank id is a dead ring');
  if (aps == null || typeof aps !== 'object' || Array.isArray(aps)) throw new Error('buildVoipPushDictionary: aps must be an object');
  // Dial DTO fields spread at the TOP LEVEL; `aps` a SIBLING (decode-ignored). The DTO is NEVER placed under a wrapper key.
  const dictionary = { ...payload, aps: { ...aps } };
  if (serializedBytes(dictionary) > DIAL_PUSHKIT_CAP) {
    throw new Error(`buildVoipPushDictionary: final dictionary exceeds ${DIAL_PUSHKIT_CAP}-byte PushKit cap`);
  }
  return dictionary;
}

/**
 * The /dial/register handler logic over an injected deviceRegistry. Pure of transport: returns {status, body} so the
 * handlers.mjs wire is a thin adapter (auth + scope check, then call this). Kept OUT of handlers.mjs to avoid colliding
 * with warden's concurrent /dial route edits — the wire is a 3-line addition alongside his route.
 * @param {{ deviceRegistry?: {register:Function, lookup?:Function}, now?: ()=>number }} deps
 */
export function createDialRegistry({ deviceRegistry, now } = {}) {
  const clock = typeof now === 'function' ? now : () => Date.now();
  const usesRegistryV2 = deviceRegistry?.protocolVersion === DEVICE_REGISTRATION_VERSION;
  return {
    /**
     * @param {{ humanId:string, body:object, isMember:(sessionId:string)=>Promise<boolean> }} args
     * @returns {Promise<{status:number, body:object}>}
     */
    async register({ principal, humanId, body, isMember } = {}) {
      const requestedV2 = body && typeof body === 'object' && (
        Object.hasOwn(body, 'registrationVersion') ||
        Object.hasOwn(body, 'installationId') ||
        Object.hasOwn(body, 'idempotencyKey') ||
        Object.hasOwn(body, 'expectedBindingId') ||
        Object.hasOwn(body, 'expectedBindingRevision') ||
        Object.hasOwn(body, 'expectedTokenClaimId') ||
        Object.hasOwn(body, 'expectedTokenClaimRevision')
      );
      if (usesRegistryV2) {
        const v = validateDeviceRegistrationV2(body);
        if (!v.ok) return { status: v.status, body: { error: v.error, reason: 'registration-v2-required' } };
        let member = false;
        try { member = await isMember(v.value.sessionId); }
        catch { return { status: 500, body: { error: 'authorization lookup failed' } }; }
        if (!member) return { status: 403, body: { error: 'not a known session for this user' } };
        let res;
        try { res = await deviceRegistry.register({ principal: principal || humanId, humanId, ...v.value }); }
        catch (error) {
          if (error instanceof DeviceRegistryV2Error && error.code === 'idempotency-conflict') {
            return { status: 409, body: { error: error.message, reason: 'idempotency-conflict' } };
          }
          if (error instanceof DeviceRegistryV2Error &&
              ['revision-exhausted', 'registration-conflict'].includes(error.code)) {
            return { status: 409, body: { error: 'registration could not be serialized', reason: error.code } };
          }
          if (error instanceof DeviceRegistryV2Error && error.code === 'target-capacity') {
            return {
              status: 409,
              body: {
                error: 'target already has the maximum number of active device installations',
                reason: 'target-capacity',
              },
            };
          }
          if (error instanceof DeviceRegistryV2Error && error.code === 'binding-conflict') {
            const current = error.details?.currentBinding;
            return {
              status: 409,
              body: {
                error: 'registration expected binding is no longer current',
                reason: 'binding-conflict',
                currentBinding: current ? {
                  bindingId: current.bindingId,
                  bindingRevision: current.bindingRevision,
                  expiresAt: new Date(current.expiresAtEpochSec * 1000).toISOString(),
                } : null,
              },
            };
          }
          if (error instanceof DeviceRegistryV2Error && error.code === 'token-claim-conflict') {
            const current = error.details?.currentTokenClaim;
            return {
              status: 409,
              body: {
                error: 'registration expected token claim is no longer current',
                reason: 'token-claim-conflict',
                currentTokenClaim: current ? {
                  tokenClaimId: current.tokenClaimId,
                  tokenClaimRevision: current.tokenClaimRevision,
                  expiresAt: new Date(current.expiresAtEpochSec * 1000).toISOString(),
                } : null,
              },
            };
          }
          return { status: 502, body: { error: 'registry write failed', reason: 'registry-write-failed' } };
        }
        return {
          status: 200,
          body: {
            registered: true,
            registrationVersion: DEVICE_REGISTRATION_VERSION,
            sessionId: v.value.sessionId,
            platform: v.value.platform,
            bindingId: res.bindingId,
            bindingRevision: res.bindingRevision,
            tokenClaimId: res.tokenClaimId,
            tokenClaimRevision: res.tokenClaimRevision,
            expiresAt: new Date(res.expiresAtEpochSec * 1000).toISOString(),
            idempotent: res.idempotent === true,
          },
        };
      }
      if (requestedV2) {
        return {
          status: 501,
          body: { error: 'dial registry v2 not configured', reason: 'dial-registry-v2-not-configured' },
        };
      }

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
    /**
     * V2 existence-oblivious compare-delete. Membership is intentionally not required: losing membership is precisely
     * when a previously authorized device still needs to revoke its old target. The authenticated humanId remains part
     * of the target HMAC and the bindingId/revision condition fences A->B races.
     */
    async unregister({ principal, humanId, body } = {}) {
      if (!usesRegistryV2 || !deviceRegistry || typeof deviceRegistry.unregister !== 'function') {
        return {
          status: 501,
          body: { error: 'dial registry v2 not configured', reason: 'dial-registry-v2-not-configured' },
        };
      }
      const v = validateDeviceUnregistrationV2(body);
      if (!v.ok) return { status: v.status, body: { error: v.error, reason: 'unregistration-v2-required' } };
      try { await deviceRegistry.unregister({ principal: principal || humanId, humanId, ...v.value }); }
      catch (error) {
        if (error instanceof DeviceRegistryV2Error && error.code === 'unregistration-conflict') {
          return {
            status: 503,
            body: {
              error: 'registry delete could not be serialized',
              reason: 'unregistration-conflict',
            },
          };
        }
        return { status: 502, body: { error: 'registry delete failed', reason: 'registry-delete-failed' } };
      }
      return {
        status: 200,
        body: {
          unregistered: true,
          registrationVersion: DEVICE_REGISTRATION_VERSION,
          sessionId: v.value.sessionId,
        },
      };
    },
    buildPayload: (fields) => buildDialPayload(fields, clock()),
    now: clock,
  };
}

/**
 * The registry-backed pushBackend IMPL that warden's POST /dial calls. Matches his exact contract:
 *   pushBackend({message, context, priority, sessionId, humanId}) -> {dispatched, dialId?, reason?}
 * PR-B2 (backward-compatible): ALSO accepts the RICH dialPayloadV1 fields (id/kind/callerName/options/checkpointId/
 * evidenceSeqs/confidence) buildDialPayload threads onto the wire, plus `storedSignal` — the full NeedCarterSignal to
 * persist for GET /dial?id= hydration. Legacy /dial callers pass NONE of these and behave EXACTLY as before (kind
 * defaults to info, id = computeDialId, no store-write).
 * It RESOLVES the device(s) from the registry my /dial/register populates, builds the deterministic payload, and fans
 * out to the injected APNs sender. Honest + fail-closed at every gap (never a fake dispatch):
 *   no registry -> dial-not-configured | lookup throws -> registry-lookup-failed | 0 devices -> no-device-token
 *   (== warden's /dial test expectation) | no apnsSend -> push-transport-not-configured | all sends fail -> all-deliveries-failed
 * HYDRATION (PR-B2): with `storedSignal`, the full signal is persisted (keyed by payload.id == signal.id) BEFORE the
 * ring. A LEAN ring (payload.fetch===true shed ALL governed content) is a dead doorbell without it -> the store-write
 * FAILS CLOSED for LEAN (signal-store-not-configured / signal-store-write-failed, no ring). A RICH ring is self-contained
 * -> its store-write is best-effort (a GET-consistency/audit copy) and NEVER blocks the ring.
 * dialId is the built payload's id (signal-originated when supplied, else computeDialId). The REAL APNs network call is
 * the injected apnsSend (deploy wires the VoIP cert) — this module never fakes delivery; `dispatched` is true ONLY when
 * at least one device actually acked.
 * @param {{ deviceRegistry?: {lookup:Function}, apnsSend?: (a:{voipToken,platform,payload})=>Promise<{delivered:boolean}>, now?: ()=>number, maxDevices?: number, signalStore?: {put:Function} }} deps
 * @returns {(input:object)=>Promise<{dispatched:boolean, dialId?:string, reason?:string, delivered?:number, devices?:number}>}
 */
export function createDialPushBackend({ deviceRegistry, apnsSend, now, maxDevices = 20, signalStore } = {}) {
  const clock = typeof now === 'function' ? now : () => Date.now();
  const cap = Number.isInteger(maxDevices) && maxDevices > 0 ? maxDevices : 20;
  const requiresBindingFence = deviceRegistry?.protocolVersion === DEVICE_REGISTRATION_VERSION;
  return async function pushBackend({ message, context, priority, sessionId, principal, humanId, id, kind, callerName, options, checkpointId, evidenceSeqs, confidence, storedSignal } = {}) {
    if (!deviceRegistry || typeof deviceRegistry.lookup !== 'function') return { dispatched: false, reason: 'dial-not-configured' };
    let devices;
    try { devices = await deviceRegistry.lookup({ principal: principal || humanId, humanId, sessionId }); }
    catch { return { dispatched: false, reason: 'registry-lookup-failed' }; }
    // Group by the normalized routing identity `(platform, token)` BEFORE fanout capping. The same token text in APNs
    // and FCM is two routes. Exact duplicate V2 rows may collapse, but conflicting binding fences make that route
    // ambiguous and therefore un-routable—never first-writer-wins.
    const routes = new Map();
    for (const d of (Array.isArray(devices) ? devices : [])) {
      if (!d || typeof d.voipToken !== 'string' || !d.voipToken) continue;
      const platform = typeof d.platform === 'string' ? d.platform.toLowerCase() : 'apns';
      if (!DIAL_PLATFORMS.includes(platform)) continue;
      if (requiresBindingFence && (
        typeof d.bindingId !== 'string' || !/^bind_[0-9a-f]{32}$/.test(d.bindingId) ||
        !Number.isSafeInteger(d.bindingRevision) || d.bindingRevision <= 0
      )) continue;
      const routeKey = JSON.stringify([platform, d.voipToken]);
      const fenceKey = requiresBindingFence
        ? JSON.stringify([d.bindingId, d.bindingRevision])
        : '';
      const existing = routes.get(routeKey);
      if (!existing) {
        routes.set(routeKey, {
          device: { ...d, platform },
          fenceKey,
          ambiguous: false,
        });
      } else if (existing.fenceKey !== fenceKey) {
        existing.ambiguous = true;
      }
    }
    const ambiguousRoutes = [...routes.values()].filter((route) => route.ambiguous).length;
    devices = [...routes.values()]
      .filter((route) => !route.ambiguous)
      .map((route) => route.device)
      .slice(0, cap);
    if (devices.length === 0) {
      return { dispatched: false, reason: ambiguousRoutes ? 'registry-route-conflict' : 'no-device-token' };
    }
    if (typeof apnsSend !== 'function') return { dispatched: false, reason: 'push-transport-not-configured' };
    let payload;
    let deviceDeliveries;
    const payloadNow = clock();
    const payloadFields = {
      humanId, sessionId, message, context, priority, id, kind, callerName, options, checkpointId,
      evidenceSeqs, confidence,
    };
    // RICH dialPayloadV1 fields flow through when present (ring-owner path); absent -> legacy defaults (kind=info, computed id).
    try {
      payload = buildDialPayload(payloadFields, payloadNow);
      deviceDeliveries = devices.map((device) => ({
        device,
        payload: requiresBindingFence
          ? buildDialPayload({
            ...payloadFields,
            id: payload.id,
            binding: {
              v: DIAL_BINDING_VERSION,
              id: device.bindingId,
              revision: device.bindingRevision,
            },
          }, payloadNow)
          : payload,
      }));
    }
    catch { return { dispatched: false, reason: 'invalid-dial-payload' }; } // fail-closed: blank/overbound/control identity never rings
    const deliveredPayloadNeedsHydration = deviceDeliveries.some((delivery) => delivery.payload.fetch === true);
    if (requiresBindingFence && deliveredPayloadNeedsHydration && storedSignal === undefined) {
      return { dispatched: false, reason: 'signal-hydration-unavailable', dialId: payload.id };
    }
    // HYDRATION store-write (PR-B2): persist the full signal so the phone can GET /dial?id= it. A LEAN ring shed ALL
    // governed content -> it MUST hydrate -> FAIL CLOSED if it can't persist (never a dead doorbell); a RICH ring is
    // self-contained -> best-effort (a GET-consistency/audit copy). Written AFTER all pre-ring checks so a ring that will
    // never fire leaves no orphan record; written BEFORE fan-out so a LEAN ring never reaches the phone unhydratable.
    if (storedSignal !== undefined) {
      const lean = deliveredPayloadNeedsHydration;
      if (!signalStore || typeof signalStore.put !== 'function') {
        if (lean) return { dispatched: false, reason: 'signal-store-not-configured' };
      } else {
        try { await signalStore.put(payload.id, storedSignal); }
        catch { if (lean) return { dispatched: false, reason: 'signal-store-write-failed' }; }
      }
    }
    // Fan out; dispatched iff AT LEAST ONE device acked. Per-device failure is isolated (one dead token never fails the ring).
    // WIRE CONTRACT: the gateway constructs the FINAL APNs dictionary so the top-level shape and 5,120-byte PushKit cap
    // are enforced before transport. The injected transport must serialize `payload` verbatim; it must not wrap it or add
    // fields. The app reads id/kind/… top-level; nesting => top-level `id` absent => every ring rejects silently.
    let delivered = 0;
    for (const { device, payload: devicePayload } of deviceDeliveries) {
      try {
        const wirePayload = buildVoipPushDictionary(devicePayload);
        const r = await apnsSend({
          voipToken: device.voipToken,
          platform: device.platform || 'apns',
          payload: wirePayload,
        });
        if (r && r.delivered) delivered += 1;
      }
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
    protocolVersion: 1,
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
