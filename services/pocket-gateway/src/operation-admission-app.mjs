// Production composition for the Registry V2 operation-admission Lambda.
//
// This module deliberately imports no cloud SDK. Deployment code resolves the exact HMAC secret version and injects
// a DocumentClient-like Dynamo adapter plus the private Lambda invoker. The composition below binds those deploy-owned
// transports to the frozen verifier/admission/proxy boundaries.

import { deriveDeviceOwnerHandle } from './device-registry-v2.mjs';
import { createOperationAdmissionAssertionSigner } from './operation-admission-assertion.mjs';
import { createOperationAdmissionProxy } from './operation-admission-proxy.mjs';
import { createRegistryOperationAdmission } from './operation-admission.mjs';
import { createSentiSessionVerifier } from './senti-session-verifier.mjs';
import { createDynamoStore } from './store.mjs';

export const REGISTRY_OPERATION_ADMISSION_AUTH_MODE = 'senti_session_reusable_v1';
export const DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID_MIN_BYTES = 32;
export const DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID_MAX_BYTES = 64;

const HMAC_VERSION_ID_RE = /^[A-Za-z0-9-]+$/;

export class OperationAdmissionAppError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'OperationAdmissionAppError';
    this.code = code;
  }
}

function configurationError(message) {
  return new OperationAdmissionAppError('operation-admission-configuration-invalid', message);
}

function requiredString(value, name) {
  if (typeof value !== 'string' || value.length === 0 || value.trim() !== value) {
    throw configurationError(`${name} must be a nonempty canonical string`);
  }
  return value;
}

function canonicalHttpsOrigin(value, name) {
  const raw = requiredString(value, name);
  if (Buffer.byteLength(raw, 'utf8') > 2048) {
    throw configurationError(`${name} must be a bounded HTTPS origin`);
  }
  let parsed;
  try {
    parsed = new URL(raw);
  } catch {
    throw configurationError(`${name} must be an HTTPS origin`);
  }
  if (
    parsed.protocol !== 'https:' ||
    parsed.username !== '' ||
    parsed.password !== '' ||
    parsed.pathname !== '/' ||
    parsed.search !== '' ||
    parsed.hash !== ''
  ) {
    throw configurationError(`${name} must be an HTTPS origin without credentials, path, query, or fragment`);
  }
  return parsed.origin;
}

function canonicalHmacVersionId(value, name) {
  const bytes = typeof value === 'string' ? Buffer.byteLength(value, 'utf8') : 0;
  if (
    typeof value !== 'string' ||
    !HMAC_VERSION_ID_RE.test(value) ||
    bytes < DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID_MIN_BYTES ||
    bytes > DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID_MAX_BYTES
  ) {
    throw configurationError(`${name} must be a canonical 32-64 character AWS secret version identifier`);
  }
  return value;
}

/**
 * Narrow a verifier to the only authentication contract safe for the admission boundary.
 *
 * Admission verifies a reusable Senti session once, then the private gateway consumes a short-lived signed assertion.
 * A single-use DPoP proof remains unsupported until its external verification can be performed once without changing
 * this declared contract. Any other verifier identity is a deployment violation, never an alternate auth path.
 */
export function createReusableSentiSessionVerifierGuard(verifyToken) {
  if (typeof verifyToken !== 'function') {
    throw configurationError('reusable Senti session guard requires verifyToken');
  }

  return async function verifyReusableSentiSession(headers) {
    const identity = await verifyToken(headers);
    if (identity === null || identity === undefined) return null;

    let authMethod;
    try {
      if (!identity || typeof identity !== 'object' || Array.isArray(identity)) {
        throw new Error('invalid verifier identity');
      }
      authMethod = identity.tokenClaims?.authMethod;
    } catch {
      throw new OperationAdmissionAppError(
        'operation-admission-auth-contract-invalid',
        'operation admission verifier returned an invalid authentication identity',
      );
    }
    if (authMethod !== 'senti_session') {
      throw new OperationAdmissionAppError(
        'operation-admission-auth-contract-invalid',
        'operation admission requires a reusable Senti session identity',
      );
    }
    return identity;
  };
}

/**
 * Compose the zero-dependency production handler.
 *
 * Deployment MUST resolve DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID explicitly and inject the key fetched by that exact
 * immutable VersionId. The private gateway and this admission Lambda must be configured from the same VersionId; a
 * mutable AWSCURRENT lookup would allow their owner/quota namespaces to diverge during rotation.
 *
 * @param {object} env deploy-owned configuration
 * @param {object} dependencies deploy-owned transports and secret material
 * @returns {(event:object)=>Promise<object>} API Gateway compatible handler
 */
export function createOperationAdmissionApp(env = {}, dependencies = {}) {
  if (env?.REGISTRY_OPERATION_ADMISSION_AUTH_MODE !== REGISTRY_OPERATION_ADMISSION_AUTH_MODE) {
    throw configurationError(
      `REGISTRY_OPERATION_ADMISSION_AUTH_MODE must equal ${REGISTRY_OPERATION_ADMISSION_AUTH_MODE}`,
    );
  }

  const apiBaseUrl = canonicalHttpsOrigin(env?.SENTI_API_BASE_URL, 'SENTI_API_BASE_URL');
  const table = requiredString(env?.OPERATION_ADMISSION_DDB_TABLE, 'OPERATION_ADMISSION_DDB_TABLE');
  const configuredHmacVersionId = canonicalHmacVersionId(
    env?.DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID,
    'DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID',
  );

  const {
    fetch,
    dynamoClient,
    invokeGateway,
    hmacKey,
    hmacKeyVersionId,
    now,
    retryDelay,
    maxBodyBytes,
    randomBytes,
  } = dependencies || {};

  if (typeof fetch !== 'function') throw configurationError('operation admission app requires injected fetch');
  if (
    !dynamoClient ||
    typeof dynamoClient.get !== 'function' ||
    typeof dynamoClient.put !== 'function' ||
    typeof dynamoClient.delete !== 'function'
  ) {
    throw configurationError('operation admission app requires injected Dynamo get/put/delete methods');
  }
  if (typeof invokeGateway !== 'function') {
    throw configurationError('operation admission app requires injected private gateway invoker');
  }
  if (hmacKey === undefined) throw configurationError('operation admission app requires injected HMAC key');

  const injectedHmacVersionId = canonicalHmacVersionId(
    hmacKeyVersionId,
    'injected hmacKeyVersionId',
  );
  if (injectedHmacVersionId !== configuredHmacVersionId) {
    throw configurationError('injected HMAC key version does not match DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID');
  }

  // Snapshot mutable Buffer input and validate it at cold start, before any request can enter auth/admission. The
  // derivation result is discarded; this uses the same frozen key parser as Registry V2 without exposing key bytes or
  // derived production identifiers.
  const pinnedHmacKey = Buffer.isBuffer(hmacKey) ? Buffer.from(hmacKey) : hmacKey;
  try {
    deriveDeviceOwnerHandle(pinnedHmacKey, 'operation-admission-bootstrap', 'operation-admission-bootstrap');
  } catch {
    throw configurationError('injected HMAC key is invalid');
  }

  const rawVerifier = createSentiSessionVerifier({
    fetch,
    apiBaseUrl,
    now,
    throwOnUnavailable: true,
  });
  const verifyToken = createReusableSentiSessionVerifierGuard(rawVerifier);
  const store = createDynamoStore({ client: dynamoClient, table, now });
  const admission = createRegistryOperationAdmission({ store, now, retryDelay });
  const assertionSigner = createOperationAdmissionAssertionSigner({
    hmacKey: Buffer.isBuffer(pinnedHmacKey) ? pinnedHmacKey.toString('base64') : pinnedHmacKey,
    kid: injectedHmacVersionId,
    secretArn: requiredString(env?.DEVICE_REGISTRY_HMAC_SECRET_ARN, 'DEVICE_REGISTRY_HMAC_SECRET_ARN'),
    audience: requiredString(env?.GATEWAY_LAMBDA_VERSION_ARN, 'GATEWAY_LAMBDA_VERSION_ARN'),
    now,
    randomBytes,
  });

  return createOperationAdmissionProxy({
    verifyToken,
    admission,
    createAssertion: (input) => assertionSigner.sign(input),
    invokeGateway,
    hmacKey: pinnedHmacKey,
    maxBodyBytes,
  });
}
