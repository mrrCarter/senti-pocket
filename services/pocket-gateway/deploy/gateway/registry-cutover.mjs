import { createHash, timingSafeEqual } from 'node:crypto';

export const REGISTRY_V1_PREFIXES = Object.freeze([
  'dial:dev:',
  'dial:v1:dev:',
]);

export const REGISTRY_V2_PREFIXES = Object.freeze([
  'dial:install:v2:',
  'dial:token:v2:',
  'dial:target:v2:',
  'dial:regop:v2:',
]);

export const REGISTRY_ALL_PREFIXES = Object.freeze([
  ...REGISTRY_V1_PREFIXES,
  ...REGISTRY_V2_PREFIXES,
]);

export const REGISTRY_CUTOVER_PLAN_MAX_AGE_MS = 5 * 60 * 1_000;
export const REGISTRY_CUTOVER_MAX_SCAN_PAGES = 10_000;
export const REGISTRY_CUTOVER_MAX_SCAN_ITEMS = 1_000_000;
export const REGISTRY_CUTOVER_MAX_V1_DELETES = 100_000;
export const REGISTRY_CUTOVER_MAX_PK_BYTES = 2_048;
export const REGISTRY_CUTOVER_MAX_SK_BYTES = 1_024;

export const REGISTRY_CUTOVER_PLAN_SCHEMA = 'senti.pocket.registry-cutover-plan.v1';
export const REGISTRY_CUTOVER_APPLY_SCHEMA = 'senti.pocket.registry-cutover-apply.v1';
export const REGISTRY_CUTOVER_DIGEST_SEMANTICS = 'tamper-evident-checksum';

const LOWERCASE_SHA256_RE = /^[a-f0-9]{64}$/;
const ACCOUNT_ID_RE = /^[0-9]{12}$/;
const REGION_RE = /^[a-z0-9-]{3,32}$/;
const TABLE_NAME_RE = /^[A-Za-z0-9_.-]{3,255}$/;
const TABLE_ARN_RE = /^arn:(aws|aws-cn|aws-us-gov|aws-iso|aws-iso-b|aws-iso-e|aws-iso-f|aws-eusc):dynamodb:([^:]+):([0-9]{12}):table\/([A-Za-z0-9_.-]{3,255})$/;
const REQUEST_ID_MAX_LENGTH = 1_024;
const START_CURSOR = Object.freeze({ position: 'start' });
const END_CURSOR = Object.freeze({ position: 'end' });

const own = (value, key) => Object.prototype.hasOwnProperty.call(value, key);

export class RegistryCutoverError extends Error {
  constructor(code, message, details = {}) {
    super(message);
    this.name = 'RegistryCutoverError';
    this.code = code;
    this.details = deepFreeze(structuredClone(details));
  }
}

function fail(code, message, details) {
  throw new RegistryCutoverError(code, message, details);
}

function isPlainObject(value) {
  if (value === null || typeof value !== 'object') return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function requirePlainObject(value, code, label) {
  if (!isPlainObject(value)) {
    fail(code, `${label} must be a plain object`);
  }
  return value;
}

function requireExactKeys(value, required, optional, code, label) {
  requirePlainObject(value, code, label);
  const allowed = new Set([...required, ...optional]);
  const keys = Object.keys(value);
  if (keys.some((key) => !allowed.has(key)) || required.some((key) => !own(value, key))) {
    fail(code, `${label} has an invalid shape`);
  }
}

function deepFreeze(value) {
  if (value && typeof value === 'object' && !Object.isFrozen(value)) {
    Object.freeze(value);
    for (const child of Object.values(value)) deepFreeze(child);
  }
  return value;
}

function canonicalJson(value) {
  const seen = new Set();

  const encode = (current) => {
    if (current === null) return 'null';
    if (typeof current === 'string' || typeof current === 'boolean') return JSON.stringify(current);
    if (typeof current === 'number') {
      if (!Number.isFinite(current)) fail('invalid-canonical-value', 'Canonical evidence contains a non-finite number');
      return Object.is(current, -0) ? '0' : JSON.stringify(current);
    }
    if (Array.isArray(current)) {
      if (seen.has(current)) fail('invalid-canonical-value', 'Canonical evidence contains a cycle');
      seen.add(current);
      const encoded = `[${current.map(encode).join(',')}]`;
      seen.delete(current);
      return encoded;
    }
    if (!isPlainObject(current)) {
      fail('invalid-canonical-value', 'Canonical evidence contains an unsupported value');
    }
    if (seen.has(current)) fail('invalid-canonical-value', 'Canonical evidence contains a cycle');
    seen.add(current);
    const keys = Object.keys(current).sort();
    const encoded = `{${keys.map((key) => {
      const child = current[key];
      if (child === undefined || typeof child === 'function' || typeof child === 'symbol' || typeof child === 'bigint') {
        fail('invalid-canonical-value', 'Canonical evidence contains an unsupported value');
      }
      return `${JSON.stringify(key)}:${encode(child)}`;
    }).join(',')}}`;
    seen.delete(current);
    return encoded;
  };

  return encode(value);
}

function sha256(domain, value) {
  const serialized = typeof value === 'string' ? value : canonicalJson(value);
  return createHash('sha256').update(domain).update('\0').update(serialized).digest('hex');
}

function digestsEqual(left, right) {
  if (!LOWERCASE_SHA256_RE.test(left) || !LOWERCASE_SHA256_RE.test(right)) return false;
  return timingSafeEqual(Buffer.from(left, 'hex'), Buffer.from(right, 'hex'));
}

function withDigest(body, domain) {
  return deepFreeze({
    ...body,
    digest: sha256(domain, body),
  });
}

function requireDigest(value, code, label) {
  if (typeof value !== 'string' || !LOWERCASE_SHA256_RE.test(value)) {
    fail(code, `${label} must be a lowercase SHA-256 digest`);
  }
  return value;
}

function requireRequestId(value, code, label) {
  if (
    typeof value !== 'string' ||
    value.length === 0 ||
    value.length > REQUEST_ID_MAX_LENGTH ||
    /[\u0000-\u001f\u007f]/u.test(value)
  ) {
    fail(code, `${label} did not return a valid request identifier`);
  }
  return value;
}

function parseTableArn(tableArn, code) {
  const match = typeof tableArn === 'string' ? TABLE_ARN_RE.exec(tableArn) : null;
  if (!match) fail(code, 'The table ARN is invalid');
  return Object.freeze({
    partition: match[1],
    region: match[2],
    accountId: match[3],
    tableName: match[4],
  });
}

function validateBinding(binding) {
  requireExactKeys(binding, ['accountId', 'region', 'tableName', 'tableArn'], [], 'invalid-binding', 'binding');
  if (!ACCOUNT_ID_RE.test(binding.accountId)) fail('invalid-binding', 'The account binding is invalid');
  if (!REGION_RE.test(binding.region)) fail('invalid-binding', 'The region binding is invalid');
  if (!TABLE_NAME_RE.test(binding.tableName)) fail('invalid-binding', 'The table-name binding is invalid');

  const arn = parseTableArn(binding.tableArn, 'invalid-binding');
  if (
    arn.accountId !== binding.accountId ||
    arn.region !== binding.region ||
    arn.tableName !== binding.tableName
  ) {
    fail('binding-mismatch', 'The account, region, table name, and table ARN binding is not exact');
  }

  return Object.freeze({
    accountId: binding.accountId,
    region: binding.region,
    tableName: binding.tableName,
    tableArn: binding.tableArn,
    partition: arn.partition,
  });
}

function sanitizeBinding(binding) {
  const evidence = {
    partition: binding.partition,
    region: binding.region,
    accountIdDigest: sha256('registry-cutover/account-id', binding.accountId),
    tableNameDigest: sha256('registry-cutover/table-name', binding.tableName),
    tableArnDigest: sha256('registry-cutover/table-arn', binding.tableArn),
  };
  return deepFreeze({
    ...evidence,
    bindingDigest: sha256('registry-cutover/binding', evidence),
  });
}

function normalizeCreationDateTime(value) {
  let epochMs;
  if (value instanceof Date) {
    epochMs = value.getTime();
  } else if (typeof value === 'number') {
    epochMs = value;
  } else if (typeof value === 'string') {
    epochMs = Date.parse(value);
    if (Number.isFinite(epochMs) && new Date(epochMs).toISOString() !== value) {
      fail('invalid-table-description', 'The table creation time is not canonical UTC');
    }
  }
  if (!Number.isSafeInteger(epochMs) || epochMs < 0) {
    fail('invalid-table-description', 'The table creation time is invalid');
  }
  return new Date(epochMs).toISOString();
}

function validateKeySchema(keySchema, attributeDefinitions) {
  if (!Array.isArray(keySchema) || keySchema.length !== 2) {
    fail('invalid-table-schema', 'The table must have exactly the pk HASH and sk RANGE keys');
  }
  for (const entry of keySchema) {
    requireExactKeys(entry, ['attributeName', 'keyType'], [], 'invalid-table-schema', 'key schema entry');
  }
  const keyMap = new Map(keySchema.map((entry) => [entry.attributeName, entry.keyType]));
  if (keyMap.size !== 2 || keyMap.get('pk') !== 'HASH' || keyMap.get('sk') !== 'RANGE') {
    fail('invalid-table-schema', 'The table must have exactly the pk HASH and sk RANGE keys');
  }

  if (!Array.isArray(attributeDefinitions) || attributeDefinitions.length !== 2) {
    fail('invalid-table-schema', 'The table keys must both be strings');
  }
  for (const entry of attributeDefinitions) {
    requireExactKeys(
      entry,
      ['attributeName', 'attributeType'],
      [],
      'invalid-table-schema',
      'attribute definition',
    );
  }
  const attributeMap = new Map(attributeDefinitions.map((entry) => [entry.attributeName, entry.attributeType]));
  if (attributeMap.size !== 2 || attributeMap.get('pk') !== 'S' || attributeMap.get('sk') !== 'S') {
    fail('invalid-table-schema', 'The table keys must both be strings');
  }
}

function validateDescribeResult(result, binding) {
  requireExactKeys(
    result,
    [
      'tableName',
      'tableArn',
      'tableId',
      'creationDateTime',
      'tableStatus',
      'keySchema',
      'attributeDefinitions',
      'replicas',
      'requestId',
    ],
    [],
    'invalid-table-description',
    'table description',
  );
  const requestId = requireRequestId(result.requestId, 'invalid-table-description', 'describeTable');
  if (result.tableName !== binding.tableName || result.tableArn !== binding.tableArn) {
    fail('binding-mismatch', 'The described table does not match the exact binding');
  }
  const describedArn = parseTableArn(result.tableArn, 'invalid-table-description');
  if (
    describedArn.accountId !== binding.accountId ||
    describedArn.region !== binding.region ||
    describedArn.tableName !== binding.tableName
  ) {
    fail('binding-mismatch', 'The described table does not match the exact account and region binding');
  }
  if (result.tableStatus !== 'ACTIVE') {
    fail('table-not-active', 'The bound table must be ACTIVE');
  }
  if (typeof result.tableId !== 'string' || result.tableId.length === 0 || result.tableId.length > 256) {
    fail('invalid-table-description', 'The table incarnation identifier is invalid');
  }
  if (!Array.isArray(result.replicas)) {
    fail('invalid-table-description', 'The table replica description is invalid');
  }
  if (result.replicas.length !== 0) {
    fail('global-table-not-supported', 'Registry cutover refuses a globally replicated table');
  }
  validateKeySchema(result.keySchema, result.attributeDefinitions);

  const creationDateTime = normalizeCreationDateTime(result.creationDateTime);
  const identity = {
    tableArn: result.tableArn,
    tableId: result.tableId,
    creationDateTime,
    keySchema: [
      { attributeName: 'pk', keyType: 'HASH', attributeType: 'S' },
      { attributeName: 'sk', keyType: 'RANGE', attributeType: 'S' },
    ],
    globalReplicaCount: 0,
  };
  return deepFreeze({
    status: 'ACTIVE',
    schema: 'pk:S:HASH+sk:S:RANGE',
    globalReplicaCount: 0,
    identityDigest: sha256('registry-cutover/table-incarnation', identity),
    tableIdDigest: sha256('registry-cutover/table-id', result.tableId),
    creationTimeDigest: sha256('registry-cutover/table-creation-time', creationDateTime),
    describeRequestDigest: sha256('registry-cutover/describe-request-id', requestId),
  });
}

function sameTableIncarnation(left, right) {
  return left.status === right.status &&
    left.schema === right.schema &&
    left.globalReplicaCount === right.globalReplicaCount &&
    digestsEqual(left.identityDigest, right.identityDigest) &&
    digestsEqual(left.tableIdDigest, right.tableIdDigest) &&
    digestsEqual(left.creationTimeDigest, right.creationTimeDigest);
}

function emptyPrefixCounts() {
  return Object.fromEntries(REGISTRY_ALL_PREFIXES.map((prefix) => [prefix, 0]));
}

function groupPrefixCounts(counts) {
  return deepFreeze({
    v1: Object.fromEntries(REGISTRY_V1_PREFIXES.map((prefix) => [prefix, counts[prefix]])),
    v2: Object.fromEntries(REGISTRY_V2_PREFIXES.map((prefix) => [prefix, counts[prefix]])),
  });
}

function validateGroupedPrefixCounts(prefixes) {
  requireExactKeys(prefixes, ['v1', 'v2'], [], 'invalid-plan', 'plan prefixes');
  requireExactKeys(prefixes.v1, REGISTRY_V1_PREFIXES, [], 'invalid-plan', 'plan V1 prefixes');
  requireExactKeys(prefixes.v2, REGISTRY_V2_PREFIXES, [], 'invalid-plan', 'plan V2 prefixes');
  const counts = {};
  for (const prefix of REGISTRY_ALL_PREFIXES) {
    const section = REGISTRY_V1_PREFIXES.includes(prefix) ? prefixes.v1 : prefixes.v2;
    if (!Number.isSafeInteger(section[prefix]) || section[prefix] < 0) {
      fail('invalid-plan', 'Plan prefix counts must be non-negative safe integers');
    }
    counts[prefix] = section[prefix];
  }
  return counts;
}

function totalForPrefixes(counts, prefixes) {
  return prefixes.reduce((total, prefix) => total + counts[prefix], 0);
}

function allPrefixesZero(counts) {
  return REGISTRY_ALL_PREFIXES.every((prefix) => counts[prefix] === 0);
}

function classifyPrefix(pk) {
  return REGISTRY_ALL_PREFIXES.find((prefix) => pk.startsWith(prefix));
}

function validateKey(value, code, label) {
  requireExactKeys(value, ['pk', 'sk'], [], code, label);
  if (typeof value.pk !== 'string' || value.pk.length === 0 || typeof value.sk !== 'string' || value.sk.length === 0) {
    fail(code, `${label} must contain non-empty string pk and sk values`);
  }
  if (
    Buffer.byteLength(value.pk, 'utf8') > REGISTRY_CUTOVER_MAX_PK_BYTES ||
    Buffer.byteLength(value.sk, 'utf8') > REGISTRY_CUTOVER_MAX_SK_BYTES
  ) {
    fail(code, `${label} exceeds the DynamoDB key byte limit`);
  }
  return Object.freeze({ pk: value.pk, sk: value.sk });
}

function validateScanResult(result) {
  requireExactKeys(
    result,
    ['items', 'requestId'],
    ['lastEvaluatedKey'],
    'invalid-scan-page',
    'scan page',
  );
  if (!Array.isArray(result.items)) fail('invalid-scan-page', 'Scan page items must be an array');
  const requestId = requireRequestId(result.requestId, 'invalid-scan-page', 'scanPage');
  const items = result.items.map((item) => validateKey(item, 'invalid-scan-item', 'scan item'));
  const lastEvaluatedKey = own(result, 'lastEvaluatedKey')
    ? validateKey(result.lastEvaluatedKey, 'invalid-scan-cursor', 'scan cursor')
    : undefined;
  return { items, lastEvaluatedKey, requestId };
}

function readNow(now) {
  let value;
  try {
    value = now();
  } catch {
    fail('invalid-clock', 'The cutover clock failed');
  }
  if (!Number.isSafeInteger(value) || value < 0) {
    fail('invalid-clock', 'The cutover clock must return non-negative epoch milliseconds');
  }
  return value;
}

function createDeadlineGuard(now, plannedAtMs, deletedCount) {
  const deadlineMs = plannedAtMs + REGISTRY_CUTOVER_PLAN_MAX_AGE_MS;
  let previous = plannedAtMs;
  return (stage) => {
    const current = readNow(now);
    if (current < previous) {
      fail('clock-regressed', 'The cutover clock regressed', { stage, deletedItems: deletedCount() });
    }
    previous = current;
    if (current >= deadlineMs) {
      fail('plan-expired', 'The cutover plan exceeded its fixed five-minute deadline', {
        stage,
        deletedItems: deletedCount(),
      });
    }
    return current;
  };
}

async function callDescribeTable(describeTable, binding, checkDeadline, stage) {
  checkDeadline?.(`${stage}:before-describe`);
  let result;
  try {
    result = await describeTable({ tableName: binding.tableName, region: binding.region });
  } catch {
    fail('describe-table-failed', 'The exact table description request failed', { stage });
  }
  checkDeadline?.(`${stage}:after-describe`);
  return validateDescribeResult(result, binding);
}

async function scanSnapshot(scanPage, binding, { checkDeadline, stage }) {
  const counts = emptyPrefixCounts();
  const requestEvidence = [];
  const matchedItems = [];
  const seenKeys = new Set();
  const seenOutputCursors = new Set();
  let cursor;
  let scannedItems = 0;

  for (let page = 0; ; page += 1) {
    if (page >= REGISTRY_CUTOVER_MAX_SCAN_PAGES) {
      fail('scan-cap-exceeded', 'The full-table scan exceeded its fixed page cap', { stage, pages: page });
    }
    checkDeadline?.(`${stage}:page-${page}:before-scan`);
    const input = {
      tableName: binding.tableName,
      region: binding.region,
      consistentRead: true,
      baseTableOnly: true,
      projection: Object.freeze(['pk', 'sk']),
      ...(cursor ? { exclusiveStartKey: cursor } : {}),
    };
    let rawPage;
    try {
      rawPage = await scanPage(input);
    } catch {
      fail('scan-page-failed', 'A strongly consistent base-table scan page failed', { stage, page });
    }
    checkDeadline?.(`${stage}:page-${page}:after-scan`);
    const current = validateScanResult(rawPage);

    scannedItems += current.items.length;
    if (scannedItems > REGISTRY_CUTOVER_MAX_SCAN_ITEMS) {
      fail('scan-cap-exceeded', 'The full-table scan exceeded its fixed item cap', { stage, page });
    }

    const pageKeyCanonicals = [];
    for (const key of current.items) {
      const keyCanonical = canonicalJson(key);
      const keyDigest = sha256('registry-cutover/item-key', keyCanonical);
      if (seenKeys.has(keyCanonical)) {
        fail('scan-key-duplicate', 'The full-table scan returned a duplicate key', { stage, page });
      }
      seenKeys.add(keyCanonical);
      pageKeyCanonicals.push(keyCanonical);
      const prefix = classifyPrefix(key.pk);
      if (prefix) {
        counts[prefix] += 1;
        matchedItems.push(Object.freeze({ key, keyCanonical, keyDigest, prefix }));
      }
    }

    let outputCursorDigest = sha256('registry-cutover/scan-cursor', END_CURSOR);
    if (current.lastEvaluatedKey) {
      const cursorCanonical = canonicalJson(current.lastEvaluatedKey);
      if (pageKeyCanonicals.at(-1) !== cursorCanonical) {
        fail('invalid-scan-cursor', 'The scan cursor was not the final evaluated item in its unfiltered page', {
          stage,
          page,
        });
      }
      outputCursorDigest = sha256('registry-cutover/scan-cursor', cursorCanonical);
      if (seenOutputCursors.has(outputCursorDigest)) {
        fail('scan-cursor-cycle', 'The full-table scan cursor repeated', { stage, page });
      }
      seenOutputCursors.add(outputCursorDigest);
    }

    requestEvidence.push(deepFreeze({
      page,
      itemCount: current.items.length,
      inputCursorDigest: sha256(
        'registry-cutover/scan-cursor',
        cursor ? canonicalJson(cursor) : START_CURSOR,
      ),
      outputCursorDigest,
      requestDigest: sha256('registry-cutover/scan-request-id', current.requestId),
    }));

    if (!current.lastEvaluatedKey) break;
    cursor = current.lastEvaluatedKey;
  }

  matchedItems.sort((left, right) => (
    left.keyCanonical < right.keyCanonical ? -1 : left.keyCanonical > right.keyCanonical ? 1 : 0
  ));
  const inventory = matchedItems.map(({ prefix, keyDigest }) => ({ prefix, keyDigest }));
  const evidence = deepFreeze({
    complete: true,
    baseTableOnly: true,
    consistentRead: true,
    projection: Object.freeze(['pk', 'sk']),
    pages: requestEvidence.length,
    scannedItems,
    matchedItems: matchedItems.length,
    inventoryDigest: sha256('registry-cutover/prefix-inventory', inventory),
    requestChainDigest: sha256('registry-cutover/scan-request-chain', requestEvidence),
    requests: requestEvidence,
  });

  return { counts, matchedItems, evidence };
}

function comparePrefixSnapshots(planCounts, planInventoryDigest, current) {
  return REGISTRY_ALL_PREFIXES.every((prefix) => planCounts[prefix] === current.counts[prefix]) &&
    digestsEqual(planInventoryDigest, current.evidence.inventoryDigest);
}

function validatePlan(plan, expectedPlanDigest, sanitizedBinding) {
  requireExactKeys(
    plan,
    [
      'schema',
      'phase',
      'digestSemantics',
      'plannedAt',
      'expiresAt',
      'binding',
      'table',
      'prefixes',
      'scan',
      'applyEligible',
      'digest',
    ],
    [],
    'invalid-plan',
    'plan',
  );
  if (
    plan.schema !== REGISTRY_CUTOVER_PLAN_SCHEMA ||
    plan.phase !== 'plan' ||
    plan.digestSemantics !== REGISTRY_CUTOVER_DIGEST_SEMANTICS
  ) {
    fail('invalid-plan', 'The cutover plan schema is invalid');
  }
  requireDigest(plan.digest, 'invalid-plan', 'plan digest');
  requireDigest(expectedPlanDigest, 'invalid-plan-digest', 'expected plan digest');
  if (!digestsEqual(plan.digest, expectedPlanDigest)) {
    fail('plan-digest-mismatch', 'The explicit plan digest does not match the supplied plan');
  }
  const { digest, ...body } = plan;
  if (!digestsEqual(digest, sha256('registry-cutover/plan', body))) {
    fail('plan-digest-mismatch', 'The plan tamper-evident checksum is invalid');
  }

  const plannedAtMs = Date.parse(plan.plannedAt);
  const expiresAtMs = Date.parse(plan.expiresAt);
  if (
    !Number.isSafeInteger(plannedAtMs) ||
    !Number.isSafeInteger(expiresAtMs) ||
    new Date(plannedAtMs).toISOString() !== plan.plannedAt ||
    new Date(expiresAtMs).toISOString() !== plan.expiresAt ||
    expiresAtMs - plannedAtMs !== REGISTRY_CUTOVER_PLAN_MAX_AGE_MS
  ) {
    fail('invalid-plan', 'The plan has an invalid fixed validity window');
  }

  if (!isPlainObject(plan.binding) || canonicalJson(plan.binding) !== canonicalJson(sanitizedBinding)) {
    fail('binding-mismatch', 'The plan does not bind the exact supplied account, region, ARN, and table');
  }
  requireExactKeys(
    plan.table,
    [
      'status',
      'schema',
      'globalReplicaCount',
      'identityDigest',
      'tableIdDigest',
      'creationTimeDigest',
      'describeRequestDigests',
    ],
    [],
    'invalid-plan',
    'plan table evidence',
  );
  for (const field of ['identityDigest', 'tableIdDigest', 'creationTimeDigest']) {
    requireDigest(plan.table[field], 'invalid-plan', `plan table ${field}`);
  }
  if (
    plan.table.status !== 'ACTIVE' ||
    plan.table.schema !== 'pk:S:HASH+sk:S:RANGE' ||
    plan.table.globalReplicaCount !== 0 ||
    !Array.isArray(plan.table.describeRequestDigests) ||
    plan.table.describeRequestDigests.length !== 2
  ) {
    fail('invalid-plan', 'The plan table evidence is invalid');
  }
  for (const digestValue of plan.table.describeRequestDigests) {
    requireDigest(digestValue, 'invalid-plan', 'plan describe request digest');
  }

  const counts = validateGroupedPrefixCounts(plan.prefixes);
  requireExactKeys(
    plan.scan,
    [
      'complete',
      'baseTableOnly',
      'consistentRead',
      'projection',
      'pages',
      'scannedItems',
      'matchedItems',
      'inventoryDigest',
      'requestChainDigest',
      'requests',
    ],
    [],
    'invalid-plan',
    'plan scan evidence',
  );
  requireDigest(plan.scan.inventoryDigest, 'invalid-plan', 'plan inventory digest');
  requireDigest(plan.scan.requestChainDigest, 'invalid-plan', 'plan scan request-chain digest');
  if (
    plan.scan.complete !== true ||
    plan.scan.baseTableOnly !== true ||
    plan.scan.consistentRead !== true ||
    canonicalJson(plan.scan.projection) !== canonicalJson(['pk', 'sk']) ||
    !Number.isSafeInteger(plan.scan.pages) || plan.scan.pages < 1 ||
    plan.scan.pages > REGISTRY_CUTOVER_MAX_SCAN_PAGES ||
    !Number.isSafeInteger(plan.scan.scannedItems) || plan.scan.scannedItems < 0 ||
    plan.scan.scannedItems > REGISTRY_CUTOVER_MAX_SCAN_ITEMS ||
    !Number.isSafeInteger(plan.scan.matchedItems) || plan.scan.matchedItems < 0 ||
    !Array.isArray(plan.scan.requests) || plan.scan.requests.length !== plan.scan.pages
  ) {
    fail('invalid-plan', 'The plan scan evidence is invalid');
  }
  let summedItems = 0;
  const startCursorDigest = sha256('registry-cutover/scan-cursor', START_CURSOR);
  const endCursorDigest = sha256('registry-cutover/scan-cursor', END_CURSOR);
  for (let index = 0; index < plan.scan.requests.length; index += 1) {
    const request = plan.scan.requests[index];
    requireExactKeys(
      request,
      ['page', 'itemCount', 'inputCursorDigest', 'outputCursorDigest', 'requestDigest'],
      [],
      'invalid-plan',
      'plan scan request evidence',
    );
    if (
      request.page !== index ||
      !Number.isSafeInteger(request.itemCount) || request.itemCount < 0 ||
      (index < plan.scan.requests.length - 1 && request.itemCount === 0)
    ) {
      fail('invalid-plan', 'The plan scan request evidence is invalid');
    }
    for (const field of ['inputCursorDigest', 'outputCursorDigest', 'requestDigest']) {
      requireDigest(request[field], 'invalid-plan', `plan scan request ${field}`);
    }
    if (
      (index === 0 && !digestsEqual(request.inputCursorDigest, startCursorDigest)) ||
      (index > 0 && !digestsEqual(
        request.inputCursorDigest,
        plan.scan.requests[index - 1].outputCursorDigest,
      )) ||
      (index === plan.scan.requests.length - 1 && !digestsEqual(request.outputCursorDigest, endCursorDigest))
    ) {
      fail('invalid-plan', 'The plan scan cursor evidence is not a complete chain');
    }
    summedItems += request.itemCount;
    if (!Number.isSafeInteger(summedItems) || summedItems > REGISTRY_CUTOVER_MAX_SCAN_ITEMS) {
      fail('invalid-plan', 'The plan scan item total exceeds the fixed cap');
    }
  }
  if (
    summedItems !== plan.scan.scannedItems ||
    plan.scan.matchedItems !== totalForPrefixes(counts, REGISTRY_ALL_PREFIXES) ||
    plan.scan.matchedItems > plan.scan.scannedItems ||
    !digestsEqual(
      plan.scan.requestChainDigest,
      sha256('registry-cutover/scan-request-chain', plan.scan.requests),
    )
  ) {
    fail('invalid-plan', 'The plan scan totals or request-chain checksum are inconsistent');
  }

  const v1Items = totalForPrefixes(counts, REGISTRY_V1_PREFIXES);
  const v2Items = totalForPrefixes(counts, REGISTRY_V2_PREFIXES);
  const eligible = v2Items === 0 && v1Items <= REGISTRY_CUTOVER_MAX_V1_DELETES;
  if (plan.applyEligible !== eligible) {
    fail('invalid-plan', 'The plan eligibility value is inconsistent with its counts');
  }

  return { plannedAtMs, expiresAtMs, counts, v1Items, v2Items };
}

function publicTableEvidence(description, requestDigests) {
  return deepFreeze({
    status: description.status,
    schema: description.schema,
    globalReplicaCount: description.globalReplicaCount,
    identityDigest: description.identityDigest,
    tableIdDigest: description.tableIdDigest,
    creationTimeDigest: description.creationTimeDigest,
    describeRequestDigests: Object.freeze([...requestDigests]),
  });
}

function assertSameTable(expected, actual, stage) {
  if (!sameTableIncarnation(expected, actual)) {
    fail('table-incarnation-drift', 'The bound table incarnation changed during cutover', { stage });
  }
}

export function createRegistryCutover({ describeTable, scanPage, deleteItem, now = Date.now } = {}) {
  if (typeof describeTable !== 'function' || typeof scanPage !== 'function' || typeof deleteItem !== 'function') {
    throw new TypeError('createRegistryCutover requires describeTable, scanPage, and deleteItem callbacks');
  }
  if (typeof now !== 'function') throw new TypeError('createRegistryCutover now must be a function');

  return Object.freeze({
    async plan({ binding } = {}) {
      const exactBinding = validateBinding(binding);
      const sanitizedBinding = sanitizeBinding(exactBinding);
      const firstDescription = await callDescribeTable(describeTable, exactBinding, undefined, 'plan-initial');
      const snapshot = await scanSnapshot(scanPage, exactBinding, { stage: 'plan-scan' });
      const finalDescription = await callDescribeTable(describeTable, exactBinding, undefined, 'plan-final');
      assertSameTable(firstDescription, finalDescription, 'plan-final');

      const plannedAtMs = readNow(now);
      const counts = groupPrefixCounts(snapshot.counts);
      const v1Items = totalForPrefixes(snapshot.counts, REGISTRY_V1_PREFIXES);
      const v2Items = totalForPrefixes(snapshot.counts, REGISTRY_V2_PREFIXES);
      const body = {
        schema: REGISTRY_CUTOVER_PLAN_SCHEMA,
        phase: 'plan',
        digestSemantics: REGISTRY_CUTOVER_DIGEST_SEMANTICS,
        plannedAt: new Date(plannedAtMs).toISOString(),
        expiresAt: new Date(plannedAtMs + REGISTRY_CUTOVER_PLAN_MAX_AGE_MS).toISOString(),
        binding: sanitizedBinding,
        table: publicTableEvidence(firstDescription, [
          firstDescription.describeRequestDigest,
          finalDescription.describeRequestDigest,
        ]),
        prefixes: counts,
        scan: snapshot.evidence,
        applyEligible: v2Items === 0 && v1Items <= REGISTRY_CUTOVER_MAX_V1_DELETES,
      };
      return withDigest(body, 'registry-cutover/plan');
    },

    async apply({
      binding,
      plan,
      expectedPlanDigest,
      allowMutations,
      trafficQuiesced,
      writerFenceEvidenceDigest,
      drainEvidenceDigest,
    } = {}) {
      if (allowMutations !== true) {
        fail('mutation-opt-in-required', 'Registry V1 purge requires explicit mutation opt-in');
      }
      if (trafficQuiesced !== true) {
        fail('traffic-quiescence-required', 'Registry V1 purge requires an explicit traffic-quiescence assertion');
      }
      requireDigest(
        writerFenceEvidenceDigest,
        'writer-fence-evidence-required',
        'writer-fence evidence digest',
      );
      requireDigest(drainEvidenceDigest, 'drain-evidence-required', 'drain evidence digest');
      if (digestsEqual(writerFenceEvidenceDigest, drainEvidenceDigest)) {
        fail(
          'cutover-evidence-not-distinct',
          'Writer-fence and drain evidence must be two distinct retained artifacts',
        );
      }

      const exactBinding = validateBinding(binding);
      const sanitizedBinding = sanitizeBinding(exactBinding);
      const verifiedPlan = validatePlan(plan, expectedPlanDigest, sanitizedBinding);
      if (verifiedPlan.v2Items !== 0) {
        fail('v2-prefix-not-empty', 'Registry V2 prefixes must be empty before any V1 deletion', {
          prefixes: plan.prefixes.v2,
        });
      }
      if (verifiedPlan.v1Items > REGISTRY_CUTOVER_MAX_V1_DELETES) {
        fail('delete-cap-exceeded', 'The V1 inventory exceeds the fixed deletion cap', {
          items: verifiedPlan.v1Items,
        });
      }

      let deletedItems = 0;
      const checkDeadline = createDeadlineGuard(now, verifiedPlan.plannedAtMs, () => deletedItems);
      checkDeadline('apply:start');

      const tableChecks = [];
      const preflightDescription = await callDescribeTable(
        describeTable,
        exactBinding,
        checkDeadline,
        'apply-preflight',
      );
      assertSameTable(plan.table, preflightDescription, 'apply-preflight');
      tableChecks.push(preflightDescription.describeRequestDigest);

      const preflight = await scanSnapshot(scanPage, exactBinding, {
        checkDeadline,
        stage: 'apply-preflight-scan',
      });
      if (!comparePrefixSnapshots(verifiedPlan.counts, plan.scan.inventoryDigest, preflight)) {
        fail('plan-drift', 'The six-prefix inventory changed after the plan', {
          planned: plan.prefixes,
          current: groupPrefixCounts(preflight.counts),
        });
      }
      if (totalForPrefixes(preflight.counts, REGISTRY_V2_PREFIXES) !== 0) {
        fail('v2-prefix-not-empty', 'Registry V2 prefixes became non-empty before deletion', {
          prefixes: groupPrefixCounts(preflight.counts).v2,
        });
      }

      const v1Items = preflight.matchedItems.filter(({ prefix }) => REGISTRY_V1_PREFIXES.includes(prefix));
      const deleteRequestEvidence = [];
      for (let index = 0; index < v1Items.length; index += 1) {
        const item = v1Items[index];
        if (!REGISTRY_V1_PREFIXES.includes(item.prefix) || !item.key.pk.startsWith(item.prefix)) {
          fail('delete-scope-violation', 'The delete set escaped the two fixed V1 prefixes', {
            deletedItems,
          });
        }
        checkDeadline(`delete-${index}:before`);
        let result;
        try {
          result = await deleteItem({
            tableName: exactBinding.tableName,
            region: exactBinding.region,
            key: item.key,
            prefix: item.prefix,
          });
        } catch {
          fail('delete-failed', 'A V1 delete request failed; no zero proof was issued', {
            attemptedItems: index + 1,
            deletedItems,
            totalItems: v1Items.length,
          });
        }
        deletedItems += 1;
        requireExactKeys(result, ['requestId'], [], 'invalid-delete-response', 'delete response');
        const requestId = requireRequestId(result.requestId, 'invalid-delete-response', 'deleteItem');
        deleteRequestEvidence.push(deepFreeze({
          index,
          prefix: item.prefix,
          requestDigest: sha256('registry-cutover/delete-request-id', requestId),
        }));
        checkDeadline(`delete-${index}:after`);
      }

      const verificationDescription = await callDescribeTable(
        describeTable,
        exactBinding,
        checkDeadline,
        'apply-verification',
      );
      assertSameTable(plan.table, verificationDescription, 'apply-verification');
      tableChecks.push(verificationDescription.describeRequestDigest);
      const verification = await scanSnapshot(scanPage, exactBinding, {
        checkDeadline,
        stage: 'apply-verification-scan',
      });
      if (!allPrefixesZero(verification.counts)) {
        fail('verification-not-zero', 'The first final scan found registry rows; no zero proof was issued', {
          prefixes: groupPrefixCounts(verification.counts),
          deletedItems,
        });
      }

      const confirmationDescription = await callDescribeTable(
        describeTable,
        exactBinding,
        checkDeadline,
        'apply-confirmation',
      );
      assertSameTable(plan.table, confirmationDescription, 'apply-confirmation');
      tableChecks.push(confirmationDescription.describeRequestDigest);
      const confirmation = await scanSnapshot(scanPage, exactBinding, {
        checkDeadline,
        stage: 'apply-confirmation-scan',
      });
      if (!allPrefixesZero(confirmation.counts)) {
        fail('race-detected', 'The confirmation scan found a registry writer race; no zero proof was issued', {
          prefixes: groupPrefixCounts(confirmation.counts),
          deletedItems,
        });
      }

      const finalDescription = await callDescribeTable(
        describeTable,
        exactBinding,
        checkDeadline,
        'apply-final',
      );
      assertSameTable(plan.table, finalDescription, 'apply-final');
      tableChecks.push(finalDescription.describeRequestDigest);
      const completedAtMs = checkDeadline('apply:complete');
      const zeroCounts = groupPrefixCounts(confirmation.counts);
      const body = {
        schema: REGISTRY_CUTOVER_APPLY_SCHEMA,
        phase: 'apply',
        digestSemantics: REGISTRY_CUTOVER_DIGEST_SEMANTICS,
        completedAt: new Date(completedAtMs).toISOString(),
        planDigest: plan.digest,
        binding: sanitizedBinding,
        table: publicTableEvidence(finalDescription, tableChecks),
        assertions: deepFreeze({
          mutationOptIn: true,
          trafficQuiesced: true,
          writerFenceEvidenceDigest,
          drainEvidenceDigest,
          safetyBoundary: 'external-writer-fence-and-drain',
        }),
        preflight: deepFreeze({
          prefixes: groupPrefixCounts(preflight.counts),
          scan: preflight.evidence,
        }),
        deleted: deepFreeze({
          prefixes: Object.fromEntries(REGISTRY_V1_PREFIXES.map((prefix) => [
            prefix,
            preflight.counts[prefix],
          ])),
          items: deletedItems,
          requestChainDigest: sha256('registry-cutover/delete-request-chain', deleteRequestEvidence),
          requests: deleteRequestEvidence,
        }),
        verification: deepFreeze({
          prefixes: groupPrefixCounts(verification.counts),
          scan: verification.evidence,
        }),
        confirmation: deepFreeze({
          prefixes: zeroCounts,
          scan: confirmation.evidence,
        }),
        zeroProof: deepFreeze({
          allSixPrefixesZero: allPrefixesZero(confirmation.counts),
          prefixes: zeroCounts,
          writerFenceEvidenceDigest,
          drainEvidenceDigest,
          safetyBoundary: 'external-writer-fence-and-drain',
        }),
      };
      return withDigest(body, 'registry-cutover/apply');
    },
  });
}
