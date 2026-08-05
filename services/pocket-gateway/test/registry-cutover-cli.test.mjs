import assert from 'node:assert/strict';
import test from 'node:test';

import {
  RegistryCutoverCliError,
  createRegistryCutoverAwsAdapter,
  createRegistryCutoverAwsClients,
  executeRegistryCutover,
  parseRegistryCutoverArguments,
  sanitizedErrorCode,
} from '../deploy/gateway/scripts/registry-cutover.mjs';

const TABLE_ARN = 'arn:aws:dynamodb:us-east-1:123456789012:table/pocket-registry-prod';
const BINDING = Object.freeze({
  accountId: '123456789012',
  region: 'us-east-1',
  tableName: 'pocket-registry-prod',
  tableArn: TABLE_ARN,
});
const BINDING_ARGS = [
  '--table-name',
  'pocket-registry-prod',
  '--table-arn',
  TABLE_ARN,
  '--account-id',
  '123456789012',
  '--region',
  'us-east-1',
];
const WRITER_FENCE_DIGEST = 'd'.repeat(64);
const DRAIN_EVIDENCE_DIGEST = 'e'.repeat(64);
const APPLY_EVIDENCE_ARGS = [
  '--writer-fence-evidence-digest',
  WRITER_FENCE_DIGEST,
  '--drain-evidence-digest',
  DRAIN_EVIDENCE_DIGEST,
];

function validTable(overrides = {}) {
  return {
    TableName: 'pocket-registry-prod',
    TableArn: TABLE_ARN,
    TableId: '11111111-2222-3333-4444-555555555555',
    CreationDateTime: new Date('2026-08-05T12:00:00.000Z'),
    TableStatus: 'ACTIVE',
    KeySchema: [
      { AttributeName: 'pk', KeyType: 'HASH' },
      { AttributeName: 'sk', KeyType: 'RANGE' },
    ],
    AttributeDefinitions: [
      { AttributeName: 'pk', AttributeType: 'S' },
      { AttributeName: 'sk', AttributeType: 'S' },
    ],
    Replicas: [],
    ...overrides,
  };
}

function fakeClients({ rawOutput, documentHandler } = {}) {
  const calls = [];
  let destroyed = 0;
  return {
    calls,
    rawDynamoClient: {
      async send(command) {
        calls.push({ client: 'raw', command });
        return rawOutput ?? {};
      },
    },
    dynamoDocumentClient: {
      async send(command) {
        calls.push({ client: 'document', command });
        return documentHandler ? documentHandler(command) : {};
      },
    },
    destroy() {
      destroyed += 1;
    },
    get destroyed() {
      return destroyed;
    },
  };
}

test('parser binds plan to one exact DynamoDB table and rejects mutation arguments', () => {
  assert.deepEqual(parseRegistryCutoverArguments(['plan', ...BINDING_ARGS]), {
    command: 'plan',
    binding: {
      accountId: '123456789012',
      region: 'us-east-1',
      tableName: 'pocket-registry-prod',
      tableArn: 'arn:aws:dynamodb:us-east-1:123456789012:table/pocket-registry-prod',
    },
  });
  assert.throws(
    () => parseRegistryCutoverArguments(['plan', ...BINDING_ARGS, '--allow-v1-purge']),
    (error) => error instanceof RegistryCutoverCliError && error.code === 'PLAN_ARGUMENT_NOT_ALLOWED',
  );
  assert.throws(
    () =>
      parseRegistryCutoverArguments([
        'plan',
        ...BINDING_ARGS.map((value) => (value === '123456789012' ? '210987654321' : value)),
      ]),
    (error) => error instanceof RegistryCutoverCliError && error.code === 'TABLE_BINDING_MISMATCH',
  );
});

test('parser requires an explicit lowercase digest, V1 purge opt-in, and traffic quiescence for apply', () => {
  const digest = 'a'.repeat(64);
  const parsed = parseRegistryCutoverArguments([
    'apply',
    ...BINDING_ARGS,
    '--plan-file',
    'registry-plan.json',
    '--plan-digest',
    digest,
    ...APPLY_EVIDENCE_ARGS,
    '--allow-v1-purge',
    '--traffic-quiesced',
  ]);
  assert.equal(parsed.expectedPlanDigest, digest);
  assert.equal(parsed.writerFenceEvidenceDigest, WRITER_FENCE_DIGEST);
  assert.equal(parsed.drainEvidenceDigest, DRAIN_EVIDENCE_DIGEST);
  assert.equal(parsed.allowMutations, true);
  assert.equal(parsed.trafficQuiesced, true);

  for (const [removed, code] of [
    ['--allow-v1-purge', 'V1_PURGE_NOT_ALLOWED'],
    ['--traffic-quiesced', 'TRAFFIC_NOT_QUIESCED'],
  ]) {
    const argv = [
      'apply',
      ...BINDING_ARGS,
      '--plan-file',
      'registry-plan.json',
      '--plan-digest',
      digest,
      ...APPLY_EVIDENCE_ARGS,
      '--allow-v1-purge',
      '--traffic-quiesced',
    ];
    argv.splice(argv.indexOf(removed), 1);
    assert.throws(
      () => parseRegistryCutoverArguments(argv),
      (error) => error instanceof RegistryCutoverCliError && error.code === code,
    );
  }

  assert.throws(
    () =>
      parseRegistryCutoverArguments([
        'apply',
        ...BINDING_ARGS,
        '--plan-file',
        'registry-plan.json',
        '--plan-digest',
        digest.toUpperCase(),
        ...APPLY_EVIDENCE_ARGS,
        '--allow-v1-purge',
        '--traffic-quiesced',
      ]),
    (error) => error instanceof RegistryCutoverCliError && error.code === 'INVALID_PLAN_DIGEST',
  );
  assert.throws(
    () =>
      parseRegistryCutoverArguments([
        'apply',
        ...BINDING_ARGS,
        '--plan-file',
        'registry-plan.json',
        '--plan-digest',
        digest,
        '--writer-fence-evidence-digest',
        WRITER_FENCE_DIGEST,
        '--drain-evidence-digest',
        WRITER_FENCE_DIGEST,
        '--allow-v1-purge',
        '--traffic-quiesced',
      ]),
    (error) => error instanceof RegistryCutoverCliError && error.code === 'EVIDENCE_DIGESTS_MUST_DIFFER',
  );
});

test('AWS client is pinned to one region/attempt and ignores ambient endpoint overrides', async () => {
  const clients = createRegistryCutoverAwsClients({ region: 'us-east-1' });
  try {
    assert.equal(await clients.rawDynamoClient.config.region(), 'us-east-1');
    assert.equal(await clients.rawDynamoClient.config.maxAttempts(), 1);
    assert.equal(clients.rawDynamoClient.config.ignoreConfiguredEndpointUrls, true);
  } finally {
    clients.destroy();
  }
});

test('AWS adapter describes the exact table and performs only a strong base-table key projection', async () => {
  const clients = fakeClients({
    rawOutput: {
      Table: validTable(),
      $metadata: { requestId: 'describe-request' },
    },
    documentHandler(command) {
      if (command.constructor.name === 'ScanCommand') {
        return {
          Items: [{ pk: 'dial:dev:legacy', sk: 'record' }],
          LastEvaluatedKey: { pk: 'cursor', sk: 'record' },
          $metadata: { requestId: 'scan-request' },
        };
      }
      throw new Error('unexpected document command');
    },
  });
  const adapter = createRegistryCutoverAwsAdapter(clients, BINDING);

  assert.deepEqual(await adapter.describeTable({ tableName: 'pocket-registry-prod', region: 'us-east-1' }), {
    tableName: 'pocket-registry-prod',
    tableArn: TABLE_ARN,
    tableId: '11111111-2222-3333-4444-555555555555',
    creationDateTime: '2026-08-05T12:00:00.000Z',
    tableStatus: 'ACTIVE',
    keySchema: [
      { attributeName: 'pk', keyType: 'HASH' },
      { attributeName: 'sk', keyType: 'RANGE' },
    ],
    attributeDefinitions: [
      { attributeName: 'pk', attributeType: 'S' },
      { attributeName: 'sk', attributeType: 'S' },
    ],
    replicas: [],
    requestId: 'describe-request',
  });
  assert.deepEqual(
    await adapter.scanPage({
      tableName: 'pocket-registry-prod',
      region: 'us-east-1',
      consistentRead: true,
      exclusiveStartKey: { pk: 'previous', sk: 'record' },
    }),
    {
      items: [{ pk: 'dial:dev:legacy', sk: 'record' }],
      lastEvaluatedKey: { pk: 'cursor', sk: 'record' },
      requestId: 'scan-request',
    },
  );

  assert.deepEqual(clients.calls[0].command.input, { TableName: TABLE_ARN });
  assert.deepEqual(clients.calls[1].command.input, {
    TableName: TABLE_ARN,
    ConsistentRead: true,
    ProjectionExpression: '#pk, #sk',
    ExpressionAttributeNames: { '#pk': 'pk', '#sk': 'sk' },
    ExclusiveStartKey: { pk: 'previous', sk: 'record' },
  });
  await assert.rejects(
    adapter.scanPage({ tableName: 'pocket-registry-prod', region: 'us-east-1', consistentRead: false }),
    (error) => error instanceof RegistryCutoverCliError && error.code === 'CONSISTENT_READ_REQUIRED',
  );
});

test('AWS adapter refuses table identity, lifecycle, schema, replica, and request-evidence drift', async () => {
  const cases = [
    [{ TableArn: 'arn:aws:dynamodb:us-east-1:123456789012:table/another-table' }, 'TABLE_BINDING_MISMATCH'],
    [{ TableStatus: 'UPDATING' }, 'TABLE_NOT_ACTIVE'],
    [{ TableId: undefined }, 'TABLE_INCARNATION_UNAVAILABLE'],
    [{ CreationDateTime: null }, 'TABLE_INCARNATION_UNAVAILABLE'],
    [{ CreationDateTime: false }, 'TABLE_INCARNATION_UNAVAILABLE'],
    [{ CreationDateTime: 0 }, 'TABLE_INCARNATION_UNAVAILABLE'],
    [
      {
        KeySchema: [
          { AttributeName: 'pk', KeyType: 'HASH' },
          { AttributeName: 'wrong', KeyType: 'RANGE' },
        ],
      },
      'TABLE_KEY_SCHEMA_MISMATCH',
    ],
    [{ Replicas: [{ RegionName: 'us-west-2' }] }, 'GLOBAL_TABLE_NOT_SUPPORTED'],
    [{ Replicas: {} }, 'INVALID_REPLICA_DESCRIPTION'],
    [
      {
        AttributeDefinitions: [
          { AttributeName: 'pk', AttributeType: 'S' },
          { AttributeName: 'sk', AttributeType: 'S' },
          { AttributeName: 'gsiPk', AttributeType: 'S' },
        ],
      },
      'TABLE_KEY_SCHEMA_MISMATCH',
    ],
    [{ GlobalSecondaryIndexes: [{ IndexName: 'unexpected' }] }, 'SECONDARY_INDEX_NOT_SUPPORTED'],
    [{ LocalSecondaryIndexes: {} }, 'INVALID_SECONDARY_INDEX_DESCRIPTION'],
  ];
  for (const [overrides, code] of cases) {
    const clients = fakeClients({ rawOutput: { Table: validTable(overrides), $metadata: { requestId: 'request' } } });
    const adapter = createRegistryCutoverAwsAdapter(clients, BINDING);
    await assert.rejects(
      adapter.describeTable({ tableName: BINDING.tableName, region: BINDING.region }),
      (error) => error instanceof RegistryCutoverCliError && error.code === code,
    );
  }

  const clients = fakeClients({ rawOutput: { Table: validTable(), $metadata: {} } });
  const adapter = createRegistryCutoverAwsAdapter(clients, BINDING);
  await assert.rejects(
    adapter.describeTable({ tableName: BINDING.tableName, region: BINDING.region }),
    (error) => error instanceof RegistryCutoverCliError && error.code === 'AWS_REQUEST_ID_MISSING',
  );
});

test('AWS adapter conditionally deletes only fixed V1 prefixes without returning sensitive prior images', async () => {
  const clients = fakeClients({
    documentHandler(command) {
      assert.equal(command.constructor.name, 'DeleteCommand');
      return {
        $metadata: { requestId: 'delete-request' },
      };
    },
  });
  const adapter = createRegistryCutoverAwsAdapter(clients, BINDING);
  assert.deepEqual(
    await adapter.deleteItem({
      tableName: 'pocket-registry-prod',
      region: 'us-east-1',
      key: { pk: 'dial:v1:dev:legacy', sk: 'record' },
      prefix: 'dial:v1:dev:',
    }),
    {
      requestId: 'delete-request',
    },
  );
  assert.deepEqual(clients.calls[0].command.input, {
    TableName: TABLE_ARN,
    Key: { pk: 'dial:v1:dev:legacy', sk: 'record' },
    ConditionExpression: 'attribute_exists(#pk)',
    ExpressionAttributeNames: { '#pk': 'pk' },
    ReturnValues: 'NONE',
    ReturnValuesOnConditionCheckFailure: 'NONE',
  });
  await assert.rejects(
    adapter.deleteItem({
      tableName: 'pocket-registry-prod',
      region: 'us-east-1',
      key: { pk: 'dial:install:v2:not-authorized', sk: 'binding' },
      prefix: 'dial:install:v2:',
    }),
    (error) => error instanceof RegistryCutoverCliError && error.code === 'NON_V1_DELETE_REFUSED',
  );
  assert.equal(clients.calls.length, 1, 'a non-V1 key is refused before any SDK request');
});

test('executor delegates plan/apply without ambient mutation and always destroys AWS clients', async () => {
  const planClients = fakeClients();
  let plannedBinding;
  const planned = await executeRegistryCutover(['plan', ...BINDING_ARGS], {
    createClients: () => planClients,
    createCutover: () => ({
      async plan({ binding }) {
        plannedBinding = binding;
        return { schema: 'sanitized-plan' };
      },
      async apply() {
        throw new Error('not called');
      },
    }),
  });
  assert.deepEqual(planned, { schema: 'sanitized-plan' });
  assert.equal(plannedBinding.tableName, 'pocket-registry-prod');
  assert.equal(planClients.destroyed, 1);

  const applyClients = fakeClients();
  let applied;
  const digest = 'b'.repeat(64);
  const result = await executeRegistryCutover(
    [
      'apply',
      ...BINDING_ARGS,
      '--plan-file',
      'registry-plan.json',
      '--plan-digest',
      digest,
      ...APPLY_EVIDENCE_ARGS,
      '--allow-v1-purge',
      '--traffic-quiesced',
    ],
    {
      createClients: () => applyClients,
      readPlanFile: async () => JSON.stringify({ schema: 'input-plan' }),
      createCutover: () => ({
        async plan() {
          throw new Error('not called');
        },
        async apply(input) {
          applied = input;
          return { schema: 'zero-proof' };
        },
      }),
    },
  );
  assert.deepEqual(result, { schema: 'zero-proof' });
  assert.deepEqual(applied.plan, { schema: 'input-plan' });
  assert.equal(applied.expectedPlanDigest, digest);
  assert.equal(applied.writerFenceEvidenceDigest, WRITER_FENCE_DIGEST);
  assert.equal(applied.drainEvidenceDigest, DRAIN_EVIDENCE_DIGEST);
  assert.equal(applied.allowMutations, true);
  assert.equal(applied.trafficQuiesced, true);
  assert.equal(applyClients.destroyed, 1);
});

test('CLI adapter and core complete a hermetic V1-only plan/apply/double-zero flow', async () => {
  const records = new Map([
    ['dial:dev:historical\0record', { pk: 'dial:dev:historical', sk: 'record' }],
    ['dial:v1:dev:current\0record', { pk: 'dial:v1:dev:current', sk: 'record' }],
    ['unrelated\0record', { pk: 'unrelated', sk: 'record' }],
  ]);
  let request = 0;
  const bundles = [];
  const createClients = ({ region }) => {
    assert.equal(region, BINDING.region);
    const bundle = fakeClients({
      rawOutput: undefined,
      documentHandler(command) {
        if (command.constructor.name === 'ScanCommand') {
          assert.equal(command.input.TableName, TABLE_ARN);
          return { Items: [...records.values()], $metadata: { requestId: `scan-${++request}` } };
        }
        if (command.constructor.name === 'DeleteCommand') {
          assert.equal(command.input.TableName, TABLE_ARN);
          const key = command.input.Key;
          assert.equal(records.delete(`${key.pk}\0${key.sk}`), true);
          return { $metadata: { requestId: `delete-${++request}` } };
        }
        throw new Error('unexpected command');
      },
    });
    bundle.rawDynamoClient.send = async (command) => {
      bundle.calls.push({ client: 'raw', command });
      return {
        Table: validTable(),
        $metadata: { requestId: `describe-${++request}` },
      };
    };
    bundles.push(bundle);
    return bundle;
  };

  const plan = await executeRegistryCutover(['plan', ...BINDING_ARGS], { createClients });
  assert.equal(plan.applyEligible, true);
  assert.equal(plan.prefixes.v1['dial:dev:'], 1);
  assert.equal(plan.prefixes.v1['dial:v1:dev:'], 1);
  const result = await executeRegistryCutover(
    [
      'apply',
      ...BINDING_ARGS,
      '--plan-file',
      'registry-plan.json',
      '--plan-digest',
      plan.digest,
      ...APPLY_EVIDENCE_ARGS,
      '--allow-v1-purge',
      '--traffic-quiesced',
    ],
    {
      createClients,
      readPlanFile: async () => JSON.stringify(plan),
    },
  );
  assert.equal(result.zeroProof.allSixPrefixesZero, true);
  assert.equal(result.deleted.items, 2);
  assert.deepEqual([...records.values()], [{ pk: 'unrelated', sk: 'record' }]);
  assert.equal(bundles.length, 2);
  assert.ok(bundles.every((bundle) => bundle.destroyed === 1));
});

test('plan-file failures occur before AWS client construction and public error text is code-only', async () => {
  let created = false;
  await assert.rejects(
    executeRegistryCutover(
      [
        'apply',
        ...BINDING_ARGS,
        '--plan-file',
        'registry-plan.json',
        '--plan-digest',
        'c'.repeat(64),
        ...APPLY_EVIDENCE_ARGS,
        '--allow-v1-purge',
        '--traffic-quiesced',
      ],
      {
        createClients: () => {
          created = true;
          return fakeClients();
        },
        readPlanFile: async () => '{not-json',
      },
    ),
    (error) => error instanceof RegistryCutoverCliError && error.code === 'INVALID_PLAN_JSON',
  );
  assert.equal(created, false);
  assert.equal(sanitizedErrorCode({ name: 'ConditionalCheckFailedException', message: 'raw key material' }), 'CONDITIONALCHECKFAILEDEXCEPTION');
  assert.equal(sanitizedErrorCode({ name: 'x', message: 'raw key material' }), 'REGISTRY_CUTOVER_FAILED');
});
