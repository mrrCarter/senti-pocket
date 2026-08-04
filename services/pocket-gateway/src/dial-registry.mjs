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
  DEVICE_REGISTRY_OWNER_VERSION,
  DeviceRegistryV2Error,
  validateDeviceRegistrationCleanupV2,
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

const DEVICE_REGISTRY_V2_METHODS = Object.freeze([
  'registrationContext',
  'register',
  'reconcileRegistration',
  'denyRegistration',
  'unregister',
  'lookup',
]);

export function assertDeviceRegistryV2Capabilities(deviceRegistry, owner = 'Registry V2') {
  const missing = DEVICE_REGISTRY_V2_METHODS.filter((method) => typeof deviceRegistry?.[method] !== 'function');
  if (deviceRegistry?.operationOutcomeVersion !== 1 || missing.length > 0) {
    throw new Error(
      `${owner} requires operationOutcomeVersion=1 and ${DEVICE_REGISTRY_V2_METHODS.join(', ')}`,
    );
  }
  return deviceRegistry;
}

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
 * @param {{ deviceRegistry?: {register:Function, reconcileRegistration?:Function, lookup?:Function}, now?: ()=>number }} deps
 */
export function createDialRegistry({ deviceRegistry, now } = {}) {
  const clock = typeof now === 'function' ? now : () => Date.now();
  const usesRegistryV2 = deviceRegistry?.protocolVersion === DEVICE_REGISTRATION_VERSION;
  if (usesRegistryV2) assertDeviceRegistryV2Capabilities(deviceRegistry);
  const exactObject = (value, keys) =>
    value &&
    typeof value === 'object' &&
    !Array.isArray(value) &&
    Object.keys(value).length === keys.length &&
    keys.every((key) => Object.hasOwn(value, key));
  const canonicalOwnerHandle = (value) =>
    typeof value === 'string' &&
    /^[A-Za-z0-9_-]{43}$/.test(value) &&
    Buffer.from(value, 'base64url').length === 32 &&
    Buffer.from(value, 'base64url').toString('base64url') === value;
  const ownerFieldsAreValid = (ownerVersion, ownerHandle) =>
    ownerVersion === DEVICE_REGISTRY_OWNER_VERSION && canonicalOwnerHandle(ownerHandle);
  const ownerConflict = () => ({
    status: 409,
    body: {
      error: 'registry owner does not match authenticated principal',
      reason: 'registry-owner-conflict',
    },
  });
  const authorityResultKeys = [
    'ownerVersion',
    'ownerHandle',
    'bindingId',
    'bindingRevision',
    'expiresAtEpochSec',
    'idempotent',
    'renewed',
    'tokenClaimId',
    'tokenClaimRevision',
  ];
  const validExpiryEpochSec = (value) => {
    const milliseconds = value * 1000;
    return (
      Number.isSafeInteger(value) &&
      value > 0 &&
      Number.isSafeInteger(milliseconds) &&
      Number.isFinite(new Date(milliseconds).getTime())
    );
  };
  // The registry is an adapter boundary, including when production injects a non-reference implementation. Snapshot
  // every returned field once, require the exact wire, and never let arbitrary adapter values become lease authority.
  const authorityRegistration = (
    result,
    {
      allowExpiredMarker = false,
      requireReplaySemantics = false,
      requireUnexpired = false,
      expectedOwner,
      nowMs,
    } = {},
  ) => {
    const hasExpiredMarker =
      allowExpiredMarker && result && typeof result === 'object' && Object.hasOwn(result, 'expired');
    const expectedKeys = hasExpiredMarker ? [...authorityResultKeys, 'expired'] : authorityResultKeys;
    if (!exactObject(result, expectedKeys)) return null;
    const snapshot = {
      ownerVersion: result.ownerVersion,
      ownerHandle: result.ownerHandle,
      bindingId: result.bindingId,
      bindingRevision: result.bindingRevision,
      expiresAtEpochSec: result.expiresAtEpochSec,
      idempotent: result.idempotent,
      renewed: result.renewed,
      tokenClaimId: result.tokenClaimId,
      tokenClaimRevision: result.tokenClaimRevision,
      ...(hasExpiredMarker ? { expired: result.expired } : {}),
    };
    if (
      !ownerFieldsAreValid(snapshot.ownerVersion, snapshot.ownerHandle) ||
      typeof snapshot.bindingId !== 'string' || !/^bind_[0-9a-f]{32}$/.test(snapshot.bindingId) ||
      !Number.isSafeInteger(snapshot.bindingRevision) || snapshot.bindingRevision <= 0 ||
      typeof snapshot.tokenClaimId !== 'string' || !/^claim_[0-9a-f]{32}$/.test(snapshot.tokenClaimId) ||
      !Number.isSafeInteger(snapshot.tokenClaimRevision) || snapshot.tokenClaimRevision <= 0 ||
      !validExpiryEpochSec(snapshot.expiresAtEpochSec) ||
      typeof snapshot.idempotent !== 'boolean' || typeof snapshot.renewed !== 'boolean' ||
      (requireReplaySemantics && (snapshot.idempotent !== true || snapshot.renewed !== false)) ||
      (hasExpiredMarker && snapshot.expired !== true) ||
      (expectedOwner &&
        (snapshot.ownerVersion !== expectedOwner.ownerVersion || snapshot.ownerHandle !== expectedOwner.ownerHandle))
    ) {
      return null;
    }
    if (allowExpiredMarker || requireUnexpired) {
      const nowEpochSec = Math.floor(nowMs / 1000);
      if (
        !Number.isFinite(nowMs) ||
        !Number.isSafeInteger(nowEpochSec) ||
        nowEpochSec <= 0 ||
        !Number.isFinite(new Date(nowMs).getTime())
      ) {
        return null;
      }
      const expiredAtObservation = nowEpochSec >= snapshot.expiresAtEpochSec;
      if ((allowExpiredMarker && hasExpiredMarker !== expiredAtObservation) ||
          (requireUnexpired && expiredAtObservation)) {
        return null;
      }
    }
    return snapshot;
  };
  const bindingConflictDetail = (error) => {
    try {
      const details = error.details;
      if (!exactObject(details, ['currentBinding'])) return null;
      const current = details.currentBinding;
      if (current === null) return { value: null };
      if (!exactObject(current, [
        'bindingId', 'bindingRevision', 'expiresAtEpochSec', 'idempotent', 'renewed',
      ])) return null;
      const value = {
        bindingId: current.bindingId,
        bindingRevision: current.bindingRevision,
        expiresAtEpochSec: current.expiresAtEpochSec,
      };
      if (
        typeof value.bindingId !== 'string' || !/^bind_[0-9a-f]{32}$/.test(value.bindingId) ||
        !Number.isSafeInteger(value.bindingRevision) || value.bindingRevision <= 0 ||
        !validExpiryEpochSec(value.expiresAtEpochSec) ||
        current.idempotent !== false || current.renewed !== false
      ) return null;
      return { value };
    } catch {
      return null;
    }
  };
  const tokenClaimConflictDetail = (error) => {
    try {
      const details = error.details;
      if (!exactObject(details, ['currentTokenClaim'])) return null;
      const current = details.currentTokenClaim;
      if (current === null) return { value: null };
      if (!exactObject(current, ['tokenClaimId', 'tokenClaimRevision', 'expiresAtEpochSec'])) return null;
      const value = {
        tokenClaimId: current.tokenClaimId,
        tokenClaimRevision: current.tokenClaimRevision,
        expiresAtEpochSec: current.expiresAtEpochSec,
      };
      if (
        typeof value.tokenClaimId !== 'string' || !/^claim_[0-9a-f]{32}$/.test(value.tokenClaimId) ||
        !Number.isSafeInteger(value.tokenClaimRevision) || value.tokenClaimRevision <= 0 ||
        !validExpiryEpochSec(value.expiresAtEpochSec)
      ) return null;
      return { value };
    } catch {
      return null;
    }
  };
  const registrationFenceFields = (value, result, receiptNowMs) => ({
    registrationVersion: DEVICE_REGISTRATION_VERSION,
    ownerVersion: result.ownerVersion,
    ownerHandle: result.ownerHandle,
    sessionId: value.sessionId,
    platform: value.platform,
    bindingId: result.bindingId,
    bindingRevision: result.bindingRevision,
    tokenClaimId: result.tokenClaimId,
    tokenClaimRevision: result.tokenClaimRevision,
    expiresAt: new Date(result.expiresAtEpochSec * 1000).toISOString(),
    // Authoritative receipt time for clients to convert the absolute lease into a monotonic countdown. This is
    // generated after the registry operation; clients conservatively subtract request round-trip duration.
    serverTime: new Date(receiptNowMs).toISOString(),
    idempotent: result.idempotent === true,
  });
  const recoveryReceipt = (value, result, { status, reason, error }, receiptNowMs = clock()) => ({
    status,
    body: {
      registered: false,
      committed: true,
      authorized: false,
      revocationRequired: true,
      reason,
      error,
      ...registrationFenceFields(value, result, receiptNowMs),
    },
  });
  const deniedBeforeCommitReceipt = (value, { status, error }) => ({
    status,
    body: {
      registered: false,
      committed: false,
      authorized: false,
      revocationRequired: false,
      reason: 'registration-denied-before-commit',
      error,
      registrationVersion: DEVICE_REGISTRATION_VERSION,
      ownerVersion: value.ownerVersion,
      ownerHandle: value.ownerHandle,
      sessionId: value.sessionId,
      platform: value.platform,
      idempotent: true,
    },
  });
  const registrationReceipt = (value, result, receiptNowMs = clock()) => {
    if (Math.floor(receiptNowMs / 1000) >= result.expiresAtEpochSec) {
      return recoveryReceipt(
        value,
        result,
        {
          status: 410,
          reason: 'registration-expired',
          error: 'registration lease expired',
        },
        receiptNowMs,
      );
    }
    return {
      status: 200,
      body: {
        registered: true,
        ...registrationFenceFields(value, result, receiptNowMs),
      },
    };
  };
  const readExactRegistration = async ({ principal, humanId, body } = {}) => {
    if (!usesRegistryV2 || typeof deviceRegistry?.reconcileRegistration !== 'function') return null;
    const validated = validateDeviceRegistrationV2(body);
    if (!validated.ok) return null;
    const rawResult = await deviceRegistry.reconcileRegistration({
      principal: principal || humanId,
      humanId,
      ...validated.value,
    });
    if (rawResult === null) return null;
    const result = authorityRegistration(rawResult, {
      allowExpiredMarker: true,
      requireReplaySemantics: true,
      expectedOwner: validated.value,
      nowMs: clock(),
    });
    if (!result) throw new Error('device registry returned an invalid reconciliation result');
    return result ? { value: validated.value, result } : null;
  };
  const cleanupIntentForRegistration = (value) => ({
    registrationVersion: value.registrationVersion,
    ownerVersion: value.ownerVersion,
    ownerHandle: value.ownerHandle,
    installationId: value.installationId,
    idempotencyKey: value.idempotencyKey,
    tokenDigest: createHash('sha256').update(value.voipToken, 'utf8').digest('base64url'),
    sessionId: value.sessionId,
    platform: value.platform,
  });
  const committedOutcomeRegistration = (outcome, expectedOwner) => {
    const outerKeys = ['state', 'registration'];
    if (!exactObject(outcome, outerKeys) || outcome.state !== 'committed' ||
        !exactObject(outcome.registration, authorityResultKeys)) return null;
    return authorityRegistration(outcome.registration, { requireReplaySemantics: true, expectedOwner });
  };
  const isDeniedOutcome = (outcome, expectedOwner) =>
    exactObject(outcome, ['state', 'ownerVersion', 'ownerHandle']) &&
    outcome.state === 'denied' &&
    ownerFieldsAreValid(outcome.ownerVersion, outcome.ownerHandle) &&
    outcome.ownerVersion === expectedOwner.ownerVersion &&
    outcome.ownerHandle === expectedOwner.ownerHandle;
  const isUnregisterOutcome = (outcome, expectedOwner) =>
    exactObject(outcome, ['removed', 'ownerVersion', 'ownerHandle']) &&
    typeof outcome.removed === 'boolean' &&
    ownerFieldsAreValid(outcome.ownerVersion, outcome.ownerHandle) &&
    outcome.ownerVersion === expectedOwner.ownerVersion &&
    outcome.ownerHandle === expectedOwner.ownerHandle;
  const recoveryForCommittedOutcome = (value, result) => {
    const receiptNowMs = clock();
    return Math.floor(receiptNowMs / 1000) >= result.expiresAtEpochSec
      ? recoveryReceipt(
          value,
          result,
          { status: 410, reason: 'registration-expired', error: 'registration lease expired' },
          receiptNowMs,
        )
      : recoveryReceipt(
          value,
          result,
          {
            status: 409,
            reason: 'registration-committed-but-unauthorized',
            error: 'registration committed but current authorization is missing',
          },
          receiptNowMs,
        );
  };
  const persistDenial = async ({ principal, humanId, value, deniedError }) => {
    if (!usesRegistryV2 || typeof deviceRegistry?.denyRegistration !== 'function') {
      return {
        status: 501,
        body: { error: 'dial registry v2 outcome protocol not configured', reason: 'dial-registry-v2-not-configured' },
      };
    }
    try {
      const outcome = await deviceRegistry.denyRegistration({
        principal: principal || humanId,
        humanId,
        ...cleanupIntentForRegistration(value),
      });
      if (outcome?.state === 'committed') {
        const registration = committedOutcomeRegistration(outcome, value);
        if (!registration) {
          return { status: 502, body: { error: 'registry denial failed', reason: 'registry-denial-failed' } };
        }
        return recoveryForCommittedOutcome(value, registration);
      }
      if (isDeniedOutcome(outcome, value)) {
        return deniedBeforeCommitReceipt(value, { status: 403, error: deniedError });
      }
      return { status: 502, body: { error: 'registry denial failed', reason: 'registry-denial-failed' } };
    } catch (error) {
      if (error instanceof DeviceRegistryV2Error && error.code === 'registry-owner-conflict') {
        return ownerConflict();
      }
      if (error instanceof DeviceRegistryV2Error && error.code === 'idempotency-conflict') {
        // A different semantic intent already owns this operation key and may have committed. Never claim that the
        // conflicting request is exact terminal proof or reveal the stored outcome to an unauthorized caller.
        return { status: 403, body: { error: deniedError } };
      }
      if (error instanceof DeviceRegistryV2Error && error.code === 'registration-outcome-conflict') {
        return {
          status: 503,
          body: { error: 'registration denial could not be serialized', reason: 'registration-outcome-conflict' },
        };
      }
      return { status: 502, body: { error: 'registry denial failed', reason: 'registry-denial-failed' } };
    }
  };
  const reconcileRegistration = async (args = {}) => {
    const replay = await readExactRegistration(args);
    if (!replay) return null;
    return replay.result.expired === true
      ? recoveryReceipt(replay.value, replay.result, {
          status: 410,
          reason: 'registration-expired',
          error: 'registration lease expired',
        })
      : recoveryReceipt(replay.value, replay.result, {
          status: 409,
          reason: 'registration-committed-but-unauthorized',
          error: 'registration committed but current authorization is missing',
        });
  };
  return {
    async registrationContext({ principal, humanId } = {}) {
      if (!usesRegistryV2 || typeof deviceRegistry?.registrationContext !== 'function') {
        return {
          status: 501,
          body: { error: 'dial registry v2 not configured', reason: 'dial-registry-v2-not-configured' },
        };
      }
      try {
        const raw = await deviceRegistry.registrationContext({ principal: principal || humanId, humanId });
        if (!exactObject(raw, ['registrationVersion', 'ownerVersion', 'ownerHandle'])) {
          return { status: 502, body: { error: 'registry context failed', reason: 'registry-context-failed' } };
        }
        const context = {
          registrationVersion: raw.registrationVersion,
          ownerVersion: raw.ownerVersion,
          ownerHandle: raw.ownerHandle,
        };
        const receiptNowMs = clock();
        if (
          context.registrationVersion !== DEVICE_REGISTRATION_VERSION ||
          !ownerFieldsAreValid(context.ownerVersion, context.ownerHandle) ||
          !Number.isFinite(receiptNowMs) ||
          !Number.isFinite(new Date(receiptNowMs).getTime())
        ) {
          return { status: 502, body: { error: 'registry context failed', reason: 'registry-context-failed' } };
        }
        return {
          status: 200,
          body: { ...context, serverTime: new Date(receiptNowMs).toISOString() },
        };
      } catch {
        return { status: 502, body: { error: 'registry context failed', reason: 'registry-context-failed' } };
      }
    },
    // Handler-facing, read-only recovery seam. Missing-scope callers receive a non-authorizing revocation receipt only
    // when they prove the exact request that committed; invalid, changed, absent, and non-V2 requests collapse to null.
    reconcileRegistration,
    async denyRegistration({ principal, humanId, body, deniedError = 'registration is not authorized' } = {}) {
      const validated = validateDeviceRegistrationV2(body);
      if (!validated.ok) return null;
      return persistDenial({ principal, humanId, value: validated.value, deniedError });
    },
    async cleanupRegistration({ principal, humanId, body } = {}) {
      if (!usesRegistryV2 || typeof deviceRegistry?.denyRegistration !== 'function' ||
          typeof deviceRegistry?.unregister !== 'function') {
        return {
          status: 501,
          body: { error: 'dial registry v2 cleanup not configured', reason: 'dial-registry-v2-not-configured' },
        };
      }
      const validated = validateDeviceRegistrationCleanupV2(body);
      if (!validated.ok) {
        return { status: validated.status, body: { error: validated.error, reason: 'registration-cleanup-v2-required' } };
      }
      const value = validated.value;
      try {
        const outcome = await deviceRegistry.denyRegistration({
          principal: principal || humanId,
          humanId,
          ...value,
        });
        if (outcome?.state === 'committed') {
          const registration = committedOutcomeRegistration(outcome, value);
          if (!registration) {
            return { status: 502, body: { error: 'registry cleanup failed', reason: 'registry-cleanup-failed' } };
          }
          const deletion = await deviceRegistry.unregister({
            principal: principal || humanId,
            humanId,
            registrationVersion: DEVICE_REGISTRATION_VERSION,
            ownerVersion: value.ownerVersion,
            ownerHandle: value.ownerHandle,
            installationId: value.installationId,
            sessionId: value.sessionId,
            bindingId: registration.bindingId,
            bindingRevision: registration.bindingRevision,
          });
          if (!isUnregisterOutcome(deletion, value)) {
            return { status: 502, body: { error: 'registry cleanup failed', reason: 'registry-cleanup-failed' } };
          }
        } else if (!isDeniedOutcome(outcome, value)) {
          return { status: 502, body: { error: 'registry cleanup failed', reason: 'registry-cleanup-failed' } };
        }
      } catch (error) {
        if (error instanceof DeviceRegistryV2Error && error.code === 'registry-owner-conflict') {
          return ownerConflict();
        }
        if (error instanceof DeviceRegistryV2Error && error.code === 'idempotency-conflict') {
          return {
            status: 409,
            body: { error: 'idempotency key was reused for different registration data', reason: 'idempotency-conflict' },
          };
        }
        if (error instanceof DeviceRegistryV2Error &&
            ['registration-outcome-conflict', 'unregistration-conflict'].includes(error.code)) {
          return {
            status: 503,
            body: { error: 'registration cleanup could not be serialized', reason: 'registration-cleanup-conflict' },
          };
        }
        return { status: 502, body: { error: 'registry cleanup failed', reason: 'registry-cleanup-failed' } };
      }
      return {
        status: 200,
        body: {
          registrationVersion: DEVICE_REGISTRATION_VERSION,
          ownerVersion: value.ownerVersion,
          ownerHandle: value.ownerHandle,
          idempotencyKey: value.idempotencyKey,
          sessionId: value.sessionId,
          platform: value.platform,
          registered: false,
          authorized: false,
          cleanupComplete: true,
          serverTime: new Date(clock()).toISOString(),
        },
      };
    },
    /**
     * @param {{ humanId:string, body:object, isMember:(sessionId:string)=>Promise<boolean> }} args
     * @returns {Promise<{status:number, body:object}>}
     */
    async register({ principal, humanId, body, isMember } = {}) {
      const requestedV2 = body && typeof body === 'object' && (
        Object.hasOwn(body, 'registrationVersion') ||
        Object.hasOwn(body, 'ownerVersion') ||
        Object.hasOwn(body, 'ownerHandle') ||
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
        let replay;
        try {
          replay = await readExactRegistration({ principal, humanId, body: v.value });
        } catch (error) {
          if (error instanceof DeviceRegistryV2Error && error.code === 'registry-owner-conflict') {
            return ownerConflict();
          }
          return {
            status: 502,
            body: { error: 'registry reconciliation failed', reason: 'registry-reconciliation-failed' },
          };
        }
        if (replay?.result.expired === true) {
          return recoveryReceipt(replay.value, replay.result, {
            status: 410,
            reason: 'registration-expired',
            error: 'registration lease expired',
          });
        }
        let member = false;
        try { member = await isMember(v.value.sessionId); }
        catch { return { status: 500, body: { error: 'authorization lookup failed' } }; }
        if (replay && !member) {
          return recoveryForCommittedOutcome(replay.value, replay.result);
        }
        if (replay) return registrationReceipt(replay.value, replay.result);
        if (!member) {
          return persistDenial({
            principal,
            humanId,
            value: v.value,
            deniedError: 'not a known session for this user',
          });
        }
        let res;
        let receiptNowMs;
        try {
          const rawResult = await deviceRegistry.register({ principal: principal || humanId, humanId, ...v.value });
          receiptNowMs = clock();
          res = authorityRegistration(rawResult, {
            requireUnexpired: true,
            expectedOwner: v.value,
            nowMs: receiptNowMs,
          });
          if (!res) {
            return { status: 502, body: { error: 'registry write failed', reason: 'registry-write-failed' } };
          }
        } catch (error) {
          if (error instanceof DeviceRegistryV2Error && error.code === 'registry-owner-conflict') {
            return ownerConflict();
          }
          if (error instanceof DeviceRegistryV2Error && error.code === 'idempotency-conflict') {
            return {
              status: 409,
              body: {
                error: 'idempotency key was reused for different registration data',
                reason: 'idempotency-conflict',
              },
            };
          }
          if (error instanceof DeviceRegistryV2Error && error.code === 'registration-operation-denied') {
            return deniedBeforeCommitReceipt(v.value, {
              status: 409,
              error: 'registration operation was denied before commit',
            });
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
            const parsed = bindingConflictDetail(error);
            if (!parsed) {
              return { status: 502, body: { error: 'registry write failed', reason: 'registry-write-failed' } };
            }
            const current = parsed.value;
            return {
              status: 409,
              body: {
                error: 'registration expected binding is no longer current',
                reason: 'binding-conflict',
                ownerVersion: v.value.ownerVersion,
                ownerHandle: v.value.ownerHandle,
                currentBinding: current ? {
                  bindingId: current.bindingId,
                  bindingRevision: current.bindingRevision,
                  expiresAt: new Date(current.expiresAtEpochSec * 1000).toISOString(),
                } : null,
              },
            };
          }
          if (error instanceof DeviceRegistryV2Error && error.code === 'token-claim-conflict') {
            const parsed = tokenClaimConflictDetail(error);
            if (!parsed) {
              return { status: 502, body: { error: 'registry write failed', reason: 'registry-write-failed' } };
            }
            const current = parsed.value;
            return {
              status: 409,
              body: {
                error: 'registration expected token claim is no longer current',
                reason: 'token-claim-conflict',
                ownerVersion: v.value.ownerVersion,
                ownerHandle: v.value.ownerHandle,
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
        return registrationReceipt(v.value, res, receiptNowMs);
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
      try {
        const deletion = await deviceRegistry.unregister({ principal: principal || humanId, humanId, ...v.value });
        if (!isUnregisterOutcome(deletion, v.value)) {
          return { status: 502, body: { error: 'registry delete failed', reason: 'registry-delete-failed' } };
        }
      }
      catch (error) {
        if (error instanceof DeviceRegistryV2Error && error.code === 'registry-owner-conflict') {
          return ownerConflict();
        }
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
          ownerVersion: v.value.ownerVersion,
          ownerHandle: v.value.ownerHandle,
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
