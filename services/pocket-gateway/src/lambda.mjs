// lambda.mjs — AWS Lambda / API Gateway (HTTP API v2) adapter for the gateway (Echo P1: no adapter existed).
// Pure request/response mapping — NO AWS SDK dependency. `export const handler = lambdaHandler(createGateway(deps))`.
// IaC (function + HTTP API + IAM + DynamoDB table + secrets) is deploy-time and lives outside this zero-dep package.

import {
  getOperationAdmissionAssertionRequest,
  OPERATION_ADMISSION_ASSERTION_EVENT_FIELD,
} from './operation-admission-assertion.mjs';
import { isRegistryOperationAdmissionRoute } from './operation-admission.mjs';

export const OPERATION_ADMISSION_ATTESTATION_REQUEST_SCHEMA =
  'senti.gateway.operation-admission-attestation.request.v1';
export const OPERATION_ADMISSION_ATTESTATION_RESPONSE_SCHEMA =
  'senti.gateway.operation-admission-attestation.response.v1';

const lowerHeaders = (h) => {
  const o = {};
  for (const k of Object.keys(h || {})) o[k.toLowerCase()] = h[k];
  return o;
};
const stripStage = (p) => p || '/';
const OPERATION_ADMISSION_UNAVAILABLE_BODY = JSON.stringify({
  error: 'registration operation admission unavailable',
  reason: 'operation-admission-unavailable',
});

function operationAdmissionUnavailable() {
  return {
    statusCode: 503,
    headers: { 'content-type': 'application/json' },
    body: OPERATION_ADMISSION_UNAVAILABLE_BODY,
    isBase64Encoded: false,
  };
}

function isOperationAdmissionAttestationEvent(event) {
  if (event === null || typeof event !== 'object') return false;
  if (
    !Object.hasOwn(event, 'schema') ||
    event.schema !== OPERATION_ADMISSION_ATTESTATION_REQUEST_SCHEMA
  ) return false;
  const keys = Reflect.ownKeys(event);
  if (keys.length !== 1 || keys[0] !== 'schema') {
    throw new Error('operation admission attestation request must contain only schema');
  }
  return true;
}

function fullUrl(event, headers, path) {
  const proto = headers['x-forwarded-proto'] || 'https';
  const host = event?.requestContext?.domainName || headers.host || 'localhost';
  return `${proto}://${host}${path}`;
}

/** Map the gateway's {status,headers,body,isBase64Encoded} response to an API Gateway HTTP API result. */
function toApiGw(res) {
  if (Buffer.isBuffer(res.body)) {
    return { statusCode: res.status, headers: res.headers || {}, body: res.body.toString('base64'), isBase64Encoded: true };
  }
  const isString = typeof res.body === 'string';
  return {
    statusCode: res.status,
    headers: { 'content-type': 'application/json', ...(res.headers || {}) },
    body: isString ? res.body : JSON.stringify(res.body ?? {}),
    isBase64Encoded: false,
  };
}

/**
 * Build an async Lambda handler(event, lambdaContext) from a gateway. Supports API Gateway HTTP API v2 (and v1-ish
 * fallbacks). Protected Registry V2 writes can require raw-event assertion verification before normalization.
 * @param {object} [opts]
 * @param {string} [opts.canonicalBaseUrl] deploy-canonical origin the DPoP `htu` must match; strongly recommended in
 *   production so the URL is not derived from an attacker-spoofable Host header
 * @param {boolean} [opts.requireOperationAdmissionAssertion] require a private assertion on protected Registry V2 POSTs
 * @param {(event:object,lambdaContext:object)=>Promise<object>} [opts.verifyOperationAdmissionAssertion] raw-event
 *   verifier returning the privately branded authorization context
 * @param {(lambdaContext:object)=>object|Promise<object>} [opts.operationAdmissionAttestation] direct-invoke runtime
 *   attestation. Its exact control event is intercepted before any HTTP event normalization or gateway work.
 */
export function lambdaHandler(gateway, opts = {}) {
  const canonicalBaseUrl = opts.canonicalBaseUrl ? opts.canonicalBaseUrl.replace(/\/+$/, '') : null;
  const requireOperationAdmissionAssertion = opts.requireOperationAdmissionAssertion === true;
  if (
    opts.requireOperationAdmissionAssertion !== undefined &&
    typeof opts.requireOperationAdmissionAssertion !== 'boolean'
  ) {
    throw new Error('requireOperationAdmissionAssertion must be boolean');
  }
  if (requireOperationAdmissionAssertion && typeof opts.verifyOperationAdmissionAssertion !== 'function') {
    throw new Error('verifyOperationAdmissionAssertion is required');
  }
  if (
    opts.operationAdmissionAttestation !== undefined &&
    typeof opts.operationAdmissionAttestation !== 'function'
  ) {
    throw new Error('operationAdmissionAttestation must be a function');
  }
  return async function handler(event, lambdaContext) {
    // This is a direct-Lambda control plane message, not an HTTP request. Recognize only the one-field schema so an
    // HTTP-looking payload cannot smuggle request data into this branch. A collision carrying the control schema plus
    // any enumerable, non-enumerable, or symbol key fails closed instead of falling through to normal HTTP handling.
    if (isOperationAdmissionAttestationEvent(event)) {
      if (typeof opts.operationAdmissionAttestation !== 'function') {
        throw new Error('operation admission attestation is not configured');
      }
      return opts.operationAdmissionAttestation(lambdaContext);
    }
    const method = event?.requestContext?.http?.method || event?.httpMethod || 'GET';
    const path = stripStage(event?.requestContext?.http?.path || event?.rawPath || event?.path || '/');
    const isProtectedOperation = isRegistryOperationAdmissionRoute(method, path);
    const carriesOperationAdmissionAssertion = Boolean(
      event && typeof event === 'object' && Object.hasOwn(event, OPERATION_ADMISSION_ASSERTION_EVENT_FIELD)
    );
    let operationAdmissionContext;
    let request;
    if (requireOperationAdmissionAssertion && isProtectedOperation) {
      try {
        operationAdmissionContext = await opts.verifyOperationAdmissionAssertion(event, lambdaContext);
        const verified = getOperationAdmissionAssertionRequest(operationAdmissionContext);
        const headers = {
          authorization: verified.authorization,
          'x-http-method': verified.method,
          'x-http-url': canonicalBaseUrl
            ? canonicalBaseUrl + verified.path
            : `https://localhost${verified.path}`,
        };
        request = Object.freeze({
          method: verified.method,
          path: verified.path,
          query: Object.freeze({}),
          headers: Object.freeze(headers),
          body: verified.body,
        });
      } catch {
        return operationAdmissionUnavailable();
      }
    } else if (carriesOperationAdmissionAssertion) {
      // The private capability is route- and deployment-mode-specific. It is never a generic alternate authenticator.
      return operationAdmissionUnavailable();
    }
    if (!request) {
      const headers = lowerHeaders(event?.headers || {});
      // SECURITY (Echo P0): x-http-method / x-http-url drive DPoP binding, so they MUST come from the trusted request
      // context, never the caller. Drop any forwarded variants and OVERWRITE with the actual method + the canonical
      // deployed URL (a spoofed value would let a stolen proof for one method/route authorize another).
      delete headers['x-http-method'];
      delete headers['x-http-url'];
      headers['x-http-method'] = method;
      headers['x-http-url'] = canonicalBaseUrl ? canonicalBaseUrl + path : fullUrl(event, headers, path);
      const query = event?.queryStringParameters || {};
      let body = event?.body;
      if (typeof body === 'string' && event?.isBase64Encoded) body = Buffer.from(body, 'base64').toString('utf8');
      request = { method, path, query, headers, body };
    }
    const res = await gateway.handle(request, operationAdmissionContext);
    return toApiGw(res);
  };
}
