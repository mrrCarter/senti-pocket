// Distributed, replay-aware admission for Registry V2 operation identities.
//
// This module intentionally knows nothing about APNs, membership, scope, or registry mutation. It receives only
// verifier-owned identity plus a validated V2 request, derives the exact frozen Registry V2 operation identity, and
// atomically records an opaque digest in one bounded CAS ledger per authenticated owner. The gateway remains the sole
// authority for semantic-fingerprint conflicts and terminal registration outcomes.

import { randomInt, timingSafeEqual } from 'node:crypto';
import {
  DEVICE_REGISTRATION_LEASE_SECONDS,
  DEVICE_REGISTRATION_RECLAIM_GRACE_SECONDS,
  assertDeviceRegistryOwnerIdentity,
  deriveDeviceOwnerHandle,
  deriveDeviceRegistrationOperationKey,
  validateDeviceRegistrationCleanupV2,
  validateDeviceRegistrationV2,
} from './device-registry-v2.mjs';

const LEDGER_SCHEMA = 'dial-registry-operation-admission-v1';
const LEDGER_PREFIX = 'dial:admission:v1:';
const OPERATION_PREFIX = 'dial:regop:v2:';
const DIGEST_RE = /^[A-Za-z0-9_-]{43}$/;
const RECORD_VERSION_RE = /^[1-9][0-9]{0,19}$/;
const MAX_UINT64 = 18_446_744_073_709_551_615n;
const MAX_LEDGER_SERIALIZED_BYTES = 64 * 1024;

export const REGISTRY_OPERATION_ADMISSION_LIMITS = Object.freeze({
  MAX_LIVE_OPERATIONS: 256,
  MAX_NEW_OPERATIONS_PER_WINDOW: 30,
  MAX_REQUESTS_PER_WINDOW: 60,
  WINDOW_MS: 60_000,
  RETENTION_SECONDS: DEVICE_REGISTRATION_LEASE_SECONDS + DEVICE_REGISTRATION_RECLAIM_GRACE_SECONDS,
  // One full total-request burst may race from different Lambda instances. The bounded retry budget must allow each
  // of the 60 admissible writes to serialize, plus the 61st decision that observes and returns the typed rate denial.
  MAX_SERIALIZATION_ATTEMPTS: 61,
});

const defaultRetryDelay = (attempt) => {
  const ceilingMs = Math.min(2 ** Math.min(attempt, 5), 32);
  const delayMs = randomInt(ceilingMs + 1);
  return delayMs > 0 ? new Promise((resolve) => setTimeout(resolve, delayMs)) : Promise.resolve();
};

export class RegistryOperationAdmissionError extends Error {
  constructor(code, message, { retryAfterSeconds, cause } = {}) {
    super(message, cause === undefined ? undefined : { cause });
    this.name = 'RegistryOperationAdmissionError';
    this.code = code;
    if (retryAfterSeconds !== undefined) this.retryAfterSeconds = retryAfterSeconds;
  }
}

export function isRegistryOperationAdmissionRoute(method, path) {
  return method === 'POST' && (path === '/dial/register' || path === '/dial/register/reconcile');
}

function canonicalDigest(value, name, code = 'operation-admission-invalid') {
  if (
    typeof value !== 'string' ||
    !DIGEST_RE.test(value) ||
    Buffer.from(value, 'base64url').length !== 32 ||
    Buffer.from(value, 'base64url').toString('base64url') !== value
  ) {
    throw new RegistryOperationAdmissionError(code, `${name} is not a canonical digest`);
  }
  return value;
}

export function timingSafeOwnerHandleEqual(provided, expected) {
  try {
    canonicalDigest(provided, 'provided owner handle');
    canonicalDigest(expected, 'expected owner handle');
    return timingSafeEqual(Buffer.from(provided, 'base64url'), Buffer.from(expected, 'base64url'));
  } catch {
    return false;
  }
}

/**
 * Validate the frozen route body and derive only opaque admission identifiers. The same helper and HMAC key used by
 * Registry V2 produce the operation identity for both register and reconcile, preventing cross-layer drift.
 */
export function deriveRegistryOperationAdmissionIdentity({ method, path, body, principal, humanId, hmacKey } = {}) {
  if (!isRegistryOperationAdmissionRoute(method, path)) return { protected: false };
  const validation = path === '/dial/register'
    ? validateDeviceRegistrationV2(body)
    : validateDeviceRegistrationCleanupV2(body);
  if (!validation.ok) {
    return {
      protected: true,
      ok: false,
      status: validation.status,
      error: validation.error,
      reason: path === '/dial/register' ? 'registration-v2-required' : 'registration-cleanup-v2-required',
    };
  }

  const value = validation.value;
  let ownerHandle;
  let operationKey;
  try {
    assertDeviceRegistryOwnerIdentity(principal, humanId);
    ownerHandle = deriveDeviceOwnerHandle(hmacKey, principal, humanId);
    operationKey = deriveDeviceRegistrationOperationKey(
      hmacKey,
      principal,
      humanId,
      value.installationId,
      value.idempotencyKey,
    );
  } catch (cause) {
    throw new RegistryOperationAdmissionError(
      'operation-admission-unavailable',
      'operation admission identity derivation failed',
      { cause },
    );
  }
  canonicalDigest(ownerHandle, 'derived owner handle', 'operation-admission-unavailable');
  if (typeof operationKey !== 'string' || !operationKey.startsWith(OPERATION_PREFIX)) {
    throw new RegistryOperationAdmissionError('operation-admission-unavailable', 'operation admission key is invalid');
  }
  const operationDigest = canonicalDigest(
    operationKey.slice(OPERATION_PREFIX.length),
    'derived operation digest',
    'operation-admission-unavailable',
  );
  return {
    protected: true,
    ok: true,
    ownerMatches: timingSafeOwnerHandleEqual(value.ownerHandle, ownerHandle),
    ownerHandle,
    ledgerKey: LEDGER_PREFIX + ownerHandle,
    operationDigest,
  };
}

function exactKeys(value, expected) {
  const keys = Object.keys(value).sort();
  const wanted = [...expected].sort();
  return keys.length === wanted.length && keys.every((key, index) => key === wanted[index]);
}

function canonicalPositiveInteger(value) {
  return Number.isSafeInteger(value) && value > 0;
}

function canonicalRecordVersion(value) {
  if (typeof value !== 'string' || !RECORD_VERSION_RE.test(value)) return null;
  try {
    const parsed = BigInt(value);
    return parsed > 0n && parsed <= MAX_UINT64 ? parsed : null;
  } catch {
    return null;
  }
}

function nextRecordVersion(current) {
  const parsed = current === null ? 0n : canonicalRecordVersion(current);
  if (parsed === null || parsed >= MAX_UINT64) {
    throw new RegistryOperationAdmissionError('operation-admission-unavailable', 'operation admission revision is invalid');
  }
  return String(parsed + 1n);
}

function validateLedger(value, limits) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new RegistryOperationAdmissionError('operation-admission-unavailable', 'operation admission ledger is corrupt');
  }
  let serialized;
  try {
    serialized = JSON.stringify(value);
  } catch (cause) {
    throw unavailable('operation admission ledger is corrupt', cause);
  }
  if (typeof serialized !== 'string' || Buffer.byteLength(serialized, 'utf8') > MAX_LEDGER_SERIALIZED_BYTES) {
    throw new RegistryOperationAdmissionError('operation-admission-unavailable', 'operation admission ledger is corrupt');
  }
  const fields = [
    'schema',
    'recordVersion',
    'maxLiveOperations',
    'maxNewOperationsPerWindow',
    'maxRequestsPerWindow',
    'windowMs',
    'retentionSeconds',
    'lastClockEpochMs',
    'operations',
    'recentNewEpochMs',
    'recentRequestEpochMs',
  ];
  if (!exactKeys(value, fields) || value.schema !== LEDGER_SCHEMA || canonicalRecordVersion(value.recordVersion) === null) {
    throw new RegistryOperationAdmissionError('operation-admission-unavailable', 'operation admission ledger is corrupt');
  }
  if (
    value.maxLiveOperations !== limits.maxLiveOperations ||
    value.maxNewOperationsPerWindow !== limits.maxNewOperationsPerWindow ||
    value.maxRequestsPerWindow !== limits.maxRequestsPerWindow ||
    value.windowMs !== limits.windowMs ||
    value.retentionSeconds !== limits.retentionSeconds ||
    !Number.isSafeInteger(value.lastClockEpochMs) ||
    value.lastClockEpochMs < 0 ||
    !Array.isArray(value.operations) ||
    value.operations.length === 0 ||
    value.operations.length > limits.maxLiveOperations ||
    !Array.isArray(value.recentNewEpochMs) ||
    value.recentNewEpochMs.length > limits.maxNewOperationsPerWindow ||
    !Array.isArray(value.recentRequestEpochMs) ||
    value.recentRequestEpochMs.length === 0 ||
    value.recentRequestEpochMs.length > limits.maxRequestsPerWindow
  ) {
    throw new RegistryOperationAdmissionError('operation-admission-unavailable', 'operation admission ledger is corrupt');
  }

  let previousDigest = null;
  const operations = value.operations.map((entry) => {
    if (
      !entry ||
      typeof entry !== 'object' ||
      Array.isArray(entry) ||
      !exactKeys(entry, ['digest', 'expiresAtEpochSec']) ||
      !canonicalPositiveInteger(entry.expiresAtEpochSec)
    ) {
      throw new RegistryOperationAdmissionError('operation-admission-unavailable', 'operation admission ledger is corrupt');
    }
    const digest = canonicalDigest(
      entry.digest,
      'stored operation digest',
      'operation-admission-unavailable',
    );
    if (entry.expiresAtEpochSec > Math.floor(value.lastClockEpochMs / 1000) + limits.retentionSeconds) {
      throw new RegistryOperationAdmissionError('operation-admission-unavailable', 'operation admission ledger is corrupt');
    }
    if (previousDigest !== null && previousDigest >= digest) {
      throw new RegistryOperationAdmissionError('operation-admission-unavailable', 'operation admission ledger is corrupt');
    }
    previousDigest = digest;
    return { digest, expiresAtEpochSec: entry.expiresAtEpochSec };
  });

  let previousTimestamp = null;
  const recentNewEpochMs = value.recentNewEpochMs.map((timestamp) => {
    if (
      !Number.isSafeInteger(timestamp) ||
      timestamp < 0 ||
      timestamp > value.lastClockEpochMs ||
      timestamp <= value.lastClockEpochMs - limits.windowMs ||
      (previousTimestamp !== null && timestamp < previousTimestamp)
    ) {
      throw new RegistryOperationAdmissionError('operation-admission-unavailable', 'operation admission ledger is corrupt');
    }
    previousTimestamp = timestamp;
    return timestamp;
  });

  previousTimestamp = null;
  const recentRequestEpochMs = value.recentRequestEpochMs.map((timestamp) => {
    if (
      !Number.isSafeInteger(timestamp) ||
      timestamp < 0 ||
      timestamp > value.lastClockEpochMs ||
      timestamp <= value.lastClockEpochMs - limits.windowMs ||
      (previousTimestamp !== null && timestamp < previousTimestamp)
    ) {
      throw new RegistryOperationAdmissionError('operation-admission-unavailable', 'operation admission ledger is corrupt');
    }
    previousTimestamp = timestamp;
    return timestamp;
  });

  if (recentRequestEpochMs.at(-1) !== value.lastClockEpochMs) {
    throw new RegistryOperationAdmissionError('operation-admission-unavailable', 'operation admission ledger is corrupt');
  }
  const requestMultiplicity = new Map();
  for (const timestamp of recentRequestEpochMs) {
    requestMultiplicity.set(timestamp, (requestMultiplicity.get(timestamp) || 0) + 1);
  }
  for (const timestamp of recentNewEpochMs) {
    const remaining = requestMultiplicity.get(timestamp) || 0;
    if (remaining === 0) {
      throw new RegistryOperationAdmissionError('operation-admission-unavailable', 'operation admission ledger is corrupt');
    }
    requestMultiplicity.set(timestamp, remaining - 1);
  }

  return { ...value, operations, recentNewEpochMs, recentRequestEpochMs };
}

function resolveLimits(options) {
  const limits = {
    maxLiveOperations: options.maxLiveOperations ?? REGISTRY_OPERATION_ADMISSION_LIMITS.MAX_LIVE_OPERATIONS,
    maxNewOperationsPerWindow:
      options.maxNewOperationsPerWindow ?? REGISTRY_OPERATION_ADMISSION_LIMITS.MAX_NEW_OPERATIONS_PER_WINDOW,
    maxRequestsPerWindow:
      options.maxRequestsPerWindow ?? REGISTRY_OPERATION_ADMISSION_LIMITS.MAX_REQUESTS_PER_WINDOW,
    windowMs: options.windowMs ?? REGISTRY_OPERATION_ADMISSION_LIMITS.WINDOW_MS,
    retentionSeconds: options.retentionSeconds ?? REGISTRY_OPERATION_ADMISSION_LIMITS.RETENTION_SECONDS,
    maxSerializationAttempts:
      options.maxSerializationAttempts ?? REGISTRY_OPERATION_ADMISSION_LIMITS.MAX_SERIALIZATION_ATTEMPTS,
  };
  for (const [name, value] of Object.entries(limits)) {
    if (!canonicalPositiveInteger(value)) throw new Error(`operation admission ${name} must be a positive safe integer`);
  }
  if (limits.maxLiveOperations > REGISTRY_OPERATION_ADMISSION_LIMITS.MAX_LIVE_OPERATIONS) {
    throw new Error('operation admission maxLiveOperations cannot exceed 256');
  }
  if (limits.maxNewOperationsPerWindow > REGISTRY_OPERATION_ADMISSION_LIMITS.MAX_NEW_OPERATIONS_PER_WINDOW) {
    throw new Error('operation admission maxNewOperationsPerWindow cannot exceed 30');
  }
  if (limits.maxRequestsPerWindow > REGISTRY_OPERATION_ADMISSION_LIMITS.MAX_REQUESTS_PER_WINDOW) {
    throw new Error('operation admission maxRequestsPerWindow cannot exceed 60');
  }
  if (limits.maxRequestsPerWindow < limits.maxNewOperationsPerWindow) {
    throw new Error('operation admission maxRequestsPerWindow cannot be lower than maxNewOperationsPerWindow');
  }
  if (limits.retentionSeconds < Math.ceil(limits.windowMs / 1000)) {
    throw new Error('operation admission retentionSeconds must cover the rolling window');
  }
  return Object.freeze(limits);
}

function unavailable(message, cause) {
  return new RegistryOperationAdmissionError('operation-admission-unavailable', message, { cause });
}

function limited(message, retryAfterSeconds) {
  return new RegistryOperationAdmissionError('operation-rate-limited', message, {
    retryAfterSeconds: Math.max(1, retryAfterSeconds),
  });
}

/**
 * @param {{store:{get:Function,compareAndSwap:Function},now?:Function,retryDelay?:Function}} options
 */
export function createRegistryOperationAdmission(options = {}) {
  const { store, now = () => Date.now(), retryDelay = defaultRetryDelay } = options;
  if (!store || typeof store.get !== 'function' || typeof store.compareAndSwap !== 'function') {
    throw new Error('createRegistryOperationAdmission requires a CAS store with get and compareAndSwap');
  }
  if (typeof now !== 'function' || typeof retryDelay !== 'function') {
    throw new Error('createRegistryOperationAdmission requires function now and retryDelay values');
  }
  const limits = resolveLimits(options);

  return Object.freeze({
    limits,
    async admit({ ledgerKey, operationDigest } = {}) {
      if (typeof ledgerKey !== 'string' || !ledgerKey.startsWith(LEDGER_PREFIX)) {
        throw unavailable('operation admission ledger key is invalid');
      }
      canonicalDigest(
        ledgerKey.slice(LEDGER_PREFIX.length),
        'admission owner digest',
        'operation-admission-unavailable',
      );
      canonicalDigest(operationDigest, 'operation digest', 'operation-admission-unavailable');

      let observed;
      try {
        observed = await store.get(ledgerKey, { consistent: true });
      } catch (cause) {
        throw unavailable('operation admission storage is unavailable', cause);
      }

      let previousLocalEpochMs = null;
      for (let attempt = 0; attempt < limits.maxSerializationAttempts; attempt += 1) {
        const current = observed === undefined ? null : validateLedger(observed, limits);
        let localEpochMs;
        try {
          localEpochMs = now();
        } catch (cause) {
          throw unavailable('operation admission clock is unavailable', cause);
        }
        if (!Number.isSafeInteger(localEpochMs) || localEpochMs < 0) {
          throw unavailable('operation admission clock is invalid');
        }
        if (previousLocalEpochMs !== null && localEpochMs < previousLocalEpochMs) {
          throw unavailable('operation admission clock moved backwards');
        }
        previousLocalEpochMs = localEpochMs;
        // A fresh request observing a future ledger fails closed as a clock rollback. After this request loses a CAS,
        // however, a legitimately later peer may have advanced the ledger beyond this request's original sample. Use
        // that winning logical time as a floor instead of misclassifying ordinary contention as clock rollback.
        if (attempt === 0 && current && localEpochMs < current.lastClockEpochMs) {
          throw unavailable('operation admission clock moved backwards');
        }
        const nowEpochMs = current ? Math.max(localEpochMs, current.lastClockEpochMs) : localEpochMs;
        const nowEpochSec = Math.floor(nowEpochMs / 1000);
        const operationExpiry = nowEpochSec + limits.retentionSeconds;
        if (!Number.isSafeInteger(operationExpiry) || operationExpiry <= nowEpochSec) {
          throw unavailable('operation admission expiry is invalid');
        }
        const activeOperations = current
          ? current.operations.filter((entry) => entry.expiresAtEpochSec > nowEpochSec)
          : [];
        const replay = activeOperations.some((entry) => entry.digest === operationDigest);
        const cutoffEpochMs = nowEpochMs - limits.windowMs;
        const recentRequestEpochMs = current
          ? current.recentRequestEpochMs.filter((timestamp) => timestamp > cutoffEpochMs)
          : [];
        if (recentRequestEpochMs.length >= limits.maxRequestsPerWindow) {
          const retryAtEpochMs = recentRequestEpochMs[0] + limits.windowMs;
          throw limited('registration operation request rate is exhausted', Math.ceil((retryAtEpochMs - nowEpochMs) / 1000));
        }
        if (!replay && activeOperations.length >= limits.maxLiveOperations) {
          const earliestExpiry = Math.min(...activeOperations.map((entry) => entry.expiresAtEpochSec));
          throw limited('registration operation capacity is exhausted', earliestExpiry - nowEpochSec);
        }

        const recentNewEpochMs = current
          ? current.recentNewEpochMs.filter((timestamp) => timestamp > cutoffEpochMs)
          : [];
        if (!replay && recentNewEpochMs.length >= limits.maxNewOperationsPerWindow) {
          const retryAtEpochMs = recentNewEpochMs[0] + limits.windowMs;
          throw limited('registration operation rate is exhausted', Math.ceil((retryAtEpochMs - nowEpochMs) / 1000));
        }

        const operations = replay
          ? activeOperations.map((entry) =>
              entry.digest === operationDigest
                ? { ...entry, expiresAtEpochSec: Math.max(entry.expiresAtEpochSec, operationExpiry) }
                : entry,
            )
          : [...activeOperations, { digest: operationDigest, expiresAtEpochSec: operationExpiry }];
        operations.sort((left, right) => (left.digest < right.digest ? -1 : left.digest > right.digest ? 1 : 0));
        const nextRecentNewEpochMs = replay ? recentNewEpochMs : [...recentNewEpochMs, nowEpochMs];
        const next = {
          schema: LEDGER_SCHEMA,
          recordVersion: nextRecordVersion(current && current.recordVersion),
          maxLiveOperations: limits.maxLiveOperations,
          maxNewOperationsPerWindow: limits.maxNewOperationsPerWindow,
          maxRequestsPerWindow: limits.maxRequestsPerWindow,
          windowMs: limits.windowMs,
          retentionSeconds: limits.retentionSeconds,
          lastClockEpochMs: nowEpochMs,
          operations,
          recentNewEpochMs: nextRecentNewEpochMs,
          recentRequestEpochMs: [...recentRequestEpochMs, nowEpochMs],
        };
        if (Buffer.byteLength(JSON.stringify(next), 'utf8') > MAX_LEDGER_SERIALIZED_BYTES) {
          throw unavailable('operation admission ledger exceeds its serialized size bound');
        }
        const requestWindowTtlEpochSec = Math.ceil(
          (next.recentRequestEpochMs.at(-1) + limits.windowMs) / 1000,
        );
        const ttlEpochSec = Math.max(
          requestWindowTtlEpochSec,
          ...operations.map((entry) => entry.expiresAtEpochSec),
        );
        let result;
        try {
          result = await store.compareAndSwap(
            ledgerKey,
            current ? current.recordVersion : null,
            next,
            { ttlEpochSec },
          );
        } catch (cause) {
          throw unavailable('operation admission storage is unavailable', cause);
        }
        if (!result || typeof result !== 'object' || typeof result.swapped !== 'boolean') {
          throw unavailable('operation admission storage returned an invalid result');
        }
        if (result.swapped) {
          return Object.freeze({ admitted: true, replay, liveOperations: operations.length });
        }
        observed = result.current;
        if (observed === undefined) {
          try {
            observed = await store.get(ledgerKey, { consistent: true });
          } catch (cause) {
            throw unavailable('operation admission storage is unavailable', cause);
          }
        }
        if (attempt + 1 < limits.maxSerializationAttempts) {
          try {
            await retryDelay(attempt + 1);
          } catch (cause) {
            throw unavailable('operation admission retry scheduling failed', cause);
          }
        }
      }
      throw unavailable('operation admission could not be serialized');
    },
  });
}
