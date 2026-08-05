// Native APNs VoIP provider transport. This module deliberately owns only the Apple HTTP/2 boundary: deployment
// resolves the exact .p8 secret version into a P-256 KeyObject and injects `transport.send` as `deps.apnsSend`.
// No credential lookup, environment-variable parsing, registry mutation, or retry queue belongs here.

import { KeyObject, randomUUID as cryptoRandomUUID, sign as cryptoSign } from 'node:crypto';
import {
  constants as http2Constants,
  connect as http2Connect,
  sensitiveHeaders as http2SensitiveHeaders,
} from 'node:http2';
import { performance } from 'node:perf_hooks';

export const APNS_VOIP_MAX_PAYLOAD_BYTES = 5_120;
export const APNS_PROVIDER_TOKEN_TTL_MS = 50 * 60 * 1_000;
export const APNS_DEFAULT_REQUEST_TIMEOUT_MS = 10_000;

const APNS_MAX_RESPONSE_BYTES = 4_096;
const APNS_MAX_TOKEN_CHARACTERS = 512;
const APNS_MAX_REQUEST_TIMEOUT_MS = 60_000;
const APNS_ORIGINS = Object.freeze({
  development: 'https://api.sandbox.push.apple.com',
  production: 'https://api.push.apple.com',
});
const APPLE_ID_RE = /^[A-Z0-9]{10}$/;
const BUNDLE_ID_RE = /^(?=.{1,255}$)[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$/;
const DEVICE_TOKEN_RE = /^[0-9a-fA-F]+$/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const KNOWN_APNS_REASONS = new Set([
  'BadCollapseId',
  'BadCertificate',
  'BadCertificateEnvironment',
  'BadDeviceToken',
  'BadEnvironmentKeyIdInToken',
  'BadExpirationDate',
  'BadMessageId',
  'BadPath',
  'BadPriority',
  'BadTopic',
  'DeviceTokenNotForTopic',
  'DuplicateHeaders',
  'ExpiredProviderToken',
  'ExpiredToken',
  'Forbidden',
  'IdleTimeout',
  'InternalServerError',
  'InvalidProviderToken',
  'InvalidPushType',
  'MethodNotAllowed',
  'MissingDeviceToken',
  'MissingProviderToken',
  'MissingTopic',
  'PayloadEmpty',
  'PayloadTooLarge',
  'Shutdown',
  'ServiceUnavailable',
  'TooManyProviderTokenUpdates',
  'TooManyRequests',
  'TopicDisallowed',
  'Unregistered',
  'UnrelatedKeyIdInToken',
]);
const PERMANENT_TOKEN_REASONS = new Set([
  'BadDeviceToken',
  'DeviceTokenNotForTopic',
  'ExpiredToken',
  'Unregistered',
]);
const DEADLINE_EXCEEDED = Symbol('apns-deadline-exceeded');

export class ApnsVoipTransportError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'ApnsVoipTransportError';
    this.code = code;
  }
}

function configurationError(message) {
  return new ApnsVoipTransportError('apns-configuration-invalid', message);
}

function requestError(message) {
  return new ApnsVoipTransportError('apns-request-invalid', message);
}

function base64Url(value) {
  return Buffer.from(value).toString('base64url');
}

function validatePrivateKey(privateKey) {
  try {
    if (!(privateKey instanceof KeyObject) || privateKey.type !== 'private' ||
        privateKey.asymmetricKeyType !== 'ec' ||
        !['prime256v1', 'P-256'].includes(privateKey.asymmetricKeyDetails?.namedCurve)) {
      throw configurationError('APNs privateKey must be a parsed private P-256 KeyObject');
    }
  } catch (error) {
    if (error instanceof ApnsVoipTransportError) throw error;
    throw configurationError('APNs privateKey must be a parsed private P-256 KeyObject');
  }
  return privateKey;
}

function validateConfiguration({
  teamId,
  keyId,
  privateKey,
  bundleId,
  environment,
  requestTimeoutMs,
  clock,
  connect,
  randomUUID,
  signer,
  onResult,
  deadlineClock,
  setTimer,
  clearTimer,
}) {
  if (typeof teamId !== 'string' || !APPLE_ID_RE.test(teamId)) {
    throw configurationError('APNs teamId must be a 10-character uppercase Apple Team ID');
  }
  if (typeof keyId !== 'string' || !APPLE_ID_RE.test(keyId)) {
    throw configurationError('APNs keyId must be a 10-character uppercase Apple Key ID');
  }
  validatePrivateKey(privateKey);
  if (typeof bundleId !== 'string' || !BUNDLE_ID_RE.test(bundleId)) {
    throw configurationError('APNs bundleId must be a bounded reverse-DNS identifier');
  }
  if (!Object.hasOwn(APNS_ORIGINS, environment)) {
    throw configurationError('APNs environment must be exactly development or production');
  }
  if (!Number.isSafeInteger(requestTimeoutMs) || requestTimeoutMs <= 0 ||
      requestTimeoutMs > APNS_MAX_REQUEST_TIMEOUT_MS) {
    throw configurationError('APNs requestTimeoutMs must be an integer from 1 through 60000');
  }
  if (typeof clock !== 'function' || typeof connect !== 'function' ||
      typeof randomUUID !== 'function' || typeof signer !== 'function' ||
      typeof deadlineClock !== 'function' || typeof setTimer !== 'function' || typeof clearTimer !== 'function') {
    throw configurationError('APNs runtime dependencies must be functions');
  }
  if (onResult !== undefined && typeof onResult !== 'function') {
    throw configurationError('APNs onResult must be a function when provided');
  }
}

function readEpochMilliseconds(clock) {
  let value;
  try {
    value = clock();
  } catch {
    throw new ApnsVoipTransportError('apns-clock-invalid', 'APNs clock is unavailable');
  }
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new ApnsVoipTransportError('apns-clock-invalid', 'APNs clock must return non-negative epoch milliseconds');
  }
  return value;
}

function serializeFinalPayload(payload) {
  let serialized;
  let decoded;
  try {
    serialized = JSON.stringify(payload);
    if (typeof serialized !== 'string') throw requestError('APNs payload must be a JSON object');
    decoded = JSON.parse(serialized);
  } catch (error) {
    if (error instanceof ApnsVoipTransportError) throw error;
    throw requestError('APNs payload must be a serializable JSON object');
  }
  if (!decoded || typeof decoded !== 'object' || Array.isArray(decoded) ||
      !Object.hasOwn(decoded, 'aps') || !decoded.aps ||
      typeof decoded.aps !== 'object' || Array.isArray(decoded.aps) ||
      typeof decoded.id !== 'string' || decoded.id.length === 0) {
    throw requestError('APNs payload must be the final top-level dial dictionary with id and aps');
  }
  const body = Buffer.from(serialized, 'utf8');
  if (body.byteLength > APNS_VOIP_MAX_PAYLOAD_BYTES) {
    throw requestError('APNs VoIP payload exceeds 5120 bytes');
  }
  return body;
}

function normalizeDeviceToken(voipToken) {
  if (typeof voipToken !== 'string' || voipToken.length < 2 ||
      voipToken.length > APNS_MAX_TOKEN_CHARACTERS ||
      voipToken.length % 2 !== 0 || !DEVICE_TOKEN_RE.test(voipToken)) {
    throw requestError('APNs device token must be bounded, even-length hexadecimal text');
  }
  return voipToken.toLowerCase();
}

function normalizeApnsId(value, fallback) {
  try {
    return typeof value === 'string' && UUID_RE.test(value) ? value.toLowerCase() : fallback;
  } catch {
    return fallback;
  }
}

function normalizeReason(value, fallback = 'apns-error') {
  return typeof value === 'string' && KNOWN_APNS_REASONS.has(value) ? value : fallback;
}

function parseResponseBody(chunks, oversized) {
  if (oversized) return { reason: 'malformed-response' };
  const bytes = chunks.length === 0 ? Buffer.alloc(0) : Buffer.concat(chunks);
  if (bytes.byteLength === 0) return {};
  try {
    const value = JSON.parse(bytes.toString('utf8'));
    if (!value || typeof value !== 'object' || Array.isArray(value)) {
      return { reason: 'malformed-response' };
    }
    return {
      reason: normalizeReason(value.reason, 'malformed-response'),
      timestamp: value.timestamp,
    };
  } catch {
    return { reason: 'malformed-response' };
  }
}

function parseRetryAfterSeconds(value, nowMs) {
  if (Array.isArray(value)) value = value[0];
  if (typeof value !== 'string' && typeof value !== 'number') return undefined;
  const text = String(value).trim();
  if (/^[0-9]{1,6}$/.test(text)) {
    const seconds = Number(text);
    return seconds <= 86_400 ? seconds : undefined;
  }
  const at = Date.parse(text);
  if (!Number.isFinite(at) || at <= nowMs) return undefined;
  return Math.min(86_400, Math.ceil((at - nowMs) / 1_000));
}

function normalizeUnregisteredAt(timestamp, nowMs) {
  if (!Number.isSafeInteger(timestamp) || timestamp < 0 || timestamp > nowMs + 5 * 60 * 1_000) {
    return undefined;
  }
  try {
    return new Date(timestamp).toISOString();
  } catch {
    return undefined;
  }
}

function dispositionFor(status, reason) {
  if (PERMANENT_TOKEN_REASONS.has(reason)) return 'permanent';
  if (status === 429 || status >= 500) return 'retryable-negative-ack';
  return 'permanent';
}

function negativeResult({ status, reason, apnsId, retryAfter, timestamp, nowMs }) {
  const normalizedReason = normalizeReason(reason, reason === 'malformed-response' ? reason : 'apns-error');
  const result = {
    delivered: false,
    status,
    reason: normalizedReason,
    apnsId,
    disposition: dispositionFor(status, normalizedReason),
  };
  const retryAfterSeconds = parseRetryAfterSeconds(retryAfter, nowMs);
  if (status >= 500) result.retryAfterSeconds = Math.max(15 * 60, retryAfterSeconds ?? 0);
  else if (retryAfterSeconds !== undefined) result.retryAfterSeconds = retryAfterSeconds;
  if (status === 410 && ['Unregistered', 'ExpiredToken'].includes(normalizedReason)) {
    const unregisteredAt = normalizeUnregisteredAt(timestamp, nowMs);
    if (unregisteredAt !== undefined) result.unregisteredAt = unregisteredAt;
  }
  return result;
}

function ambiguousResult(apnsId, reason = 'transport-outcome-unknown') {
  const result = {
    delivered: false,
    reason,
    disposition: 'ambiguous',
  };
  if (apnsId !== undefined) result.apnsId = apnsId;
  return result;
}

function notSentResult(apnsId, reason = 'delivery-not-attempted') {
  const result = {
    delivered: false,
    reason,
    disposition: 'not-sent',
  };
  if (apnsId !== undefined) result.apnsId = apnsId;
  return result;
}

function safeResultCallback(onResult, event) {
  if (!onResult) return;
  try {
    const pending = onResult(event);
    if (pending && typeof pending.catch === 'function') pending.catch(() => {});
  } catch {
    // Telemetry is observation only; it cannot change push delivery semantics.
  }
}

/**
 * Create a dark, deploy-injected APNs VoIP transport.
 *
 * The provider key must already be resolved into a P-256 private KeyObject. The returned `send` function is the exact
 * shape consumed by createDialPushBackend; unsupported platforms are rejected without opening a network connection.
 */
export function createApnsVoipTransport({
  teamId,
  keyId,
  privateKey,
  bundleId,
  environment,
  requestTimeoutMs = APNS_DEFAULT_REQUEST_TIMEOUT_MS,
  clock = Date.now,
  connect = http2Connect,
  randomUUID = cryptoRandomUUID,
  signer = cryptoSign,
  deadlineClock = () => performance.now(),
  setTimer = setTimeout,
  clearTimer = clearTimeout,
  onResult,
} = {}) {
  validateConfiguration({
    teamId,
    keyId,
    privateKey,
    bundleId,
    environment,
    requestTimeoutMs,
    clock,
    connect,
    randomUUID,
    signer,
    deadlineClock,
    setTimer,
    clearTimer,
    onResult,
  });

  const origin = APNS_ORIGINS[environment];
  const topic = `${bundleId}.voip`;
  let providerToken;
  let providerTokenIssuedAtMs = -1;
  let providerTokenPromise;
  let sessionState;
  const sessionStates = new Set();
  let transportClosed = false;
  let lastClockMs = -1;
  let lastDeadlineClockMs = -1;

  function readClockMs() {
    const nowMs = readEpochMilliseconds(clock);
    if (nowMs < lastClockMs) {
      throw new ApnsVoipTransportError('apns-clock-invalid', 'APNs clock moved backwards');
    }
    lastClockMs = nowMs;
    return nowMs;
  }

  function readDeadlineClockMs() {
    let nowMs;
    try {
      nowMs = deadlineClock();
    } catch {
      throw new ApnsVoipTransportError('apns-deadline-clock-invalid', 'APNs deadline clock is unavailable');
    }
    if (typeof nowMs !== 'number' || !Number.isFinite(nowMs) || nowMs < lastDeadlineClockMs) {
      throw new ApnsVoipTransportError('apns-deadline-clock-invalid', 'APNs deadline clock must be monotonic');
    }
    lastDeadlineClockMs = nowMs;
    return nowMs;
  }

  function clearDeadlineTimer(timer) {
    if (timer === undefined) return;
    try { clearTimer(timer); } catch {}
  }

  function waitUntilDeadline(pending, deadlineAtMs) {
    const remainingMs = deadlineAtMs - readDeadlineClockMs();
    if (remainingMs <= 0) return Promise.resolve(DEADLINE_EXCEEDED);
    return new Promise((resolve, reject) => {
      let settled = false;
      let timer;
      const finish = (callback, value) => {
        if (settled) return;
        settled = true;
        clearDeadlineTimer(timer);
        callback(value);
      };
      try {
        timer = setTimer(() => finish(resolve, DEADLINE_EXCEEDED), Math.ceil(remainingMs));
      } catch {
        settled = true;
        reject(new ApnsVoipTransportError('apns-deadline-unavailable', 'APNs request deadline is unavailable'));
        return;
      }
      Promise.resolve(pending).then(
        (value) => finish(resolve, value),
        (error) => finish(reject, error),
      );
    });
  }

  async function issueProviderToken(nowMs) {
    const issuedAt = Math.floor(nowMs / 1_000);
    const header = base64Url(JSON.stringify({ alg: 'ES256', kid: keyId }));
    const claims = base64Url(JSON.stringify({ iss: teamId, iat: issuedAt }));
    const signingInput = `${header}.${claims}`;
    let signature;
    try {
      signature = await signer('sha256', Buffer.from(signingInput, 'ascii'), {
        key: privateKey,
        dsaEncoding: 'ieee-p1363',
      });
    } catch {
      throw new ApnsVoipTransportError('apns-provider-token-unavailable', 'APNs provider token signing failed');
    }
    if (!ArrayBuffer.isView(signature) || signature.byteLength !== 64) {
      throw new ApnsVoipTransportError('apns-provider-token-unavailable', 'APNs provider token signing failed');
    }
    return `${signingInput}.${base64Url(new Uint8Array(signature.buffer, signature.byteOffset, signature.byteLength))}`;
  }

  async function getProviderToken() {
    const nowMs = readClockMs();
    if (providerToken && nowMs >= providerTokenIssuedAtMs &&
        nowMs - providerTokenIssuedAtMs < APNS_PROVIDER_TOKEN_TTL_MS) {
      return providerToken;
    }
    if (!providerTokenPromise) {
      providerTokenPromise = issueProviderToken(nowMs)
        .then((value) => {
          providerToken = value;
          providerTokenIssuedAtMs = nowMs;
          return value;
        })
        .finally(() => {
          providerTokenPromise = undefined;
        });
    }
    return providerTokenPromise;
  }

  function invalidateProviderToken(usedToken) {
    if (providerToken === usedToken) {
      providerToken = undefined;
      providerTokenIssuedAtMs = -1;
    }
  }

  function closeSessionState(state, destroy = false) {
    if (!state) return;
    sessionStates.delete(state);
    if (state.closed) return;
    state.closed = true;
    if (sessionState === state) sessionState = undefined;
    try {
      if (destroy && typeof state.client.destroy === 'function') state.client.destroy();
      else if (typeof state.client.close === 'function') state.client.close();
      else if (typeof state.client.destroy === 'function') state.client.destroy();
    } catch {
      // Session cleanup is best-effort and never changes a completed APNs result.
    }
  }

  function retireSession(state, destroyWhenIdle = false) {
    if (!state) return;
    if (destroyWhenIdle) state.destroyWhenIdle = true;
    if (!state.retired) {
      state.retired = true;
      if (sessionState === state) sessionState = undefined;
    }
    if (state.active.size === 0) closeSessionState(state, state.destroyWhenIdle);
  }

  function getSessionState() {
    if (transportClosed) {
      throw new ApnsVoipTransportError('apns-transport-closed', 'APNs transport is closed');
    }
    if (sessionState) {
      const current = sessionState;
      let reusable = false;
      try {
        reusable = !current.closed && !current.retired &&
          current.client?.closed !== true && current.client?.destroyed !== true;
      } catch {}
      if (reusable) return current;
      retireSession(current, true);
    }
    let client;
    try {
      // Apple token-auth connections permit only one stream until the first authenticated request succeeds. Node's
      // pre-SETTINGS default is much higher, so declare the safe prior; peer SETTINGS may raise it after authentication.
      client = connect(origin, { minVersion: 'TLSv1.2', peerMaxConcurrentStreams: 1 });
    } catch {
      throw new ApnsVoipTransportError('apns-connection-unavailable', 'APNs connection is unavailable');
    }
    if (!client || typeof client.request !== 'function' || typeof client.on !== 'function') {
      try { client?.destroy?.(); } catch {}
      throw new ApnsVoipTransportError('apns-connection-unavailable', 'APNs connection is unavailable');
    }
    const state = {
      client,
      active: new Set(),
      retired: false,
      destroyWhenIdle: false,
      closed: false,
    };
    sessionStates.add(state);
    sessionState = state;
    try {
      client.on('goaway', () => retireSession(state));
      client.on('close', () => {
        state.closed = true;
        sessionStates.delete(state);
        if (sessionState === state) sessionState = undefined;
        for (const fail of [...state.active]) fail();
      });
      client.on('error', () => {
        if (sessionState === state) sessionState = undefined;
        for (const fail of [...state.active]) fail();
        closeSessionState(state, true);
      });
    } catch {
      closeSessionState(state, true);
      throw new ApnsVoipTransportError('apns-connection-unavailable', 'APNs connection is unavailable');
    }
    return state;
  }

  function sendOnce({ token, body, authorization, deadlineAtMs }) {
    if (deadlineAtMs - readDeadlineClockMs() <= 0) {
      return Promise.resolve(notSentResult(undefined, 'request-deadline-exceeded'));
    }
    let apnsId;
    try {
      apnsId = randomUUID();
    } catch {
      throw new ApnsVoipTransportError('apns-request-id-unavailable', 'APNs request ID generation failed');
    }
    if (typeof apnsId !== 'string' || !UUID_RE.test(apnsId)) {
      throw new ApnsVoipTransportError('apns-request-id-unavailable', 'APNs request ID generation failed');
    }
    apnsId = apnsId.toLowerCase();

    let state;
    try {
      state = getSessionState();
    } catch (error) {
      return Promise.resolve(notSentResult(
        apnsId,
        error instanceof ApnsVoipTransportError && error.code === 'apns-transport-closed'
          ? 'transport-closed'
          : 'connection-unavailable',
      ));
    }

    return new Promise((resolve) => {
      let stream;
      let timer;
      let responseStatus;
      let responseApnsId = apnsId;
      let retryAfter;
      let responseBytes = 0;
      let responseOversized = false;
      const responseChunks = [];
      let settled = false;

      const finish = (result) => {
        if (settled) return;
        settled = true;
        clearDeadlineTimer(timer);
        state.active.delete(failAmbiguous);
        if (state.retired && state.active.size === 0) closeSessionState(state, state.destroyWhenIdle);
        resolve(result);
      };
      const failAmbiguous = () => finish(ambiguousResult(responseApnsId));
      const failNotSent = (reason) => finish(notSentResult(responseApnsId, reason));
      state.active.add(failAmbiguous);

      try {
        stream = state.client.request({
          ':method': 'POST',
          ':path': `/3/device/${token}`,
          authorization: `bearer ${authorization}`,
          'apns-id': apnsId,
          'apns-push-type': 'voip',
          'apns-topic': topic,
          'apns-priority': '10',
          'apns-expiration': '0',
          'content-type': 'application/json',
          'content-length': String(body.byteLength),
          [http2SensitiveHeaders]: ['authorization', ':path'],
        });
      } catch {
        retireSession(state, true);
        failNotSent('request-not-sent');
        return;
      }
      if (!stream || typeof stream.on !== 'function' || typeof stream.end !== 'function') {
        retireSession(state, true);
        failAmbiguous();
        return;
      }

      stream.on('response', (headers) => {
        try {
          const status = headers?.[':status'];
          responseStatus = typeof status === 'string' && /^[0-9]{3}$/.test(status) ? Number(status) : status;
          responseApnsId = normalizeApnsId(headers?.['apns-id'], apnsId);
          retryAfter = headers?.['retry-after'];
        } catch {
          responseStatus = undefined;
          responseApnsId = apnsId;
          retryAfter = undefined;
        }
      });
      stream.on('data', (chunk) => {
        if (settled || responseOversized) return;
        try {
          const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
          responseBytes += bytes.byteLength;
          if (responseBytes > APNS_MAX_RESPONSE_BYTES) {
            responseOversized = true;
            responseChunks.length = 0;
          } else {
            responseChunks.push(bytes);
          }
        } catch {
          responseOversized = true;
          responseChunks.length = 0;
        }
      });
      stream.on('end', () => {
        if (!Number.isInteger(responseStatus) || responseStatus < 200 || responseStatus > 599) {
          finish(ambiguousResult(responseApnsId, 'malformed-response'));
          return;
        }
        const nowMs = (() => {
          try { return readClockMs(); } catch { return 0; }
        })();
        if (responseStatus === 200) {
          if (responseOversized || responseBytes !== 0) {
            finish(ambiguousResult(responseApnsId, 'malformed-response'));
          } else {
            // `delivered` is the legacy gateway seam name: true means APNs accepted the request, not that a handset
            // received the push or presented CallKit. Device receipt remains a separate end-to-end smoke-gate fact.
            finish({ delivered: true, status: 200, apnsId: responseApnsId });
          }
          return;
        }
        const parsed = parseResponseBody(responseChunks, responseOversized);
        const result = negativeResult({
          status: responseStatus,
          reason: parsed.reason,
          apnsId: responseApnsId,
          retryAfter,
          timestamp: parsed.timestamp,
          nowMs,
        });
        if (result.reason === 'UnrelatedKeyIdInToken') retireSession(state, true);
        finish(result);
      });
      stream.on('aborted', failAmbiguous);
      stream.on('error', failAmbiguous);
      stream.on('close', () => {
        if (!settled) failAmbiguous();
      });

      let remainingMs;
      try {
        remainingMs = deadlineAtMs - readDeadlineClockMs();
        if (remainingMs <= 0) throw new Error('deadline elapsed after stream creation');
        timer = setTimer(() => {
          retireSession(state, true);
          failAmbiguous();
          try {
            if (typeof stream.close === 'function') stream.close(http2Constants.NGHTTP2_CANCEL);
            else if (typeof stream.destroy === 'function') stream.destroy();
          } catch {}
        }, Math.ceil(remainingMs));
      } catch {
        retireSession(state, true);
        failAmbiguous();
        try {
          if (typeof stream.close === 'function') stream.close(http2Constants.NGHTTP2_CANCEL);
          else if (typeof stream.destroy === 'function') stream.destroy();
        } catch {}
        return;
      }

      try {
        stream.end(body);
      } catch {
        retireSession(state, true);
        failAmbiguous();
      }
    });
  }

  async function send(input = {}) {
    if (transportClosed) {
      throw new ApnsVoipTransportError('apns-transport-closed', 'APNs transport is closed');
    }
    let voipToken;
    let platform;
    let payload;
    try {
      if (!input || typeof input !== 'object' || Array.isArray(input)) throw requestError('APNs request is invalid');
      voipToken = input.voipToken;
      platform = input.platform;
      payload = input.payload;
    } catch (error) {
      if (error instanceof ApnsVoipTransportError) throw error;
      throw requestError('APNs request fields are unavailable');
    }
    if (platform !== 'apns') {
      const result = {
        delivered: false,
        reason: 'unsupported-platform',
        disposition: 'permanent',
      };
      safeResultCallback(onResult, { ...result, environment, latencyMs: 0 });
      return result;
    }

    const deadlineAtMs = readDeadlineClockMs() + requestTimeoutMs;
    const startedAtMs = readClockMs();
    const token = normalizeDeviceToken(voipToken);
    const body = serializeFinalPayload(payload);
    let authorization = await waitUntilDeadline(getProviderToken(), deadlineAtMs);
    let result;
    if (authorization === DEADLINE_EXCEEDED) {
      result = notSentResult(undefined, 'request-deadline-exceeded');
    } else if (transportClosed) {
      result = notSentResult(undefined, 'transport-closed');
    } else {
      result = await sendOnce({ token, body, authorization, deadlineAtMs });
    }

    // An explicit Apple negative acknowledgement proves the first request was not accepted. This is the only safe
    // in-call replay: refresh the provider token once. Timeouts/stream/session failures remain outcome-ambiguous and
    // are never retried because a duplicate PushKit ring would surface a duplicate CallKit call.
    if (result.status === 403 && result.reason === 'ExpiredProviderToken') {
      invalidateProviderToken(authorization);
      authorization = await waitUntilDeadline(getProviderToken(), deadlineAtMs);
      if (authorization === DEADLINE_EXCEEDED) {
        result = notSentResult(undefined, 'request-deadline-exceeded');
      } else if (transportClosed) {
        result = notSentResult(undefined, 'transport-closed');
      } else {
        result = await sendOnce({ token, body, authorization, deadlineAtMs });
      }
    }

    let finishedAtMs = startedAtMs;
    try { finishedAtMs = readClockMs(); } catch {}
    safeResultCallback(onResult, {
      ...result,
      environment,
      latencyMs: Math.max(0, finishedAtMs - startedAtMs),
    });
    return result;
  }

  function close() {
    if (transportClosed) return;
    transportClosed = true;
    sessionState = undefined;
    for (const state of [...sessionStates]) {
      state.destroyWhenIdle = true;
      for (const fail of [...state.active]) fail();
      closeSessionState(state, true);
    }
  }

  return Object.freeze({ send, close });
}
