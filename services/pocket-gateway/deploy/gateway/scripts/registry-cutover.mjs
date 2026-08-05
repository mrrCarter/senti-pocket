#!/usr/bin/env node

import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

import { DescribeTableCommand, DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DeleteCommand, DynamoDBDocumentClient, ScanCommand } from '@aws-sdk/lib-dynamodb';
import { NodeHttpHandler } from '@smithy/node-http-handler';

import { createRegistryCutover } from '../registry-cutover.mjs';
import { GATEWAY_AWS_TRANSPORT_OPTIONS } from '../aws-clients.mjs';

// Ten thousand sanitized page-evidence entries remain bounded but can exceed a tiny config-file limit.
const MAX_PLAN_FILE_BYTES = 8 * 1024 * 1024;
const MAX_PLAN_PATH_LENGTH = 2_048;
const SHA256_RE = /^[0-9a-f]{64}$/;
const TABLE_NAME_RE = /^[A-Za-z0-9_.-]{3,255}$/;
const REGION_RE = /^[a-z0-9-]{3,32}$/;
const ACCOUNT_ID_RE = /^\d{12}$/;
const TABLE_ARN_RE = /^arn:(aws(?:-us-gov|-cn|-iso(?:-[bef])?)?):dynamodb:([a-z0-9-]{3,32}):(\d{12}):table\/([A-Za-z0-9_.-]{3,255})$/;
const V1_DELETE_PREFIXES = Object.freeze(['dial:dev:', 'dial:v1:dev:']);

export const REGISTRY_CUTOVER_USAGE = `Usage:
  npm --silent run registry:plan -- --table-name NAME --table-arn ARN --account-id 123456789012 --region REGION
  npm --silent run registry:apply -- --table-name NAME --table-arn ARN --account-id 123456789012 --region REGION \\
    --plan-file FILE --plan-digest SHA256 --writer-fence-evidence-digest SHA256 \\
    --drain-evidence-digest SHA256 --allow-v1-purge --traffic-quiesced

The plan command is read-only and writes sanitized JSON to stdout. Apply accepts only a recent, exact plan digest,
requires both explicit safety acknowledgements, deletes only fixed Registry V1 prefixes, and never changes deployment
or readiness configuration.`;

export class RegistryCutoverCliError extends Error {
  constructor(code) {
    super(code);
    this.name = 'RegistryCutoverCliError';
    this.code = code;
  }
}

function fail(code) {
  throw new RegistryCutoverCliError(code);
}

function requiredString(value, code, maxLength) {
  if (typeof value !== 'string' || value.length === 0 || value.length > maxLength || value.includes('\0')) fail(code);
  return value;
}

function parseTableBinding(values) {
  const tableName = requiredString(values.get('--table-name'), 'INVALID_TABLE_NAME', 255);
  const tableArn = requiredString(values.get('--table-arn'), 'INVALID_TABLE_ARN', 1_024);
  const accountId = requiredString(values.get('--account-id'), 'INVALID_ACCOUNT_ID', 12);
  const region = requiredString(values.get('--region'), 'INVALID_REGION', 32);

  if (!TABLE_NAME_RE.test(tableName)) fail('INVALID_TABLE_NAME');
  if (!ACCOUNT_ID_RE.test(accountId)) fail('INVALID_ACCOUNT_ID');
  if (!REGION_RE.test(region)) fail('INVALID_REGION');

  const arn = TABLE_ARN_RE.exec(tableArn);
  if (!arn || arn[2] !== region || arn[3] !== accountId || arn[4] !== tableName) fail('TABLE_BINDING_MISMATCH');

  return Object.freeze({ accountId, region, tableName, tableArn });
}

export function parseRegistryCutoverArguments(argv) {
  if (!Array.isArray(argv)) fail('INVALID_ARGUMENTS');
  if (argv.includes('--help') || argv.includes('-h')) return Object.freeze({ command: 'help' });

  const command = argv[0];
  if (command !== 'plan' && command !== 'apply') fail('INVALID_COMMAND');

  const booleanFlags = new Set(['--allow-v1-purge', '--traffic-quiesced']);
  const valueFlags = new Set([
    '--table-name',
    '--table-arn',
    '--account-id',
    '--region',
    '--plan-file',
    '--plan-digest',
    '--writer-fence-evidence-digest',
    '--drain-evidence-digest',
  ]);
  const values = new Map();
  const booleans = new Set();

  for (let index = 1; index < argv.length; index += 1) {
    const flag = argv[index];
    if (booleanFlags.has(flag)) {
      if (booleans.has(flag)) fail('DUPLICATE_ARGUMENT');
      booleans.add(flag);
      continue;
    }
    if (!valueFlags.has(flag)) fail('UNKNOWN_ARGUMENT');
    if (values.has(flag)) fail('DUPLICATE_ARGUMENT');
    const value = argv[index + 1];
    if (typeof value !== 'string' || value.length === 0 || value.startsWith('--')) fail('MISSING_ARGUMENT_VALUE');
    values.set(flag, value);
    index += 1;
  }

  const binding = parseTableBinding(values);
  if (command === 'plan') {
    if (
      ['--plan-file', '--plan-digest', '--writer-fence-evidence-digest', '--drain-evidence-digest'].some((flag) =>
        values.has(flag),
      ) || booleans.size > 0
    ) {
      fail('PLAN_ARGUMENT_NOT_ALLOWED');
    }
    return Object.freeze({ command, binding });
  }

  const planFile = requiredString(values.get('--plan-file'), 'INVALID_PLAN_FILE', MAX_PLAN_PATH_LENGTH);
  const expectedPlanDigest = requiredString(values.get('--plan-digest'), 'INVALID_PLAN_DIGEST', 64);
  if (!SHA256_RE.test(expectedPlanDigest)) fail('INVALID_PLAN_DIGEST');
  const writerFenceEvidenceDigest = requiredString(
    values.get('--writer-fence-evidence-digest'),
    'INVALID_WRITER_FENCE_EVIDENCE_DIGEST',
    64,
  );
  if (!SHA256_RE.test(writerFenceEvidenceDigest)) fail('INVALID_WRITER_FENCE_EVIDENCE_DIGEST');
  const drainEvidenceDigest = requiredString(
    values.get('--drain-evidence-digest'),
    'INVALID_DRAIN_EVIDENCE_DIGEST',
    64,
  );
  if (!SHA256_RE.test(drainEvidenceDigest)) fail('INVALID_DRAIN_EVIDENCE_DIGEST');
  if (writerFenceEvidenceDigest === drainEvidenceDigest) fail('EVIDENCE_DIGESTS_MUST_DIFFER');
  if (!booleans.has('--allow-v1-purge')) fail('V1_PURGE_NOT_ALLOWED');
  if (!booleans.has('--traffic-quiesced')) fail('TRAFFIC_NOT_QUIESCED');

  return Object.freeze({
    command,
    binding,
    planFile,
    expectedPlanDigest,
    writerFenceEvidenceDigest,
    drainEvidenceDigest,
    allowMutations: true,
    trafficQuiesced: true,
  });
}

export function createRegistryCutoverAwsClients({ region }) {
  const rawDynamoClient = new DynamoDBClient({
    region,
    maxAttempts: 1,
    ignoreConfiguredEndpointUrls: true,
    requestHandler: new NodeHttpHandler(GATEWAY_AWS_TRANSPORT_OPTIONS),
  });
  const dynamoDocumentClient = DynamoDBDocumentClient.from(rawDynamoClient, {
    marshallOptions: {
      convertClassInstanceToMap: false,
      removeUndefinedValues: false,
    },
  });
  return Object.freeze({
    rawDynamoClient,
    dynamoDocumentClient,
    destroy() {
      dynamoDocumentClient.destroy();
    },
  });
}

function requestIdOf(output) {
  const requestId = output?.$metadata?.requestId;
  if (
    typeof requestId !== 'string' ||
    requestId.length === 0 ||
    requestId.length > 512 ||
    /[\u0000-\u001f\u007f]/.test(requestId)
  ) {
    fail('AWS_REQUEST_ID_MISSING');
  }
  return requestId;
}

function validatedTableDescription(output, binding) {
  const table = output?.Table;
  if (!table || table.TableName !== binding.tableName || table.TableArn !== binding.tableArn) {
    fail('TABLE_BINDING_MISMATCH');
  }
  if (table.TableStatus !== 'ACTIVE') fail('TABLE_NOT_ACTIVE');
  if (typeof table.TableId !== 'string' || table.TableId.length === 0 || table.TableId.length > 128) {
    fail('TABLE_INCARNATION_UNAVAILABLE');
  }
  if (!(table.CreationDateTime instanceof Date)) fail('TABLE_INCARNATION_UNAVAILABLE');
  const creationDate = table.CreationDateTime;
  if (!Number.isFinite(creationDate.getTime())) fail('TABLE_INCARNATION_UNAVAILABLE');
  const keySchema = Array.isArray(table.KeySchema) ? table.KeySchema : [];
  if (
    keySchema.length !== 2 ||
    !keySchema.some((entry) => entry?.AttributeName === 'pk' && entry?.KeyType === 'HASH') ||
    !keySchema.some((entry) => entry?.AttributeName === 'sk' && entry?.KeyType === 'RANGE')
  ) {
    fail('TABLE_KEY_SCHEMA_MISMATCH');
  }
  const attributes = Array.isArray(table.AttributeDefinitions) ? table.AttributeDefinitions : [];
  if (
    attributes.length !== 2 ||
    !attributes.some((entry) => entry?.AttributeName === 'pk' && entry?.AttributeType === 'S') ||
    !attributes.some((entry) => entry?.AttributeName === 'sk' && entry?.AttributeType === 'S')
  ) {
    fail('TABLE_KEY_SCHEMA_MISMATCH');
  }
  if (table.Replicas !== undefined && !Array.isArray(table.Replicas)) fail('INVALID_REPLICA_DESCRIPTION');
  if ((Array.isArray(table.Replicas) && table.Replicas.length > 0) || table.GlobalTableVersion) {
    fail('GLOBAL_TABLE_NOT_SUPPORTED');
  }
  if (table.GlobalSecondaryIndexes !== undefined && !Array.isArray(table.GlobalSecondaryIndexes)) {
    fail('INVALID_SECONDARY_INDEX_DESCRIPTION');
  }
  if (table.LocalSecondaryIndexes !== undefined && !Array.isArray(table.LocalSecondaryIndexes)) {
    fail('INVALID_SECONDARY_INDEX_DESCRIPTION');
  }
  if (
    (Array.isArray(table.GlobalSecondaryIndexes) && table.GlobalSecondaryIndexes.length > 0) ||
    (Array.isArray(table.LocalSecondaryIndexes) && table.LocalSecondaryIndexes.length > 0)
  ) {
    fail('SECONDARY_INDEX_NOT_SUPPORTED');
  }
  return {
    tableName: table.TableName,
    tableArn: table.TableArn,
    tableId: table.TableId,
    creationDateTime: creationDate.toISOString(),
    tableStatus: table.TableStatus,
    keySchema: [
      { attributeName: 'pk', keyType: 'HASH' },
      { attributeName: 'sk', keyType: 'RANGE' },
    ],
    attributeDefinitions: [
      { attributeName: 'pk', attributeType: 'S' },
      { attributeName: 'sk', attributeType: 'S' },
    ],
    replicas: [],
    requestId: requestIdOf(output),
  };
}

export function createRegistryCutoverAwsAdapter(clients, binding) {
  if (!clients?.rawDynamoClient || typeof clients.rawDynamoClient.send !== 'function') fail('INVALID_RAW_DYNAMO_CLIENT');
  if (!clients?.dynamoDocumentClient || typeof clients.dynamoDocumentClient.send !== 'function') {
    fail('INVALID_DOCUMENT_DYNAMO_CLIENT');
  }
  if (!binding || typeof binding.tableArn !== 'string' || typeof binding.tableName !== 'string') fail('INVALID_BINDING');

  const assertRequestBinding = ({ tableName, region }) => {
    if (tableName !== binding.tableName || region !== binding.region) fail('TABLE_BINDING_MISMATCH');
  };

  return Object.freeze({
    async describeTable(request) {
      assertRequestBinding(request);
      const output = await clients.rawDynamoClient.send(new DescribeTableCommand({ TableName: binding.tableArn }));
      return validatedTableDescription(output, binding);
    },

    async scanPage({ tableName, region, consistentRead, exclusiveStartKey }) {
      assertRequestBinding({ tableName, region });
      if (consistentRead !== true) fail('CONSISTENT_READ_REQUIRED');
      const input = {
        TableName: binding.tableArn,
        ConsistentRead: true,
        ProjectionExpression: '#pk, #sk',
        ExpressionAttributeNames: { '#pk': 'pk', '#sk': 'sk' },
      };
      if (exclusiveStartKey !== undefined) input.ExclusiveStartKey = exclusiveStartKey;
      const output = await clients.dynamoDocumentClient.send(new ScanCommand(input));
      const result = {
        items: output?.Items,
        requestId: requestIdOf(output),
      };
      if (output?.LastEvaluatedKey !== undefined) result.lastEvaluatedKey = output.LastEvaluatedKey;
      return result;
    },

    async deleteItem({ tableName, region, key, prefix }) {
      assertRequestBinding({ tableName, region });
      if (!key || typeof key.pk !== 'string' || typeof key.sk !== 'string') fail('INVALID_DELETE_KEY');
      if (!V1_DELETE_PREFIXES.includes(prefix) || !key.pk.startsWith(prefix)) fail('NON_V1_DELETE_REFUSED');
      const output = await clients.dynamoDocumentClient.send(
        new DeleteCommand({
          TableName: binding.tableArn,
          Key: { pk: key.pk, sk: key.sk },
          ConditionExpression: 'attribute_exists(#pk)',
          ExpressionAttributeNames: { '#pk': 'pk' },
          ReturnValues: 'NONE',
          ReturnValuesOnConditionCheckFailure: 'NONE',
        }),
      );
      return {
        requestId: requestIdOf(output),
      };
    },
  });
}

async function loadPlan(planFile, readPlanFile) {
  let bytes;
  try {
    bytes = await readPlanFile(planFile);
  } catch {
    fail('PLAN_FILE_UNREADABLE');
  }
  const text = Buffer.isBuffer(bytes) ? bytes.toString('utf8') : String(bytes);
  if (Buffer.byteLength(text, 'utf8') > MAX_PLAN_FILE_BYTES) fail('PLAN_FILE_TOO_LARGE');
  try {
    const plan = JSON.parse(text);
    if (!plan || typeof plan !== 'object' || Array.isArray(plan)) fail('INVALID_PLAN_FILE');
    return plan;
  } catch (error) {
    if (error instanceof RegistryCutoverCliError) throw error;
    fail('INVALID_PLAN_JSON');
  }
}

export async function executeRegistryCutover(
  argv,
  { createClients = createRegistryCutoverAwsClients, readPlanFile = readFile, createCutover = createRegistryCutover } = {},
) {
  const options = parseRegistryCutoverArguments(argv);
  if (options.command === 'help') return Object.freeze({ help: true, text: REGISTRY_CUTOVER_USAGE });

  const plan = options.command === 'apply' ? await loadPlan(options.planFile, readPlanFile) : undefined;
  const clients = createClients({ region: options.binding.region });
  if (!clients || typeof clients.destroy !== 'function') fail('INVALID_AWS_CLIENT_BUNDLE');

  try {
    const cutover = createCutover(createRegistryCutoverAwsAdapter(clients, options.binding));
    if (!cutover || typeof cutover.plan !== 'function' || typeof cutover.apply !== 'function') fail('INVALID_CUTOVER_CORE');
    if (options.command === 'plan') return await cutover.plan({ binding: options.binding });
    return await cutover.apply({
      binding: options.binding,
      plan,
      expectedPlanDigest: options.expectedPlanDigest,
      writerFenceEvidenceDigest: options.writerFenceEvidenceDigest,
      drainEvidenceDigest: options.drainEvidenceDigest,
      allowMutations: options.allowMutations,
      trafficQuiesced: options.trafficQuiesced,
    });
  } finally {
    clients.destroy();
  }
}

export function sanitizedErrorCode(error) {
  const candidate = typeof error?.code === 'string' ? error.code : typeof error?.name === 'string' ? error.name : '';
  const normalized = candidate.toUpperCase().replace(/[^A-Z0-9_]/g, '_');
  return /^[A-Z][A-Z0-9_]{2,63}$/.test(normalized) ? normalized : 'REGISTRY_CUTOVER_FAILED';
}

async function main() {
  try {
    const output = await executeRegistryCutover(process.argv.slice(2));
    process.stdout.write(`${output?.help ? output.text : JSON.stringify(output, null, 2)}\n`);
  } catch (error) {
    process.stderr.write(`registry-cutover: ${sanitizedErrorCode(error)}\n`);
    process.exitCode = 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) await main();
