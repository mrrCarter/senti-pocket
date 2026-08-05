// Registry V2's body-reading admission Lambda boundary.
//
// The proxy deliberately does not authorize registry semantics. It authenticates only far enough to derive the
// verifier-owned operation identity, admits that identity in shared state, and then forwards a shallow event clone with
// a short-lived request-bound assertion. The original bearer/body remain byte-identical; the private gateway verifies
// the assertion instead of consuming a second /auth/me request.
import {
  deriveRegistryOperationAdmissionIdentity,
  isRegistryOperationAdmissionRoute,
} from './operation-admission.mjs';
import {
  OPERATION_ADMISSION_ASSERTION_EVENT_FIELD,
  snapshotOperationAdmissionRawRequest,
  snapshotOperationAdmissionScopes,
} from './operation-admission-assertion.mjs';
import { assertDeviceRegistryOwnerIdentity } from './device-registry-v2.mjs';

export const OPERATION_ADMISSION_MAX_BODY_BYTES = 4 * 1024;

const OWNER_CONFLICT = Object.freeze({
  error: 'registry owner does not match authenticated principal',
  reason: 'registry-owner-conflict',
});
const RATE_LIMITED = Object.freeze({
  error: 'registration operation rate limited',
  reason: 'operation-rate-limited',
});
const UNAVAILABLE = Object.freeze({
  error: 'registration operation admission unavailable',
  reason: 'operation-admission-unavailable',
});

function json(statusCode, value, headers = {}) {
  return {
    statusCode,
    headers: { 'content-type': 'application/json', ...headers },
    body: JSON.stringify(value),
    isBase64Encoded: false,
  };
}

function unavailable() {
  return json(503, UNAVAILABLE);
}

function requestRoute(event) {
  const rawMethod = event?.requestContext?.http?.method ?? event?.httpMethod ?? 'GET';
  const rawPath = event?.requestContext?.http?.path ?? event?.rawPath ?? event?.path ?? '/';
  return {
    method: typeof rawMethod === 'string' ? rawMethod.toUpperCase() : 'GET',
    path: typeof rawPath === 'string' ? rawPath : '/',
  };
}

function validHeaders(headers) {
  if (headers === undefined) return true;
  if (!headers || typeof headers !== 'object' || Array.isArray(headers)) return false;
  return Object.values(headers).every((value) =>
    typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean');
}

function validGatewayResponse(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  if (!Number.isInteger(value.statusCode) || value.statusCode < 100 || value.statusCode > 599) return false;
  if (typeof value.body !== 'string') return false;
  if (!validHeaders(value.headers)) return false;
  if (value.isBase64Encoded !== undefined && typeof value.isBase64Encoded !== 'boolean') return false;
  if (value.cookies !== undefined &&
      (!Array.isArray(value.cookies) || !value.cookies.every((cookie) => typeof cookie === 'string'))) return false;
  return true;
}

async function invokePrivateGateway(invokeGateway, event) {
  let response;
  try {
    response = await invokeGateway(event);
  } catch {
    return unavailable();
  }
  // The invoker owns AWS-SDK response unwrapping. Accept only the API Gateway result emitted by lambdaHandler; Lambda
  // transport metadata or a FunctionError envelope must never be reflected to the caller.
  try {
    return validGatewayResponse(response) ? response : unavailable();
  } catch {
    return unavailable();
  }
}

function positiveRetryAfter(error) {
  const value = error && error.retryAfterSeconds;
  if (typeof value !== 'number' || !Number.isFinite(value) || value <= 0) return null;
  const rounded = Math.ceil(value);
  return Number.isSafeInteger(rounded) && rounded > 0 ? rounded : null;
}

function attachAssertion(event, assertion) {
  if (!event || typeof event !== 'object' || Object.hasOwn(event, OPERATION_ADMISSION_ASSERTION_EVENT_FIELD)) {
    throw new Error('operation admission assertion field is reserved');
  }
  const privateEvent = Object.create(Object.getPrototypeOf(event));
  Object.defineProperties(privateEvent, Object.getOwnPropertyDescriptors(event));
  Object.defineProperty(privateEvent, OPERATION_ADMISSION_ASSERTION_EVENT_FIELD, {
    value: assertion,
    enumerable: true,
    configurable: false,
    writable: false,
  });
  return privateEvent;
}

/**
 * @param {object} options
 * @param {(headers:object)=>Promise<object|null>} options.verifyToken verifier-owned identity boundary
 * @param {{admit:({ledgerKey:string,operationDigest:string})=>Promise<object>}} options.admission shared admission store
 * @param {(input:object)=>object} options.createAssertion short-lived exact-request internal assertion signer
 * @param {(originalEvent:object)=>Promise<object>} options.invokeGateway private gateway-Lambda invoker; unwraps AWS SDK
 * @param {Buffer|string} options.hmacKey Registry V2 HMAC key used by the frozen derivation helper
 * @param {number} [options.maxBodyBytes]
 * @returns {(event:object)=>Promise<object>} API Gateway HTTP API v2 compatible Lambda handler
 */
export function createOperationAdmissionProxy({
  verifyToken,
  admission,
  createAssertion,
  invokeGateway,
  hmacKey,
  maxBodyBytes = OPERATION_ADMISSION_MAX_BODY_BYTES,
} = {}) {
  if (typeof verifyToken !== 'function') throw new Error('operation admission proxy requires verifyToken');
  if (!admission || typeof admission.admit !== 'function') {
    throw new Error('operation admission proxy requires admission.admit');
  }
  if (typeof createAssertion !== 'function') {
    throw new Error('operation admission proxy requires createAssertion');
  }
  if (typeof invokeGateway !== 'function') throw new Error('operation admission proxy requires invokeGateway');
  if (hmacKey === undefined) throw new Error('operation admission proxy requires hmacKey');
  if (
    !Number.isSafeInteger(maxBodyBytes) ||
    maxBodyBytes <= 0 ||
    maxBodyBytes > OPERATION_ADMISSION_MAX_BODY_BYTES
  ) {
    throw new Error(`operation admission proxy maxBodyBytes must be an integer from 1 through ${OPERATION_ADMISSION_MAX_BODY_BYTES}`);
  }

  return async function operationAdmissionProxy(event) {
    const { method, path } = requestRoute(event);
    if (!isRegistryOperationAdmissionRoute(method, path)) {
      // This Lambda is a single-purpose security boundary, not a general gateway proxy. Public non-protected routes
      // integrate with the gateway directly; rejecting them here also fails closed if API routing is misconfigured or
      // a principal invokes the admission function directly.
      return unavailable();
    }
    let snapshot;
    try {
      snapshot = snapshotOperationAdmissionRawRequest(event, { maxBodyBytes });
    } catch (error) {
      if (error?.code === 'operation-admission-assertion-body-too-large') {
        return json(413, {
          error: `registry operation request exceeds ${maxBodyBytes} bytes`,
          reason: 'operation-admission-body-too-large',
        });
      }
      if (error?.code === 'operation-admission-assertion-body-invalid') {
        return json(400, { error: 'invalid JSON body' });
      }
      return unavailable();
    }

    let identity;
    try {
      identity = await verifyToken(Object.freeze({ authorization: snapshot.authorization }));
    } catch {
      return unavailable();
    }
    if (identity === null || identity === undefined) {
      return json(401, { error: 'authentication required' }, { 'www-authenticate': 'Bearer' });
    }
    let principal;
    let humanId;
    let scopes;
    try {
      principal = identity?.principal;
      humanId = identity?.humanId;
      if (!identity || typeof identity !== 'object') throw new Error('verified identity is invalid');
      assertDeviceRegistryOwnerIdentity(principal, humanId);
      // Capture verifier authority before the first post-auth await. The assertion signer validates the same canonical
      // shape again, but it must never observe a mutable identity after the admission CAS has committed.
      scopes = snapshotOperationAdmissionScopes(identity.scopes);
    } catch {
      return unavailable();
    }

    let derived;
    try {
      derived = deriveRegistryOperationAdmissionIdentity({
        method,
        path,
        body: snapshot.parsedBody,
        principal,
        humanId,
        hmacKey,
      });
    } catch {
      return unavailable();
    }
    if (!derived || derived.protected !== true) return unavailable();
    if (!derived.ok) return json(derived.status, { error: derived.error, reason: derived.reason });
    if (derived.ownerMatches !== true) return json(409, OWNER_CONFLICT);

    let decision;
    try {
      decision = await admission.admit({
        ledgerKey: derived.ledgerKey,
        operationDigest: derived.operationDigest,
      });
    } catch (error) {
      if (error && error.code === 'operation-rate-limited') {
        const retryAfter = positiveRetryAfter(error);
        if (retryAfter !== null) return json(429, RATE_LIMITED, { 'retry-after': String(retryAfter) });
      }
      return unavailable();
    }
    try {
      if (!decision || decision.admitted !== true || typeof decision.replay !== 'boolean') return unavailable();
    } catch {
      return unavailable();
    }

    let privateEvent;
    try {
      const assertion = createAssertion({
        snapshot,
        principal,
        humanId,
        scopes,
        ownerHandle: derived.ownerHandle,
        operationDigest: derived.operationDigest,
      });
      // Preserve the original bearer, original plain/base64 body, and every existing API event field byte-for-byte.
      // Clone only the top-level event to add the signed private proof; preserve the original body/header references and
      // never mutate the public caller event or inject raw trusted identity outside the authenticated assertion.
      privateEvent = attachAssertion(event, assertion);
    } catch {
      return unavailable();
    }
    return invokePrivateGateway(invokeGateway, privateEvent);
  };
}
