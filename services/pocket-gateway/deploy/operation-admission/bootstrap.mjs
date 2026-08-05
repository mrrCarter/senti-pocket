import { AsyncLocalStorage } from 'node:async_hooks';

import { createLambdaInvokeAdapter } from '../../src/lambda-invoke-adapter.mjs';
import { createOperationAdmissionApp } from '../../src/operation-admission-app.mjs';
import { createDynamoClientAdapter } from '../../src/store.mjs';

export const REGISTRY_HMAC_SECRET_MIN_BYTES = 32;
export const REGISTRY_HMAC_SECRET_MAX_BYTES = 1024;
export const OPERATION_ADMISSION_REQUEST_DEADLINE_MS = 24_000;
export const OPERATION_ADMISSION_RETURN_RESERVE_MS = 2_000;

const SECRET_ID_MAX_BYTES = 2048;
const SECRET_VERSION_ID_RE = /^[A-Za-z0-9-]{32,64}$/;
const CANONICAL_BASE64_RE = /^[A-Za-z0-9+/]+={0,2}$/;
const UNAVAILABLE_BODY = JSON.stringify({
  error: 'registration operation admission unavailable',
  reason: 'operation-admission-unavailable',
});

export class OperationAdmissionBootstrapError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'OperationAdmissionBootstrapError';
    this.code = code;
  }
}

function configurationError(message) {
  return new OperationAdmissionBootstrapError(
    'operation-admission-bootstrap-configuration-invalid',
    message,
  );
}

function secretUnavailable() {
  // Deliberately omit a cause. SDK failures and malformed secret responses must not retain secret material in an
  // application error that an outer Lambda error reporter could serialize.
  return new OperationAdmissionBootstrapError(
    'operation-admission-secret-unavailable',
    'operation admission secret unavailable',
  );
}

function canonicalSecretId(value) {
  if (
    typeof value !== 'string' ||
    value.length === 0 ||
    value.trim() !== value ||
    Buffer.byteLength(value, 'utf8') > SECRET_ID_MAX_BYTES
  ) {
    throw configurationError('DEVICE_REGISTRY_HMAC_SECRET_ARN must be a bounded canonical string');
  }
  return value;
}

function canonicalVersionId(value) {
  if (typeof value !== 'string' || !SECRET_VERSION_ID_RE.test(value)) {
    throw configurationError(
      'DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID must be a 32-64 character canonical version identifier',
    );
  }
  return value;
}

function validSecretLength(length) {
  return length >= REGISTRY_HMAC_SECRET_MIN_BYTES && length <= REGISTRY_HMAC_SECRET_MAX_BYTES;
}

function snapshotEnvironment(env) {
  // Retain only the public configuration this handler consumes. In particular, never pass the complete Lambda
  // environment (which can contain unrelated credentials) into application composition or keep it mutable across the
  // asynchronous cold-start secret read.
  return Object.freeze({
    DEVICE_REGISTRY_HMAC_SECRET_ARN: env?.DEVICE_REGISTRY_HMAC_SECRET_ARN,
    DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID: env?.DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID,
    GATEWAY_LAMBDA_VERSION_ARN: env?.GATEWAY_LAMBDA_VERSION_ARN,
    GATEWAY_LAMBDA_VERSION: env?.GATEWAY_LAMBDA_VERSION,
    OPERATION_ADMISSION_DDB_TABLE: env?.OPERATION_ADMISSION_DDB_TABLE,
    REGISTRY_OPERATION_ADMISSION_AUTH_MODE: env?.REGISTRY_OPERATION_ADMISSION_AUTH_MODE,
    SENTI_API_BASE_URL: env?.SENTI_API_BASE_URL,
  });
}

function readSecretString(value) {
  if (
    typeof value !== 'string' ||
    value.length === 0 ||
    value.length % 4 !== 0 ||
    !CANONICAL_BASE64_RE.test(value) ||
    Buffer.byteLength(value, 'utf8') > Math.ceil(REGISTRY_HMAC_SECRET_MAX_BYTES / 3) * 4
  ) {
    throw secretUnavailable();
  }

  const decoded = Buffer.from(value, 'base64');
  try {
    if (!validSecretLength(decoded.byteLength) || decoded.toString('base64') !== value) {
      throw secretUnavailable();
    }
  } finally {
    decoded.fill(0);
  }
  // Preserve the canonical base64 representation expected by Registry V2 instead of materializing a long-lived
  // second plaintext copy in application state.
  return value;
}

function positiveDeadlineMs(value) {
  if (!Number.isSafeInteger(value) || value <= 0 || value > OPERATION_ADMISSION_REQUEST_DEADLINE_MS) {
    throw configurationError(
      `requestDeadlineMs must be an integer from 1 through ${OPERATION_ADMISSION_REQUEST_DEADLINE_MS}`,
    );
  }
  return value;
}

function combineAbortSignals(first, second) {
  const signals = [first, second].filter(Boolean);
  if (signals.length === 0) return undefined;
  if (signals.length === 1) return signals[0];
  if (typeof AbortSignal.any === 'function') return AbortSignal.any(signals);

  const controller = new AbortController();
  const abort = (signal) => {
    if (!controller.signal.aborted) controller.abort(signal.reason);
  };
  for (const signal of signals) {
    if (signal.aborted) {
      abort(signal);
      break;
    }
    signal.addEventListener('abort', () => abort(signal), { once: true });
  }
  return controller.signal;
}

function createRequestDeadlineContext(deadlineMs) {
  const storage = new AsyncLocalStorage();

  function deadlineError() {
    return new OperationAdmissionBootstrapError(
      'operation-admission-request-deadline-exceeded',
      'operation admission request deadline exceeded',
    );
  }

  function currentSignal(existingSignal) {
    return combineAbortSignals(existingSignal, storage.getStore()?.signal);
  }

  function wrapSdkClient(client) {
    if (!client || typeof client.send !== 'function') return client;
    return Object.freeze({
      send(command, options = {}) {
        const abortSignal = currentSignal(options?.abortSignal);
        return client.send(command, abortSignal ? { ...options, abortSignal } : options);
      },
    });
  }

  function wrapFetch(fetch) {
    if (typeof fetch !== 'function') return fetch;
    return (url, init = {}) => {
      const signal = currentSignal(init?.signal);
      return fetch(url, signal ? { ...init, signal } : init);
    };
  }

  function workBudgetMs(lambdaContext) {
    let budget = deadlineMs;
    if (lambdaContext && typeof lambdaContext.getRemainingTimeInMillis === 'function') {
      try {
        const remaining = lambdaContext.getRemainingTimeInMillis();
        if (Number.isFinite(remaining)) {
          budget = Math.min(budget, Math.floor(remaining) - OPERATION_ADMISSION_RETURN_RESERVE_MS);
        }
      } catch {
        // An invalid adapter context cannot widen the fixed code-owned deadline.
      }
    }
    return budget;
  }

  async function run(work, lambdaContext) {
    const workMs = workBudgetMs(lambdaContext);
    if (workMs <= 0) throw deadlineError();

    const controller = new AbortController();
    let timeoutId;
    const timeout = new Promise((_, reject) => {
      timeoutId = setTimeout(() => {
        const error = deadlineError();
        controller.abort(error);
        reject(error);
      }, workMs);
    });

    try {
      return await storage.run(
        Object.freeze({ signal: controller.signal }),
        () => Promise.race([Promise.resolve().then(work), timeout]),
      );
    } finally {
      clearTimeout(timeoutId);
    }
  }

  return Object.freeze({ run, wrapFetch, wrapSdkClient });
}

/**
 * Resolve one immutable Registry HMAC key. No VersionStage fallback is permitted.
 */
export async function loadPinnedRegistryHmacSecret({
  env = process.env,
  secretsManagerClient,
  GetSecretValueCommand,
} = {}) {
  if (!secretsManagerClient || typeof secretsManagerClient.send !== 'function') {
    throw configurationError('Secrets Manager v3 client is required');
  }
  if (typeof GetSecretValueCommand !== 'function') {
    throw configurationError('GetSecretValueCommand is required');
  }

  const secretId = canonicalSecretId(env?.DEVICE_REGISTRY_HMAC_SECRET_ARN);
  const versionId = canonicalVersionId(env?.DEVICE_REGISTRY_HMAC_SECRET_VERSION_ID);

  let response;
  try {
    response = await secretsManagerClient.send(
      new GetSecretValueCommand({ SecretId: secretId, VersionId: versionId }),
    );
  } catch {
    throw secretUnavailable();
  }

  try {
    if (!response || typeof response !== 'object' || Array.isArray(response)) {
      throw secretUnavailable();
    }
    if (response.VersionId !== versionId) throw secretUnavailable();

    // The gateway and admission fleet share one strict representation: a canonical-base64 SecretString. Supporting
    // SecretBinary here but not in the gateway would allow the two owner/quota namespaces to diverge at cutover.
    if (!Object.hasOwn(response, 'SecretString') || Object.hasOwn(response, 'SecretBinary')) {
      throw secretUnavailable();
    }

    const hmacKey = readSecretString(response.SecretString);
    return { hmacKey, hmacKeyVersionId: versionId };
  } catch {
    throw secretUnavailable();
  }
}

/**
 * Create the Node Lambda handler. The returned closure is the cold-start singleton: concurrent first requests share
 * one pinned-secret read and one app composition. A failed initialization is not cached, allowing a later invocation
 * to recover from a transient Secrets Manager failure without ever falling back to a mutable secret stage. Bootstrap
 * and unexpected app failures are reduced to the same identifier-free 503 used by the admission proxy; API Gateway
 * must never reflect SDK/configuration details or substitute an ambiguous integration 502.
 */
export function createOperationAdmissionBootstrap({
  env = process.env,
  fetch = globalThis.fetch,
  secretsManagerClient,
  GetSecretValueCommand,
  dynamoDocumentClient,
  dynamoCommands,
  lambdaClient,
  InvokeCommand,
  requestDeadlineMs = OPERATION_ADMISSION_REQUEST_DEADLINE_MS,
  createApp = createOperationAdmissionApp,
  createDynamoAdapter = createDynamoClientAdapter,
  createGatewayInvoker = createLambdaInvokeAdapter,
} = {}) {
  if (typeof createApp !== 'function') throw configurationError('createApp must be a function');
  if (typeof createDynamoAdapter !== 'function') {
    throw configurationError('createDynamoAdapter must be a function');
  }
  if (typeof createGatewayInvoker !== 'function') {
    throw configurationError('createGatewayInvoker must be a function');
  }

  const deadline = createRequestDeadlineContext(positiveDeadlineMs(requestDeadlineMs));
  const runtimeEnv = snapshotEnvironment(env);
  const boundedFetch = deadline.wrapFetch(fetch);
  const boundedSecretsManagerClient = deadline.wrapSdkClient(secretsManagerClient);
  const boundedDynamoDocumentClient = deadline.wrapSdkClient(dynamoDocumentClient);
  const boundedLambdaClient = deadline.wrapSdkClient(lambdaClient);
  let appPromise;
  let initializedApp;

  async function initialize() {
    const { hmacKey, hmacKeyVersionId } = await loadPinnedRegistryHmacSecret({
      env: runtimeEnv,
      secretsManagerClient: boundedSecretsManagerClient,
      GetSecretValueCommand,
    });
    const dynamoClient = createDynamoAdapter(boundedDynamoDocumentClient, dynamoCommands);
    const invokeGateway = createGatewayInvoker({
      client: boundedLambdaClient,
      InvokeCommand,
      gatewayVersionArn: runtimeEnv.GATEWAY_LAMBDA_VERSION_ARN,
      expectedExecutedVersion: runtimeEnv.GATEWAY_LAMBDA_VERSION,
    });

    const app = createApp(runtimeEnv, {
      fetch: boundedFetch,
      dynamoClient,
      invokeGateway,
      hmacKey,
      hmacKeyVersionId,
    });
    if (typeof app !== 'function') throw configurationError('createApp must return a handler function');
    return app;
  }

  async function getApp() {
    if (initializedApp) return initializedApp;
    if (!appPromise) {
      const pending = initialize();
      appPromise = pending;
      try {
        const app = await pending;
        if (appPromise === pending) initializedApp = app;
        return app;
      } catch (error) {
        if (appPromise === pending) appPromise = undefined;
        throw error;
      }
    }
    return appPromise;
  }

  return async function handler(event, lambdaContext) {
    try {
      return await deadline.run(async () => {
        const app = await getApp();
        return app(event);
      }, lambdaContext);
    } catch (error) {
      // A deliberately uncooperative injected client can ignore AbortSignal and leave cold-start initialization
      // pending after the outer race returns. Never cache that promise: the next invocation must get a fresh exact-pin
      // attempt. Production AWS SDK clients honor the signal, so this is also a defense-in-depth recovery path.
      if (error?.code === 'operation-admission-request-deadline-exceeded' && !initializedApp) {
        appPromise = undefined;
      }
      return {
        statusCode: 503,
        headers: { 'content-type': 'application/json' },
        body: UNAVAILABLE_BODY,
        isBase64Encoded: false,
      };
    }
  };
}
