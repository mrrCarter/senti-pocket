// senti-target-membership.mjs — fixed-origin, bearer-bound authorization for one Pocket target session.
//
// The gateway deliberately does not trust a caller-supplied human id and does not hold a Senti signing secret. It asks
// the SentinelLayer API for the role associated with the SAME bearer already authenticated at the Pocket door. The
// response is tiny, streamed through a hard byte cap, and validated exactly before any role reaches a route policy.

import { createHash } from 'node:crypto';
import { TextDecoder } from 'node:util';
import { timeoutSignal } from './http-timeout.mjs';

const DEFAULT_TIMEOUT_MS = 3_000;
const DEFAULT_MAX_RESPONSE_BYTES = 4_096;
const DEFAULT_POSITIVE_TTL_MS = 5_000;
const DEFAULT_NEGATIVE_TTL_MS = 1_000;
const DEFAULT_MAX_CACHE_ENTRIES = 5_000;
const DEFAULT_MAX_IN_FLIGHT = 128;
const MAX_AUTHORIZATION_BYTES = 16_384;
const MAX_SESSION_SCALARS = 64;
const MAX_SESSION_UTF8_BYTES = 256;
const MAX_RETRY_AFTER_SECONDS = 3_600;
const TOKEN68_BEARER_RE = /^Bearer [A-Za-z0-9\-._~+/]+=*$/i;
const CONTROL_RE = /[\u0000-\u001f\u007f-\u009f]/u;
const ROLES = new Set(['owner', 'admin', 'contributor', 'viewer']);

export const SENTI_TARGET_MEMBERSHIP_ERROR_CODES = Object.freeze({
  invalidTarget: 'senti-target-membership-invalid-target',
  credentialRejected: 'senti-target-membership-credential-rejected',
  rateLimited: 'senti-target-membership-rate-limited',
  unavailable: 'senti-target-membership-unavailable',
});

class SentiTargetMembershipError extends Error {
  constructor(name, code, message) {
    super(message);
    this.name = name;
    this.code = code;
  }
}

export class SentiTargetMembershipInvalidTargetError extends SentiTargetMembershipError {
  constructor() {
    super(
      'SentiTargetMembershipInvalidTargetError',
      SENTI_TARGET_MEMBERSHIP_ERROR_CODES.invalidTarget,
      'Senti target membership target is invalid',
    );
  }
}

export class SentiTargetMembershipCredentialRejectedError extends SentiTargetMembershipError {
  constructor() {
    super(
      'SentiTargetMembershipCredentialRejectedError',
      SENTI_TARGET_MEMBERSHIP_ERROR_CODES.credentialRejected,
      'Senti target membership credential was rejected',
    );
  }
}

export class SentiTargetMembershipRateLimitedError extends SentiTargetMembershipError {
  constructor(retryAfterSeconds) {
    super(
      'SentiTargetMembershipRateLimitedError',
      SENTI_TARGET_MEMBERSHIP_ERROR_CODES.rateLimited,
      'Senti target membership lookup was rate limited',
    );
    if (Number.isSafeInteger(retryAfterSeconds)) this.retryAfterSeconds = retryAfterSeconds;
  }
}

export class SentiTargetMembershipUnavailableError extends SentiTargetMembershipError {
  constructor() {
    super(
      'SentiTargetMembershipUnavailableError',
      SENTI_TARGET_MEMBERSHIP_ERROR_CODES.unavailable,
      'Senti target membership lookup is unavailable',
    );
  }
}

const unavailable = () => new SentiTargetMembershipUnavailableError();

const assertNonNegativeSafeNumber = (name, value) => {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new Error(`createSentiTargetMembershipResolver: ${name} must be a non-negative safe integer`);
  }
};

const assertPositiveSafeNumber = (name, value) => {
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`createSentiTargetMembershipResolver: ${name} must be a positive safe integer`);
  }
};

const strictApiOrigin = (value) => {
  let parsed;
  try { parsed = new URL(String(value || '')); }
  catch { throw new Error('createSentiTargetMembershipResolver: apiBaseUrl must be an HTTPS origin'); }
  if (
    parsed.protocol !== 'https:' ||
    parsed.username ||
    parsed.password ||
    parsed.pathname !== '/' ||
    parsed.search ||
    parsed.hash ||
    parsed.origin === 'null'
  ) {
    throw new Error('createSentiTargetMembershipResolver: apiBaseUrl must be an HTTPS origin');
  }
  return parsed.origin;
};

const isWellFormedUnicode = (value) => {
  for (let i = 0; i < value.length; i += 1) {
    const unit = value.charCodeAt(i);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      const next = value.charCodeAt(i + 1);
      if (!(next >= 0xdc00 && next <= 0xdfff)) return false;
      i += 1;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return false;
    }
  }
  return true;
};

const validSessionId = (value) => typeof value === 'string' &&
  value.length > 0 &&
  value.length <= MAX_SESSION_UTF8_BYTES &&
  value === value.trim() &&
  value !== '.' &&
  value !== '..' &&
  !CONTROL_RE.test(value) &&
  isWellFormedUnicode(value) &&
  [...value].length <= MAX_SESSION_SCALARS &&
  Buffer.byteLength(value, 'utf8') <= MAX_SESSION_UTF8_BYTES;

const validAuthorization = (value) => typeof value === 'string' &&
  value.length <= MAX_AUTHORIZATION_BYTES &&
  Buffer.byteLength(value, 'utf8') <= MAX_AUTHORIZATION_BYTES &&
  TOKEN68_BEARER_RE.test(value);

const lp = (value) => `${Buffer.byteLength(value, 'utf8')}:${value}`;
const decisionKey = (authorization, sessionId) => createHash('sha256')
  .update('senti-pocket-target-membership-v1\n', 'utf8')
  .update(lp(authorization), 'utf8')
  .update(lp(sessionId), 'utf8')
  .digest('base64url');

const headerValue = (response, name) => {
  try {
    const headers = response?.headers;
    if (!headers || typeof headers.get !== 'function') throw unavailable();
    const value = headers.get(name);
    return value == null ? null : String(value);
  } catch { throw unavailable(); }
};

const hasDirective = (value, directive) => typeof value === 'string' && value
  .split(',')
  .map((part) => part.trim().toLowerCase())
  .includes(directive);

const assertNoStoreHeaders = (response) => {
  if (!hasDirective(headerValue(response, 'cache-control'), 'no-store')) throw unavailable();
  if (!hasDirective(headerValue(response, 'pragma'), 'no-cache')) throw unavailable();
};

const cancelBody = (body) => {
  try {
    if (!body || typeof body.cancel !== 'function') return;
    const pending = body.cancel();
    if (pending && typeof pending.catch === 'function') void pending.catch(() => {});
  } catch { /* cancellation is best effort; the caller still receives the sanitized primary failure */ }
};

const cancelResponseBody = (response) => {
  try { cancelBody(response?.body); }
  catch { /* a hostile response getter must not replace the sanitized primary failure */ }
};

const cancelReader = (reader) => {
  try {
    if (!reader || typeof reader.cancel !== 'function') return;
    const pending = reader.cancel();
    if (pending && typeof pending.catch === 'function') void pending.catch(() => {});
  } catch { /* best effort */ }
};

const readWithSignal = (reader, signal) => {
  if (!signal || typeof signal.addEventListener !== 'function' || typeof signal.removeEventListener !== 'function') {
    return Promise.reject(unavailable());
  }
  if (signal.aborted) return Promise.reject(unavailable());
  return new Promise((resolve, reject) => {
    const onAbort = () => {
      signal.removeEventListener('abort', onAbort);
      reject(unavailable());
    };
    signal.addEventListener('abort', onAbort, { once: true });
    Promise.resolve()
      .then(() => reader.read())
      .then(
        (value) => { signal.removeEventListener('abort', onAbort); resolve(value); },
        () => { signal.removeEventListener('abort', onAbort); reject(unavailable()); },
      );
  });
};

const readBoundedJson = async (response, maxBytes, signal) => {
  let body;
  let reader;
  try {
    const contentType = headerValue(response, 'content-type');
    if (!contentType || !/^application\/json(?:\s*;|\s*$)/i.test(contentType)) throw unavailable();
    assertNoStoreHeaders(response);
    const contentEncoding = headerValue(response, 'content-encoding');
    if (contentEncoding && contentEncoding.trim().toLowerCase() !== 'identity') throw unavailable();

    const declared = headerValue(response, 'content-length');
    if (declared !== null) {
      if (!/^(?:0|[1-9][0-9]*)$/.test(declared)) throw unavailable();
      const declaredBytes = Number(declared);
      if (!Number.isSafeInteger(declaredBytes) || declaredBytes > maxBytes) throw unavailable();
    }

    body = response.body;
    if (!body || typeof body.getReader !== 'function') throw unavailable();
    reader = body.getReader();
    if (!reader || typeof reader.read !== 'function') throw unavailable();
  } catch {
    cancelReader(reader);
    try { reader?.releaseLock?.(); } catch { /* best effort */ }
    if (body === undefined) cancelResponseBody(response);
    else cancelBody(body);
    throw unavailable();
  }

  let bytes = 0;
  let text = '';
  let done = false;
  const utf8 = new TextDecoder('utf-8', { fatal: true });
  try {
    while (!done) {
      let part;
      try { part = await readWithSignal(reader, signal); }
      catch { throw unavailable(); }
      if (!part || typeof part.done !== 'boolean') throw unavailable();
      done = part.done;
      if (!done) {
        if (!(part.value instanceof Uint8Array)) throw unavailable();
        bytes += part.value.byteLength;
        if (bytes > maxBytes) {
          cancelReader(reader);
          throw unavailable();
        }
        try { text += utf8.decode(part.value, { stream: true }); }
        catch { throw unavailable(); }
      }
    }
    try { text += utf8.decode(); }
    catch { throw unavailable(); }
  } finally {
    if (!done) cancelReader(reader);
    try { reader.releaseLock?.(); } catch { /* best effort */ }
  }

  try { return JSON.parse(text); }
  catch { throw unavailable(); }
};

const exactMembership = (payload, sessionId) => {
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) throw unavailable();
  const keys = Object.keys(payload).sort();
  if (keys.length !== 2 || keys[0] !== 'membershipRole' || keys[1] !== 'sessionId') throw unavailable();
  if (Object.getPrototypeOf(payload) !== Object.prototype && Object.getPrototypeOf(payload) !== null) throw unavailable();
  if (payload.sessionId !== sessionId || typeof payload.membershipRole !== 'string' || !ROLES.has(payload.membershipRole)) {
    throw unavailable();
  }
  return payload.membershipRole;
};

const retryAfter = (response) => {
  const value = headerValue(response, 'retry-after');
  if (!value || !/^(?:0|[1-9][0-9]{0,8})$/.test(value)) return undefined;
  const seconds = Number(value);
  if (!Number.isSafeInteger(seconds)) return undefined;
  return Math.min(MAX_RETRY_AFTER_SECONDS, Math.max(0, seconds));
};

/**
 * Build the production resolver for `GET /api/v1/sessions/{sessionId}/membership`.
 *
 * @returns {({sessionId:string,authorization:string}) => Promise<null|Readonly<{sessionId:string,membershipRole:string}>>}
 */
export function createSentiTargetMembershipResolver({
  fetch,
  apiBaseUrl,
  timeoutMs = DEFAULT_TIMEOUT_MS,
  maxResponseBytes = DEFAULT_MAX_RESPONSE_BYTES,
  positiveTtlMs = DEFAULT_POSITIVE_TTL_MS,
  negativeTtlMs = DEFAULT_NEGATIVE_TTL_MS,
  maxCacheEntries = DEFAULT_MAX_CACHE_ENTRIES,
  maxInFlight = DEFAULT_MAX_IN_FLIGHT,
  now = () => Date.now(),
} = {}) {
  if (typeof fetch !== 'function') throw new Error('createSentiTargetMembershipResolver: fetch is required');
  if (typeof now !== 'function') throw new Error('createSentiTargetMembershipResolver: now must be a function');
  const origin = strictApiOrigin(apiBaseUrl);
  assertPositiveSafeNumber('timeoutMs', timeoutMs);
  assertPositiveSafeNumber('maxResponseBytes', maxResponseBytes);
  assertNonNegativeSafeNumber('positiveTtlMs', positiveTtlMs);
  assertNonNegativeSafeNumber('negativeTtlMs', negativeTtlMs);
  assertPositiveSafeNumber('maxCacheEntries', maxCacheEntries);
  assertPositiveSafeNumber('maxInFlight', maxInFlight);

  const cache = new Map(); // hashed key -> { role:string|null, expiresAt:number }; no raw token/target/value object
  const inFlight = new Map(); // hashed key -> bounded promise; raw args live only in its closure until finally
  let lastClock;

  const clock = () => {
    let value;
    try { value = now(); }
    catch { throw unavailable(); }
    if (!Number.isFinite(value) || !Number.isSafeInteger(value) || value < 0) throw unavailable();
    if (lastClock !== undefined && value < lastClock) cache.clear();
    lastClock = value;
    return value;
  };

  const cacheGet = (key, sessionId, at) => {
    const hit = cache.get(key);
    if (!hit) return undefined;
    if (hit.expiresAt <= at) {
      cache.delete(key);
      return undefined;
    }
    cache.delete(key);
    cache.set(key, hit); // bounded LRU; keys are credential+target hashes only
    return hit.role === null ? null : Object.freeze({ sessionId, membershipRole: hit.role });
  };

  const cachePut = (key, role, ttlMs, at) => {
    if (ttlMs === 0) return;
    if (at > Number.MAX_SAFE_INTEGER - ttlMs) return; // never create an imprecise or already-expired cache deadline
    if (cache.has(key)) cache.delete(key);
    while (cache.size >= maxCacheEntries) {
      const oldest = cache.keys().next().value;
      if (oldest === undefined) break;
      cache.delete(oldest);
    }
    cache.set(key, { role, expiresAt: at + ttlMs });
  };

  return async function getTargetMembership({ sessionId, authorization } = {}) {
    if (!validSessionId(sessionId)) throw new SentiTargetMembershipInvalidTargetError();
    if (!validAuthorization(authorization)) throw new SentiTargetMembershipCredentialRejectedError();

    const key = decisionKey(authorization, sessionId);
    const at = clock();
    const cached = cacheGet(key, sessionId, at);
    if (cached !== undefined) return cached;
    const existing = inFlight.get(key);
    if (existing) return existing;
    if (inFlight.size >= maxInFlight) throw unavailable();

    const task = (async () => {
      const signal = timeoutSignal(timeoutMs);
      if (!signal) throw unavailable();
      let response;
      try {
        response = await fetch(`${origin}/api/v1/sessions/${encodeURIComponent(sessionId)}/membership`, {
          method: 'GET',
          headers: {
            authorization,
            accept: 'application/json',
            'accept-encoding': 'identity',
            'cache-control': 'no-store',
            pragma: 'no-cache',
          },
          cache: 'no-store',
          redirect: 'error',
          signal,
        });
      } catch { throw unavailable(); }

      let status;
      try { status = response?.status; }
      catch {
        cancelResponseBody(response);
        throw unavailable();
      }
      if (!Number.isSafeInteger(status)) {
        cancelResponseBody(response);
        throw unavailable();
      }

      if (status === 404) {
        cancelResponseBody(response);
        assertNoStoreHeaders(response);
        cachePut(key, null, negativeTtlMs, clock());
        return null;
      }
      if (status === 401 || status === 403) {
        cancelResponseBody(response);
        throw new SentiTargetMembershipCredentialRejectedError();
      }
      if (status === 429) {
        cancelResponseBody(response);
        throw new SentiTargetMembershipRateLimitedError(retryAfter(response));
      }
      if (status !== 200) {
        cancelResponseBody(response);
        throw unavailable();
      }

      const role = exactMembership(await readBoundedJson(response, maxResponseBytes, signal), sessionId);
      cachePut(key, role, positiveTtlMs, clock());
      return Object.freeze({ sessionId, membershipRole: role });
    })();

    inFlight.set(key, task);
    try { return await task; }
    finally { inFlight.delete(key); }
  };
}
