import { KeyObject, createPrivateKey } from 'node:crypto';

import { createApnsVoipTransport } from '../../src/apns-voip-transport.mjs';
import { createLambda } from '../../src/app.mjs';
import { createDynamoClientAdapter } from '../../src/store.mjs';

export const GATEWAY_SECRET_VERSION_ID_RE = /^[A-Za-z0-9-]{32,64}$/;
export const GATEWAY_HMAC_SECRET_MIN_BYTES = 32;
export const GATEWAY_HMAC_SECRET_MAX_BYTES = 1_024;
export const GATEWAY_PRIVATE_KEY_SECRET_MAX_BYTES = 16_384;

const SECRET_ARN_RE =
  /^arn:(?:aws|aws-cn|aws-us-gov):secretsmanager:[a-z0-9-]{1,32}:[0-9]{12}:secret:[A-Za-z0-9/_+=.@-]{1,512}-[A-Za-z0-9]{6}$/;
const CANONICAL_BASE64_RE = /^[A-Za-z0-9+/]+={0,2}$/;
const APPLE_ID_RE = /^[A-Z0-9]{10}$/;
const BUNDLE_ID_RE = /^(?=.{1,255}$)[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$/;
const APNS_ENVIRONMENTS = new Set(['development', 'production']);
const METRICS = new Set([
  'gateway_bootstrap_failure',
  'gateway_runtime_failure',
  'apns_accepted',
  'apns_ambiguous',
  'apns_negative_acknowledgement',
  'apns_not_sent',
]);
const APNS_DISPOSITIONS = new Set([
  'accepted',
  'ambiguous',
  'permanent',
  'retryable-negative-ack',
  'not-sent',
]);
const UNAVAILABLE_RESPONSE = Object.freeze({
  statusCode: 503,
  headers: Object.freeze({ 'content-type': 'application/json' }),
  body: JSON.stringify({
    error: 'pocket gateway unavailable',
    reason: 'gateway-unavailable',
  }),
  isBase64Encoded: false,
});

export class GatewayBootstrapError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'GatewayBootstrapError';
    this.code = code;
  }
}

function configurationError(message) {
  return new GatewayBootstrapError('gateway-bootstrap-configuration-invalid', message);
}

function secretUnavailable() {
  // Never retain an SDK response, PEM, or cause on an application error. Lambda reporters may serialize errors.
  return new GatewayBootstrapError('gateway-secret-unavailable', 'gateway secret unavailable');
}

function canonicalSecretArn(value, label) {
  if (typeof value !== 'string' || !SECRET_ARN_RE.test(value)) {
    throw configurationError(`${label} must be a complete wildcard-free Secrets Manager ARN`);
  }
  return value;
}

function canonicalVersionId(value, label) {
  if (typeof value !== 'string' || !GATEWAY_SECRET_VERSION_ID_RE.test(value)) {
    throw configurationError(`${label} must be a 32-64 character canonical version identifier`);
  }
  return value;
}

function canonicalFlag(value, label, { defaultValue } = {}) {
  if ((value === undefined || value === '') && defaultValue !== undefined) return defaultValue;
  if (value === '0') return false;
  if (value === '1') return true;
  throw configurationError(`${label} must be exactly 0 or 1`);
}

function snapshotEnvironment(env) {
  // Keep only owned scalar configuration. In particular, do not retain the complete Lambda environment or any
  // unrelated credential that happens to share the process.
  return Object.freeze({
    APNS_BUNDLE_ID: env?.APNS_BUNDLE_ID,
    APNS_KEY_ID: env?.APNS_KEY_ID,
    APNS_PRIVATE_KEY_SECRET_ARN: env?.APNS_PRIVATE_KEY_SECRET_ARN,
    APNS_PRIVATE_KEY_SECRET_VERSION_ID: env?.APNS_PRIVATE_KEY_SECRET_VERSION_ID,
    APNS_TEAM_ID: env?.APNS_TEAM_ID,
    APNS_VOIP_ENABLED: env?.APNS_VOIP_ENABLED,
    APNS_VOIP_ENVIRONMENT: env?.APNS_VOIP_ENVIRONMENT,
    AWS_LAMBDA_FUNCTION_VERSION: env?.AWS_LAMBDA_FUNCTION_VERSION,
    DDB_TABLE: env?.DDB_TABLE,
    DEVICE_REGISTRY_CLIENT_V2_READY: env?.DEVICE_REGISTRY_CLIENT_V2_READY,
    DEVICE_REGISTRY_HMAC_SECRET_ARN: env?.DEVICE_REGISTRY_HMAC_SECRET_ARN,
    DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID: env?.DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID,
    DEVICE_REGISTRY_MODE: env?.DEVICE_REGISTRY_MODE,
    DEVICE_REGISTRY_OUTCOME_PROTOCOL_READY: env?.DEVICE_REGISTRY_OUTCOME_PROTOCOL_READY,
    DEVICE_REGISTRY_OWNER_CONTINUITY_READY: env?.DEVICE_REGISTRY_OWNER_CONTINUITY_READY,
    DEVICE_REGISTRY_V1_PURGED: env?.DEVICE_REGISTRY_V1_PURGED,
    GATEWAY_PUBLIC_URL: env?.GATEWAY_PUBLIC_URL,
    SENTI_API_BASE_URL: env?.SENTI_API_BASE_URL,
    SIGNING_KEY_ID: env?.SIGNING_KEY_ID,
    SIGNING_KEY_SECRET_ARN: env?.SIGNING_KEY_SECRET_ARN,
    SIGNING_KEY_SECRET_VERSION_ID: env?.SIGNING_KEY_SECRET_VERSION_ID,
  });
}

function secretPin(secretArn, versionId, arnLabel, versionLabel) {
  return Object.freeze({
    secretArn: canonicalSecretArn(secretArn, arnLabel),
    versionId: canonicalVersionId(versionId, versionLabel),
  });
}

function validateConfiguration(env) {
  if (!['v1', 'v2'].includes(env.DEVICE_REGISTRY_MODE)) {
    throw configurationError('DEVICE_REGISTRY_MODE must be exactly v1 or v2');
  }

  const signing = secretPin(
    env.SIGNING_KEY_SECRET_ARN,
    env.SIGNING_KEY_SECRET_VERSION_ID,
    'SIGNING_KEY_SECRET_ARN',
    'SIGNING_KEY_SECRET_VERSION_ID',
  );
  const registry = env.DEVICE_REGISTRY_MODE === 'v2'
    ? secretPin(
      env.DEVICE_REGISTRY_HMAC_SECRET_ARN,
      env.DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID,
      'DEVICE_REGISTRY_HMAC_SECRET_ARN',
      'DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID',
    )
    : undefined;
  const apnsEnabled = canonicalFlag(env.APNS_VOIP_ENABLED, 'APNS_VOIP_ENABLED', {
    defaultValue: false,
  });
  let apns;
  if (apnsEnabled) {
    if (typeof env.APNS_TEAM_ID !== 'string' || !APPLE_ID_RE.test(env.APNS_TEAM_ID)) {
      throw configurationError('APNS_TEAM_ID must be a 10-character uppercase Apple Team ID');
    }
    if (typeof env.APNS_KEY_ID !== 'string' || !APPLE_ID_RE.test(env.APNS_KEY_ID)) {
      throw configurationError('APNS_KEY_ID must be a 10-character uppercase Apple Key ID');
    }
    if (typeof env.APNS_BUNDLE_ID !== 'string' || !BUNDLE_ID_RE.test(env.APNS_BUNDLE_ID)) {
      throw configurationError('APNS_BUNDLE_ID must be a bounded reverse-DNS bundle identifier');
    }
    if (!APNS_ENVIRONMENTS.has(env.APNS_VOIP_ENVIRONMENT)) {
      throw configurationError('APNS_VOIP_ENVIRONMENT must be exactly development or production');
    }
    apns = Object.freeze({
      ...secretPin(
        env.APNS_PRIVATE_KEY_SECRET_ARN,
        env.APNS_PRIVATE_KEY_SECRET_VERSION_ID,
        'APNS_PRIVATE_KEY_SECRET_ARN',
        'APNS_PRIVATE_KEY_SECRET_VERSION_ID',
      ),
      teamId: env.APNS_TEAM_ID,
      keyId: env.APNS_KEY_ID,
      bundleId: env.APNS_BUNDLE_ID,
      environment: env.APNS_VOIP_ENVIRONMENT,
    });
  }
  return Object.freeze({ signing, registry, apnsEnabled, apns });
}

/** Read exactly one SecretString version. Mutable stages and SecretBinary are deliberately unsupported. */
export async function loadPinnedSecretString({
  secretsManagerClient,
  GetSecretValueCommand,
  secretArn,
  versionId,
  minBytes = 1,
  maxBytes = GATEWAY_PRIVATE_KEY_SECRET_MAX_BYTES,
} = {}) {
  if (!secretsManagerClient || typeof secretsManagerClient.send !== 'function') {
    throw configurationError('Secrets Manager v3 client is required');
  }
  if (typeof GetSecretValueCommand !== 'function') {
    throw configurationError('GetSecretValueCommand is required');
  }
  canonicalSecretArn(secretArn, 'secret ARN');
  canonicalVersionId(versionId, 'secret version');
  if (!Number.isSafeInteger(minBytes) || !Number.isSafeInteger(maxBytes) ||
      minBytes <= 0 || maxBytes < minBytes || maxBytes > GATEWAY_PRIVATE_KEY_SECRET_MAX_BYTES) {
    throw configurationError('secret byte bounds are invalid');
  }

  let response;
  try {
    response = await secretsManagerClient.send(
      new GetSecretValueCommand({ SecretId: secretArn, VersionId: versionId }),
    );
  } catch {
    throw secretUnavailable();
  }
  try {
    if (!response || typeof response !== 'object' || Array.isArray(response) ||
        response.VersionId !== versionId || !Object.hasOwn(response, 'SecretString') ||
        Object.hasOwn(response, 'SecretBinary') || typeof response.SecretString !== 'string') {
      throw secretUnavailable();
    }
    const byteLength = Buffer.byteLength(response.SecretString, 'utf8');
    if (byteLength < minBytes || byteLength > maxBytes) throw secretUnavailable();
    return response.SecretString;
  } catch {
    throw secretUnavailable();
  }
}

function parsePrivateKey(pem, expectedType) {
  try {
    const key = createPrivateKey(pem);
    if (!(key instanceof KeyObject) || key.type !== 'private') throw secretUnavailable();
    if (expectedType === 'ed25519' && key.asymmetricKeyType !== 'ed25519') throw secretUnavailable();
    if (expectedType === 'p256' && (
      key.asymmetricKeyType !== 'ec' ||
      !['prime256v1', 'P-256'].includes(key.asymmetricKeyDetails?.namedCurve)
    )) {
      throw secretUnavailable();
    }
    return key;
  } catch {
    throw secretUnavailable();
  }
}

function canonicalHmacSecret(value) {
  try {
    if (typeof value !== 'string' || value.length === 0 || value.length % 4 !== 0 ||
        !CANONICAL_BASE64_RE.test(value) ||
        Buffer.byteLength(value, 'utf8') > Math.ceil(GATEWAY_HMAC_SECRET_MAX_BYTES / 3) * 4) {
      throw secretUnavailable();
    }
    const decoded = Buffer.from(value, 'base64');
    try {
      if (decoded.byteLength < GATEWAY_HMAC_SECRET_MIN_BYTES ||
          decoded.byteLength > GATEWAY_HMAC_SECRET_MAX_BYTES || decoded.toString('base64') !== value) {
        throw secretUnavailable();
      }
    } finally {
      decoded.fill(0);
    }
    return value;
  } catch {
    throw secretUnavailable();
  }
}

export function createGatewayMetricEmitter({ write = console.log, now = Date.now } = {}) {
  if (typeof write !== 'function' || typeof now !== 'function') {
    throw configurationError('metric writer and clock must be functions');
  }
  return (event = {}) => {
    try {
      if (!METRICS.has(event.metric)) return;
      const record = {
        event: 'senti_pocket_gateway_metric',
        metric: event.metric,
        timestamp: new Date(now()).toISOString(),
      };
      if (APNS_DISPOSITIONS.has(event.disposition)) record.disposition = event.disposition;
      if (APNS_ENVIRONMENTS.has(event.environment)) record.apnsEnvironment = event.environment;
      write(JSON.stringify(record));
    } catch {
      // Telemetry is observation only. It cannot affect APNs or gateway request semantics.
    }
  };
}

function apnsMetric(event) {
  if (event?.delivered === true) {
    return { metric: 'apns_accepted', disposition: 'accepted', environment: event.environment };
  }
  if (event?.disposition === 'ambiguous') {
    return { metric: 'apns_ambiguous', disposition: event.disposition, environment: event.environment };
  }
  if (event?.disposition === 'not-sent') {
    return { metric: 'apns_not_sent', disposition: event.disposition, environment: event.environment };
  }
  return {
    metric: 'apns_negative_acknowledgement',
    disposition: event?.disposition,
    environment: event?.environment,
  };
}

function unavailableResponse() {
  return {
    ...UNAVAILABLE_RESPONSE,
    headers: { ...UNAVAILABLE_RESPONSE.headers },
  };
}

/**
 * Compose one cold-start gateway singleton. The production gateway constructs its authoritative, role-aware target
 * membership resolver from this injected fetch boundary plus SENTI_API_BASE_URL. Bootstrap therefore exposes no
 * membership-adapter seam that could be replaced with an empty, demo, or static allowlist. The Terraform module also
 * creates no route or alias.
 */
export function createGatewayBootstrap({
  env = process.env,
  fetch = globalThis.fetch,
  secretsManagerClient,
  GetSecretValueCommand,
  dynamoDocumentClient,
  dynamoCommands,
  createGatewayHandler = createLambda,
  createDynamoAdapter = createDynamoClientAdapter,
  createApnsTransport = createApnsVoipTransport,
  emitMetric = createGatewayMetricEmitter(),
} = {}) {
  if (typeof fetch !== 'function') throw configurationError('fetch must be a function');
  if (typeof createGatewayHandler !== 'function') {
    throw configurationError('createGatewayHandler must be a function');
  }
  if (typeof createDynamoAdapter !== 'function') {
    throw configurationError('createDynamoAdapter must be a function');
  }
  if (typeof createApnsTransport !== 'function') {
    throw configurationError('createApnsTransport must be a function');
  }
  if (typeof emitMetric !== 'function') throw configurationError('emitMetric must be a function');

  const runtimeEnv = snapshotEnvironment(env);
  let handlerPromise;
  let initializedHandler;

  async function initialize() {
    const configuration = validateConfiguration(runtimeEnv);
    const signingPromise = loadPinnedSecretString({
      secretsManagerClient,
      GetSecretValueCommand,
      secretArn: configuration.signing.secretArn,
      versionId: configuration.signing.versionId,
      minBytes: 64,
    });
    const hmacPromise = configuration.registry
      ? loadPinnedSecretString({
        secretsManagerClient,
        GetSecretValueCommand,
        secretArn: configuration.registry.secretArn,
        versionId: configuration.registry.versionId,
        minBytes: 44,
        maxBytes: Math.ceil(GATEWAY_HMAC_SECRET_MAX_BYTES / 3) * 4,
      })
      : Promise.resolve(undefined);
    const apnsPromise = configuration.apnsEnabled
      ? loadPinnedSecretString({
        secretsManagerClient,
        GetSecretValueCommand,
        secretArn: configuration.apns.secretArn,
        versionId: configuration.apns.versionId,
        minBytes: 64,
      })
      : Promise.resolve(undefined);

    // Named promises prevent an optional Registry V1 read from shifting the APNs result into the HMAC slot.
    const [signingPem, hmacSecret, apnsPem] = await Promise.all([
      signingPromise,
      hmacPromise,
      apnsPromise,
    ]);
    const signingKey = parsePrivateKey(signingPem, 'ed25519');
    const hmacKey = configuration.registry ? canonicalHmacSecret(hmacSecret) : undefined;
    const privateKey = configuration.apnsEnabled ? parsePrivateKey(apnsPem, 'p256') : undefined;
    const dynamoClient = createDynamoAdapter(dynamoDocumentClient, dynamoCommands);
    let apns;
    try {
      if (configuration.apnsEnabled) {
        apns = createApnsTransport({
          teamId: configuration.apns.teamId,
          keyId: configuration.apns.keyId,
          privateKey,
          bundleId: configuration.apns.bundleId,
          environment: configuration.apns.environment,
          onResult(event) {
            emitMetric(apnsMetric(event));
          },
        });
        if (!apns || typeof apns.send !== 'function') {
          throw configurationError('createApnsTransport must return a send function');
        }
      }

      const composedEnv = Object.freeze({
        ...runtimeEnv,
        ...(configuration.registry ? { DEVICE_REGISTRY_HMAC_KEY_B64: hmacKey } : {}),
      });
      const handler = createGatewayHandler(composedEnv, {
        dynamoClient,
        signingKey,
        fetch,
        ...(apns ? { apnsSend: apns.send } : {}),
      });
      if (typeof handler !== 'function') {
        throw configurationError('createGatewayHandler must return a handler function');
      }
      return handler;
    } catch (error) {
      try { apns?.close?.(); } catch {}
      throw error;
    }
  }

  async function getHandler() {
    if (initializedHandler) return initializedHandler;
    if (!handlerPromise) {
      const pending = initialize();
      handlerPromise = pending;
      try {
        const handler = await pending;
        if (handlerPromise === pending) initializedHandler = handler;
        return handler;
      } catch (error) {
        if (handlerPromise === pending) handlerPromise = undefined;
        throw error;
      }
    }
    return handlerPromise;
  }

  return async function handler(event, lambdaContext) {
    try {
      const gateway = await getHandler();
      return await gateway(event, lambdaContext);
    } catch {
      emitMetric({ metric: initializedHandler ? 'gateway_runtime_failure' : 'gateway_bootstrap_failure' });
      return unavailableResponse();
    }
  };
}
