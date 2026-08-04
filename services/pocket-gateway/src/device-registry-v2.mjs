import { createHash, createHmac, randomInt, randomUUID } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';

export const DEVICE_REGISTRATION_VERSION = 2;
export const DEVICE_REGISTRY_OWNER_VERSION = 1;
export const DEVICE_REGISTRATION_LEASE_SECONDS = 7 * 24 * 60 * 60;
// Logical routing stops at expiresAtEpochSec. Physical TTL cleanup and automatic token reclaim wait through this
// additional window so workers whose clocks differ by no more than the bound cannot disagree about an old live route.
export const DEVICE_REGISTRATION_RECLAIM_GRACE_SECONDS = 5 * 60;
export const DEVICE_REGISTRATION_LIMITS = Object.freeze({
  VOIP_TOKEN_BYTES: 512,
  SESSION_ID_BYTES: 128,
  PRINCIPAL_BYTES: 1024,
  INSTALLATION_ID_CHARS: 43, // 32 random bytes encoded as unpadded base64url.
  IDEMPOTENCY_KEY_CHARS: 36, // UUID textual representation.
  MAX_DEVICES: 20,
});
export const DEVICE_REGISTRY_MAX_SERIALIZATION_ATTEMPTS = DEVICE_REGISTRATION_LIMITS.MAX_DEVICES + 1;

const SCHEMA = 'dial-device-binding-v2';
const BINDING_SK = 'binding';
const TOKEN_CLAIM_SCHEMA = 'dial-device-token-claim-v2';
const TOKEN_CLAIM_SK = 'claim';
const TARGET_DIRECTORY_SCHEMA = 'dial-device-target-directory-v2';
const TARGET_DIRECTORY_SK = 'directory';
const REGISTRATION_OPERATION_SCHEMA = 'dial-device-registration-operation-v2';
const REGISTRATION_OPERATION_SK = 'outcome';
const MAX_BINDING_REVISION = Number.MAX_SAFE_INTEGER - 1;
const PLATFORM_SET = new Set(['apns', 'fcm']);
const INSTALLATION_ID_RE = /^[A-Za-z0-9_-]{43}$/;
const DIGEST_RE = /^[A-Za-z0-9_-]{43}$/;
const OWNER_HANDLE_RE = /^[A-Za-z0-9_-]{43}$/;
const INSTALLATION_KEY_RE = /^dial:install:v2:[A-Za-z0-9_-]{43}$/;
const TARGET_KEY_RE = /^dial:target:v2:[A-Za-z0-9_-]{43}$/;
const TOKEN_KEY_RE = /^dial:token:v2:[A-Za-z0-9_-]{43}$/;
const REGISTRATION_OPERATION_KEY_RE = /^dial:regop:v2:[A-Za-z0-9_-]{43}$/;
const IDEMPOTENCY_KEY_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const BINDING_ID_RE = /^bind_[0-9a-f]{32}$/;
const TOKEN_CLAIM_ID_RE = /^claim_[0-9a-f]{32}$/;
const TARGET_DIRECTORY_ID_RE = /^dir_[0-9a-f]{32}$/;
const CONTROL_RE = /[\u0000-\u001f\u007f-\u009f]/;

const defaultRetryDelay = (attempt) => {
  const ceilingMs = Math.min(2 ** Math.min(attempt, 5), 32);
  const delayMs = randomInt(ceilingMs + 1);
  return delayMs > 0 ? new Promise((resolve) => setTimeout(resolve, delayMs)) : Promise.resolve();
};

const utf8 = (value) => Buffer.byteLength(String(value ?? ''), 'utf8');
const compareOpaque = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
const b64url = (value) =>
  Buffer.from(value).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const isCanonicalOwnerHandle = (value) =>
  typeof value === 'string' &&
  OWNER_HANDLE_RE.test(value) &&
  Buffer.from(value, 'base64url').length === 32 &&
  Buffer.from(value, 'base64url').toString('base64url') === value;
const isConditional = (error) =>
  error && (error.name === 'ConditionalCheckFailedException' || error.code === 'ConditionalCheckFailedException');
const TRANSACTION_CANCELLATION_MESSAGE_RE =
  /^Transaction cancelled, please refer cancellation reasons for specific reasons \[([A-Za-z]+(?:, [A-Za-z]+)*)\]$/;
const ALLOWED_TRANSACTION_CANCELLATION_CODES = new Set(['None', 'ConditionalCheckFailed', 'TransactionConflict']);
const CONTENTION_TRANSACTION_CANCELLATION_CODES = new Set(['ConditionalCheckFailed', 'TransactionConflict']);
const transactionCancellationCodes = (error) => {
  try {
    const structured = Object.hasOwn(error, 'CancellationReasons') ? error.CancellationReasons : undefined;
    if (structured !== undefined) {
      if (!Array.isArray(structured)) return null;
      const codes = [];
      for (const reason of structured) {
        if (
          !reason ||
          typeof reason !== 'object' ||
          Array.isArray(reason) ||
          !Object.hasOwn(reason, 'Code') ||
          typeof reason.Code !== 'string'
        ) {
          return null;
        }
        codes.push(reason.Code);
      }
      return codes;
    }
    if (typeof error?.message !== 'string') return null;
    const match = TRANSACTION_CANCELLATION_MESSAGE_RE.exec(error.message);
    return match ? match[1].split(', ') : null;
  } catch {
    return null;
  }
};
const isTransactionRetryable = (error, expectedReasonCount) => {
  try {
    if (isConditional(error)) return true;
    if (!error || (error.name !== 'TransactionCanceledException' && error.code !== 'TransactionCanceledException')) {
      return false;
    }
    // DynamoDB emits one ordered reason per transaction action. Accept the current JS v3 structured property or the
    // documented non-Java service-message form, and parse only that anchored grammar: malformed, unknown, throttling,
    // and validation cancellations must propagate instead of becoming contention.
    const reasons = transactionCancellationCodes(error);
    return (
      Array.isArray(reasons) &&
      Number.isSafeInteger(expectedReasonCount) &&
      expectedReasonCount > 0 &&
      reasons.length === expectedReasonCount &&
      reasons.some((reason) => CONTENTION_TRANSACTION_CANCELLATION_CODES.has(reason)) &&
      reasons.every((reason) => ALLOWED_TRANSACTION_CANCELLATION_CODES.has(reason))
    );
  } catch {
    return false;
  }
};

export class DeviceRegistryV2Error extends Error {
  constructor(code, message, details = undefined) {
    super(message);
    this.name = 'DeviceRegistryV2Error';
    this.code = code;
    this.details = details;
  }
}

function validationFailure(status, error) {
  return { ok: false, status, error };
}

function exactObject(body, allowed) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) return validationFailure(400, 'JSON object required');
  for (const key of Object.keys(body)) {
    if (!allowed.has(key)) return validationFailure(400, `unsupported registry field: ${key}`);
  }
  return null;
}

function canonicalOpaque(value, name, maxBytes) {
  if (typeof value !== 'string' || value.length === 0) return validationFailure(400, `${name} required`);
  if (value !== value.trim() || CONTROL_RE.test(value)) return validationFailure(400, `${name} must be canonical`);
  if (utf8(value) > maxBytes) return validationFailure(413, `${name} exceeds ${maxBytes} bytes`);
  return null;
}

/**
 * V2 is deliberately exact and versioned. An unversioned request is never silently upgraded because the phone must
 * retain the server-issued bindingId/revision before any push can be considered authorized.
 */
export function validateDeviceRegistrationV2(body) {
  const shape = exactObject(
    body,
    new Set([
      'registrationVersion',
      'ownerVersion',
      'ownerHandle',
      'installationId',
      'idempotencyKey',
      'voipToken',
      'sessionId',
      'platform',
      'expectedBindingId',
      'expectedBindingRevision',
      'expectedTokenClaimId',
      'expectedTokenClaimRevision',
    ]),
  );
  if (shape) return shape;

  // Snapshot every getter-backed field exactly once before validation.
  const registrationVersion = body.registrationVersion;
  const ownerVersion = body.ownerVersion;
  const ownerHandle = body.ownerHandle;
  const installationId = body.installationId;
  const idempotencyKey = body.idempotencyKey;
  const voipToken = body.voipToken;
  const sessionId = body.sessionId;
  const platform = body.platform;
  const expectedBindingId = body.expectedBindingId;
  const expectedBindingRevision = body.expectedBindingRevision;
  const expectedTokenClaimId = body.expectedTokenClaimId;
  const expectedTokenClaimRevision = body.expectedTokenClaimRevision;

  if (registrationVersion !== DEVICE_REGISTRATION_VERSION) {
    return validationFailure(426, `registrationVersion ${DEVICE_REGISTRATION_VERSION} required`);
  }
  if (ownerVersion !== DEVICE_REGISTRY_OWNER_VERSION) {
    return validationFailure(426, `ownerVersion ${DEVICE_REGISTRY_OWNER_VERSION} required`);
  }
  if (!isCanonicalOwnerHandle(ownerHandle)) {
    return validationFailure(400, 'ownerHandle must be 32 bytes encoded as base64url');
  }
  if (
    typeof installationId !== 'string' ||
    !INSTALLATION_ID_RE.test(installationId) ||
    Buffer.from(installationId, 'base64url').length !== 32 ||
    Buffer.from(installationId, 'base64url').toString('base64url') !== installationId
  ) {
    return validationFailure(400, 'installationId must be 32 random bytes encoded as base64url');
  }
  if (
    typeof idempotencyKey !== 'string' ||
    idempotencyKey.length !== DEVICE_REGISTRATION_LIMITS.IDEMPOTENCY_KEY_CHARS ||
    !IDEMPOTENCY_KEY_RE.test(idempotencyKey)
  ) {
    return validationFailure(400, 'idempotencyKey must be a UUID');
  }
  const tokenError = canonicalOpaque(voipToken, 'voipToken', DEVICE_REGISTRATION_LIMITS.VOIP_TOKEN_BYTES);
  if (tokenError) return tokenError;
  const sessionError = canonicalOpaque(sessionId, 'sessionId', DEVICE_REGISTRATION_LIMITS.SESSION_ID_BYTES);
  if (sessionError) return sessionError;
  if (typeof platform !== 'string' || !PLATFORM_SET.has(platform)) {
    return validationFailure(400, 'platform must be one of apns, fcm');
  }
  const hasExpectedId = expectedBindingId !== undefined;
  const hasExpectedRevision = expectedBindingRevision !== undefined;
  if (hasExpectedId !== hasExpectedRevision) {
    return validationFailure(400, 'expectedBindingId and expectedBindingRevision must be supplied together');
  }
  if (hasExpectedId && (typeof expectedBindingId !== 'string' || !BINDING_ID_RE.test(expectedBindingId))) {
    return validationFailure(400, 'expectedBindingId is invalid');
  }
  if (hasExpectedRevision && (!Number.isSafeInteger(expectedBindingRevision) || expectedBindingRevision <= 0)) {
    return validationFailure(400, 'expectedBindingRevision must be a positive safe integer');
  }
  const hasExpectedTokenId = expectedTokenClaimId !== undefined;
  const hasExpectedTokenRevision = expectedTokenClaimRevision !== undefined;
  if (hasExpectedTokenId !== hasExpectedTokenRevision) {
    return validationFailure(400, 'expectedTokenClaimId and expectedTokenClaimRevision must be supplied together');
  }
  if (
    hasExpectedTokenId &&
    (typeof expectedTokenClaimId !== 'string' || !TOKEN_CLAIM_ID_RE.test(expectedTokenClaimId))
  ) {
    return validationFailure(400, 'expectedTokenClaimId is invalid');
  }
  if (
    hasExpectedTokenRevision &&
    (!Number.isSafeInteger(expectedTokenClaimRevision) || expectedTokenClaimRevision <= 0)
  ) {
    return validationFailure(400, 'expectedTokenClaimRevision must be a positive safe integer');
  }
  return {
    ok: true,
    value: {
      registrationVersion,
      ownerVersion,
      ownerHandle,
      installationId,
      idempotencyKey,
      voipToken,
      sessionId,
      platform,
      ...(hasExpectedId ? { expectedBindingId, expectedBindingRevision } : {}),
      ...(hasExpectedTokenId ? { expectedTokenClaimId, expectedTokenClaimRevision } : {}),
    },
  };
}

/**
 * Cleanup is deliberately digest-only: PushKit may invalidate the raw token after a registration response is lost,
 * while this operation identity is already persisted by the phone. Expected CAS fences are not semantic identity.
 */
export function validateDeviceRegistrationCleanupV2(body) {
  const shape = exactObject(
    body,
    new Set([
      'registrationVersion',
      'ownerVersion',
      'ownerHandle',
      'installationId',
      'idempotencyKey',
      'tokenDigest',
      'sessionId',
      'platform',
    ]),
  );
  if (shape) return shape;

  const registrationVersion = body.registrationVersion;
  const ownerVersion = body.ownerVersion;
  const ownerHandle = body.ownerHandle;
  const installationId = body.installationId;
  const idempotencyKey = body.idempotencyKey;
  const tokenDigest = body.tokenDigest;
  const sessionId = body.sessionId;
  const platform = body.platform;
  if (registrationVersion !== DEVICE_REGISTRATION_VERSION) {
    return validationFailure(426, `registrationVersion ${DEVICE_REGISTRATION_VERSION} required`);
  }
  if (ownerVersion !== DEVICE_REGISTRY_OWNER_VERSION) {
    return validationFailure(426, `ownerVersion ${DEVICE_REGISTRY_OWNER_VERSION} required`);
  }
  if (!isCanonicalOwnerHandle(ownerHandle)) {
    return validationFailure(400, 'ownerHandle must be 32 bytes encoded as base64url');
  }
  if (
    typeof installationId !== 'string' ||
    !INSTALLATION_ID_RE.test(installationId) ||
    Buffer.from(installationId, 'base64url').length !== 32 ||
    Buffer.from(installationId, 'base64url').toString('base64url') !== installationId
  ) {
    return validationFailure(400, 'installationId must be 32 random bytes encoded as base64url');
  }
  if (
    typeof idempotencyKey !== 'string' ||
    idempotencyKey.length !== DEVICE_REGISTRATION_LIMITS.IDEMPOTENCY_KEY_CHARS ||
    !IDEMPOTENCY_KEY_RE.test(idempotencyKey)
  ) {
    return validationFailure(400, 'idempotencyKey must be a UUID');
  }
  if (
    typeof tokenDigest !== 'string' ||
    !DIGEST_RE.test(tokenDigest) ||
    Buffer.from(tokenDigest, 'base64url').length !== 32 ||
    Buffer.from(tokenDigest, 'base64url').toString('base64url') !== tokenDigest
  ) {
    return validationFailure(400, 'tokenDigest must be a SHA-256 digest encoded as base64url');
  }
  const sessionError = canonicalOpaque(sessionId, 'sessionId', DEVICE_REGISTRATION_LIMITS.SESSION_ID_BYTES);
  if (sessionError) return sessionError;
  if (typeof platform !== 'string' || !PLATFORM_SET.has(platform)) {
    return validationFailure(400, 'platform must be one of apns, fcm');
  }
  return {
    ok: true,
    value: {
      registrationVersion,
      ownerVersion,
      ownerHandle,
      installationId,
      idempotencyKey,
      tokenDigest,
      sessionId,
      platform,
    },
  };
}

export function validateDeviceUnregistrationV2(body) {
  const shape = exactObject(
    body,
    new Set([
      'registrationVersion',
      'ownerVersion',
      'ownerHandle',
      'installationId',
      'sessionId',
      'bindingId',
      'bindingRevision',
    ]),
  );
  if (shape) return shape;

  const registrationVersion = body.registrationVersion;
  const ownerVersion = body.ownerVersion;
  const ownerHandle = body.ownerHandle;
  const installationId = body.installationId;
  const sessionId = body.sessionId;
  const bindingId = body.bindingId;
  const bindingRevision = body.bindingRevision;

  if (registrationVersion !== DEVICE_REGISTRATION_VERSION) {
    return validationFailure(426, `registrationVersion ${DEVICE_REGISTRATION_VERSION} required`);
  }
  if (ownerVersion !== DEVICE_REGISTRY_OWNER_VERSION) {
    return validationFailure(426, `ownerVersion ${DEVICE_REGISTRY_OWNER_VERSION} required`);
  }
  if (!isCanonicalOwnerHandle(ownerHandle)) {
    return validationFailure(400, 'ownerHandle must be 32 bytes encoded as base64url');
  }
  if (
    typeof installationId !== 'string' ||
    !INSTALLATION_ID_RE.test(installationId) ||
    Buffer.from(installationId, 'base64url').length !== 32 ||
    Buffer.from(installationId, 'base64url').toString('base64url') !== installationId
  ) {
    return validationFailure(400, 'installationId must be 32 random bytes encoded as base64url');
  }
  const sessionError = canonicalOpaque(sessionId, 'sessionId', DEVICE_REGISTRATION_LIMITS.SESSION_ID_BYTES);
  if (sessionError) return sessionError;
  if (typeof bindingId !== 'string' || !BINDING_ID_RE.test(bindingId)) {
    return validationFailure(400, 'bindingId is invalid');
  }
  if (!Number.isSafeInteger(bindingRevision) || bindingRevision <= 0) {
    return validationFailure(400, 'bindingRevision must be a positive safe integer');
  }
  return {
    ok: true,
    value: {
      registrationVersion,
      ownerVersion,
      ownerHandle,
      installationId,
      sessionId,
      bindingId,
      bindingRevision,
    },
  };
}

function readHmacKey(value) {
  if (Buffer.isBuffer(value)) {
    if (value.length < 32) throw new Error('device registry HMAC key must contain at least 32 bytes');
    return Buffer.from(value);
  }
  if (typeof value !== 'string' || !/^[A-Za-z0-9+/]+={0,2}$/.test(value) || value.length % 4 !== 0) {
    throw new Error('device registry HMAC key must be canonical base64');
  }
  const decoded = Buffer.from(value, 'base64');
  if (decoded.length < 32 || decoded.toString('base64') !== value) {
    throw new Error('device registry HMAC key must decode to at least 32 bytes');
  }
  return decoded;
}

function lengthPrefixed(...parts) {
  return parts
    .map((part) => {
      const value = String(part ?? '');
      return `${utf8(value)}:${value}`;
    })
    .join('|');
}

export function deriveDeviceInstallationKey(hmacKey, installationId) {
  const key = readHmacKey(hmacKey);
  return (
    'dial:install:v2:' +
    b64url(createHmac('sha256', key).update(lengthPrefixed('installation', installationId), 'utf8').digest())
  );
}

/** Stable across bearer rotation because it binds the verifier-owned principal identity, never bearer bytes. */
export function deriveDeviceOwnerHandle(hmacKey, principal, humanId) {
  const key = readHmacKey(hmacKey);
  return b64url(
    createHmac('sha256', key)
      .update(lengthPrefixed('registry-owner-handle-v1', principal, humanId), 'utf8')
      .digest(),
  );
}

export function deriveDeviceRegistrationOperationKey(hmacKey, principal, humanId, installationId, idempotencyKey) {
  const key = readHmacKey(hmacKey);
  return (
    'dial:regop:v2:' +
    b64url(
      createHmac('sha256', key)
        .update(
          lengthPrefixed('registration-operation', principal, humanId, installationId, idempotencyKey),
          'utf8',
        )
        .digest(),
    )
  );
}

export function deriveDeviceTargetKey(hmacKey, principal, humanId, sessionId) {
  const key = readHmacKey(hmacKey);
  return (
    'dial:target:v2:' +
    b64url(
      createHmac('sha256', key)
        .update(lengthPrefixed('target', principal, humanId, sessionId), 'utf8')
        .digest(),
    )
  );
}

export function deriveDeviceTokenKey(hmacKey, platform, voipToken) {
  const key = readHmacKey(hmacKey);
  return (
    'dial:token:v2:' +
    b64url(
      createHmac('sha256', key)
        .update(lengthPrefixed('token', platform, voipToken), 'utf8')
        .digest(),
    )
  );
}

function registrationFingerprint(hmacKey, targetKey, tokenHash, platform) {
  const key = readHmacKey(hmacKey);
  return b64url(
    createHmac('sha256', key)
      .update(lengthPrefixed('registration', targetKey, tokenHash, platform), 'utf8')
      .digest(),
  );
}

function tokenHash(voipToken) {
  return b64url(createHash('sha256').update(voipToken, 'utf8').digest());
}

function freshBindingId() {
  return 'bind_' + randomUUID().replace(/-/g, '');
}

function freshTokenClaimId() {
  return 'claim_' + randomUUID().replace(/-/g, '');
}

function freshTargetDirectoryId() {
  return 'dir_' + randomUUID().replace(/-/g, '');
}

function safeNowSeconds(now) {
  const value = now();
  if (!Number.isFinite(value)) throw new DeviceRegistryV2Error('clock-invalid', 'registry clock is invalid');
  const seconds = Math.floor(value / 1000);
  if (!Number.isSafeInteger(seconds) || seconds <= 0) {
    throw new DeviceRegistryV2Error('clock-invalid', 'registry clock is invalid');
  }
  return seconds;
}

function physicalTtlEpochSec(expiresAtEpochSec) {
  const ttl = expiresAtEpochSec + DEVICE_REGISTRATION_RECLAIM_GRACE_SECONDS;
  if (!Number.isSafeInteger(ttl) || ttl <= expiresAtEpochSec) {
    throw new DeviceRegistryV2Error('clock-invalid', 'registry physical expiry is invalid');
  }
  return ttl;
}

function assertRegistryInput(value) {
  const checked = validateDeviceRegistrationV2(value);
  if (!checked.ok) throw new DeviceRegistryV2Error('invalid-input', checked.error);
  return checked.value;
}

function assertCleanupInput(value) {
  const checked = validateDeviceRegistrationCleanupV2(value);
  if (!checked.ok) throw new DeviceRegistryV2Error('invalid-input', checked.error);
  return checked.value;
}

function assertUnregisterInput(value) {
  const checked = validateDeviceUnregistrationV2(value);
  if (!checked.ok) throw new DeviceRegistryV2Error('invalid-input', checked.error);
  return checked.value;
}

function assertOwner(principal, humanId) {
  // `principal` is a trusted verifier-owned namespace and intentionally contains length-prefix separators/newlines in
  // production. Treat it as bounded opaque bytes; do not apply request-body canonicalization to that internal format.
  const principalError =
    typeof principal !== 'string' ||
    principal.length === 0 ||
    utf8(principal) > DEVICE_REGISTRATION_LIMITS.PRINCIPAL_BYTES;
  const humanError = canonicalOpaque(humanId, 'humanId', DEVICE_REGISTRATION_LIMITS.PRINCIPAL_BYTES);
  if (principalError || humanError) {
    throw new DeviceRegistryV2Error('invalid-owner', 'authenticated registry owner is invalid');
  }
}

function authenticatedOwnerFields(hmacKey, principal, humanId, value = undefined) {
  assertOwner(principal, humanId);
  const ownerHandle = deriveDeviceOwnerHandle(hmacKey, principal, humanId);
  if (
    value &&
    (value.ownerVersion !== DEVICE_REGISTRY_OWNER_VERSION || value.ownerHandle !== ownerHandle)
  ) {
    throw new DeviceRegistryV2Error(
      'registry-owner-conflict',
      'registry owner does not match authenticated principal',
    );
  }
  return { ownerVersion: DEVICE_REGISTRY_OWNER_VERSION, ownerHandle };
}

function assertStoredOwner(item, expectedOwnerHandle) {
  if (
    item.ownerVersion !== DEVICE_REGISTRY_OWNER_VERSION ||
    !isCanonicalOwnerHandle(item.ownerHandle)
  ) {
    throw new DeviceRegistryV2Error('corrupt-record', 'device registry returned an invalid owner handle');
  }
  if (item.ownerHandle !== expectedOwnerHandle) {
    throw new DeviceRegistryV2Error(
      'registry-owner-conflict',
      'registry owner does not match authenticated principal',
    );
  }
  return item;
}

function storedBaseOwnerDisposition(item, expectedOwnerHandle, nowEpochSec) {
  if (
    item.ownerVersion !== DEVICE_REGISTRY_OWNER_VERSION ||
    !isCanonicalOwnerHandle(item.ownerHandle)
  ) {
    throw new DeviceRegistryV2Error('corrupt-record', 'device registry returned an invalid owner handle');
  }
  if (item.ownerHandle === expectedOwnerHandle) return 'owned';
  // A foreign installation row remains an ownership fence through its bounded clock-skew grace. Once its physical
  // TTL is reached it is semantically absent even if DynamoDB has not removed it yet; registration may reclaim it by
  // exact CAS, while read/cleanup operations must leave the old owner's row untouched.
  if (item.ttl <= nowEpochSec) return 'reclaimable';
  throw new DeviceRegistryV2Error(
    'registry-owner-conflict',
    'registry owner does not match authenticated principal',
  );
}

function publicBinding(item, { idempotent = false, renewed = false } = {}) {
  if (
    !item ||
    item.schema !== SCHEMA ||
    typeof item.bindingId !== 'string' ||
    !BINDING_ID_RE.test(item.bindingId) ||
    !Number.isSafeInteger(item.bindingRevision) ||
    item.bindingRevision <= 0 ||
    !Number.isSafeInteger(item.expiresAtEpochSec) ||
    item.expiresAtEpochSec <= 0
  ) {
    throw new DeviceRegistryV2Error('corrupt-record', 'device registry returned an invalid binding');
  }
  return {
    bindingId: item.bindingId,
    bindingRevision: item.bindingRevision,
    expiresAtEpochSec: item.expiresAtEpochSec,
    idempotent,
    renewed,
  };
}

function currentDevice(item, targetKey, nowEpochSec) {
  if (
    !item ||
    item.schema !== SCHEMA ||
    typeof item.pk !== 'string' ||
    !INSTALLATION_KEY_RE.test(item.pk) ||
    item.sk !== BINDING_SK ||
    item.targetKey !== targetKey ||
    !Number.isSafeInteger(item.expiresAtEpochSec) ||
    item.expiresAtEpochSec <= nowEpochSec ||
    typeof item.voipToken !== 'string' ||
    item.voipToken.length === 0 ||
    typeof item.voipTokenHash !== 'string' ||
    item.voipTokenHash.length === 0 ||
    item.voipTokenHash !== tokenHash(item.voipToken) ||
    !PLATFORM_SET.has(item.platform) ||
    typeof item.bindingId !== 'string' ||
    !BINDING_ID_RE.test(item.bindingId) ||
    !Number.isSafeInteger(item.bindingRevision) ||
    item.bindingRevision <= 0
  ) {
    return null;
  }
  return {
    voipToken: item.voipToken,
    voipTokenHash: item.voipTokenHash,
    platform: item.platform,
    bindingId: item.bindingId,
    bindingRevision: item.bindingRevision,
    expiresAtEpochSec: item.expiresAtEpochSec,
    installationKey: item.pk,
  };
}

function assertStoredBinding(item, installationKey) {
  publicBinding(item);
  if (
    item.pk !== installationKey ||
    item.sk !== BINDING_SK ||
    item.ownerVersion !== DEVICE_REGISTRY_OWNER_VERSION ||
    !isCanonicalOwnerHandle(item.ownerHandle) ||
    typeof item.targetKey !== 'string' ||
    !TARGET_KEY_RE.test(item.targetKey) ||
    typeof item.voipToken !== 'string' ||
    item.voipToken.length === 0 ||
    typeof item.voipTokenHash !== 'string' ||
    !DIGEST_RE.test(item.voipTokenHash) ||
    item.voipTokenHash !== tokenHash(item.voipToken) ||
    !PLATFORM_SET.has(item.platform) ||
    typeof item.requestFingerprint !== 'string' ||
    !DIGEST_RE.test(item.requestFingerprint) ||
    typeof item.idempotencyKey !== 'string' ||
    !IDEMPOTENCY_KEY_RE.test(item.idempotencyKey) ||
    item.ttl !== physicalTtlEpochSec(item.expiresAtEpochSec)
  ) {
    throw new DeviceRegistryV2Error('corrupt-record', 'device registry returned an invalid binding');
  }
  return item;
}

function directoryMember(binding) {
  return {
    installationKey: binding.pk,
    bindingId: binding.bindingId,
    bindingRevision: binding.bindingRevision,
    expiresAtEpochSec: binding.expiresAtEpochSec,
  };
}

function directoryMemberMatches(member, binding) {
  return (
    member?.installationKey === binding?.pk &&
    member.bindingId === binding.bindingId &&
    member.bindingRevision === binding.bindingRevision &&
    member.expiresAtEpochSec === binding.expiresAtEpochSec
  );
}

function assertStoredTargetDirectory(item, targetKey) {
  if (
    !item ||
    item.pk !== targetKey ||
    item.sk !== TARGET_DIRECTORY_SK ||
    item.schema !== TARGET_DIRECTORY_SCHEMA ||
    !TARGET_KEY_RE.test(targetKey) ||
    typeof item.directoryId !== 'string' ||
    !TARGET_DIRECTORY_ID_RE.test(item.directoryId) ||
    item.capacity !== DEVICE_REGISTRATION_LIMITS.MAX_DEVICES ||
    !Number.isSafeInteger(item.revision) ||
    item.revision <= 0 ||
    !Number.isSafeInteger(item.updatedAtEpochSec) ||
    item.updatedAtEpochSec <= 0 ||
    !Number.isSafeInteger(item.expiresAtEpochSec) ||
    item.expiresAtEpochSec <= 0 ||
    item.ttl !== physicalTtlEpochSec(item.expiresAtEpochSec) ||
    !Array.isArray(item.members) ||
    item.members.length === 0 ||
    item.members.length > DEVICE_REGISTRATION_LIMITS.MAX_DEVICES
  ) {
    throw new DeviceRegistryV2Error('corrupt-record', 'device registry returned an invalid target directory');
  }
  let previous = '';
  let maximumExpiry = 0;
  for (const member of item.members) {
    if (
      !member ||
      Object.keys(member).sort().join(',') !== 'bindingId,bindingRevision,expiresAtEpochSec,installationKey' ||
      typeof member.installationKey !== 'string' ||
      !INSTALLATION_KEY_RE.test(member.installationKey) ||
      (previous && compareOpaque(previous, member.installationKey) >= 0) ||
      typeof member.bindingId !== 'string' ||
      !BINDING_ID_RE.test(member.bindingId) ||
      !Number.isSafeInteger(member.bindingRevision) ||
      member.bindingRevision <= 0 ||
      !Number.isSafeInteger(member.expiresAtEpochSec) ||
      member.expiresAtEpochSec <= 0
    ) {
      throw new DeviceRegistryV2Error('corrupt-record', 'device registry returned an invalid target directory');
    }
    previous = member.installationKey;
    maximumExpiry = Math.max(maximumExpiry, member.expiresAtEpochSec);
  }
  if (item.expiresAtEpochSec !== maximumExpiry) {
    throw new DeviceRegistryV2Error('corrupt-record', 'device registry returned an invalid target directory');
  }
  return item;
}

function activeDirectoryMembers(directory, nowEpochSec) {
  return directory ? directory.members.filter((member) => member.expiresAtEpochSec > nowEpochSec) : [];
}

function activityWindowIsStable(observations, startEpochSec, endEpochSec) {
  if (endEpochSec < startEpochSec) return false;
  for (const { item } of observations.values()) {
    const expiries = [
      item?.expiresAtEpochSec,
      item?.ttl,
      ...(Array.isArray(item?.members) ? item.members.map((member) => member?.expiresAtEpochSec) : []),
    ];
    for (const expiry of expiries) {
      if (Number.isSafeInteger(expiry) && expiry > startEpochSec !== expiry > endEpochSec) {
        return false;
      }
    }
  }
  return true;
}

function mutateTargetDirectory({ directory, targetKey, removeBindings = [], addBinding, nowEpochSec, maxDevices }) {
  if (directory) assertStoredTargetDirectory(directory, targetKey);
  let members = activeDirectoryMembers(directory, nowEpochSec);
  const removals = new Map();
  for (const binding of removeBindings) {
    if (!binding || binding.targetKey !== targetKey) {
      throw new DeviceRegistryV2Error('corrupt-record', 'target directory mutation has an invalid binding');
    }
    const key = [binding.pk, binding.bindingId, binding.bindingRevision, binding.expiresAtEpochSec].join(':');
    removals.set(key, binding);
  }
  for (const binding of removals.values()) {
    const storedMember = directory?.members.find((member) => member.installationKey === binding.pk);
    if (storedMember && !directoryMemberMatches(storedMember, binding)) {
      throw new DeviceRegistryV2Error('corrupt-record', 'device binding disagrees with its target directory member');
    }
    // A faster worker may have pruned this exact member at logical expiry while this worker (within the bounded skew)
    // still sees the base as active. A wholly missing member is recoverable: renewal re-adds it under the normal cap,
    // while unregister/rebind removes the exact base+claim. A present non-exact tuple remains a hard corruption fence.
    members = members.filter((member) => !directoryMemberMatches(member, binding));
  }
  if (addBinding) {
    if (
      addBinding.targetKey !== targetKey ||
      addBinding.expiresAtEpochSec <= nowEpochSec ||
      members.some((member) => member.installationKey === addBinding.pk)
    ) {
      throw new DeviceRegistryV2Error('corrupt-record', 'target directory mutation has an invalid binding');
    }
    if (members.length >= maxDevices) {
      throw new DeviceRegistryV2Error(
        'target-capacity',
        'target already has the maximum number of active device installations',
      );
    }
    members.push(directoryMember(addBinding));
  }
  members.sort((a, b) => compareOpaque(a.installationKey, b.installationKey));
  if (members.length === 0) return null;
  if (directory && directory.revision >= MAX_BINDING_REVISION) {
    throw new DeviceRegistryV2Error('revision-exhausted', 'target directory revision exhausted');
  }
  const expiresAtEpochSec = Math.max(...members.map((member) => member.expiresAtEpochSec));
  return {
    pk: targetKey,
    sk: TARGET_DIRECTORY_SK,
    schema: TARGET_DIRECTORY_SCHEMA,
    directoryId: directory?.directoryId ?? freshTargetDirectoryId(),
    capacity: DEVICE_REGISTRATION_LIMITS.MAX_DEVICES,
    revision: directory ? directory.revision + 1 : 1,
    members,
    updatedAtEpochSec: nowEpochSec,
    expiresAtEpochSec,
    ttl: physicalTtlEpochSec(expiresAtEpochSec),
  };
}

function registrationDirectoryEffects({ currentBinding, nextBinding, displacedBinding }) {
  const effects = new Map();
  const effectFor = (targetKey) => {
    if (!effects.has(targetKey)) effects.set(targetKey, { removeBindings: [], addBinding: undefined });
    return effects.get(targetKey);
  };
  if (currentBinding) effectFor(currentBinding.targetKey).removeBindings.push(currentBinding);
  if (displacedBinding) effectFor(displacedBinding.targetKey).removeBindings.push(displacedBinding);
  effectFor(nextBinding.targetKey).addBinding = nextBinding;
  return effects;
}

function assertStoredTokenClaim(item, tokenKey) {
  if (
    !item ||
    item.pk !== tokenKey ||
    item.sk !== TOKEN_CLAIM_SK ||
    item.schema !== TOKEN_CLAIM_SCHEMA ||
    item.ownerVersion !== DEVICE_REGISTRY_OWNER_VERSION ||
    !isCanonicalOwnerHandle(item.ownerHandle) ||
    !TOKEN_KEY_RE.test(tokenKey) ||
    typeof item.ownerInstallationKey !== 'string' ||
    !INSTALLATION_KEY_RE.test(item.ownerInstallationKey) ||
    typeof item.targetKey !== 'string' ||
    !TARGET_KEY_RE.test(item.targetKey) ||
    typeof item.tokenHash !== 'string' ||
    !DIGEST_RE.test(item.tokenHash) ||
    !PLATFORM_SET.has(item.platform) ||
    typeof item.bindingId !== 'string' ||
    !BINDING_ID_RE.test(item.bindingId) ||
    !Number.isSafeInteger(item.bindingRevision) ||
    item.bindingRevision <= 0 ||
    typeof item.tokenClaimId !== 'string' ||
    !TOKEN_CLAIM_ID_RE.test(item.tokenClaimId) ||
    !Number.isSafeInteger(item.tokenClaimRevision) ||
    item.tokenClaimRevision <= 0 ||
    !Number.isSafeInteger(item.expiresAtEpochSec) ||
    item.expiresAtEpochSec <= 0 ||
    item.ttl !== physicalTtlEpochSec(item.expiresAtEpochSec)
  ) {
    throw new DeviceRegistryV2Error('corrupt-record', 'device registry returned an invalid token claim');
  }
  return item;
}

function publicTokenClaim(item) {
  assertStoredTokenClaim(item, item?.pk);
  return {
    tokenClaimId: item.tokenClaimId,
    tokenClaimRevision: item.tokenClaimRevision,
    expiresAtEpochSec: item.expiresAtEpochSec,
  };
}

function claimMatchesBinding(claim, binding, tokenKey) {
  if (!claim || !binding) return false;
  assertStoredTokenClaim(claim, tokenKey);
  return (
    claim.ownerVersion === binding.ownerVersion &&
    claim.ownerHandle === binding.ownerHandle &&
    claim.ownerInstallationKey === binding.pk &&
    claim.targetKey === binding.targetKey &&
    claim.tokenHash === binding.voipTokenHash &&
    claim.platform === binding.platform &&
    claim.bindingId === binding.bindingId &&
    claim.bindingRevision === binding.bindingRevision &&
    claim.expiresAtEpochSec === binding.expiresAtEpochSec
  );
}

function claimOwnsBinding(claim, binding, tokenKey, nowEpochSec) {
  return claim?.expiresAtEpochSec > nowEpochSec && claimMatchesBinding(claim, binding, tokenKey);
}

function publicRegistration(binding, claim, options = {}) {
  if (
    binding.ownerVersion !== claim.ownerVersion ||
    binding.ownerHandle !== claim.ownerHandle
  ) {
    throw new DeviceRegistryV2Error('corrupt-record', 'device binding and token claim owners disagree');
  }
  return {
    ownerVersion: binding.ownerVersion,
    ownerHandle: binding.ownerHandle,
    ...publicBinding(binding, options),
    ...publicTokenClaim(claim),
  };
}

function assertStoredRegistrationOperation(item, operationKey) {
  const baseKeys = [
    'createdAtEpochSec',
    'expiresAtEpochSec',
    'ownerHandle',
    'ownerVersion',
    'pk',
    'requestFingerprint',
    'schema',
    'sk',
    'state',
    'ttl',
    'updatedAtEpochSec',
  ];
  const committedKeys = [
    ...baseKeys,
    'bindingId',
    'bindingRevision',
    'installationKey',
    'targetKey',
    'tokenClaimId',
    'tokenClaimRevision',
    'tokenKey',
  ];
  const expectedKeys = item?.state === 'committed' ? committedKeys : baseKeys;
  const commonInvalid =
    !item ||
    item.pk !== operationKey ||
    !REGISTRATION_OPERATION_KEY_RE.test(operationKey) ||
    item.sk !== REGISTRATION_OPERATION_SK ||
    item.schema !== REGISTRATION_OPERATION_SCHEMA ||
    !['committed', 'denied'].includes(item.state) ||
    Object.keys(item).sort().join(',') !== expectedKeys.sort().join(',') ||
    item.ownerVersion !== DEVICE_REGISTRY_OWNER_VERSION ||
    !isCanonicalOwnerHandle(item.ownerHandle) ||
    typeof item.requestFingerprint !== 'string' ||
    !DIGEST_RE.test(item.requestFingerprint) ||
    !Number.isSafeInteger(item.createdAtEpochSec) ||
    item.createdAtEpochSec <= 0 ||
    !Number.isSafeInteger(item.updatedAtEpochSec) ||
    item.updatedAtEpochSec < item.createdAtEpochSec ||
    !Number.isSafeInteger(item.expiresAtEpochSec) ||
    item.expiresAtEpochSec <= item.updatedAtEpochSec ||
    item.ttl !== physicalTtlEpochSec(item.expiresAtEpochSec);
  const committedInvalid =
    item?.state === 'committed' &&
    (typeof item.installationKey !== 'string' ||
      !INSTALLATION_KEY_RE.test(item.installationKey) ||
      typeof item.targetKey !== 'string' ||
      !TARGET_KEY_RE.test(item.targetKey) ||
      typeof item.tokenKey !== 'string' ||
      !TOKEN_KEY_RE.test(item.tokenKey) ||
      typeof item.bindingId !== 'string' ||
      !BINDING_ID_RE.test(item.bindingId) ||
      !Number.isSafeInteger(item.bindingRevision) ||
      item.bindingRevision <= 0 ||
      typeof item.tokenClaimId !== 'string' ||
      !TOKEN_CLAIM_ID_RE.test(item.tokenClaimId) ||
      !Number.isSafeInteger(item.tokenClaimRevision) ||
      item.tokenClaimRevision <= 0);
  if (commonInvalid || committedInvalid) {
    throw new DeviceRegistryV2Error('corrupt-record', 'device registry returned an invalid registration outcome');
  }
  return item;
}

function publicOperationRegistration(item) {
  assertStoredRegistrationOperation(item, item?.pk);
  if (item.state !== 'committed') {
    throw new DeviceRegistryV2Error('corrupt-record', 'denied registration outcome has no commit fences');
  }
  return {
    ownerVersion: item.ownerVersion,
    ownerHandle: item.ownerHandle,
    bindingId: item.bindingId,
    bindingRevision: item.bindingRevision,
    expiresAtEpochSec: item.expiresAtEpochSec,
    idempotent: true,
    renewed: false,
    tokenClaimId: item.tokenClaimId,
    tokenClaimRevision: item.tokenClaimRevision,
  };
}

function deniedRegistrationOperation({
  operationKey,
  ownerVersion,
  ownerHandle,
  requestFingerprint,
  nowEpochSec,
  leaseSeconds,
}) {
  const expiresAtEpochSec = nowEpochSec + leaseSeconds;
  if (!Number.isSafeInteger(expiresAtEpochSec) || expiresAtEpochSec <= nowEpochSec) {
    throw new DeviceRegistryV2Error('clock-invalid', 'registration outcome expiry is invalid');
  }
  return {
    pk: operationKey,
    sk: REGISTRATION_OPERATION_SK,
    schema: REGISTRATION_OPERATION_SCHEMA,
    state: 'denied',
    ownerVersion,
    ownerHandle,
    requestFingerprint,
    createdAtEpochSec: nowEpochSec,
    updatedAtEpochSec: nowEpochSec,
    expiresAtEpochSec,
    ttl: physicalTtlEpochSec(expiresAtEpochSec),
  };
}

function committedRegistrationOperation({ operationKey, requestFingerprint, binding, claim, nowEpochSec }) {
  const outcome = {
    pk: operationKey,
    sk: REGISTRATION_OPERATION_SK,
    schema: REGISTRATION_OPERATION_SCHEMA,
    state: 'committed',
    ownerVersion: binding.ownerVersion,
    ownerHandle: binding.ownerHandle,
    requestFingerprint,
    installationKey: binding.pk,
    targetKey: binding.targetKey,
    tokenKey: claim.pk,
    bindingId: binding.bindingId,
    bindingRevision: binding.bindingRevision,
    tokenClaimId: claim.tokenClaimId,
    tokenClaimRevision: claim.tokenClaimRevision,
    createdAtEpochSec: nowEpochSec,
    updatedAtEpochSec: nowEpochSec,
    expiresAtEpochSec: binding.expiresAtEpochSec,
    ttl: physicalTtlEpochSec(binding.expiresAtEpochSec),
  };
  assertStoredRegistrationOperation(outcome, operationKey);
  return outcome;
}

function registrationCleanupValue(value) {
  return {
    registrationVersion: value.registrationVersion,
    ownerVersion: value.ownerVersion,
    ownerHandle: value.ownerHandle,
    installationId: value.installationId,
    idempotencyKey: value.idempotencyKey,
    tokenDigest: tokenHash(value.voipToken),
    sessionId: value.sessionId,
    platform: value.platform,
  };
}

function registrationOperationIdentityFields({ hmacKey, principal, humanId, value }) {
  const operationKey = deriveDeviceRegistrationOperationKey(
    hmacKey,
    principal,
    humanId,
    value.installationId,
    value.idempotencyKey,
  );
  const installationKey = deriveDeviceInstallationKey(hmacKey, value.installationId);
  const targetKey = deriveDeviceTargetKey(hmacKey, principal, humanId, value.sessionId);
  const requestFingerprint = registrationFingerprint(hmacKey, targetKey, value.tokenDigest, value.platform);
  return {
    operationKey,
    installationKey,
    targetKey,
    ownerVersion: value.ownerVersion,
    ownerHandle: value.ownerHandle,
    requestFingerprint,
  };
}

function registrationIdentityFields({ hmacKey, principal, humanId, value }) {
  const voipTokenHash = tokenHash(value.voipToken);
  const tokenKey = deriveDeviceTokenKey(hmacKey, value.platform, value.voipToken);
  const operation = registrationOperationIdentityFields({
    hmacKey,
    principal,
    humanId,
    value: registrationCleanupValue(value),
  });
  return { ...operation, tokenKey, voipTokenHash };
}

function registrationFields({ hmacKey, principal, humanId, value, nowEpochSec, leaseSeconds }) {
  const identity = registrationIdentityFields({ hmacKey, principal, humanId, value });
  const expiresAtEpochSec = nowEpochSec + leaseSeconds;
  if (!Number.isSafeInteger(expiresAtEpochSec) || expiresAtEpochSec <= nowEpochSec) {
    throw new DeviceRegistryV2Error('clock-invalid', 'registration lease expiry is invalid');
  }
  physicalTtlEpochSec(expiresAtEpochSec);
  return { ...identity, expiresAtEpochSec };
}

function reclaimProtectedTokenClaim(claim, tokenKey, nowEpochSec, ownerHandle) {
  if (!claim) return null;
  assertStoredTokenClaim(claim, tokenKey);
  if (claim.ttl <= nowEpochSec) return null;
  assertStoredOwner(claim, ownerHandle);
  return claim;
}

function authorizeTokenClaim({ claim, tokenKey, currentBinding, value, nowEpochSec, ownerHandle }) {
  const protectedClaim = reclaimProtectedTokenClaim(claim, tokenKey, nowEpochSec, ownerHandle);
  const isCurrentOwner =
    protectedClaim && currentBinding && claimMatchesBinding(protectedClaim, currentBinding, tokenKey);
  if (isCurrentOwner) return { protectedClaim, isCurrentOwner: true };

  const suppliedExpected = value.expectedTokenClaimId !== undefined;
  if (!protectedClaim) {
    if (suppliedExpected) {
      throw new DeviceRegistryV2Error(
        'token-claim-conflict',
        'registration expected token claim is no longer current',
        { currentTokenClaim: null },
      );
    }
    return { protectedClaim: null, isCurrentOwner: false };
  }
  if (
    !suppliedExpected ||
    protectedClaim.tokenClaimId !== value.expectedTokenClaimId ||
    protectedClaim.tokenClaimRevision !== value.expectedTokenClaimRevision
  ) {
    throw new DeviceRegistryV2Error('token-claim-conflict', 'registration expected token claim is no longer current', {
      currentTokenClaim: publicTokenClaim(protectedClaim),
    });
  }
  return { protectedClaim, isCurrentOwner: false };
}

function nextTokenClaim({ protectedClaim, isCurrentOwner, binding, tokenKey, nowEpochSec }) {
  const keepIdentity =
    protectedClaim &&
    isCurrentOwner &&
    protectedClaim.bindingId === binding.bindingId &&
    protectedClaim.bindingRevision === binding.bindingRevision;
  if (protectedClaim && !keepIdentity && protectedClaim.tokenClaimRevision >= MAX_BINDING_REVISION) {
    throw new DeviceRegistryV2Error('revision-exhausted', 'token claim revision exhausted');
  }
  return {
    pk: tokenKey,
    sk: TOKEN_CLAIM_SK,
    schema: TOKEN_CLAIM_SCHEMA,
    ownerVersion: binding.ownerVersion,
    ownerHandle: binding.ownerHandle,
    ownerInstallationKey: binding.pk,
    targetKey: binding.targetKey,
    tokenHash: binding.voipTokenHash,
    platform: binding.platform,
    bindingId: binding.bindingId,
    bindingRevision: binding.bindingRevision,
    tokenClaimId: keepIdentity ? protectedClaim.tokenClaimId : freshTokenClaimId(),
    tokenClaimRevision: keepIdentity
      ? protectedClaim.tokenClaimRevision
      : protectedClaim
        ? protectedClaim.tokenClaimRevision + 1
        : 1,
    updatedAtEpochSec: nowEpochSec,
    expiresAtEpochSec: binding.expiresAtEpochSec,
    ttl: physicalTtlEpochSec(binding.expiresAtEpochSec),
  };
}

/**
 * Hermetic implementation with the same atomic registry-state semantics as Dynamo. Raw installation IDs are never
 * retained.
 */
export function createInMemoryDeviceRegistryV2({
  hmacKey,
  now = () => Date.now(),
  leaseSeconds = DEVICE_REGISTRATION_LEASE_SECONDS,
  maxDevices = DEVICE_REGISTRATION_LIMITS.MAX_DEVICES,
} = {}) {
  const key = readHmacKey(hmacKey);
  if (!Number.isSafeInteger(leaseSeconds) || leaseSeconds <= 0)
    throw new Error('device registry leaseSeconds must be positive');
  if (maxDevices !== DEVICE_REGISTRATION_LIMITS.MAX_DEVICES) {
    throw new Error(`device registry maxDevices is schema-fixed at ${DEVICE_REGISTRATION_LIMITS.MAX_DEVICES}`);
  }
  const records = new Map();
  const tokenClaims = new Map();
  const targetDirectories = new Map();
  const operations = new Map();

  return {
    protocolVersion: DEVICE_REGISTRATION_VERSION,
    operationOutcomeVersion: 1,
    async registrationContext({ principal, humanId } = {}) {
      return {
        registrationVersion: DEVICE_REGISTRATION_VERSION,
        ...authenticatedOwnerFields(key, principal, humanId),
      };
    },
    async denyRegistration({ principal, humanId, ...body } = {}) {
      const value = assertCleanupInput(body);
      authenticatedOwnerFields(key, principal, humanId, value);
      const nowEpochSec = safeNowSeconds(now);
      const f = registrationOperationIdentityFields({ hmacKey: key, principal, humanId, value });
      const binding = records.get(f.installationKey);
      if (binding) {
        assertStoredBinding(binding, f.installationKey);
        storedBaseOwnerDisposition(binding, f.ownerHandle, nowEpochSec);
      }
      const current = operations.get(f.operationKey);
      if (current) {
        assertStoredRegistrationOperation(current, f.operationKey);
        assertStoredOwner(current, f.ownerHandle);
        if (current.requestFingerprint !== f.requestFingerprint) {
          throw new DeviceRegistryV2Error(
            'idempotency-conflict',
            'idempotency key was reused for different registration data',
          );
        }
        return current.state === 'committed'
          ? { state: 'committed', registration: publicOperationRegistration(current) }
          : { state: 'denied', ownerVersion: f.ownerVersion, ownerHandle: f.ownerHandle };
      }
      operations.set(
        f.operationKey,
        deniedRegistrationOperation({
          operationKey: f.operationKey,
          ownerVersion: f.ownerVersion,
          ownerHandle: f.ownerHandle,
          requestFingerprint: f.requestFingerprint,
          nowEpochSec,
          leaseSeconds,
        }),
      );
      return { state: 'denied', ownerVersion: f.ownerVersion, ownerHandle: f.ownerHandle };
    },
    async reconcileRegistration({ principal, humanId, ...body } = {}) {
      const value = assertRegistryInput(body);
      authenticatedOwnerFields(key, principal, humanId, value);
      const f = registrationIdentityFields({ hmacKey: key, principal, humanId, value });
      const nowEpochSec = safeNowSeconds(now);
      const current = records.get(f.installationKey);
      if (current) {
        assertStoredBinding(current, f.installationKey);
        if (storedBaseOwnerDisposition(current, f.ownerHandle, nowEpochSec) === 'reclaimable') return null;
      }
      if (
        !current ||
        current.idempotencyKey !== value.idempotencyKey ||
        current.requestFingerprint !== f.requestFingerprint
      ) {
        return null;
      }
      const claim = tokenClaims.get(f.tokenKey);
      if (!claim || !claimMatchesBinding(claim, current, f.tokenKey)) {
        throw new DeviceRegistryV2Error('corrupt-record', 'exact registration replay has no exact token claim');
      }
      const result = publicRegistration(current, claim, { idempotent: true, renewed: false });
      return current.expiresAtEpochSec <= nowEpochSec ? { ...result, expired: true } : result;
    },
    async register({ principal, humanId, ...body } = {}) {
      const value = assertRegistryInput(body);
      authenticatedOwnerFields(key, principal, humanId, value);
      const nowEpochSec = safeNowSeconds(now);
      const f = registrationFields({ hmacKey: key, principal, humanId, value, nowEpochSec, leaseSeconds });
      const operation = operations.get(f.operationKey);
      if (operation) {
        assertStoredRegistrationOperation(operation, f.operationKey);
        assertStoredOwner(operation, f.ownerHandle);
        if (operation.requestFingerprint !== f.requestFingerprint) {
          throw new DeviceRegistryV2Error(
            'idempotency-conflict',
            'idempotency key was reused for different registration data',
          );
        }
        if (operation.state === 'denied') {
          throw new DeviceRegistryV2Error(
            'registration-operation-denied',
            'registration operation was durably denied before commit',
          );
        }
      }
      const observedCurrent = records.get(f.installationKey);
      let current = observedCurrent;
      if (observedCurrent) {
        assertStoredBinding(observedCurrent, f.installationKey);
        if (storedBaseOwnerDisposition(observedCurrent, f.ownerHandle, nowEpochSec) === 'reclaimable') {
          current = undefined;
        }
      }
      const priorBinding = observedCurrent;
      if (
        operation?.state === 'committed' &&
        (!current ||
          current.targetKey !== operation.targetKey ||
          current.bindingId !== operation.bindingId ||
          current.bindingRevision !== operation.bindingRevision ||
          current.requestFingerprint !== operation.requestFingerprint)
      ) {
        throw new DeviceRegistryV2Error(
          'binding-conflict',
          'registration expected binding is no longer current',
          { currentBinding: current ? publicBinding(current) : null },
        );
      }
      if (current && current.idempotencyKey === value.idempotencyKey) {
        if (current.requestFingerprint !== f.requestFingerprint) {
          throw new DeviceRegistryV2Error(
            'idempotency-conflict',
            'idempotency key was reused for different registration data',
          );
        }
      }
      let nextBinding;
      let resultOptions = {};
      if (current && current.requestFingerprint === f.requestFingerprint) {
        const sameOperation = current.idempotencyKey === value.idempotencyKey;
        if (
          !sameOperation &&
          (current.bindingId !== value.expectedBindingId ||
            current.bindingRevision !== value.expectedBindingRevision)
        ) {
          throw new DeviceRegistryV2Error(
            'binding-conflict',
            'registration expected binding is no longer current',
            { currentBinding: publicBinding(current) },
          );
        }
        if (!sameOperation && current.bindingRevision >= MAX_BINDING_REVISION) {
          throw new DeviceRegistryV2Error('revision-exhausted', 'binding revision exhausted');
        }
        const expiresAtEpochSec = Math.max(current.expiresAtEpochSec, f.expiresAtEpochSec);
        nextBinding = {
          ...current,
          // The request fingerprint intentionally excludes the idempotency key, so two authorized operations may
          // renew the same semantic route. They must still receive different revocation fences: otherwise cleanup for
          // older operation A can delete newer operation B. Exact retries keep the revision; a distinct operation
          // advances it while preserving the stable binding identity.
          bindingRevision: sameOperation ? current.bindingRevision : current.bindingRevision + 1,
          idempotencyKey: value.idempotencyKey,
          updatedAtEpochSec: nowEpochSec,
          expiresAtEpochSec,
          ttl: physicalTtlEpochSec(expiresAtEpochSec),
        };
        resultOptions = {
          idempotent: sameOperation,
          renewed: expiresAtEpochSec > current.expiresAtEpochSec,
        };
      } else {
        const expectedMatches = current
          ? current.bindingId === value.expectedBindingId && current.bindingRevision === value.expectedBindingRevision
          : value.expectedBindingId === undefined;
        if (!expectedMatches) {
          throw new DeviceRegistryV2Error(
            'binding-conflict',
            'registration expected binding is no longer current',
            current ? { currentBinding: publicBinding(current) } : { currentBinding: null },
          );
        }
        if (
          current &&
          (!Number.isSafeInteger(current.bindingRevision) || current.bindingRevision >= MAX_BINDING_REVISION)
        ) {
          throw new DeviceRegistryV2Error('revision-exhausted', 'binding revision exhausted');
        }
        nextBinding = {
          pk: f.installationKey,
          sk: BINDING_SK,
          schema: SCHEMA,
          ownerVersion: f.ownerVersion,
          ownerHandle: f.ownerHandle,
          targetKey: f.targetKey,
          voipToken: value.voipToken,
          voipTokenHash: f.voipTokenHash,
          platform: value.platform,
          bindingId: freshBindingId(),
          bindingRevision: current ? current.bindingRevision + 1 : 1,
          idempotencyKey: value.idempotencyKey,
          requestFingerprint: f.requestFingerprint,
          createdAtEpochSec: current?.createdAtEpochSec ?? nowEpochSec,
          updatedAtEpochSec: nowEpochSec,
          expiresAtEpochSec: f.expiresAtEpochSec,
          ttl: physicalTtlEpochSec(f.expiresAtEpochSec),
        };
      }

      const requestedClaim = tokenClaims.get(f.tokenKey);
      if (current && current.expiresAtEpochSec > nowEpochSec) {
        const currentTokenKey = deriveDeviceTokenKey(key, current.platform, current.voipToken);
        const currentClaim = tokenClaims.get(currentTokenKey);
        if (!claimOwnsBinding(currentClaim, current, currentTokenKey, nowEpochSec)) {
          throw new DeviceRegistryV2Error('corrupt-record', 'active device binding has no exact token claim');
        }
      }
      const claimAuthorization = authorizeTokenClaim({
        claim: requestedClaim,
        tokenKey: f.tokenKey,
        currentBinding: current,
        value,
        nowEpochSec,
        ownerHandle: f.ownerHandle,
      });
      const nextClaim = nextTokenClaim({
        protectedClaim: claimAuthorization.protectedClaim,
        isCurrentOwner: claimAuthorization.isCurrentOwner,
        binding: nextBinding,
        tokenKey: f.tokenKey,
        nowEpochSec,
      });
      let displacedBinding;
      if (claimAuthorization.protectedClaim && !claimAuthorization.isCurrentOwner) {
        if (claimAuthorization.protectedClaim.ownerInstallationKey === f.installationKey) {
          throw new DeviceRegistryV2Error('corrupt-record', 'token claim disagrees with its installation binding');
        }
        displacedBinding = records.get(claimAuthorization.protectedClaim.ownerInstallationKey);
        if (displacedBinding) {
          assertStoredBinding(displacedBinding, claimAuthorization.protectedClaim.ownerInstallationKey);
          assertStoredOwner(displacedBinding, f.ownerHandle);
        }
        if (
          !displacedBinding ||
          !claimMatchesBinding(claimAuthorization.protectedClaim, displacedBinding, f.tokenKey)
        ) {
          throw new DeviceRegistryV2Error('corrupt-record', 'token claim has no exact installation binding');
        }
      }
      const directoryPlans = new Map();
      for (const [targetKey, effect] of registrationDirectoryEffects({
        currentBinding: priorBinding,
        nextBinding,
        displacedBinding,
      })) {
        const directory = targetDirectories.get(targetKey);
        const nextDirectory = mutateTargetDirectory({
          directory,
          targetKey,
          ...effect,
          nowEpochSec,
          maxDevices,
        });
        directoryPlans.set(targetKey, nextDirectory);
      }

      // One synchronous state transition mirrors the Dynamo TransactWrite: no observer can see a new binding without
      // its exact token owner and bounded target-directory membership. A cross-install transfer must CAS the claim tuple
      // returned by a prior 409.
      if (priorBinding && (priorBinding.platform !== value.platform || priorBinding.voipTokenHash !== f.voipTokenHash)) {
        const oldTokenKey = deriveDeviceTokenKey(key, priorBinding.platform, priorBinding.voipToken);
        const oldClaim = tokenClaims.get(oldTokenKey);
        if (oldClaim) {
          assertStoredTokenClaim(oldClaim, oldTokenKey);
          if (
            oldClaim.ownerInstallationKey === priorBinding.pk &&
            oldClaim.bindingId === priorBinding.bindingId &&
            oldClaim.bindingRevision === priorBinding.bindingRevision
          ) {
            tokenClaims.delete(oldTokenKey);
          }
        }
      }
      if (displacedBinding) records.delete(displacedBinding.pk);
      records.set(f.installationKey, nextBinding);
      tokenClaims.set(f.tokenKey, nextClaim);
      for (const [targetKey, nextDirectory] of directoryPlans) {
        if (nextDirectory) targetDirectories.set(targetKey, nextDirectory);
        else targetDirectories.delete(targetKey);
      }
      operations.set(
        f.operationKey,
        committedRegistrationOperation({
          operationKey: f.operationKey,
          requestFingerprint: f.requestFingerprint,
          binding: nextBinding,
          claim: nextClaim,
          nowEpochSec,
        }),
      );
      return publicRegistration(nextBinding, nextClaim, resultOptions);
    },
    async unregister({ principal, humanId, ...body } = {}) {
      const value = assertUnregisterInput(body);
      const owner = authenticatedOwnerFields(key, principal, humanId, value);
      const installationKey = deriveDeviceInstallationKey(key, value.installationId);
      const targetKey = deriveDeviceTargetKey(key, principal, humanId, value.sessionId);
      const nowEpochSec = safeNowSeconds(now);
      const current = records.get(installationKey);
      if (current) {
        assertStoredBinding(current, installationKey);
        if (storedBaseOwnerDisposition(current, owner.ownerHandle, nowEpochSec) === 'reclaimable') {
          return { removed: false, ...owner };
        }
      }
      const matches =
        current &&
        current.schema === SCHEMA &&
        current.targetKey === targetKey &&
        current.bindingId === value.bindingId &&
        current.bindingRevision === value.bindingRevision;
      if (matches) {
        const directory = targetDirectories.get(targetKey);
        const nextDirectory = mutateTargetDirectory({
          directory,
          targetKey,
          removeBindings: [current],
          nowEpochSec,
          maxDevices,
        });
        const tokenKey = deriveDeviceTokenKey(key, current.platform, current.voipToken);
        const claim = tokenClaims.get(tokenKey);
        let exactClaim = false;
        if (claim) {
          assertStoredTokenClaim(claim, tokenKey);
          exactClaim =
            claim.ownerInstallationKey === current.pk &&
            claim.targetKey === current.targetKey &&
            claim.tokenHash === current.voipTokenHash &&
            claim.platform === current.platform &&
            claim.bindingId === current.bindingId &&
            claim.bindingRevision === current.bindingRevision &&
            claim.expiresAtEpochSec === current.expiresAtEpochSec;
        }
        if (current.expiresAtEpochSec > nowEpochSec && !exactClaim) {
          throw new DeviceRegistryV2Error('corrupt-record', 'active device binding has no exact token claim');
        }
        if (exactClaim) tokenClaims.delete(tokenKey);
        records.delete(installationKey);
        if (nextDirectory) targetDirectories.set(targetKey, nextDirectory);
        else targetDirectories.delete(targetKey);
      }
      return { removed: Boolean(matches), ...owner };
    },
    async lookup({ principal, humanId, sessionId } = {}) {
      const owner = authenticatedOwnerFields(key, principal, humanId);
      const sessionError = canonicalOpaque(sessionId, 'sessionId', DEVICE_REGISTRATION_LIMITS.SESSION_ID_BYTES);
      if (sessionError) throw new DeviceRegistryV2Error('invalid-input', sessionError.error);
      const targetKey = deriveDeviceTargetKey(key, principal, humanId, sessionId);
      const nowEpochSec = safeNowSeconds(now);
      const directory = targetDirectories.get(targetKey);
      if (!directory) return [];
      assertStoredTargetDirectory(directory, targetKey);
      return activeDirectoryMembers(directory, nowEpochSec)
        .map((member) => {
          const item = records.get(member.installationKey);
          const device = directoryMemberMatches(member, item) ? currentDevice(item, targetKey, nowEpochSec) : null;
          if (!item || !device) {
            throw new DeviceRegistryV2Error(
              'corrupt-record',
              'target directory member disagrees with its installation binding',
            );
          }
          assertStoredOwner(item, owner.ownerHandle);
          const tokenKey = deriveDeviceTokenKey(key, device.platform, device.voipToken);
          if (!claimOwnsBinding(tokenClaims.get(tokenKey), item, tokenKey, nowEpochSec)) {
            throw new DeviceRegistryV2Error('corrupt-record', 'target directory member has no exact token claim');
          }
          return { item, device };
        })
        .map(({ device }) => device)
        .sort((a, b) => compareOpaque(a.installationKey, b.installationKey))
        .map(({ installationKey: _installationKey, voipTokenHash: _voipTokenHash, ...device }) => device);
    },
    _records: records,
    _tokenClaims: tokenClaims,
    _targetDirectories: targetDirectories,
    _operations: operations,
  };
}

/**
 * DynamoDB V2 registry. One base-table item is keyed by HMAC(installationId). Each HMAC human/session target has one
 * strongly-read directory containing exactly the schema-fixed maximum of 20 installation keys. Binding, token
 * ownership, and every affected directory move in one transaction, so lookup never depends on an
 * unbounded/eventually-consistent GSI.
 */
export function createDynamoDeviceRegistryV2({
  client,
  table,
  hmacKey,
  now = () => Date.now(),
  leaseSeconds = DEVICE_REGISTRATION_LEASE_SECONDS,
  maxDevices = DEVICE_REGISTRATION_LIMITS.MAX_DEVICES,
  retryDelay = defaultRetryDelay,
} = {}) {
  if (!client || typeof client.get !== 'function' || typeof client.transactWrite !== 'function') {
    throw new Error('createDynamoDeviceRegistryV2 requires a { get, transactWrite } client');
  }
  if (typeof table !== 'string' || !table.trim()) throw new Error('device registry table required');
  const key = readHmacKey(hmacKey);
  if (!Number.isSafeInteger(leaseSeconds) || leaseSeconds <= 0)
    throw new Error('device registry leaseSeconds must be positive');
  if (maxDevices !== DEVICE_REGISTRATION_LIMITS.MAX_DEVICES) {
    throw new Error(`device registry maxDevices is schema-fixed at ${DEVICE_REGISTRATION_LIMITS.MAX_DEVICES}`);
  }
  if (typeof retryDelay !== 'function') throw new Error('device registry retryDelay must be a function');

  const strongGet = async (pk, sk) => {
    const response = await client.get({
      TableName: table,
      Key: { pk, sk },
      ConsistentRead: true,
    });
    return response?.Item;
  };
  const observationKey = (pk, sk) => JSON.stringify([pk, sk]);
  const observe = async (observations, pk, sk) => {
    const item = await strongGet(pk, sk);
    const snapshot = item === undefined ? undefined : structuredClone(item);
    observations.set(observationKey(pk, sk), { pk, sk, item: snapshot });
    return snapshot;
  };
  const observationsAreStable = async (observations) => {
    const entries = [...observations.values()];
    const current = await Promise.all(entries.map(({ pk, sk }) => strongGet(pk, sk)));
    return entries.every(({ item }, index) => isDeepStrictEqual(item, current[index]));
  };
  const waitToRetry = async (attempt) => {
    if (attempt + 1 < DEVICE_REGISTRY_MAX_SERIALIZATION_ATTEMPTS) {
      await retryDelay(attempt + 1);
    }
  };
  const baseGet = (installationKey) => strongGet(installationKey, BINDING_SK);
  const targetDirectoryGet = (targetKey) => strongGet(targetKey, TARGET_DIRECTORY_SK);

  const registrationOperationPut = (nextOperation, currentOperation) => ({
    Put: {
      TableName: table,
      Item: nextOperation,
      ConditionExpression: currentOperation
        ? [
            '#schema = :schema AND #ownerVersion = :ownerVersion AND #ownerHandle = :ownerHandle',
            'AND #state = :state AND #fingerprint = :fingerprint',
            'AND #bindingId = :bindingId AND #bindingRevision = :bindingRevision',
            'AND #claimId = :claimId AND #claimRevision = :claimRevision AND #expires = :expires',
          ].join(' ')
        : 'attribute_not_exists(#pk)',
      ExpressionAttributeNames: currentOperation
        ? {
            '#schema': 'schema',
            '#ownerVersion': 'ownerVersion',
            '#ownerHandle': 'ownerHandle',
            '#state': 'state',
            '#fingerprint': 'requestFingerprint',
            '#bindingId': 'bindingId',
            '#bindingRevision': 'bindingRevision',
            '#claimId': 'tokenClaimId',
            '#claimRevision': 'tokenClaimRevision',
            '#expires': 'expiresAtEpochSec',
          }
        : { '#pk': 'pk' },
      ...(currentOperation
        ? {
            ExpressionAttributeValues: {
              ':schema': REGISTRATION_OPERATION_SCHEMA,
              ':ownerVersion': DEVICE_REGISTRY_OWNER_VERSION,
              ':ownerHandle': currentOperation.ownerHandle,
              ':state': 'committed',
              ':fingerprint': currentOperation.requestFingerprint,
              ':bindingId': currentOperation.bindingId,
              ':bindingRevision': currentOperation.bindingRevision,
              ':claimId': currentOperation.tokenClaimId,
              ':claimRevision': currentOperation.tokenClaimRevision,
              ':expires': currentOperation.expiresAtEpochSec,
            },
          }
        : {}),
    },
  });

  const basePut = (nextBinding, current) => ({
    Put: {
      TableName: table,
      Item: nextBinding,
      ConditionExpression: current
        ? [
            '#schema = :schema AND #ownerVersion = :ownerVersion AND #ownerHandle = :ownerHandle',
            'AND #bindingId = :bindingId AND #revision = :revision',
            'AND #expires = :expires AND #fingerprint = :fingerprint',
          ].join(' ')
        : 'attribute_not_exists(#pk)',
      ExpressionAttributeNames: current
        ? {
            '#schema': 'schema',
            '#ownerVersion': 'ownerVersion',
            '#ownerHandle': 'ownerHandle',
            '#bindingId': 'bindingId',
            '#revision': 'bindingRevision',
            '#expires': 'expiresAtEpochSec',
            '#fingerprint': 'requestFingerprint',
          }
        : {
            '#pk': 'pk',
          },
      ...(current
        ? {
            ExpressionAttributeValues: {
              ':schema': SCHEMA,
              ':ownerVersion': DEVICE_REGISTRY_OWNER_VERSION,
              ':ownerHandle': current.ownerHandle,
              ':bindingId': current.bindingId,
              ':revision': current.bindingRevision,
              ':expires': current.expiresAtEpochSec,
              ':fingerprint': current.requestFingerprint,
            },
          }
        : {}),
    },
  });

  const baseDelete = (binding) => ({
    Delete: {
      TableName: table,
      Key: { pk: binding.pk, sk: BINDING_SK },
      ConditionExpression: [
        '#schema = :schema AND #ownerVersion = :ownerVersion AND #ownerHandle = :ownerHandle',
        'AND #target = :target',
        'AND #bindingId = :bindingId AND #revision = :revision',
        'AND #expires = :expires AND #tokenHash = :tokenHash AND #platform = :platform',
      ].join(' '),
      ExpressionAttributeNames: {
        '#schema': 'schema',
        '#ownerVersion': 'ownerVersion',
        '#ownerHandle': 'ownerHandle',
        '#target': 'targetKey',
        '#bindingId': 'bindingId',
        '#revision': 'bindingRevision',
        '#expires': 'expiresAtEpochSec',
        '#tokenHash': 'voipTokenHash',
        '#platform': 'platform',
      },
      ExpressionAttributeValues: {
        ':schema': SCHEMA,
        ':ownerVersion': DEVICE_REGISTRY_OWNER_VERSION,
        ':ownerHandle': binding.ownerHandle,
        ':target': binding.targetKey,
        ':bindingId': binding.bindingId,
        ':revision': binding.bindingRevision,
        ':expires': binding.expiresAtEpochSec,
        ':tokenHash': binding.voipTokenHash,
        ':platform': binding.platform,
      },
    },
  });

  const claimPut = (nextClaim, protectedClaim, nowEpochSec) => ({
    Put: {
      TableName: table,
      Item: nextClaim,
      ConditionExpression: protectedClaim
        ? [
            '#schema = :schema AND #ownerVersion = :ownerVersion AND #ownerHandle = :ownerHandle',
            'AND #claimId = :claimId AND #claimRevision = :claimRevision',
          ].join(' ')
        : '(attribute_not_exists(#pk) OR #ttl <= :now)',
      ExpressionAttributeNames: protectedClaim
        ? {
            '#schema': 'schema',
            '#ownerVersion': 'ownerVersion',
            '#ownerHandle': 'ownerHandle',
            '#claimId': 'tokenClaimId',
            '#claimRevision': 'tokenClaimRevision',
          }
        : {
            '#pk': 'pk',
            '#ttl': 'ttl',
          },
      ExpressionAttributeValues: protectedClaim
        ? {
            ':schema': TOKEN_CLAIM_SCHEMA,
            ':ownerVersion': DEVICE_REGISTRY_OWNER_VERSION,
            ':ownerHandle': protectedClaim.ownerHandle,
            ':claimId': protectedClaim.tokenClaimId,
            ':claimRevision': protectedClaim.tokenClaimRevision,
          }
        : {
            ':now': nowEpochSec,
          },
    },
  });

  const claimDelete = (claim) => ({
    Delete: {
      TableName: table,
      Key: { pk: claim.pk, sk: TOKEN_CLAIM_SK },
      ConditionExpression: [
        '#schema = :schema AND #ownerVersion = :ownerVersion AND #ownerHandle = :ownerHandle',
        'AND #claimId = :claimId AND #claimRevision = :claimRevision',
        'AND #owner = :owner AND #bindingId = :bindingId AND #bindingRevision = :bindingRevision',
      ].join(' '),
      ExpressionAttributeNames: {
        '#schema': 'schema',
        '#ownerVersion': 'ownerVersion',
        '#ownerHandle': 'ownerHandle',
        '#claimId': 'tokenClaimId',
        '#claimRevision': 'tokenClaimRevision',
        '#owner': 'ownerInstallationKey',
        '#bindingId': 'bindingId',
        '#bindingRevision': 'bindingRevision',
      },
      ExpressionAttributeValues: {
        ':schema': TOKEN_CLAIM_SCHEMA,
        ':ownerVersion': DEVICE_REGISTRY_OWNER_VERSION,
        ':ownerHandle': claim.ownerHandle,
        ':claimId': claim.tokenClaimId,
        ':claimRevision': claim.tokenClaimRevision,
        ':owner': claim.ownerInstallationKey,
        ':bindingId': claim.bindingId,
        ':bindingRevision': claim.bindingRevision,
      },
    },
  });

  const targetDirectoryPut = (nextDirectory, currentDirectory) => ({
    Put: {
      TableName: table,
      Item: nextDirectory,
      ConditionExpression: currentDirectory
        ? '#schema = :schema AND #directoryId = :directoryId AND #revision = :revision'
        : 'attribute_not_exists(#pk)',
      ExpressionAttributeNames: currentDirectory
        ? {
            '#schema': 'schema',
            '#directoryId': 'directoryId',
            '#revision': 'revision',
          }
        : {
            '#pk': 'pk',
          },
      ...(currentDirectory
        ? {
            ExpressionAttributeValues: {
              ':schema': TARGET_DIRECTORY_SCHEMA,
              ':directoryId': currentDirectory.directoryId,
              ':revision': currentDirectory.revision,
            },
          }
        : {}),
    },
  });

  const targetDirectoryDelete = (currentDirectory) => ({
    Delete: {
      TableName: table,
      Key: { pk: currentDirectory.pk, sk: TARGET_DIRECTORY_SK },
      ConditionExpression: '#schema = :schema AND #directoryId = :directoryId AND #revision = :revision',
      ExpressionAttributeNames: {
        '#schema': 'schema',
        '#directoryId': 'directoryId',
        '#revision': 'revision',
      },
      ExpressionAttributeValues: {
        ':schema': TARGET_DIRECTORY_SCHEMA,
        ':directoryId': currentDirectory.directoryId,
        ':revision': currentDirectory.revision,
      },
    },
  });

  return {
    protocolVersion: DEVICE_REGISTRATION_VERSION,
    operationOutcomeVersion: 1,
    async registrationContext({ principal, humanId } = {}) {
      return {
        registrationVersion: DEVICE_REGISTRATION_VERSION,
        ...authenticatedOwnerFields(key, principal, humanId),
      };
    },
    async denyRegistration({ principal, humanId, ...body } = {}) {
      const value = assertCleanupInput(body);
      authenticatedOwnerFields(key, principal, humanId, value);
      for (let attempt = 0; attempt < DEVICE_REGISTRY_MAX_SERIALIZATION_ATTEMPTS; attempt += 1) {
        const nowEpochSec = safeNowSeconds(now);
        const f = registrationOperationIdentityFields({ hmacKey: key, principal, humanId, value });
        const binding = await baseGet(f.installationKey);
        if (binding) {
          assertStoredBinding(binding, f.installationKey);
          storedBaseOwnerDisposition(binding, f.ownerHandle, nowEpochSec);
        }
        const current = await strongGet(f.operationKey, REGISTRATION_OPERATION_SK);
        if (current) {
          assertStoredRegistrationOperation(current, f.operationKey);
          assertStoredOwner(current, f.ownerHandle);
          if (current.requestFingerprint !== f.requestFingerprint) {
            throw new DeviceRegistryV2Error(
              'idempotency-conflict',
              'idempotency key was reused for different registration data',
            );
          }
          return current.state === 'committed'
            ? { state: 'committed', registration: publicOperationRegistration(current) }
            : { state: 'denied', ownerVersion: f.ownerVersion, ownerHandle: f.ownerHandle };
        }
        const denied = deniedRegistrationOperation({
          operationKey: f.operationKey,
          ownerVersion: f.ownerVersion,
          ownerHandle: f.ownerHandle,
          requestFingerprint: f.requestFingerprint,
          nowEpochSec,
          leaseSeconds,
        });
        const transactItems = [registrationOperationPut(denied)];
        try {
          await client.transactWrite({ TransactItems: transactItems });
          return { state: 'denied', ownerVersion: f.ownerVersion, ownerHandle: f.ownerHandle };
        } catch (error) {
          if (isTransactionRetryable(error, transactItems.length)) {
            await waitToRetry(attempt);
            continue;
          }
          throw error;
        }
      }
      throw new DeviceRegistryV2Error(
        'registration-outcome-conflict',
        'registration denial could not be serialized',
      );
    },
    async reconcileRegistration({ principal, humanId, ...body } = {}) {
      const value = assertRegistryInput(body);
      authenticatedOwnerFields(key, principal, humanId, value);
      const f = registrationIdentityFields({ hmacKey: key, principal, humanId, value });
      const nowEpochSec = safeNowSeconds(now);
      const current = await baseGet(f.installationKey);
      if (current) {
        assertStoredBinding(current, f.installationKey);
        if (storedBaseOwnerDisposition(current, f.ownerHandle, nowEpochSec) === 'reclaimable') return null;
      }
      if (
        !current ||
        current.idempotencyKey !== value.idempotencyKey ||
        current.requestFingerprint !== f.requestFingerprint
      ) {
        return null;
      }
      const claim = await strongGet(f.tokenKey, TOKEN_CLAIM_SK);
      if (!claim || !claimMatchesBinding(claim, current, f.tokenKey)) {
        throw new DeviceRegistryV2Error('corrupt-record', 'exact registration replay has no exact token claim');
      }
      const result = publicRegistration(current, claim, { idempotent: true, renewed: false });
      return current.expiresAtEpochSec <= nowEpochSec ? { ...result, expired: true } : result;
    },
    async register({ principal, humanId, ...body } = {}) {
      const value = assertRegistryInput(body);
      authenticatedOwnerFields(key, principal, humanId, value);

      // Binding + global (platform,token) ownership move in one transaction. A second installation cannot win merely
      // because its physical write arrived late: an active cross-owner claim requires the exact claim tuple returned by
      // a prior 409. The same installation may renew/rotate its own exact claim alongside its binding CAS.
      for (let attempt = 0; attempt < DEVICE_REGISTRY_MAX_SERIALIZATION_ATTEMPTS; attempt += 1) {
        const observations = new Map();
        const nowEpochSec = safeNowSeconds(now);
        try {
          const f = registrationFields({ hmacKey: key, principal, humanId, value, nowEpochSec, leaseSeconds });
          const operation = await observe(observations, f.operationKey, REGISTRATION_OPERATION_SK);
          if (operation) {
            assertStoredRegistrationOperation(operation, f.operationKey);
            assertStoredOwner(operation, f.ownerHandle);
            if (operation.requestFingerprint !== f.requestFingerprint) {
              throw new DeviceRegistryV2Error(
                'idempotency-conflict',
                'idempotency key was reused for different registration data',
              );
            }
            if (operation.state === 'denied') {
              throw new DeviceRegistryV2Error(
                'registration-operation-denied',
                'registration operation was durably denied before commit',
              );
            }
          }
          const observedCurrent = await observe(observations, f.installationKey, BINDING_SK);
          let current = observedCurrent;
          if (observedCurrent) {
            assertStoredBinding(observedCurrent, f.installationKey);
            if (storedBaseOwnerDisposition(observedCurrent, f.ownerHandle, nowEpochSec) === 'reclaimable') {
              current = undefined;
            }
          }
          const priorBinding = observedCurrent;
          if (
            operation?.state === 'committed' &&
            (!current ||
              current.targetKey !== operation.targetKey ||
              current.bindingId !== operation.bindingId ||
              current.bindingRevision !== operation.bindingRevision ||
              current.requestFingerprint !== operation.requestFingerprint)
          ) {
            throw new DeviceRegistryV2Error(
              'binding-conflict',
              'registration expected binding is no longer current',
              { currentBinding: current ? publicBinding(current) : null },
            );
          }
          if (current?.idempotencyKey === value.idempotencyKey && current.requestFingerprint !== f.requestFingerprint) {
            throw new DeviceRegistryV2Error(
              'idempotency-conflict',
              'idempotency key was reused for different registration data',
            );
          }

          let nextBinding;
          let resultOptions = {};
          if (current?.requestFingerprint === f.requestFingerprint) {
            const sameOperation = current.idempotencyKey === value.idempotencyKey;
            if (
              !sameOperation &&
              (current.bindingId !== value.expectedBindingId ||
                current.bindingRevision !== value.expectedBindingRevision)
            ) {
              throw new DeviceRegistryV2Error(
                'binding-conflict',
                'registration expected binding is no longer current',
                { currentBinding: publicBinding(current) },
              );
            }
            if (!sameOperation && current.bindingRevision >= MAX_BINDING_REVISION) {
              throw new DeviceRegistryV2Error('revision-exhausted', 'binding revision exhausted');
            }
            const expiresAtEpochSec = Math.max(current.expiresAtEpochSec, f.expiresAtEpochSec);
            nextBinding = {
              ...current,
              // A fresh operation over the same semantic route is a new revocation generation. Exact retries renew in
              // place; distinct idempotency keys advance the revision so stale cleanup cannot erase the newer grant.
              bindingRevision: sameOperation ? current.bindingRevision : current.bindingRevision + 1,
              idempotencyKey: value.idempotencyKey,
              updatedAtEpochSec: nowEpochSec,
              expiresAtEpochSec,
              ttl: physicalTtlEpochSec(expiresAtEpochSec),
            };
            resultOptions = {
              idempotent: sameOperation,
              renewed: expiresAtEpochSec > current.expiresAtEpochSec,
            };
          } else {
            const expectsBinding = value.expectedBindingId !== undefined;
            if (current) {
              const expectedMatches =
                current.bindingId === value.expectedBindingId &&
                current.bindingRevision === value.expectedBindingRevision;
              if (!expectedMatches) {
                throw new DeviceRegistryV2Error(
                  'binding-conflict',
                  'registration expected binding is no longer current',
                  { currentBinding: publicBinding(current) },
                );
              }
              if (current.bindingRevision >= MAX_BINDING_REVISION) {
                throw new DeviceRegistryV2Error('revision-exhausted', 'binding revision exhausted');
              }
            } else if (expectsBinding) {
              throw new DeviceRegistryV2Error(
                'binding-conflict',
                'registration expected binding is no longer current',
                { currentBinding: null },
              );
            }
            nextBinding = {
              pk: f.installationKey,
              sk: BINDING_SK,
              schema: SCHEMA,
              ownerVersion: f.ownerVersion,
              ownerHandle: f.ownerHandle,
              targetKey: f.targetKey,
              voipToken: value.voipToken,
              voipTokenHash: f.voipTokenHash,
              platform: value.platform,
              bindingId: freshBindingId(),
              bindingRevision: current ? current.bindingRevision + 1 : 1,
              idempotencyKey: value.idempotencyKey,
              requestFingerprint: f.requestFingerprint,
              createdAtEpochSec: current?.createdAtEpochSec ?? nowEpochSec,
              updatedAtEpochSec: nowEpochSec,
              expiresAtEpochSec: f.expiresAtEpochSec,
              ttl: physicalTtlEpochSec(f.expiresAtEpochSec),
            };
          }

          const claim = await observe(observations, f.tokenKey, TOKEN_CLAIM_SK);
          const claimAuthorization = authorizeTokenClaim({
            claim,
            tokenKey: f.tokenKey,
            currentBinding: current,
            value,
            nowEpochSec,
            ownerHandle: f.ownerHandle,
          });
          const nextClaim = nextTokenClaim({
            protectedClaim: claimAuthorization.protectedClaim,
            isCurrentOwner: claimAuthorization.isCurrentOwner,
            binding: nextBinding,
            tokenKey: f.tokenKey,
            nowEpochSec,
          });

          let oldClaim;
          let oldTokenKey;
          if (
            priorBinding &&
            (priorBinding.platform !== value.platform || priorBinding.voipTokenHash !== f.voipTokenHash)
          ) {
            oldTokenKey = deriveDeviceTokenKey(key, priorBinding.platform, priorBinding.voipToken);
            oldClaim = await observe(observations, oldTokenKey, TOKEN_CLAIM_SK);
            if (oldClaim) {
              assertStoredTokenClaim(oldClaim, oldTokenKey);
              const ownedOldClaim =
                oldClaim.ownerInstallationKey === priorBinding.pk &&
                oldClaim.bindingId === priorBinding.bindingId &&
                oldClaim.bindingRevision === priorBinding.bindingRevision;
              if (!ownedOldClaim) oldClaim = undefined;
            }
          }
          if (current && current.expiresAtEpochSec > nowEpochSec) {
            const currentTokenKey = oldTokenKey ?? f.tokenKey;
            const currentClaim = oldTokenKey ? oldClaim : claim;
            if (!claimOwnsBinding(currentClaim, current, currentTokenKey, nowEpochSec)) {
              throw new DeviceRegistryV2Error('corrupt-record', 'active device binding has no exact token claim');
            }
          }

          let displacedBinding;
          if (claimAuthorization.protectedClaim && !claimAuthorization.isCurrentOwner) {
            if (claimAuthorization.protectedClaim.ownerInstallationKey === f.installationKey) {
              throw new DeviceRegistryV2Error('corrupt-record', 'token claim disagrees with its installation binding');
            }
            displacedBinding = await observe(
              observations,
              claimAuthorization.protectedClaim.ownerInstallationKey,
              BINDING_SK,
            );
            if (displacedBinding) {
              assertStoredBinding(displacedBinding, claimAuthorization.protectedClaim.ownerInstallationKey);
              assertStoredOwner(displacedBinding, f.ownerHandle);
            }
            if (
              !displacedBinding ||
              !claimMatchesBinding(claimAuthorization.protectedClaim, displacedBinding, f.tokenKey)
            ) {
              throw new DeviceRegistryV2Error('corrupt-record', 'token claim has no exact installation binding');
            }
          }
          const directoryWrites = [];
          for (const [targetKey, effect] of registrationDirectoryEffects({
            currentBinding: priorBinding,
            nextBinding,
            displacedBinding,
          })) {
            const directory = await observe(observations, targetKey, TARGET_DIRECTORY_SK);
            const nextDirectory = mutateTargetDirectory({
              directory,
              targetKey,
              ...effect,
              nowEpochSec,
              maxDevices,
            });
            if (directory) {
              directoryWrites.push(
                nextDirectory ? targetDirectoryPut(nextDirectory, directory) : targetDirectoryDelete(directory),
              );
            } else if (nextDirectory) {
              directoryWrites.push(targetDirectoryPut(nextDirectory));
            }
          }

          const nextOperation = committedRegistrationOperation({
            operationKey: f.operationKey,
            requestFingerprint: f.requestFingerprint,
            binding: nextBinding,
            claim: nextClaim,
            nowEpochSec,
          });
          const transactItems = [
            basePut(nextBinding, observedCurrent),
            claimPut(nextClaim, claimAuthorization.protectedClaim, nowEpochSec),
            ...(oldClaim ? [claimDelete(oldClaim)] : []),
            ...(displacedBinding ? [baseDelete(displacedBinding)] : []),
            ...directoryWrites,
            registrationOperationPut(nextOperation, operation),
          ];
          try {
            await client.transactWrite({
              TransactItems: transactItems,
            });
            return publicRegistration(nextBinding, nextClaim, resultOptions);
          } catch (error) {
            if (isTransactionRetryable(error, transactItems.length)) {
              await waitToRetry(attempt);
              continue;
            }
            throw error;
          }
        } catch (error) {
          if (error instanceof DeviceRegistryV2Error) {
            const recordsAreStable = await observationsAreStable(observations);
            const latestNowEpochSec = safeNowSeconds(now);
            if (!recordsAreStable || !activityWindowIsStable(observations, nowEpochSec, latestNowEpochSec)) {
              await waitToRetry(attempt);
              continue;
            }
          }
          throw error;
        }
      }

      throw new DeviceRegistryV2Error('registration-conflict', 'registration could not be serialized');
    },

    async unregister({ principal, humanId, ...body } = {}) {
      const value = assertUnregisterInput(body);
      const owner = authenticatedOwnerFields(key, principal, humanId, value);
      const installationKey = deriveDeviceInstallationKey(key, value.installationId);
      const targetKey = deriveDeviceTargetKey(key, principal, humanId, value.sessionId);

      for (let attempt = 0; attempt < DEVICE_REGISTRY_MAX_SERIALIZATION_ATTEMPTS; attempt += 1) {
        const observations = new Map();
        const nowEpochSec = safeNowSeconds(now);
        try {
          const current = await observe(observations, installationKey, BINDING_SK);
          if (!current) return { removed: false, ...owner };
          assertStoredBinding(current, installationKey);
          if (storedBaseOwnerDisposition(current, owner.ownerHandle, nowEpochSec) === 'reclaimable') {
            return { removed: false, ...owner };
          }
          const matches =
            current.targetKey === targetKey &&
            current.bindingId === value.bindingId &&
            current.bindingRevision === value.bindingRevision;
          if (!matches) return { removed: false, ...owner };

          const tokenKey = deriveDeviceTokenKey(key, current.platform, current.voipToken);
          let claim = await observe(observations, tokenKey, TOKEN_CLAIM_SK);
          if (claim) {
            assertStoredTokenClaim(claim, tokenKey);
            const owned =
              claim.ownerInstallationKey === current.pk &&
              claim.targetKey === current.targetKey &&
              claim.tokenHash === current.voipTokenHash &&
              claim.platform === current.platform &&
              claim.bindingId === current.bindingId &&
              claim.bindingRevision === current.bindingRevision &&
              claim.expiresAtEpochSec === current.expiresAtEpochSec;
            if (!owned) claim = undefined;
          }
          if (current.expiresAtEpochSec > nowEpochSec && !claim) {
            throw new DeviceRegistryV2Error('corrupt-record', 'active device binding has no exact token claim');
          }
          const directory = await observe(observations, targetKey, TARGET_DIRECTORY_SK);
          const nextDirectory = mutateTargetDirectory({
            directory,
            targetKey,
            removeBindings: [current],
            nowEpochSec,
            maxDevices,
          });
          const directoryWrite = directory
            ? nextDirectory
              ? targetDirectoryPut(nextDirectory, directory)
              : targetDirectoryDelete(directory)
            : undefined;

          const transactItems = [
            baseDelete(current),
            ...(claim ? [claimDelete(claim)] : []),
            ...(directoryWrite ? [directoryWrite] : []),
          ];
          try {
            await client.transactWrite({
              TransactItems: transactItems,
            });
            return { removed: true, ...owner };
          } catch (error) {
            if (isTransactionRetryable(error, transactItems.length)) {
              await waitToRetry(attempt);
              continue;
            }
            throw error;
          }
        } catch (error) {
          if (error instanceof DeviceRegistryV2Error) {
            const recordsAreStable = await observationsAreStable(observations);
            const latestNowEpochSec = safeNowSeconds(now);
            if (!recordsAreStable || !activityWindowIsStable(observations, nowEpochSec, latestNowEpochSec)) {
              await waitToRetry(attempt);
              continue;
            }
          }
          throw error;
        }
      }
      const current = await baseGet(installationKey);
      if (!current) return { removed: false, ...owner };
      assertStoredBinding(current, installationKey);
      if (storedBaseOwnerDisposition(current, owner.ownerHandle, safeNowSeconds(now)) === 'reclaimable') {
        return { removed: false, ...owner };
      }
      if (
        current.targetKey !== targetKey ||
        current.bindingId !== value.bindingId ||
        current.bindingRevision !== value.bindingRevision
      ) {
        return { removed: false, ...owner };
      }
      throw new DeviceRegistryV2Error(
        'unregistration-conflict',
        'unregistration could not be serialized while the exact binding tuple remained present',
      );
    },

    async lookup({ principal, humanId, sessionId } = {}) {
      const owner = authenticatedOwnerFields(key, principal, humanId);
      const sessionError = canonicalOpaque(sessionId, 'sessionId', DEVICE_REGISTRATION_LIMITS.SESSION_ID_BYTES);
      if (sessionError) throw new DeviceRegistryV2Error('invalid-input', sessionError.error);
      const targetKey = deriveDeviceTargetKey(key, principal, humanId, sessionId);
      for (let attempt = 0; attempt < DEVICE_REGISTRY_MAX_SERIALIZATION_ATTEMPTS; attempt += 1) {
        const nowEpochSec = safeNowSeconds(now);
        const observations = new Map();
        const directory = await observe(observations, targetKey, TARGET_DIRECTORY_SK);
        if (!directory) {
          const latestDirectory = await targetDirectoryGet(targetKey);
          const latestNowEpochSec = safeNowSeconds(now);
          if (
            !isDeepStrictEqual(directory, latestDirectory) ||
            !activityWindowIsStable(observations, nowEpochSec, latestNowEpochSec)
          ) {
            await waitToRetry(attempt);
            continue;
          }
          return [];
        }
        try {
          assertStoredTargetDirectory(directory, targetKey);
          const members = activeDirectoryMembers(directory, nowEpochSec);
          const bindings = await Promise.all(
            members.map((member) => observe(observations, member.installationKey, BINDING_SK)),
          );
          const resolved = bindings.map((item, index) => {
            const member = members[index];
            if (!item) {
              throw new DeviceRegistryV2Error('corrupt-record', 'target directory member has no installation binding');
            }
            assertStoredBinding(item, member.installationKey);
            assertStoredOwner(item, owner.ownerHandle);
            const device = directoryMemberMatches(member, item) ? currentDevice(item, targetKey, nowEpochSec) : null;
            if (!device) {
              throw new DeviceRegistryV2Error(
                'corrupt-record',
                'target directory member disagrees with its installation binding',
              );
            }
            return { item, device };
          });
          const claims = await Promise.all(
            resolved.map(async ({ device }) => {
              const tokenKey = deriveDeviceTokenKey(key, device.platform, device.voipToken);
              const claim = await observe(observations, tokenKey, TOKEN_CLAIM_SK);
              return { claim, tokenKey };
            }),
          );
          const devices = resolved.map(({ item, device }, index) => {
            const { claim, tokenKey } = claims[index];
            if (!claimOwnsBinding(claim, item, tokenKey, nowEpochSec)) {
              throw new DeviceRegistryV2Error('corrupt-record', 'target directory member has no exact token claim');
            }
            return device;
          });
          const latestDirectory = await targetDirectoryGet(targetKey);
          const latestNowEpochSec = safeNowSeconds(now);
          if (
            !isDeepStrictEqual(directory, latestDirectory) ||
            !activityWindowIsStable(observations, nowEpochSec, latestNowEpochSec)
          ) {
            await waitToRetry(attempt);
            continue;
          }
          return devices
            .sort((a, b) => compareOpaque(a.installationKey, b.installationKey))
            .map(({ installationKey: _installationKey, voipTokenHash: _voipTokenHash, ...device }) => device);
        } catch (error) {
          if (error instanceof DeviceRegistryV2Error) {
            const latestDirectory = await targetDirectoryGet(targetKey);
            const latestNowEpochSec = safeNowSeconds(now);
            if (
              !isDeepStrictEqual(directory, latestDirectory) ||
              !activityWindowIsStable(observations, nowEpochSec, latestNowEpochSec)
            ) {
              await waitToRetry(attempt);
              continue;
            }
          }
          throw error;
        }
      }
      throw new DeviceRegistryV2Error('lookup-conflict', 'device registry lookup could not obtain a stable snapshot');
    },
  };
}
