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

import { createHash, createHmac, randomBytes } from 'node:crypto';

export const DIAL_LIMITS = Object.freeze({
  VOIP_TOKEN: 512,   // APNs device token hex / FCM token — generously bounded
  MESSAGE: 4096,     // matches warden's /dial message bound (kept in sync)
  CONTEXT: 2048,     // matches warden's /dial context bound (post-scrub)
  WHO: 128,
});
// Priority set kept in SYNC with warden's /dial validate (low|medium|high|urgent). buildDialPayload defaults to medium.
export const DIAL_PRIORITIES = Object.freeze(['low', 'medium', 'high', 'urgent']);
export const DIAL_PLATFORMS = Object.freeze(['apns', 'fcm']);
export const DIAL_REGISTRY_VERSION = 2;
export const DIAL_REGISTRY_LIMITS = Object.freeze({
  INSTALLATION_ID: 128,
  BINDING_ID: 128,
  BINDING_REVISION: 128,
  SESSION_ID: 256,
  DEFAULT_LEASE_SECONDS: 30 * 24 * 60 * 60,
  DEFAULT_RESERVATION_SECONDS: 2 * 60,
  DEFAULT_MAX_DEVICES: 20,
});

const utf8 = (s) => Buffer.byteLength(String(s ?? ''), 'utf8');
const b64url = (buf) => Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const hasOwn = (o, k) => Object.hasOwn(o, k);
const isOpaqueBase64Url = (v, max) =>
  typeof v === 'string' && v.length >= 22 && utf8(v) <= max && /^[A-Za-z0-9_-]+$/.test(v);
const MAX_UINT64 = 18_446_744_073_709_551_615n;
const parseGeneration = (v) => {
  if (typeof v !== 'string' || !/^[1-9][0-9]{0,19}$/.test(v)) return null;
  const n = BigInt(v);
  return n <= MAX_UINT64 ? n : null;
};
const generationOrder = (v) => String(v).padStart(20, '0');

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
  const hasV2Field = ['registryVersion', 'installationId', 'installationGeneration'].some((k) => hasOwn(b, k));
  if (!hasV2Field) return { ok: true, value: { voipToken, sessionId, platform } };
  if (b.registryVersion !== DIAL_REGISTRY_VERSION) {
    return { ok: false, status: 400, error: `registryVersion must be ${DIAL_REGISTRY_VERSION}` };
  }
  if (utf8(sessionId) > DIAL_REGISTRY_LIMITS.SESSION_ID) {
    return { ok: false, status: 413, error: `sessionId exceeds ${DIAL_REGISTRY_LIMITS.SESSION_ID} bytes` };
  }
  if (!isOpaqueBase64Url(b.installationId, DIAL_REGISTRY_LIMITS.INSTALLATION_ID)) {
    return { ok: false, status: 400, error: 'installationId must be a bounded base64url opaque id' };
  }
  if (parseGeneration(b.installationGeneration) === null) {
    return { ok: false, status: 400, error: 'installationGeneration must be a canonical positive uint64 decimal string' };
  }
  return {
    ok: true,
    value: {
      registryVersion: DIAL_REGISTRY_VERSION,
      installationId: b.installationId,
      installationGeneration: b.installationGeneration,
      voipToken,
      sessionId,
      platform,
    },
  };
}

/** Validate the compare-delete body for POST /dial/unregister. */
export function validateUnregistration(body) {
  const b = body && typeof body === 'object' ? body : {};
  const sessionId = typeof b.sessionId === 'string' ? b.sessionId.trim() : '';
  if (b.registryVersion !== DIAL_REGISTRY_VERSION) {
    return { ok: false, status: 400, error: `registryVersion must be ${DIAL_REGISTRY_VERSION}` };
  }
  if (!sessionId || utf8(sessionId) > DIAL_REGISTRY_LIMITS.SESSION_ID) {
    return { ok: false, status: 400, error: 'bounded sessionId required' };
  }
  if (!isOpaqueBase64Url(b.installationId, DIAL_REGISTRY_LIMITS.INSTALLATION_ID)) {
    return { ok: false, status: 400, error: 'installationId must be a bounded base64url opaque id' };
  }
  const unregisterGeneration = parseGeneration(b.installationGeneration);
  const previousGeneration = parseGeneration(b.previousInstallationGeneration);
  if (unregisterGeneration === null || previousGeneration === null || unregisterGeneration <= previousGeneration) {
    return { ok: false, status: 400, error: 'unregister generation must be a canonical uint64 decimal string greater than the previous generation' };
  }
  if (!isOpaqueBase64Url(b.bindingId, DIAL_REGISTRY_LIMITS.BINDING_ID)) {
    return { ok: false, status: 400, error: 'bindingId must be a bounded base64url opaque id' };
  }
  if (!isOpaqueBase64Url(b.bindingRevision, DIAL_REGISTRY_LIMITS.BINDING_REVISION)) {
    return { ok: false, status: 400, error: 'bindingRevision must be a bounded base64url opaque id' };
  }
  return {
    ok: true,
    value: {
      registryVersion: DIAL_REGISTRY_VERSION,
      installationId: b.installationId,
      installationGeneration: b.installationGeneration,
      previousInstallationGeneration: b.previousInstallationGeneration,
      bindingId: b.bindingId,
      bindingRevision: b.bindingRevision,
      sessionId,
    },
  };
}

// ── dialPayloadV1 — the versioned, bounded APNs ring wire (spec v0.6 @ C:\tmp\dialPayloadV1-spec, Pulse SPEC +1) ──
// PushKit VoIP caps the ENTIRE push at 5120 bytes; we target our serialized payload at 5120 minus an envelope reserve.
export const DIAL_PUSHKIT_CAP = 5120;               // Apple PushKit VoIP total-payload hard cap (bytes)
const DIAL_ENVELOPE_RESERVE = 256;                  // headroom for the APNs aps envelope + framing wrapping our JSON
export const DIAL_PAYLOAD_MAX_BYTES = DIAL_PUSHKIT_CAP - DIAL_ENVELOPE_RESERVE; // 4864: budget our serialized payload fits under
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
const serializedBytes = (obj) => Buffer.byteLength(JSON.stringify(obj), 'utf8');

/**
 * Optional per-installation authorization proof. Legacy payload callers omit every field and remain byte-for-byte
 * unchanged. Once any field is present, the complete V2 tuple is mandatory; a partial tuple must never be downgraded
 * to a legacy push because the new app treats the tuple as its account-switch fence.
 */
function bindingProof(f) {
  const names = ['bindingVersion', 'bindingId', 'bindingRevision', 'installationGeneration'];
  if (!names.some((name) => f[name] !== undefined)) return {};
  if (f.bindingVersion !== DIAL_REGISTRY_VERSION) throw new Error(`dial: bindingVersion must be ${DIAL_REGISTRY_VERSION}`);
  if (!isOpaqueBase64Url(f.bindingId, DIAL_REGISTRY_LIMITS.BINDING_ID)) throw new Error('dial: bindingId invalid');
  if (!isOpaqueBase64Url(f.bindingRevision, DIAL_REGISTRY_LIMITS.BINDING_REVISION)) throw new Error('dial: bindingRevision invalid');
  if (parseGeneration(f.installationGeneration) === null) {
    throw new Error('dial: installationGeneration must be a canonical positive uint64 decimal string');
  }
  return {
    bindingVersion: DIAL_REGISTRY_VERSION,
    bindingId: f.bindingId,
    bindingRevision: f.bindingRevision,
    installationGeneration: f.installationGeneration,
  };
}

/**
 * Build the DialPayloadV1 the phone decodes. CORE (v/id/kind/priority/callerName/who/sessionId/checkpointId?/fetch/ts)
 * is always present + bounded (always fits). GOVERNED content (message/options/context/evidenceSeqs/confidence) is
 * included only when the whole payload fits DIAL_PAYLOAD_MAX_BYTES; else the deterministic RICH->LEAN ladder sheds it:
 *   fits -> fetch=false (complete, renderable)  |  drop confidence (non-governed) -> still fetch=false  |
 *   else fetch=true LEAN: ALL governed content dropped, core-only; phone hydrates via the authenticated GET (no partial-speak).
 * Identity is OPAQUE + FAIL-CLOSED (throws on blank/overbound/control; never truncated). A pickOption with no options is
 * malformed -> throws. `id` override (opaque) is used verbatim (signal-originated); absent -> computeDialId (legacy /dial).
 * @param {{humanId?, sessionId, message?, context?, priority?, who?, id?, kind?, callerName?, options?, checkpointId?, evidenceSeqs?, confidence?, bindingVersion?, bindingId?, bindingRevision?, installationGeneration?}} f
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
  const binding = bindingProof(f);

  const core = {
    v: 1, id, kind, priority, callerName, who, sessionId,
    ...binding,
    ...(checkpointId ? { checkpointId } : {}),
    fetch: false,
    ts,
  };
  // SECURITY (Warden push-model doorbell): a WRITE-KIND (decisionYours/pickOption/go) carries a governed decision the
  // push must not reveal — even post-scrub, "approve the wire to acct Y?" leaks a pending action to Apple/the notification
  // layer. So a write-kind is ALWAYS a LEAN doorbell: ALL governed content (message/options/context/evidenceSeqs/confidence)
  // is shed and hydrated only via the authed, membership-gated GET /dial?id=. This is unbypassable — the policy lives in the
  // wire builder keyed on kind, not on any caller flag. RICH (governed-in-push) stays available for info/checkpointReady only.
  // (Validation above still runs first, so a malformed write-kind still fails closed before it is shed to LEAN.)
  if (DIAL_WRITE_KINDS.has(kind)) return { ...core, fetch: true };
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
 * Wrap a DialPayloadV1 into the PKPushPayload.dictionaryPayload the deploy's apnsSend MUST deliver: the dial DTO fields at
 * the TOP LEVEL, with the APNs `aps` envelope as a SIBLING key — NEVER nesting the DTO under a payload/data wrapper. This is
 * the EXECUTABLE form of the load-bearing wire contract documented on app.mjs deps.apnsSend: SentiCallKit.receiveState reads
 * `dict["id"]`/who/callerName/… TOP-LEVEL and IGNORES `aps`; if the DTO is nested, top-level `id` is absent -> the decode
 * returns nil -> EVERY ring silently declines (a dead doorbell with green everything). A deploy apnsSend that delivers
 * `buildVoipPushDictionary(payload)` verbatim CANNOT get the envelope shape wrong — the one seam with zero in-repo coverage
 * (the gateway suite exercises a FAKE apnsSend that only captures `payload`, so it can't catch a real-transport nesting bug).
 * `aps` defaults to a minimal VoIP-safe envelope; a deploy may override/extend it (its content is ignored by the app decode).
 * @param {object} payload  the bare DialPayloadV1 from buildDialPayload
 * @param {object} [aps]     APNs `aps` envelope fields, merged over the default (its content is decode-irrelevant)
 * @returns {object} the dictionaryPayload delivered to the device: { ...payload (TOP-LEVEL), aps }
 */
export function buildVoipPushDictionary(payload, aps = {}) {
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) throw new Error('buildVoipPushDictionary: payload object required');
  if (typeof payload.id !== 'string' || payload.id.length === 0) throw new Error('buildVoipPushDictionary: payload.id (top-level identity) required — a nested/blank id is a dead ring');
  if (aps == null || typeof aps !== 'object' || Array.isArray(aps)) throw new Error('buildVoipPushDictionary: aps must be an object');
  // Dial DTO fields spread at the TOP LEVEL; `aps` a SIBLING (decode-ignored). The DTO is NEVER placed under a wrapper key.
  return { ...payload, aps: { ...aps } };
}

/**
 * The /dial/register handler logic over an injected deviceRegistry. Pure of transport: returns {status, body} so the
 * handlers.mjs wire is a thin adapter (auth + scope check, then call this). Kept OUT of handlers.mjs to avoid colliding
 * with warden's concurrent /dial route edits — the wire is a 3-line addition alongside his route.
 * @param {{ deviceRegistry?: {register?:Function, registerV2?:Function, unregisterV2?:Function, lookup?:Function}, now?: ()=>number }} deps
 */
export function createDialRegistry({ deviceRegistry, now } = {}) {
  const clock = typeof now === 'function' ? now : () => Date.now();
  const writeFailure = (error) => {
    if (error && Number.isInteger(error.registryStatus) && typeof error.registryReason === 'string') {
      return {
        status: error.registryStatus,
        body: { error: error.registryMessage || 'registry request rejected', reason: error.registryReason },
      };
    }
    return { status: 502, body: { error: 'registry write failed', reason: 'registry-write-failed' } };
  };
  return {
    /**
     * @param {{ humanId:string, principal?:string, body:object, isMember:(sessionId:string)=>Promise<boolean> }} args
     * @returns {Promise<{status:number, body:object}>}
     */
    async register({ humanId, principal, body, isMember } = {}) {
      const v = validateRegistration(body);
      if (!v.ok) return { status: v.status, body: { error: v.error } };
      const isV2 = v.value.registryVersion === DIAL_REGISTRY_VERSION;
      const register = isV2 ? deviceRegistry?.registerV2 : deviceRegistry?.register;
      if (typeof register !== 'function') {
        return { status: 501, body: { error: 'dial registry not configured', reason: 'dial-not-configured' } };
      }
      let member = false;
      try { member = await isMember(v.value.sessionId); }
      catch { return { status: 500, body: { error: 'authorization lookup failed' } }; }
      if (!member) return { status: 403, body: { error: 'not a known session for this user' } };
      let res;
      try {
        res = await register.call(deviceRegistry, {
          humanId, principal, sessionId: v.value.sessionId, voipToken: v.value.voipToken, platform: v.value.platform,
          ...(isV2 ? {
            registryVersion: DIAL_REGISTRY_VERSION,
            installationId: v.value.installationId,
            installationGeneration: v.value.installationGeneration,
          } : {}),
          registeredAt: new Date(clock()).toISOString(),
        });
      } catch (error) { return writeFailure(error); }
      if (isV2) {
        if (!res ||
            !isOpaqueBase64Url(res.bindingId, DIAL_REGISTRY_LIMITS.BINDING_ID) ||
            !isOpaqueBase64Url(res.bindingRevision, DIAL_REGISTRY_LIMITS.BINDING_REVISION) ||
            res.installationGeneration !== v.value.installationGeneration ||
            !Number.isSafeInteger(res.leaseExpiresAtSec) ||
            res.leaseExpiresAtSec <= Math.floor(clock() / 1000)) {
          return { status: 502, body: { error: 'registry returned an invalid V2 binding', reason: 'registry-invalid-binding' } };
        }
        return {
          status: 200,
          body: {
            registered: true,
            registryVersion: DIAL_REGISTRY_VERSION,
            sessionId: v.value.sessionId,
            platform: v.value.platform,
            installationGeneration: res.installationGeneration,
            bindingId: res.bindingId,
            bindingRevision: res.bindingRevision,
            leaseExpiresAtSec: res.leaseExpiresAtSec,
            deviceCount: Number.isFinite(res.deviceCount) ? res.deviceCount : undefined,
          },
        };
      }
      return {
        status: 200,
        body: { registered: true, sessionId: v.value.sessionId, platform: v.value.platform, deviceCount: (res && Number.isFinite(res.deviceCount)) ? res.deviceCount : undefined },
      };
    },
    /**
     * Conditional, generation-advancing revocation. Membership is intentionally not required: an authenticated former
     * member must still be able to revoke its own exact binding after room access disappears. The verified humanId plus
     * prior binding proof are the authorization boundary, and every outcome has the same idempotent response.
     */
    async unregister({ humanId, principal, body } = {}) {
      const v = validateUnregistration(body);
      if (!v.ok) return { status: v.status, body: { error: v.error } };
      if (!deviceRegistry || typeof deviceRegistry.unregisterV2 !== 'function') {
        return { status: 501, body: { error: 'dial registry not configured', reason: 'dial-not-configured' } };
      }
      try {
        await deviceRegistry.unregisterV2({ humanId, principal, ...v.value });
      } catch (error) {
        // A stale compare-delete is deliberately idempotent and non-oracular. Only backend availability/configuration
        // faults escape from the default registry; custom adapters may use the typed status channel.
        const failure = writeFailure(error);
        if (failure.status === 409) return { status: 200, body: { unregistered: true } };
        return failure;
      }
      return { status: 200, body: { unregistered: true } };
    },
    buildPayload: (fields) => buildDialPayload(fields, clock()),
    now: clock,
  };
}

/**
 * The registry-backed pushBackend IMPL that warden's POST /dial calls. Matches his exact contract:
 *   pushBackend({message, context, priority, sessionId, humanId, principal?}) -> {dispatched, dialId?, reason?}
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
  return async function pushBackend({ message, context, priority, sessionId, humanId, principal, id, kind, callerName, options, checkpointId, evidenceSeqs, confidence, storedSignal } = {}) {
    if (!deviceRegistry || typeof deviceRegistry.lookup !== 'function') return { dispatched: false, reason: 'dial-not-configured' };
    let devices;
    try { devices = await deviceRegistry.lookup({ humanId, principal, sessionId, limit: cap }); }
    catch { return { dispatched: false, reason: 'registry-lookup-failed' }; }
    const normalized = (Array.isArray(devices) ? devices : []).filter((d) => {
      if (!d || typeof d.voipToken !== 'string' || !d.voipToken) return false;
      if (d.registryVersion === DIAL_REGISTRY_VERSION) {
        return isOpaqueBase64Url(d.bindingId, DIAL_REGISTRY_LIMITS.BINDING_ID) &&
          isOpaqueBase64Url(d.bindingRevision, DIAL_REGISTRY_LIMITS.BINDING_REVISION) &&
          parseGeneration(d.installationGeneration) !== null &&
          typeof d.installationHash === 'string' && d.installationHash.length > 0;
      }
      // Legacy is an explicit migration lane. A partial V2 tuple must never silently downgrade to legacy.
      return (d.registryVersion === undefined || d.registryVersion === 1) &&
        d.bindingId === undefined && d.bindingRevision === undefined && d.installationGeneration === undefined;
    });
    // Prefer the V2 row when a migration lookup returns the same token in both lanes. Then dedupe so a re-login or
    // stale V1 record can never double-ring one physical token.
    normalized.sort((a, b) => Number(b.registryVersion === DIAL_REGISTRY_VERSION) - Number(a.registryVersion === DIAL_REGISTRY_VERSION));
    const seenTokens = new Set();
    devices = normalized.filter((d) => !seenTokens.has(d.voipToken) && seenTokens.add(d.voipToken)).slice(0, cap);
    if (devices.length === 0) return { dispatched: false, reason: 'no-device-token' };
    if (typeof apnsSend !== 'function') return { dispatched: false, reason: 'push-transport-not-configured' };
    const payloadNow = clock();
    let deliveries;
    // A V2 authorization proof is PER INSTALLATION, so payloads are built per device from one captured timestamp. Legacy
    // rows omit the proof and preserve the existing fixture bytes. All payloads still share the exact same dial id.
    try {
      deliveries = devices.map((device) => ({
        device,
        payload: buildDialPayload({
          // The generated dial id is durable signal-store identity, so namespace it by the same full principal as the
          // target index. Membership remains humanId-based; two sites sharing that humanId must not collide here.
          humanId: principal || humanId,
          sessionId,
          message,
          context,
          priority,
          id,
          kind,
          callerName,
          options,
          checkpointId,
          evidenceSeqs,
          confidence,
          ...(device.registryVersion === DIAL_REGISTRY_VERSION ? {
            bindingVersion: DIAL_REGISTRY_VERSION,
            bindingId: device.bindingId,
            bindingRevision: device.bindingRevision,
            installationGeneration: device.installationGeneration,
          } : {}),
        }, payloadNow),
      }));
    }
    catch { return { dispatched: false, reason: 'invalid-dial-payload' }; } // fail-closed: blank/overbound/control identity never rings
    const payload = deliveries[0].payload;
    // HYDRATION store-write (PR-B2): persist the full signal so the phone can GET /dial?id= it. A LEAN ring shed ALL
    // governed content -> it MUST hydrate -> FAIL CLOSED if it can't persist (never a dead doorbell); a RICH ring is
    // self-contained -> best-effort (a GET-consistency/audit copy). Written AFTER all pre-ring checks so a ring that will
    // never fire leaves no orphan record; written BEFORE fan-out so a LEAN ring never reaches the phone unhydratable.
    if (storedSignal !== undefined) {
      const lean = deliveries.some((delivery) => delivery.payload.fetch === true);
      if (!signalStore || typeof signalStore.put !== 'function') {
        if (lean) return { dispatched: false, reason: 'signal-store-not-configured' };
      } else {
        try { await signalStore.put(payload.id, storedSignal); }
        catch { if (lean) return { dispatched: false, reason: 'signal-store-write-failed' }; }
      }
    }
    // Fan out; dispatched iff AT LEAST ONE device acked. Per-device failure is isolated (one dead token never fails the ring).
    // WIRE CONTRACT (deploy-owned apnsSend): `payload` is the BARE dial DTO — the injected apnsSend MUST deliver its fields
    // at the TOP LEVEL of the device's PKPushPayload.dictionaryPayload (alongside `aps`), NOT nested under a `payload`/`data`
    // key. The app reads id/kind/… top-level; nesting => top-level `id` absent => every ring decodes .rejected, silently.
    // See app.mjs deps.apnsSend JSDoc + part-b criterion #6 (app-side enveloped round-trip test).
    let delivered = 0;
    let currentDevices = 0;
    for (const delivery of deliveries) {
      const d = delivery.device;
      // Narrow the lookup→send window. The app's exact binding-proof comparison remains the final fence if a rebind
      // wins after this check but before APNs delivery.
      if (typeof deviceRegistry.revalidate === 'function') {
        try {
          if (!await deviceRegistry.revalidate({ humanId, principal, sessionId, device: d })) continue;
        } catch { continue; }
      }
      currentDevices += 1;
      try {
        const r = await apnsSend({ voipToken: d.voipToken, platform: d.platform || 'apns', payload: delivery.payload });
        if (r && r.delivered) delivered += 1;
      }
      catch { /* isolated: continue to the next device */ }
    }
    return delivered > 0
      ? { dispatched: true, dialId: payload.id, delivered, devices: devices.length }
      : {
          dispatched: false,
          reason: currentDevices === 0 ? 'stale-device-binding' : 'all-deliveries-failed',
          dialId: payload.id,
          devices: devices.length,
        };
  };
}

/**
 * V1 remains a bounded migration lane, but it must use the same full-principal authority boundary as V2. Historical
 * `dial:dev:*` rows had no site/principal tag and are intentionally not read: accepting one under an arbitrary current
 * principal would let equal pairwise human IDs at two sites ring each other's devices.
 */
const legacyTargetAuthority = (humanId, principal) =>
  typeof principal === 'string' && principal ? principal : String(humanId ?? '');
const LEGACY_DEVICE_KEY = (humanId, principal, sessionId) => {
  const authority = legacyTargetAuthority(humanId, principal);
  return `dial:v1:dev:${utf8(authority)}:${authority}:${sessionId ?? ''}`;
};

/**
 * Store-backed registry with an explicit migration boundary:
 *   - V1 remains a one-record, expiring compatibility lane and never emits V2 authorization metadata.
 *   - V2 owns one DURABLE monotonic head per physical installation, one generation-specific expiring lease, a bounded
 *     CAS-maintained candidate index per full-principal/session target, and one topic/environment-scoped token claim.
 *
 * The durable head is the security authority. `advanceGeneration` is an atomic conditional put, so a delayed principal
 * A registration can never overwrite principal B's higher generation. Leases use generation-specific keys, so even a
 * worker that stalled before B and resumes after B cannot overwrite B's token. Lookup validates index -> head -> exact
 * lease every time; stale index entries are only availability debris and are compacted by CAS. Unregister advances the
 * head to a durable tombstone before deleting anything, so a delayed register cannot resurrect the old lease.
 *
 * A short two-phase preparation reserves target capacity and token ownership before the head changes. Installation,
 * principal target, and scoped token keys are server-HMACed; raw identifiers never appear in V2 keys. APNs tokens
 * remain only in expiring lease values and are never returned by registration or logged here.
 *
 * @param {{
 *   store: {get:Function, put:Function, delete?:Function, advanceGeneration?:Function, compareAndSwap?:Function},
 *   now?: ()=>number,
 *   installationHmacKey?: string|Buffer|Uint8Array,
 *   tokenScope?: string,
 *   leaseSeconds?: number,
 *   reservationSeconds?: number,
 *   legacyGraceSeconds?: number,
 *   maxDevices?: number,
 *   allowLegacyRegistration?: boolean,
 *   readLegacy?: boolean,
 * }} cfg
 */
export function createStoreDeviceRegistry({
  store,
  now = () => Date.now(),
  installationHmacKey,
  tokenScope = 'default',
  leaseSeconds = DIAL_REGISTRY_LIMITS.DEFAULT_LEASE_SECONDS,
  reservationSeconds = DIAL_REGISTRY_LIMITS.DEFAULT_RESERVATION_SECONDS,
  legacyGraceSeconds = DIAL_REGISTRY_LIMITS.DEFAULT_LEASE_SECONDS,
  maxDevices = DIAL_REGISTRY_LIMITS.DEFAULT_MAX_DEVICES,
  allowLegacyRegistration = true,
  readLegacy = true,
} = {}) {
  if (!store || typeof store.get !== 'function' || typeof store.put !== 'function') {
    throw new Error('createStoreDeviceRegistry requires a { get, put } store');
  }
  const clock = typeof now === 'function' ? now : () => Date.now();
  const leaseTtl = Number.isSafeInteger(leaseSeconds) && leaseSeconds > 0 ? leaseSeconds : DIAL_REGISTRY_LIMITS.DEFAULT_LEASE_SECONDS;
  const reservationTtl = Number.isSafeInteger(reservationSeconds) && reservationSeconds > 0
    ? reservationSeconds
    : DIAL_REGISTRY_LIMITS.DEFAULT_RESERVATION_SECONDS;
  const legacyTtl = Number.isSafeInteger(legacyGraceSeconds) && legacyGraceSeconds > 0 ? legacyGraceSeconds : leaseTtl;
  const deviceCap = Number.isSafeInteger(maxDevices) && maxDevices > 0 ? maxDevices : DIAL_REGISTRY_LIMITS.DEFAULT_MAX_DEVICES;
  const nowSec = () => Math.floor(clock() / 1000);
  const fault = (status, reason, message) => Object.assign(new Error(message), {
    registryStatus: status,
    registryReason: reason,
    registryMessage: message,
  });
  const legacyIsActive = (record, atSec) => {
    if (!record || typeof record.voipToken !== 'string' || !record.voipToken) return false;
    if (Number.isSafeInteger(record.expiresAtSec)) return record.expiresAtSec > atSec;
    const registeredMs = Date.parse(record.registeredAt);
    return Number.isFinite(registeredMs) && Math.floor(registeredMs / 1000) + legacyTtl > atSec;
  };
  const registry = {
    async register({ humanId, principal, sessionId, voipToken, platform, registeredAt } = {}) {
      if (!allowLegacyRegistration) throw fault(426, 'registry-v2-required', 'this deployment requires device registry V2');
      const expiresAtSec = nowSec() + legacyTtl;
      const authority = legacyTargetAuthority(humanId, principal);
      // atomic full-item put: no read-modify-write, so two concurrent registers for the same (human,session) can't lose
      // an update. This is explicitly the V1 migration lane; it never gains a binding proof.
      await store.put(LEGACY_DEVICE_KEY(humanId, principal, sessionId), {
        principal: authority,
        voipToken,
        platform: platform || 'apns',
        registeredAt: registeredAt || new Date(clock()).toISOString(),
        expiresAtSec,
      }, { ttlEpochSec: expiresAtSec });
      return { deviceCount: 1 };
    },
    async lookup({ humanId, principal, sessionId, limit = deviceCap } = {}) {
      const cap = Number.isSafeInteger(limit) && limit > 0 ? Math.min(limit, deviceCap) : deviceCap;
      const rows = [];
      if (readLegacy && rows.length < cap) {
        const authority = legacyTargetAuthority(humanId, principal);
        const d = await store.get(LEGACY_DEVICE_KEY(humanId, principal, sessionId));
        if (d?.principal === authority && legacyIsActive(d, nowSec())) {
          rows.push({ voipToken: d.voipToken, platform: d.platform || 'apns' });
        }
      }
      return rows;
    },
    async revalidate({ humanId, principal, sessionId, device } = {}) {
      if (device?.registryVersion === DIAL_REGISTRY_VERSION) return false;
      const authority = legacyTargetAuthority(humanId, principal);
      const current = await store.get(LEGACY_DEVICE_KEY(humanId, principal, sessionId));
      return current?.principal === authority &&
        legacyIsActive(current, nowSec()) &&
        current.voipToken === device?.voipToken &&
        (current.platform || 'apns') === (device?.platform || 'apns');
    },
  };

  if (installationHmacKey === undefined || installationHmacKey === null || installationHmacKey === '') return registry;
  const hmacKey = Buffer.isBuffer(installationHmacKey)
    ? Buffer.from(installationHmacKey)
    : installationHmacKey instanceof Uint8Array
      ? Buffer.from(installationHmacKey)
      : Buffer.from(String(installationHmacKey), 'utf8');
  if (hmacKey.length < 32) throw new Error('createStoreDeviceRegistry: installationHmacKey must contain at least 32 bytes');
  if (typeof tokenScope !== 'string' || !tokenScope.trim() || utf8(tokenScope) > 256) {
    throw new Error('createStoreDeviceRegistry: tokenScope must be a non-empty bounded APNs topic/environment namespace');
  }
  if (typeof store.delete !== 'function' ||
      typeof store.advanceGeneration !== 'function' ||
      typeof store.compareAndSwap !== 'function') {
    throw new Error('createStoreDeviceRegistry V2 requires store { delete, advanceGeneration, compareAndSwap } atomic primitives');
  }

  const lp = (s) => { const v = String(s ?? ''); return `${utf8(v)}:${v}`; };
  const digest = (domain, ...parts) =>
    b64url(createHmac('sha256', hmacKey).update(`${lp(domain)}|${parts.map(lp).join('|')}`, 'utf8').digest());
  const installationHashFor = (installationId) => digest('installation', installationId);
  const targetAuthorityFor = (humanId, principal) =>
    typeof principal === 'string' && principal ? principal : humanId;
  const targetHashFor = (humanId, principal, sessionId) =>
    digest('target', targetAuthorityFor(humanId, principal), sessionId);
  const tokenHashFor = (platform, token) =>
    digest('token', tokenScope.trim(), platform || 'apns', token);
  const bindingDigestFor = ({ generation, targetHash, tokenHash, platform }) =>
    digest('binding', generation, targetHash, tokenHash, platform || 'apns');
  const tombstoneDigestFor = ({ generation, previousGeneration, targetHash, bindingId, bindingRevision }) =>
    digest('unregister', generation, previousGeneration, targetHash, bindingId, bindingRevision);
  const randomOpaque = (bytes = 24) => b64url(randomBytes(bytes));
  const HEAD_KEY = (installationHash) => `dial:v2:head:${installationHash}`;
  const PREPARATION_KEY = (installationHash) => `dial:v2:prepare:${installationHash}`;
  const LEASE_KEY = (installationHash, generation) => `dial:v2:lease:${installationHash}:${generation}`;
  const INDEX_KEY = (targetHash) => `dial:v2:index:${targetHash}`;
  const TOKEN_CLAIM_KEY = (tokenHash) => `dial:v2:token:${tokenHash}`;
  const validHead = (head) =>
    head && head.schemaVersion === DIAL_REGISTRY_VERSION &&
    parseGeneration(head.generation) !== null &&
    head.generationOrder === generationOrder(head.generation) &&
    (head.operation === 'register' || head.operation === 'unregister');
  const sameHead = (a, b) =>
    validHead(a) && validHead(b) &&
    a.generation === b.generation &&
    a.operation === b.operation &&
    a.bindingDigest === b.bindingDigest &&
    a.bindingId === b.bindingId &&
    a.bindingRevision === b.bindingRevision;
  const validProofDescriptor = (value) =>
    value && value.schemaVersion === DIAL_REGISTRY_VERSION &&
    typeof value.installationHash === 'string' && value.installationHash &&
    parseGeneration(value.generation) !== null &&
    value.generationOrder === generationOrder(value.generation) &&
    isOpaqueBase64Url(value.targetHash, 128) &&
    isOpaqueBase64Url(value.tokenHash, 128) &&
    typeof value.platform === 'string' && DIAL_PLATFORMS.includes(value.platform) &&
    isOpaqueBase64Url(value.bindingDigest, 128) &&
    isOpaqueBase64Url(value.bindingId, DIAL_REGISTRY_LIMITS.BINDING_ID) &&
    isOpaqueBase64Url(value.bindingRevision, DIAL_REGISTRY_LIMITS.BINDING_REVISION) &&
    Number.isSafeInteger(value.expiresAtSec) && value.expiresAtSec > 0;
  const sameProofDescriptor = (a, b) =>
    validProofDescriptor(a) && validProofDescriptor(b) &&
    a.installationHash === b.installationHash &&
    a.generation === b.generation &&
    a.targetHash === b.targetHash &&
    a.tokenHash === b.tokenHash &&
    a.platform === b.platform &&
    a.bindingDigest === b.bindingDigest &&
    a.bindingId === b.bindingId &&
    a.bindingRevision === b.bindingRevision;
  const validPreparation = (value) =>
    validProofDescriptor(value) &&
    typeof value.recordVersion === 'string' &&
    /^[1-9][0-9]{0,19}$/.test(value.recordVersion);
  const validTokenClaim = (value) =>
    value && value.schemaVersion === DIAL_REGISTRY_VERSION &&
    typeof value.recordVersion === 'string' &&
    /^[1-9][0-9]{0,19}$/.test(value.recordVersion) &&
    (value.active === null || validProofDescriptor(value.active)) &&
    (value.pending === null || validProofDescriptor(value.pending));
  const validIndex = (value) =>
    value && value.schemaVersion === DIAL_REGISTRY_VERSION &&
    typeof value.recordVersion === 'string' &&
    /^[1-9][0-9]{0,19}$/.test(value.recordVersion) &&
    Array.isArray(value.installationHashes);

  async function activeV2Binding(installationHash, targetHash, atSec = nowSec()) {
    const head = await store.get(HEAD_KEY(installationHash));
    if (!validHead(head) ||
        head.operation !== 'register' ||
        head.targetHash !== targetHash ||
        !isOpaqueBase64Url(head.tokenHash, 128) ||
        typeof head.platform !== 'string' ||
        !DIAL_PLATFORMS.includes(head.platform) ||
        !isOpaqueBase64Url(head.bindingDigest, 128) ||
        !isOpaqueBase64Url(head.bindingId, DIAL_REGISTRY_LIMITS.BINDING_ID) ||
        !isOpaqueBase64Url(head.bindingRevision, DIAL_REGISTRY_LIMITS.BINDING_REVISION)) return null;
    const lease = await store.get(LEASE_KEY(installationHash, head.generation));
    if (!lease ||
        lease.schemaVersion !== DIAL_REGISTRY_VERSION ||
        lease.installationHash !== installationHash ||
        lease.targetHash !== targetHash ||
        lease.generation !== head.generation ||
        lease.bindingId !== head.bindingId ||
        lease.bindingRevision !== head.bindingRevision ||
        lease.bindingDigest !== head.bindingDigest ||
        lease.tokenHash !== head.tokenHash ||
        lease.platform !== head.platform ||
        !Number.isSafeInteger(lease.expiresAtSec) ||
        lease.expiresAtSec <= atSec ||
        typeof lease.voipToken !== 'string' ||
        !lease.voipToken) return null;
    const tokenClaim = await store.get(TOKEN_CLAIM_KEY(head.tokenHash));
    if (!validTokenClaim(tokenClaim) ||
        !tokenClaim.active ||
        tokenClaim.active.expiresAtSec <= atSec ||
        tokenClaim.active.installationHash !== installationHash ||
        tokenClaim.active.generation !== head.generation ||
        tokenClaim.active.targetHash !== targetHash ||
        tokenClaim.active.tokenHash !== head.tokenHash ||
        tokenClaim.active.bindingDigest !== head.bindingDigest ||
        tokenClaim.active.bindingId !== head.bindingId ||
        tokenClaim.active.bindingRevision !== head.bindingRevision) return null;
    return {
      registryVersion: DIAL_REGISTRY_VERSION,
      installationHash,
      installationGeneration: head.generation,
      bindingId: head.bindingId,
      bindingRevision: head.bindingRevision,
      voipToken: lease.voipToken,
      platform: lease.platform || 'apns',
      expiresAtSec: lease.expiresAtSec,
    };
  }

  const nextRecordVersion = (current) => {
    const n = current === null ? 1n : BigInt(current) + 1n;
    if (n > MAX_UINT64) throw fault(503, 'registry-index-exhausted', 'registry index version exhausted');
    return n.toString();
  };

  async function prepareRegistration({
    installationHash,
    generation,
    targetHash,
    tokenHash,
    platform,
  }) {
    const bindingDigest = bindingDigestFor({ generation, targetHash, tokenHash, platform });
    for (let attempt = 0; attempt < 12; attempt += 1) {
      const head = await store.get(HEAD_KEY(installationHash));
      if (head !== undefined && !validHead(head)) {
        throw fault(503, 'registry-head-corrupt', 'installation head is corrupt');
      }
      let installedProof = null;
      if (head) {
        const requested = parseGeneration(generation);
        const installed = parseGeneration(head.generation);
        if (requested < installed) {
          throw fault(409, 'binding-superseded', 'a newer installation generation is already active');
        }
        if (requested === installed) {
          if (head.operation !== 'register' || head.bindingDigest !== bindingDigest) {
            throw fault(409, 'binding-generation-conflict', 'this installation generation is already bound to different authority');
          }
          installedProof = head;
        }
      }

      const current = await store.get(PREPARATION_KEY(installationHash));
      if (current !== undefined && !validPreparation(current)) {
        throw fault(503, 'registry-preparation-corrupt', 'installation preparation is corrupt');
      }
      if (current) {
        const requested = parseGeneration(generation);
        const prepared = parseGeneration(current.generation);
        if (requested < prepared) {
          throw fault(409, 'binding-superseded', 'a newer installation generation is already prepared');
        }
        if (requested === prepared && current.bindingDigest !== bindingDigest) {
          throw fault(409, 'binding-generation-conflict', 'this installation generation is prepared for different authority');
        }
      }

      const expectedVersion = current === undefined ? null : current.recordVersion;
      const reuse = installedProof || (
        current &&
        current.generation === generation &&
        current.bindingDigest === bindingDigest
          ? current
          : null
      );
      const next = {
        schemaVersion: DIAL_REGISTRY_VERSION,
        recordVersion: nextRecordVersion(expectedVersion),
        installationHash,
        generation,
        generationOrder: generationOrder(generation),
        targetHash,
        tokenHash,
        platform,
        bindingDigest,
        bindingId: reuse?.bindingId || randomOpaque(18),
        bindingRevision: reuse?.bindingRevision || randomOpaque(24),
        expiresAtSec: nowSec() + reservationTtl,
      };
      const result = await store.compareAndSwap(
        PREPARATION_KEY(installationHash),
        expectedVersion,
        next
      );
      if (result?.swapped) return next;
    }
    throw fault(503, 'registry-preparation-busy', 'installation preparation is busy; retry');
  }

  async function currentPreparationMatches(expected) {
    const current = await store.get(PREPARATION_KEY(expected.installationHash));
    return validPreparation(current) &&
      current.expiresAtSec > nowSec() &&
      sameProofDescriptor(current, expected);
  }

  async function reserveTokenClaim(preparation) {
    const key = TOKEN_CLAIM_KEY(preparation.tokenHash);
    for (let attempt = 0; attempt < 12; attempt += 1) {
      const current = await store.get(key);
      if (current !== undefined && !validTokenClaim(current)) {
        throw fault(503, 'registry-token-claim-corrupt', 'device token claim is corrupt');
      }
      const atSec = nowSec();
      const active = current?.active?.expiresAtSec > atSec ? current.active : null;
      const pending = current?.pending?.expiresAtSec > atSec ? current.pending : null;
      for (const owner of [active, pending]) {
        if (!owner) continue;
        if (owner.installationHash !== preparation.installationHash) {
          throw fault(409, 'device-token-claimed', 'this device token is already owned by another installation');
        }
        const requested = parseGeneration(preparation.generation);
        const owned = parseGeneration(owner.generation);
        if (requested < owned) {
          throw fault(409, 'binding-superseded', 'a newer installation generation already owns this device token');
        }
        if (requested === owned && owner.bindingDigest !== preparation.bindingDigest) {
          throw fault(409, 'binding-generation-conflict', 'this generation already claims the device token for different authority');
        }
      }
      const expectedVersion = current === undefined ? null : current.recordVersion;
      const next = {
        schemaVersion: DIAL_REGISTRY_VERSION,
        recordVersion: nextRecordVersion(expectedVersion),
        active,
        pending: { ...preparation },
      };
      const result = await store.compareAndSwap(key, expectedVersion, next);
      if (result?.swapped) return next;
    }
    throw fault(503, 'registry-token-claim-busy', 'device token claim is busy; retry');
  }

  async function reserveTokenOrRollbackIndex(preparation) {
    try {
      return await reserveTokenClaim(preparation);
    } catch (error) {
      // A synchronous second-phase loser must not consume an otherwise empty target slot for the full reservation TTL.
      // Cleanup is fenced: removeStaleIndexCandidate retains an active same-installation binding and any different
      // live preparation record (including an exact same-generation sibling), so this request cannot erase authority
      // that won or is still completing after its index reservation.
      await removeStaleIndexCandidate(
        preparation.targetHash,
        preparation.installationHash,
        preparation.generation,
        preparation
      );
      throw error;
    }
  }

  async function activateTokenClaim(preparation, expiresAtSec) {
    const key = TOKEN_CLAIM_KEY(preparation.tokenHash);
    for (let attempt = 0; attempt < 12; attempt += 1) {
      const current = await store.get(key);
      if (!validTokenClaim(current)) {
        throw fault(503, 'registry-token-claim-lost', 'device token reservation was lost');
      }
      const activeMatches = current.active && sameProofDescriptor(current.active, preparation);
      const pendingMatches = current.pending &&
        current.pending.expiresAtSec > nowSec() &&
        sameProofDescriptor(current.pending, preparation);
      if (!activeMatches && !pendingMatches) {
        throw fault(409, 'device-token-claimed', 'device token ownership changed before activation');
      }
      const next = {
        schemaVersion: DIAL_REGISTRY_VERSION,
        recordVersion: nextRecordVersion(current.recordVersion),
        active: { ...preparation, expiresAtSec },
        pending: null,
      };
      const result = await store.compareAndSwap(key, current.recordVersion, next);
      if (result?.swapped) return next;
    }
    throw fault(503, 'registry-token-claim-busy', 'device token activation is busy; retry');
  }

  async function releaseTokenClaim(expected) {
    if (!expected || !isOpaqueBase64Url(expected.tokenHash, 128)) return;
    const key = TOKEN_CLAIM_KEY(expected.tokenHash);
    for (let attempt = 0; attempt < 12; attempt += 1) {
      const current = await store.get(key);
      if (current === undefined) return;
      if (!validTokenClaim(current)) return;
      if (!current.active ||
          current.active.installationHash !== expected.installationHash ||
          current.active.generation !== expected.generation ||
          current.active.targetHash !== expected.targetHash ||
          current.active.bindingId !== expected.bindingId ||
          current.active.bindingRevision !== expected.bindingRevision) return;
      const next = {
        schemaVersion: DIAL_REGISTRY_VERSION,
        recordVersion: nextRecordVersion(current.recordVersion),
        active: null,
        pending: current.pending,
      };
      const result = await store.compareAndSwap(key, current.recordVersion, next);
      if (result?.swapped) return;
    }
  }

  async function legacyTokenMigrated(platform, token) {
    const claim = await store.get(TOKEN_CLAIM_KEY(tokenHashFor(platform, token)));
    // A durable claim record is also the migration fence. Corruption fails closed instead of reviving V1.
    return claim !== undefined;
  }

  /**
   * CAS loop over a bounded candidate set. It validates each candidate through the durable head + exact lease, so
   * physical Dynamo TTL lag and stale index writes never authorize a push.
   */
  async function mutateIndex(targetHash, mutation) {
    const key = INDEX_KEY(targetHash);
    for (let attempt = 0; attempt < 12; attempt += 1) {
      const current = await store.get(key);
      if (current !== undefined && !validIndex(current)) {
        throw fault(503, 'registry-index-corrupt', 'registry index is corrupt');
      }
      const expectedVersion = current === undefined ? null : current.recordVersion;
      const boundedHashes = [];
      const seen = new Set();
      for (const candidate of (current?.installationHashes || [])) {
        if (boundedHashes.length >= deviceCap || typeof candidate !== 'string' || seen.has(candidate)) continue;
        seen.add(candidate);
        boundedHashes.push(candidate);
      }
      const candidates = [];
      for (const installationHash of boundedHashes) {
        const row = await activeV2Binding(installationHash, targetHash);
        if (row) {
          candidates.push(row);
          continue;
        }
        const preparation = await store.get(PREPARATION_KEY(installationHash));
        if (validPreparation(preparation) &&
            preparation.targetHash === targetHash &&
            preparation.expiresAtSec > nowSec()) {
          candidates.push({ installationHash, reserved: true, preparation });
        }
      }
      const nextHashes = await mutation(candidates);
      const unique = [];
      const nextSeen = new Set();
      for (const installationHash of nextHashes) {
        if (unique.length >= deviceCap || typeof installationHash !== 'string' || nextSeen.has(installationHash)) continue;
        nextSeen.add(installationHash);
        unique.push(installationHash);
      }
      const next = {
        schemaVersion: DIAL_REGISTRY_VERSION,
        recordVersion: nextRecordVersion(expectedVersion),
        installationHashes: unique,
      };
      const result = await store.compareAndSwap(key, expectedVersion, next);
      if (result?.swapped) return unique;
    }
    throw fault(503, 'registry-index-busy', 'registry index is busy; retry');
  }

  async function reserveIndexSlot(targetHash, installationHash, preparation) {
    return mutateIndex(targetHash, async (candidates) => {
      if (!await currentPreparationMatches(preparation)) {
        throw fault(409, 'binding-superseded', 'a newer installation binding superseded this request');
      }
      const others = candidates.filter((row) => row.installationHash !== installationHash);
      if (others.length >= deviceCap) {
        throw fault(409, 'device-cap-reached', `target already has ${deviceCap} active or reserved devices`);
      }
      return [installationHash, ...others.map((row) => row.installationHash)];
    });
  }

  async function removeStaleIndexCandidate(
    targetHash,
    installationHash,
    throughGeneration = null,
    rollbackPreparation = null
  ) {
    try {
      await mutateIndex(targetHash, async (candidates) => {
        // A stale unregister may name the same human/session now owned by a newer generation. Never remove that newer
        // binding's candidate; compare-delete applies to the index as well as the durable head.
        const stillCurrent = await activeV2Binding(installationHash, targetHash);
        const preparation = await store.get(PREPARATION_KEY(installationHash));
        const hasNewerPreparation = validPreparation(preparation) &&
          preparation.targetHash === targetHash &&
          preparation.expiresAtSec > nowSec() &&
          throughGeneration !== null &&
          parseGeneration(preparation.generation) > parseGeneration(throughGeneration);
        const hasSiblingPreparation = validPreparation(preparation) &&
          preparation.targetHash === targetHash &&
          preparation.expiresAtSec > nowSec() &&
          rollbackPreparation !== null &&
          (
            preparation.recordVersion !== rollbackPreparation.recordVersion ||
            !sameProofDescriptor(preparation, rollbackPreparation)
          );
        return candidates
          .filter((row) =>
            row.installationHash !== installationHash ||
            stillCurrent ||
            hasNewerPreparation ||
            hasSiblingPreparation
          )
          .map((row) => row.installationHash);
      });
    } catch {
      // Candidate entries are never authoritative. A failed cleanup cannot re-authorize a stale head/lease and the next
      // lookup or mutation validates them again.
    }
  }

  async function installPreparedHead(preparation) {
    for (let attempt = 0; attempt < 8; attempt += 1) {
      const current = await store.get(HEAD_KEY(preparation.installationHash));
      if (current !== undefined && !validHead(current)) throw fault(503, 'registry-head-corrupt', 'installation head is corrupt');
      if (current) {
        const requested = parseGeneration(preparation.generation);
        const installed = parseGeneration(current.generation);
        if (requested < installed) throw fault(409, 'binding-superseded', 'a newer installation generation is already active');
        if (requested === installed) {
          if (current.operation === 'register' &&
              current.bindingDigest === preparation.bindingDigest &&
              current.bindingId === preparation.bindingId &&
              current.bindingRevision === preparation.bindingRevision) {
            return { head: current, priorHead: current };
          }
          throw fault(409, 'binding-generation-conflict', 'this installation generation is already bound to different authority');
        }
      }
      const next = {
        schemaVersion: DIAL_REGISTRY_VERSION,
        generation: preparation.generation,
        generationOrder: generationOrder(preparation.generation),
        operation: 'register',
        targetHash: preparation.targetHash,
        tokenHash: preparation.tokenHash,
        platform: preparation.platform,
        bindingDigest: preparation.bindingDigest,
        bindingId: preparation.bindingId,
        bindingRevision: preparation.bindingRevision,
      };
      const result = await store.advanceGeneration(HEAD_KEY(preparation.installationHash), next);
      if (result?.advanced) return { head: next, priorHead: current };
      // Another writer won between get and the conditional put. Loop and classify its durable head.
    }
    throw fault(503, 'registry-head-busy', 'installation head is busy; retry');
  }

  registry.registerV2 = async ({
    humanId,
    principal,
    sessionId,
    voipToken,
    platform = 'apns',
    installationId,
    installationGeneration,
    registeredAt,
  } = {}) => {
    const installationHash = installationHashFor(installationId);
    const targetHash = targetHashFor(humanId, principal, sessionId);
    const tokenHash = tokenHashFor(platform, voipToken);
    let preparation = await prepareRegistration({
      installationHash,
      generation: installationGeneration,
      targetHash,
      tokenHash,
      platform,
    });
    // Capacity and token ownership are reserved BEFORE the durable installation head changes. A full/busy target or
    // duplicate-token rejection therefore leaves the installation's prior binding authoritative.
    let hashes = await reserveIndexSlot(targetHash, installationHash, preparation);
    await reserveTokenOrRollbackIndex(preparation);
    const expiresAtSec = nowSec() + leaseTtl;
    const lease = {
      schemaVersion: DIAL_REGISTRY_VERSION,
      installationHash,
      targetHash,
      generation: preparation.generation,
      bindingId: preparation.bindingId,
      bindingRevision: preparation.bindingRevision,
      bindingDigest: preparation.bindingDigest,
      tokenHash,
      voipToken,
      platform,
      registeredAt: registeredAt || new Date(clock()).toISOString(),
      expiresAtSec,
    };
    // Generation-specific key: an old worker can write only its old lease, never overwrite a newer generation's token.
    await store.put(LEASE_KEY(installationHash, preparation.generation), lease, { ttlEpochSec: expiresAtSec });
    // Refresh and re-acquire both short reservations after the only raw-token write. A worker stalled past reservation
    // expiry cannot wake up and advance the head using capacity/token ownership that another request has since won.
    preparation = await prepareRegistration({
      installationHash,
      generation: installationGeneration,
      targetHash,
      tokenHash,
      platform,
    });
    hashes = await reserveIndexSlot(targetHash, installationHash, preparation);
    await reserveTokenOrRollbackIndex(preparation);
    const { head, priorHead } = await installPreparedHead(preparation);
    await activateTokenClaim(preparation, expiresAtSec);
    const finalHead = await store.get(HEAD_KEY(installationHash));
    if (!sameHead(finalHead, head)) throw fault(409, 'binding-superseded', 'a newer installation binding superseded this request');
    const active = await activeV2Binding(installationHash, targetHash);
    if (!active ||
        active.installationGeneration !== head.generation ||
        active.bindingId !== head.bindingId ||
        active.bindingRevision !== head.bindingRevision) {
      throw fault(503, 'registry-binding-incomplete', 'device binding did not become fully authoritative');
    }
    if (priorHead && priorHead.targetHash !== targetHash) {
      await removeStaleIndexCandidate(priorHead.targetHash, installationHash, head.generation);
    }
    if (priorHead &&
        (priorHead.generation !== head.generation || priorHead.tokenHash !== head.tokenHash)) {
      await releaseTokenClaim({ ...priorHead, installationHash });
    }
    return {
      deviceCount: hashes.length,
      installationGeneration: head.generation,
      bindingId: head.bindingId,
      bindingRevision: head.bindingRevision,
      leaseExpiresAtSec: expiresAtSec,
    };
  };

  registry.unregisterV2 = async ({
    humanId,
    principal,
    sessionId,
    installationId,
    installationGeneration,
    previousInstallationGeneration,
    bindingId,
    bindingRevision,
  } = {}) => {
    const installationHash = installationHashFor(installationId);
    const targetHash = targetHashFor(humanId, principal, sessionId);
    const tombstoneDigest = tombstoneDigestFor({
      generation: installationGeneration,
      previousGeneration: previousInstallationGeneration,
      targetHash,
      bindingId,
      bindingRevision,
    });
    let tombstoned = false;
    let revokedHead = null;
    for (let attempt = 0; attempt < 8; attempt += 1) {
      const current = await store.get(HEAD_KEY(installationHash));
      if (!current) break;
      if (!validHead(current)) throw fault(503, 'registry-head-corrupt', 'installation head is corrupt');
      const requested = parseGeneration(installationGeneration);
      const installed = parseGeneration(current.generation);
      if (installed > requested) break; // stale cleanup: deliberately idempotent/non-oracular
      if (installed === requested) {
        tombstoned = current.operation === 'unregister' && current.bindingDigest === tombstoneDigest;
        if (tombstoned) revokedHead = current;
        break;
      }
      // Only the exact currently authenticated owner + prior binding may advance this head to a tombstone.
      if (current.operation !== 'register' ||
          current.generation !== previousInstallationGeneration ||
          current.targetHash !== targetHash ||
          current.bindingId !== bindingId ||
          current.bindingRevision !== bindingRevision) break;
      const next = {
        schemaVersion: DIAL_REGISTRY_VERSION,
        generation: installationGeneration,
        generationOrder: generationOrder(installationGeneration),
        operation: 'unregister',
        targetHash,
        bindingDigest: tombstoneDigest,
        bindingId,
        bindingRevision,
        tokenHash: current.tokenHash,
        platform: current.platform,
      };
      const result = await store.advanceGeneration(HEAD_KEY(installationHash), next);
      if (result?.advanced) {
        tombstoned = true;
        revokedHead = next;
        break;
      }
    }
    if (tombstoned) {
      try { await store.delete(LEASE_KEY(installationHash, previousInstallationGeneration)); } catch { /* TTL + head fence remain */ }
      await releaseTokenClaim({
        schemaVersion: DIAL_REGISTRY_VERSION,
        installationHash,
        generation: previousInstallationGeneration,
        generationOrder: generationOrder(previousInstallationGeneration),
        targetHash,
        tokenHash: revokedHead?.tokenHash,
        platform: revokedHead?.platform || 'apns',
        bindingDigest: revokedHead?.bindingDigest,
        bindingId,
        bindingRevision,
        expiresAtSec: 1,
      });
      // Clean secondary-index debris only when this request observed or created its exact tombstone. An equal/newer
      // register may have landed its head but still be activating its token claim; a stale cleanup must not remove that
      // in-flight register's sole candidate. Non-authoritative stale entries are compacted by later index mutations.
      await removeStaleIndexCandidate(targetHash, installationHash, installationGeneration);
    }
    return { unregistered: true };
  };

  const legacyLookup = registry.lookup;
  registry.lookup = async ({ humanId, principal, sessionId, limit = deviceCap } = {}) => {
    const cap = Number.isSafeInteger(limit) && limit > 0 ? Math.min(limit, deviceCap) : deviceCap;
    const targetHash = targetHashFor(humanId, principal, sessionId);
    const index = await store.get(INDEX_KEY(targetHash));
    const rows = [];
    const seen = new Set();
    if (index !== undefined && !validIndex(index)) {
      throw fault(503, 'registry-index-corrupt', 'registry index is corrupt');
    }
    if (validIndex(index)) {
      for (const installationHash of index.installationHashes.slice(0, deviceCap)) {
        if (rows.length >= cap || typeof installationHash !== 'string' || seen.has(installationHash)) continue;
        seen.add(installationHash);
        const row = await activeV2Binding(installationHash, targetHash);
        if (row) rows.push(row);
      }
    }
    if (readLegacy && rows.length < cap) {
      const legacy = await legacyLookup({ humanId, principal, sessionId, limit: cap - rows.length });
      for (const row of legacy) {
        if (!await legacyTokenMigrated(row.platform || 'apns', row.voipToken)) rows.push(row);
      }
    }
    return rows.slice(0, cap);
  };

  registry.revalidate = async ({ humanId, principal, sessionId, device } = {}) => {
    if (device?.registryVersion !== DIAL_REGISTRY_VERSION) {
      const authority = legacyTargetAuthority(humanId, principal);
      const current = await store.get(LEGACY_DEVICE_KEY(humanId, principal, sessionId));
      return current?.principal === authority &&
        legacyIsActive(current, nowSec()) &&
        !await legacyTokenMigrated(current.platform || 'apns', current.voipToken) &&
        current.voipToken === device?.voipToken &&
        (current.platform || 'apns') === (device?.platform || 'apns');
    }
    const targetHash = targetHashFor(humanId, principal, sessionId);
    const current = await activeV2Binding(device.installationHash, targetHash);
    return !!current &&
      current.installationGeneration === device.installationGeneration &&
      current.bindingId === device.bindingId &&
      current.bindingRevision === device.bindingRevision &&
      current.voipToken === device.voipToken;
  };

  return registry;
}
