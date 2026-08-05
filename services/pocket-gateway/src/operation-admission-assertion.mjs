// Short-lived, request-bound proof that the public operation-admission Lambda already authenticated a reusable Senti
// session. The private gateway accepts this proof only for the two frozen Registry V2 write routes, preventing a second
// /auth/me call without turning the shared Registry HMAC root into a general-purpose bearer-token minting key.

import { createHash, createHmac, randomBytes as secureRandomBytes, timingSafeEqual } from 'node:crypto';
import { TextDecoder } from 'node:util';

import { assertDeviceRegistryOwnerIdentity } from './device-registry-v2.mjs';
import {
  deriveRegistryOperationAdmissionIdentity,
  isRegistryOperationAdmissionRoute,
} from './operation-admission.mjs';

export const OPERATION_ADMISSION_ASSERTION_SCHEMA = 'senti-pocket-operation-admission-assertion-v1';
export const OPERATION_ADMISSION_ASSERTION_EVENT_FIELD = '__sentiOperationAdmissionAssertion';
export const OPERATION_ADMISSION_ASSERTION_LIFETIME_SECONDS = 10;
export const OPERATION_ADMISSION_ASSERTION_MAX_FUTURE_SECONDS = 2;
export const OPERATION_ADMISSION_ASSERTION_MAX_BODY_BYTES = 4 * 1024;
export const OPERATION_ADMISSION_ASSERTION_MAX_BYTES = 8 * 1024;
export const OPERATION_ADMISSION_ASSERTION_JTI_BYTES = 32;

const KDF_DOMAIN = 'senti-pocket-operation-admission-assertion-subkey-v1';
const ASSERTION_FIELDS = Object.freeze([
  'schema',
  'kid',
  'secretArn',
  'aud',
  'method',
  'path',
  'authorizationSha256',
  'decodedBodySha256',
  'principal',
  'humanId',
  'scopes',
  'ownerHandle',
  'operationDigest',
  'jti',
  'iat',
  'exp',
  'mac',
]);
const MAC_FIELDS = Object.freeze(ASSERTION_FIELDS.filter((field) => field !== 'mac'));
const BASE64_RE = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;
const DIGEST_RE = /^[A-Za-z0-9_-]{43}$/;
const HEADER_NAME_RE = /^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/;
const KID_RE = /^[A-Za-z0-9-]{32,64}$/;
const LAMBDA_VERSION_ARN_RE = /^arn:(?:aws|aws-cn|aws-us-gov):lambda:[a-z0-9-]+:[0-9]{12}:function:[A-Za-z0-9_-]{1,64}:[1-9][0-9]*$/;
const SECRET_ARN_RE = /^arn:(?:aws|aws-cn|aws-us-gov):secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:[A-Za-z0-9/_+=.@-]{1,512}$/;
const SCOPE_RE = /^[A-Za-z0-9][A-Za-z0-9:._-]{0,127}$/;
const UTF8 = new TextDecoder('utf-8', { fatal: true });
const MAX_ROOT_KEY_BYTES = 1024;
const MAX_AUTHORIZATION_BYTES = 16 * 1024;
const MAX_AUDIENCE_BYTES = 2048;
const MAX_SCOPES = 32;
const SNAPSHOT_STATE = new WeakMap();
const ASSERTION_CONTEXTS = new WeakSet();
const ASSERTION_REQUESTS = new WeakMap();

export class OperationAdmissionAssertionError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'OperationAdmissionAssertionError';
    this.code = code;
  }
}

function invalid() {
  return new OperationAdmissionAssertionError(
    'operation-admission-assertion-invalid',
    'operation admission assertion is invalid',
  );
}

function invalidBody() {
  return new OperationAdmissionAssertionError(
    'operation-admission-assertion-body-invalid',
    'operation admission request body is invalid',
  );
}

function bodyTooLarge() {
  return new OperationAdmissionAssertionError(
    'operation-admission-assertion-body-too-large',
    'operation admission request body is too large',
  );
}

function configurationError(message) {
  return new OperationAdmissionAssertionError(
    'operation-admission-assertion-configuration-invalid',
    message,
  );
}

function isPlainObject(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function ownDataValue(object, name) {
  const descriptor = Object.getOwnPropertyDescriptor(object, name);
  if (!descriptor || !Object.hasOwn(descriptor, 'value') || descriptor.enumerable !== true) throw invalid();
  return descriptor.value;
}

function validUtf8String(value, { minBytes = 0, maxBytes = Number.MAX_SAFE_INTEGER } = {}) {
  if (typeof value !== 'string') return false;
  const bytes = Buffer.from(value, 'utf8');
  if (bytes.length < minBytes || bytes.length > maxBytes) return false;
  try {
    return UTF8.decode(bytes) === value;
  } catch {
    return false;
  }
}

function canonicalDigest(value) {
  if (typeof value !== 'string' || !DIGEST_RE.test(value)) return null;
  const decoded = Buffer.from(value, 'base64url');
  return decoded.length === 32 && decoded.toString('base64url') === value ? decoded : null;
}

function digestEqual(left, right) {
  const leftBytes = canonicalDigest(left);
  const rightBytes = canonicalDigest(right);
  return Boolean(leftBytes && rightBytes && timingSafeEqual(leftBytes, rightBytes));
}

function canonicalRootSecret(value) {
  if (
    typeof value !== 'string' ||
    value.length === 0 ||
    value.length % 4 !== 0 ||
    !BASE64_RE.test(value) ||
    Buffer.byteLength(value, 'utf8') > Math.ceil(MAX_ROOT_KEY_BYTES / 3) * 4
  ) {
    throw configurationError('operation admission assertion root secret must be canonical base64');
  }
  const decoded = Buffer.from(value, 'base64');
  if (decoded.length < 32 || decoded.length > MAX_ROOT_KEY_BYTES || decoded.toString('base64') !== value) {
    decoded.fill(0);
    throw configurationError('operation admission assertion root secret must decode to 32-1024 bytes');
  }
  return decoded;
}

function canonicalKid(value) {
  if (typeof value !== 'string' || !KID_RE.test(value)) {
    throw configurationError('operation admission assertion kid must be a canonical 32-64 character version id');
  }
  return value;
}

function canonicalSecretArn(value) {
  if (
    !validUtf8String(value, { minBytes: 1, maxBytes: MAX_AUDIENCE_BYTES }) ||
    !SECRET_ARN_RE.test(value)
  ) {
    throw configurationError('operation admission assertion secretArn must be a canonical Secrets Manager ARN');
  }
  return value;
}

function canonicalAudience(value) {
  if (
    !validUtf8String(value, { minBytes: 1, maxBytes: MAX_AUDIENCE_BYTES }) ||
    value.trim() !== value ||
    /[\u0000-\u001f\u007f-\u009f]/.test(value) ||
    !LAMBDA_VERSION_ARN_RE.test(value)
  ) {
    throw configurationError('operation admission assertion audience must be an immutable numeric Lambda version ARN');
  }
  return value;
}

function boundedBodyLimit(value) {
  const resolved = value ?? OPERATION_ADMISSION_ASSERTION_MAX_BODY_BYTES;
  if (
    !Number.isSafeInteger(resolved) ||
    resolved <= 0 ||
    resolved > OPERATION_ADMISSION_ASSERTION_MAX_BODY_BYTES
  ) {
    throw configurationError(
      `operation admission assertion maxBodyBytes must be an integer from 1 through ${OPERATION_ADMISSION_ASSERTION_MAX_BODY_BYTES}`,
    );
  }
  return resolved;
}

function epochSeconds(now) {
  let epochMs;
  try {
    epochMs = now();
  } catch {
    throw invalid();
  }
  if (!Number.isFinite(epochMs) || !Number.isSafeInteger(epochMs) || epochMs < 0) throw invalid();
  const seconds = Math.floor(epochMs / 1000);
  if (!Number.isSafeInteger(seconds) || seconds <= 0) throw invalid();
  return seconds;
}

function sha256(value) {
  return createHash('sha256').update(value).digest('base64url');
}

function canonicalScopes(value, { requireCanonical = false } = {}) {
  if (!Array.isArray(value) || value.length > MAX_SCOPES) throw invalid();
  const expectedKeys = new Set(['length', ...Array.from({ length: value.length }, (_, index) => String(index))]);
  const keys = Reflect.ownKeys(value);
  if (keys.length !== expectedKeys.size || keys.some((key) => typeof key !== 'string' || !expectedKeys.has(key))) {
    throw invalid();
  }

  const scopes = [];
  for (let index = 0; index < value.length; index += 1) {
    const descriptor = Object.getOwnPropertyDescriptor(value, String(index));
    if (!descriptor || !Object.hasOwn(descriptor, 'value') || descriptor.enumerable !== true) throw invalid();
    const scope = descriptor.value;
    if (typeof scope !== 'string' || !SCOPE_RE.test(scope)) throw invalid();
    scopes.push(scope);
  }
  if (new Set(scopes).size !== scopes.length) throw invalid();
  const canonical = [...scopes].sort();
  if (requireCanonical && canonical.some((scope, index) => scope !== scopes[index])) throw invalid();
  return Object.freeze(canonical);
}

/**
 * Snapshot verifier-owned scopes before admission yields to shared storage. This prevents a mutable verifier result (or
 * an accessor-backed array) from changing the authority that is signed after the admission CAS commits.
 */
export function snapshotOperationAdmissionScopes(value) {
  return canonicalScopes(value);
}

function randomJti(randomBytes) {
  let value;
  try {
    value = randomBytes(OPERATION_ADMISSION_ASSERTION_JTI_BYTES);
  } catch {
    throw invalid();
  }
  if (!Buffer.isBuffer(value) && !ArrayBuffer.isView(value)) throw invalid();
  const bytes = Buffer.from(value.buffer, value.byteOffset, value.byteLength);
  if (bytes.length !== OPERATION_ADMISSION_ASSERTION_JTI_BYTES) throw invalid();
  return Buffer.from(bytes).toString('base64url');
}

function lengthPrefixed(parts) {
  const chunks = [];
  for (const part of parts) {
    const bytes = Buffer.from(String(part), 'utf8');
    if (bytes.length > 0xffff_ffff) throw invalid();
    const length = Buffer.allocUnsafe(4);
    length.writeUInt32BE(bytes.length, 0);
    chunks.push(length, bytes);
  }
  return Buffer.concat(chunks);
}

function deriveSubkey(rootKey, kid, secretArn, audience) {
  return createHmac('sha256', rootKey)
    .update(lengthPrefixed([KDF_DOMAIN, kid, secretArn, audience]))
    .digest();
}

function computeMac(subkey, value) {
  return createHmac('sha256', subkey)
    .update(lengthPrefixed(MAC_FIELDS.map((field) =>
      field === 'scopes' ? JSON.stringify(value[field]) : value[field])))
    .digest('base64url');
}

function freezeParsedJson(root) {
  const pending = [root];
  const objects = [];
  while (pending.length > 0) {
    const value = pending.pop();
    if (typeof value === 'string') {
      if (!validUtf8String(value)) throw invalid();
      continue;
    }
    if (value === null || typeof value === 'boolean' || typeof value === 'number') continue;
    if (!value || typeof value !== 'object' || (!Array.isArray(value) && !isPlainObject(value))) throw invalid();
    objects.push(value);
    for (const key of Reflect.ownKeys(value)) {
      if (typeof key !== 'string') throw invalid();
      if (!validUtf8String(key)) throw invalid();
      const descriptor = Object.getOwnPropertyDescriptor(value, key);
      if (!descriptor || !Object.hasOwn(descriptor, 'value') || descriptor.enumerable !== true) throw invalid();
      pending.push(descriptor.value);
    }
  }
  for (let index = objects.length - 1; index >= 0; index -= 1) Object.freeze(objects[index]);
  return root;
}

function decodeBody(rawBody, isBase64Encoded, maxBodyBytes) {
  if (typeof rawBody !== 'string' || typeof isBase64Encoded !== 'boolean') throw invalidBody();
  let bytes;
  if (isBase64Encoded) {
    const maxEncodedCharacters = Math.ceil(maxBodyBytes / 3) * 4;
    if (rawBody.length > maxEncodedCharacters) throw bodyTooLarge();
    if (!BASE64_RE.test(rawBody)) throw invalidBody();
    bytes = Buffer.from(rawBody, 'base64');
    if (bytes.length > maxBodyBytes) throw bodyTooLarge();
    if (bytes.toString('base64') !== rawBody) throw invalidBody();
  } else {
    bytes = Buffer.from(rawBody, 'utf8');
    if (bytes.length > maxBodyBytes) throw bodyTooLarge();
    try {
      if (UTF8.decode(bytes) !== rawBody) throw invalidBody();
    } catch {
      throw invalidBody();
    }
  }

  let text;
  try {
    text = UTF8.decode(bytes);
  } catch {
    throw invalidBody();
  }
  let parsedBody;
  try {
    parsedBody = freezeParsedJson(JSON.parse(text));
  } catch {
    throw invalidBody();
  }
  return { bytes, parsedBody };
}

function readAuthorization(headers, { allowMissing = false } = {}) {
  if (!isPlainObject(headers)) throw invalid();
  let authorization;
  let count = 0;
  for (const key of Reflect.ownKeys(headers)) {
    if (typeof key !== 'string' || !HEADER_NAME_RE.test(key)) throw invalid();
    const descriptor = Object.getOwnPropertyDescriptor(headers, key);
    if (!descriptor || !Object.hasOwn(descriptor, 'value') || descriptor.enumerable !== true) throw invalid();
    if (typeof descriptor.value !== 'string') throw invalid();
    if (key.toLowerCase() === 'authorization') {
      count += 1;
      authorization = descriptor.value;
    }
  }
  if (allowMissing && count === 0) return null;
  if (
    count !== 1 ||
    !validUtf8String(authorization, { minBytes: 1, maxBytes: MAX_AUTHORIZATION_BYTES })
  ) {
    throw invalid();
  }
  return authorization;
}

function createSnapshot(event, maxBodyBytes, assertionMode) {
  if (!isPlainObject(event)) throw invalid();
  const hasAssertion = Object.hasOwn(event, OPERATION_ADMISSION_ASSERTION_EVENT_FIELD);
  if (assertionMode === 'absent' ? hasAssertion : !hasAssertion) throw invalid();
  if (Object.hasOwn(event, 'multiValueHeaders') || Object.hasOwn(event, 'httpMethod') || Object.hasOwn(event, 'path')) {
    throw invalid();
  }

  if (ownDataValue(event, 'version') !== '2.0') throw invalid();
  const rawPath = ownDataValue(event, 'rawPath');
  const requestContext = ownDataValue(event, 'requestContext');
  if (!isPlainObject(requestContext)) throw invalid();
  const http = ownDataValue(requestContext, 'http');
  if (!isPlainObject(http)) throw invalid();
  const method = ownDataValue(http, 'method');
  const path = ownDataValue(http, 'path');
  if (
    typeof rawPath !== 'string' ||
    rawPath !== path ||
    !isRegistryOperationAdmissionRoute(method, path)
  ) {
    throw invalid();
  }

  const headers = ownDataValue(event, 'headers');
  const authorization = readAuthorization(headers, { allowMissing: assertionMode === 'absent' });
  const authorizationBytes = Buffer.from(authorization ?? '', 'utf8');
  const hasBody = Object.hasOwn(event, 'body');
  const hasEncoding = Object.hasOwn(event, 'isBase64Encoded');
  let isBase64Encoded = hasEncoding ? ownDataValue(event, 'isBase64Encoded') : false;
  let decoded;
  if (assertionMode === 'absent' && (!hasBody || ownDataValue(event, 'body') == null)) {
    if (isBase64Encoded !== false) throw invalidBody();
    decoded = { bytes: Buffer.alloc(0), parsedBody: Object.freeze({}) };
    isBase64Encoded = false;
  } else {
    if (!hasBody || !hasEncoding) throw invalidBody();
    decoded = decodeBody(ownDataValue(event, 'body'), isBase64Encoded, maxBodyBytes);
  }
  const state = {
    authorizationBytes,
    decodedBodyBytes: decoded.bytes,
    hasAuthorization: authorization !== null,
  };
  const snapshot = {
    method,
    path,
    authorization: authorization ?? '',
    hasAuthorization: authorization !== null,
    authorizationSha256: sha256(authorizationBytes),
    decodedBodySha256: sha256(decoded.bytes),
    parsedBody: decoded.parsedBody,
    bodyEncoding: isBase64Encoded ? 'base64' : 'utf8',
    isBase64Encoded,
    bodyByteLength: decoded.bytes.length,
    get authorizationBytes() {
      return Buffer.from(state.authorizationBytes);
    },
    get decodedBodyBytes() {
      return Buffer.from(state.decodedBodyBytes);
    },
  };
  Object.freeze(snapshot);
  SNAPSHOT_STATE.set(snapshot, state);

  return {
    snapshot,
    assertion: hasAssertion ? ownDataValue(event, OPERATION_ADMISSION_ASSERTION_EVENT_FIELD) : undefined,
  };
}

/**
 * Capture the exact untrusted API Gateway v2 request before any asynchronous authentication or admission work.
 * Byte getters return defensive copies; all signer-authoritative state is retained privately and cannot be mutated.
 */
export function snapshotOperationAdmissionRawRequest(event, { maxBodyBytes } = {}) {
  return createSnapshot(event, boundedBodyLimit(maxBodyBytes), 'absent').snapshot;
}

function assertionShape(value) {
  if (!isPlainObject(value)) throw invalid();
  const keys = Reflect.ownKeys(value);
  if (
    keys.length !== ASSERTION_FIELDS.length ||
    keys.some((key) => typeof key !== 'string' || !ASSERTION_FIELDS.includes(key))
  ) {
    throw invalid();
  }
  const out = {};
  for (const field of ASSERTION_FIELDS) out[field] = ownDataValue(value, field);

  if (
    out.schema !== OPERATION_ADMISSION_ASSERTION_SCHEMA ||
    typeof out.kid !== 'string' ||
    typeof out.secretArn !== 'string' ||
    typeof out.aud !== 'string' ||
    out.method !== 'POST' ||
    !isRegistryOperationAdmissionRoute(out.method, out.path) ||
    !canonicalDigest(out.authorizationSha256) ||
    !canonicalDigest(out.decodedBodySha256) ||
    !validUtf8String(out.principal, { minBytes: 1, maxBytes: 1024 }) ||
    !validUtf8String(out.humanId, { minBytes: 1, maxBytes: 1024 }) ||
    !canonicalDigest(out.ownerHandle) ||
    !canonicalDigest(out.operationDigest) ||
    !canonicalDigest(out.jti) ||
    !Number.isSafeInteger(out.iat) ||
    out.iat <= 0 ||
    !Number.isSafeInteger(out.exp) ||
    out.exp <= 0 ||
    !canonicalDigest(out.mac)
  ) {
    throw invalid();
  }
  if (!SECRET_ARN_RE.test(out.secretArn)) throw invalid();
  out.scopes = canonicalScopes(out.scopes, { requireCanonical: true });
  try {
    assertDeviceRegistryOwnerIdentity(out.principal, out.humanId);
  } catch {
    throw invalid();
  }
  let serialized;
  try {
    serialized = JSON.stringify(out);
  } catch {
    throw invalid();
  }
  if (Buffer.byteLength(serialized, 'utf8') > OPERATION_ADMISSION_ASSERTION_MAX_BYTES) throw invalid();
  return out;
}

function deriveAndMatch(snapshot, { principal, humanId, ownerHandle, operationDigest }, hmacKey) {
  try {
    assertDeviceRegistryOwnerIdentity(principal, humanId);
  } catch {
    throw invalid();
  }
  if (!canonicalDigest(ownerHandle) || !canonicalDigest(operationDigest)) throw invalid();

  let derived;
  try {
    derived = deriveRegistryOperationAdmissionIdentity({
      method: snapshot.method,
      path: snapshot.path,
      body: snapshot.parsedBody,
      principal,
      humanId,
      hmacKey,
    });
  } catch {
    throw invalid();
  }
  const derivedOwnerHandle = typeof derived?.ledgerKey === 'string'
    ? derived.ledgerKey.slice('dial:admission:v1:'.length)
    : null;
  if (
    derived?.protected !== true ||
    derived.ok !== true ||
    derived.ownerMatches !== true ||
    !digestEqual(ownerHandle, derivedOwnerHandle) ||
    !digestEqual(ownerHandle, snapshot.parsedBody?.ownerHandle) ||
    !digestEqual(operationDigest, derived.operationDigest)
  ) {
    throw invalid();
  }
  return { ownerHandle: derivedOwnerHandle, operationDigest: derived.operationDigest };
}

function resolveCryptoConfiguration({ hmacKey, kid, secretArn, audience, now = () => Date.now(), maxBodyBytes } = {}) {
  if (typeof now !== 'function') throw configurationError('operation admission assertion now must be a function');
  const canonicalVersionId = canonicalKid(kid);
  const canonicalSecret = canonicalSecretArn(secretArn);
  const canonicalAud = canonicalAudience(audience);
  const rootKey = canonicalRootSecret(hmacKey);
  let subkey;
  try {
    subkey = deriveSubkey(rootKey, canonicalVersionId, canonicalSecret, canonicalAud);
  } finally {
    rootKey.fill(0);
  }
  return Object.freeze({
    hmacKey,
    kid: canonicalVersionId,
    secretArn: canonicalSecret,
    audience: canonicalAud,
    now,
    maxBodyBytes: boundedBodyLimit(maxBodyBytes),
    subkey,
  });
}

/** Create the admission-side signer. It accepts only a genuine immutable raw-request snapshot. */
export function createOperationAdmissionAssertionSigner(options = {}) {
  const configuration = resolveCryptoConfiguration(options);
  const randomBytes = options?.randomBytes ?? secureRandomBytes;
  if (typeof randomBytes !== 'function') {
    throw configurationError('operation admission assertion randomBytes must be a function');
  }

  return Object.freeze({
    sign({ snapshot, principal, humanId, scopes, ownerHandle, operationDigest } = {}) {
      if (!SNAPSHOT_STATE.has(snapshot) || SNAPSHOT_STATE.get(snapshot).hasAuthorization !== true) throw invalid();
      const matched = deriveAndMatch(snapshot, { principal, humanId, ownerHandle, operationDigest }, configuration.hmacKey);
      const canonicalGrantedScopes = snapshotOperationAdmissionScopes(scopes);
      const iat = epochSeconds(configuration.now);
      const unsigned = {
        schema: OPERATION_ADMISSION_ASSERTION_SCHEMA,
        kid: configuration.kid,
        secretArn: configuration.secretArn,
        aud: configuration.audience,
        method: snapshot.method,
        path: snapshot.path,
        authorizationSha256: snapshot.authorizationSha256,
        decodedBodySha256: snapshot.decodedBodySha256,
        principal,
        humanId,
        scopes: canonicalGrantedScopes,
        ownerHandle: matched.ownerHandle,
        operationDigest: matched.operationDigest,
        jti: randomJti(randomBytes),
        iat,
        exp: iat + OPERATION_ADMISSION_ASSERTION_LIFETIME_SECONDS,
      };
      const assertion = Object.freeze({
        ...unsigned,
        mac: computeMac(configuration.subkey, unsigned),
      });
      if (Buffer.byteLength(JSON.stringify(assertion), 'utf8') > OPERATION_ADMISSION_ASSERTION_MAX_BYTES) throw invalid();
      return assertion;
    },
  });
}

/**
 * Create the private-gateway verifier. Verification re-snapshots the raw event, authenticates every bound field, then
 * re-runs the frozen Registry V2 validator and operation derivation before returning a privately branded identity.
 */
export function createOperationAdmissionAssertionVerifier(options = {}) {
  const configuration = resolveCryptoConfiguration(options);
  let replaySeen;
  try {
    if (!options?.replayGuard || typeof options.replayGuard.seen !== 'function') throw new Error('invalid replay guard');
    replaySeen = options.replayGuard.seen.bind(options.replayGuard);
  } catch {
    throw configurationError('operation admission assertion replayGuard.seen must be a function');
  }

  return Object.freeze({
    verify(event) {
      const captured = createSnapshot(event, configuration.maxBodyBytes, 'present');
      const assertion = assertionShape(captured.assertion);
      if (
        assertion.kid !== configuration.kid ||
        assertion.secretArn !== configuration.secretArn ||
        assertion.aud !== configuration.audience
      ) throw invalid();

      const expectedMac = computeMac(configuration.subkey, assertion);
      if (!digestEqual(assertion.mac, expectedMac)) throw invalid();
      if (
        assertion.method !== captured.snapshot.method ||
        assertion.path !== captured.snapshot.path ||
        !digestEqual(assertion.authorizationSha256, captured.snapshot.authorizationSha256) ||
        !digestEqual(assertion.decodedBodySha256, captured.snapshot.decodedBodySha256)
      ) {
        throw invalid();
      }

      const nowEpochSec = epochSeconds(configuration.now);
      if (
        assertion.exp !== assertion.iat + OPERATION_ADMISSION_ASSERTION_LIFETIME_SECONDS ||
        assertion.iat > nowEpochSec + OPERATION_ADMISSION_ASSERTION_MAX_FUTURE_SECONDS ||
        nowEpochSec >= assertion.exp
      ) {
        throw invalid();
      }

      deriveAndMatch(captured.snapshot, assertion, configuration.hmacKey);

      // Offline proof checks deliberately precede the shared write: malformed or forged input cannot consume replay
      // capacity. The store operation itself is one atomic put-if-absent with a top-level TTL at the signed expiry.
      return (async () => {
        let replayed;
        try {
          replayed = await replaySeen(assertion.jti, assertion.exp);
        } catch {
          throw invalid();
        }
        if (replayed !== false) throw invalid();
        // The atomic write is asynchronous. Never brand a context if storage latency carried the capability past its
        // exclusive expiry, or if the process clock moved backwards across this authorization boundary.
        const afterReplayEpochSec = epochSeconds(configuration.now);
        if (afterReplayEpochSec < nowEpochSec || afterReplayEpochSec >= assertion.exp) throw invalid();
        const verifiedRequest = Object.freeze({
          method: captured.snapshot.method,
          path: captured.snapshot.path,
          authorization: captured.snapshot.authorization,
          body: UTF8.decode(captured.snapshot.decodedBodyBytes),
        });
        const context = Object.freeze({
          humanId: assertion.humanId,
          principal: assertion.principal,
          scopes: assertion.scopes,
          site: null,
          tokenClaims: Object.freeze({
            authMethod: 'senti_session',
            via: 'operation_admission_assertion',
            exp: assertion.exp,
          }),
        });
        ASSERTION_CONTEXTS.add(context);
        ASSERTION_REQUESTS.set(context, verifiedRequest);
        return context;
      })();
    },
  });
}

/** A structural lookalike or clone cannot acquire the private verifier brand. */
export function isOperationAdmissionAssertionContext(value) {
  return Boolean(value && typeof value === 'object' && ASSERTION_CONTEXTS.has(value));
}

/** Retrieve the exact verified request bytes without exposing them as forgeable properties on the branded identity. */
export function getOperationAdmissionAssertionRequest(value) {
  if (!isOperationAdmissionAssertionContext(value) || !ASSERTION_REQUESTS.has(value)) throw invalid();
  return ASSERTION_REQUESTS.get(value);
}
