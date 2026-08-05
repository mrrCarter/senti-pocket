import assert from 'node:assert/strict';
import test from 'node:test';

import {
  REGISTRY_ALL_PREFIXES,
  REGISTRY_CUTOVER_APPLY_SCHEMA,
  REGISTRY_CUTOVER_DIGEST_SEMANTICS,
  REGISTRY_CUTOVER_MAX_PK_BYTES,
  REGISTRY_CUTOVER_MAX_SCAN_ITEMS,
  REGISTRY_CUTOVER_MAX_SCAN_PAGES,
  REGISTRY_CUTOVER_MAX_SK_BYTES,
  REGISTRY_CUTOVER_MAX_V1_DELETES,
  REGISTRY_CUTOVER_PLAN_MAX_AGE_MS,
  REGISTRY_CUTOVER_PLAN_SCHEMA,
  REGISTRY_V1_PREFIXES,
  REGISTRY_V2_PREFIXES,
  RegistryCutoverError,
  createRegistryCutover,
} from '../deploy/gateway/registry-cutover.mjs';

const NOW = Date.parse('2026-08-05T14:00:00.000Z');
const BINDING = Object.freeze({
  accountId: '123456789012',
  region: 'us-east-1',
  tableName: 'senti-pocket-gateway-prod',
  tableArn: 'arn:aws:dynamodb:us-east-1:123456789012:table/senti-pocket-gateway-prod',
});
const WRITER_FENCE_DIGEST = 'a'.repeat(64);
const DRAIN_EVIDENCE_DIGEST = 'b'.repeat(64);

const row = (pk, sk = 'record') => ({ pk, sk });
const keyString = ({ pk, sk }) => JSON.stringify([pk, sk]);
const clone = (value) => structuredClone(value);

function createHarness({ rows = [], pageSize = 2 } = {}) {
  const state = {
    now: NOW,
    pageSize,
    rows: new Map(rows.map((item) => [keyString(item), clone(item)])),
    table: {
      tableName: BINDING.tableName,
      tableArn: BINDING.tableArn,
      tableId: 'raw-table-id-4fd3a61e',
      creationDateTime: '2026-08-01T00:00:00.000Z',
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
    },
    describeCalls: [],
    scanCalls: [],
    deleteCalls: [],
    describeOverride: undefined,
    scanOverride: undefined,
    deleteOverride: undefined,
    beforeDescribe: undefined,
    afterDescribe: undefined,
    beforeScan: undefined,
    afterScan: undefined,
    beforeDelete: undefined,
    afterDelete: undefined,
  };

  const describeTable = async (input) => {
    const call = state.describeCalls.length + 1;
    state.describeCalls.push(clone(input));
    await state.beforeDescribe?.({ call, input, state });
    const defaultResult = {
      ...clone(state.table),
      requestId: `raw-describe-request-${call}`,
    };
    const result = state.describeOverride
      ? await state.describeOverride({ call, input, defaultResult, state })
      : defaultResult;
    await state.afterDescribe?.({ call, input, result, state });
    return result;
  };

  const scanPage = async (input) => {
    const call = state.scanCalls.length + 1;
    state.scanCalls.push(clone(input));
    await state.beforeScan?.({ call, input, state });

    const sortedRows = [...state.rows.values()].sort((left, right) => {
      const leftKey = keyString(left);
      const rightKey = keyString(right);
      return leftKey < rightKey ? -1 : leftKey > rightKey ? 1 : 0;
    });
    let start = 0;
    if (input.exclusiveStartKey) {
      const cursorIndex = sortedRows.findIndex((item) => keyString(item) === keyString(input.exclusiveStartKey));
      if (cursorIndex < 0) throw new Error('fake cursor no longer exists');
      start = cursorIndex + 1;
    }
    const items = sortedRows.slice(start, start + state.pageSize).map(clone);
    const defaultResult = {
      items,
      ...(start + items.length < sortedRows.length && items.length > 0
        ? { lastEvaluatedKey: clone(items.at(-1)) }
        : {}),
      requestId: `raw-scan-request-${call}`,
    };
    const result = state.scanOverride
      ? await state.scanOverride({ call, input, defaultResult, state })
      : defaultResult;
    await state.afterScan?.({ call, input, result, state });
    return result;
  };

  const deleteItem = async (input) => {
    const call = state.deleteCalls.length + 1;
    state.deleteCalls.push(clone(input));
    await state.beforeDelete?.({ call, input, state });
    let result;
    if (state.deleteOverride) {
      result = await state.deleteOverride({ call, input, state });
    } else {
      if (!state.rows.delete(keyString(input.key))) throw new Error('conditional delete failed');
      result = { requestId: `raw-delete-request-${call}` };
    }
    await state.afterDelete?.({ call, input, result, state });
    return result;
  };

  return {
    state,
    cutover: createRegistryCutover({
      describeTable,
      scanPage,
      deleteItem,
      now: () => state.now,
    }),
    add(item) {
      state.rows.set(keyString(item), clone(item));
    },
    remove(item) {
      state.rows.delete(keyString(item));
    },
  };
}

function applyInput(plan, overrides = {}) {
  return {
    binding: BINDING,
    plan,
    expectedPlanDigest: plan.digest,
    allowMutations: true,
    trafficQuiesced: true,
    writerFenceEvidenceDigest: WRITER_FENCE_DIGEST,
    drainEvidenceDigest: DRAIN_EVIDENCE_DIGEST,
    ...overrides,
  };
}

async function expectCode(promise, code) {
  await assert.rejects(promise, (error) => {
    assert.ok(error instanceof RegistryCutoverError);
    assert.equal(error.code, code);
    return true;
  });
}

test('exports lock the six namespaces, fixed deadline, and hard safety caps', () => {
  assert.deepEqual(REGISTRY_V1_PREFIXES, ['dial:dev:', 'dial:v1:dev:']);
  assert.deepEqual(REGISTRY_V2_PREFIXES, [
    'dial:install:v2:',
    'dial:token:v2:',
    'dial:target:v2:',
    'dial:regop:v2:',
  ]);
  assert.deepEqual(REGISTRY_ALL_PREFIXES, [...REGISTRY_V1_PREFIXES, ...REGISTRY_V2_PREFIXES]);
  assert.equal(REGISTRY_CUTOVER_PLAN_MAX_AGE_MS, 300_000);
  assert.equal(REGISTRY_CUTOVER_MAX_SCAN_PAGES, 10_000);
  assert.equal(REGISTRY_CUTOVER_MAX_SCAN_ITEMS, 1_000_000);
  assert.equal(REGISTRY_CUTOVER_MAX_V1_DELETES, 100_000);
  assert.equal(REGISTRY_CUTOVER_MAX_PK_BYTES, 2_048);
  assert.equal(REGISTRY_CUTOVER_MAX_SK_BYTES, 1_024);
});

test('plan is read-only, fully paginates the base table, and emits only sanitized canonical evidence', async () => {
  const dynamicRows = [
    row('unrelated:raw-business-id'),
    row('dial:dev:raw-old-device'),
    row('dial:v1:dev:raw-current-device'),
    row('dial:install:v2:raw-installation'),
    row('dial:token:v2:raw-token'),
    row('dial:target:v2:raw-target'),
    row('dial:regop:v2:raw-operation'),
  ];
  const harness = createHarness({ rows: dynamicRows, pageSize: 2 });

  const plan = await harness.cutover.plan({ binding: BINDING });

  assert.equal(plan.schema, REGISTRY_CUTOVER_PLAN_SCHEMA);
  assert.equal(plan.phase, 'plan');
  assert.equal(plan.digestSemantics, REGISTRY_CUTOVER_DIGEST_SEMANTICS);
  assert.equal(plan.plannedAt, '2026-08-05T14:00:00.000Z');
  assert.equal(plan.expiresAt, '2026-08-05T14:05:00.000Z');
  assert.equal(plan.applyEligible, false);
  assert.deepEqual(plan.prefixes.v1, { 'dial:dev:': 1, 'dial:v1:dev:': 1 });
  assert.deepEqual(plan.prefixes.v2, {
    'dial:install:v2:': 1,
    'dial:token:v2:': 1,
    'dial:target:v2:': 1,
    'dial:regop:v2:': 1,
  });
  assert.equal(plan.scan.pages, 4);
  assert.equal(plan.scan.scannedItems, 7);
  assert.equal(plan.scan.matchedItems, 6);
  assert.equal(plan.scan.requests.length, 4);
  assert.equal(harness.state.deleteCalls.length, 0);
  assert.equal(harness.state.describeCalls.length, 2);
  assert.equal(harness.state.scanCalls.length, 4);
  for (const call of harness.state.scanCalls) {
    assert.equal(call.tableName, BINDING.tableName);
    assert.equal(call.region, BINDING.region);
    assert.equal(call.consistentRead, true);
    assert.equal(call.baseTableOnly, true);
    assert.deepEqual(call.projection, ['pk', 'sk']);
    assert.equal('indexName' in call, false);
  }
  assert.ok(Object.isFrozen(plan));
  assert.ok(Object.isFrozen(plan.scan.requests));

  const serialized = JSON.stringify(plan);
  for (const secret of [
    BINDING.accountId,
    BINDING.tableName,
    BINDING.tableArn,
    harness.state.table.tableId,
    ...dynamicRows.map(({ pk }) => pk),
    'raw-describe-request-1',
    'raw-scan-request-1',
  ]) {
    assert.equal(serialized.includes(secret), false, `evidence leaked ${secret}`);
  }
});

test('apply rechecks the exact snapshot, deletes V1 only, and issues zero proof after two complete zero scans', async () => {
  const oldV1 = row('dial:dev:raw-old-device');
  const currentV1 = row('dial:v1:dev:raw-current-device');
  const unrelated = row('receipt:unrelated-row');
  const harness = createHarness({ rows: [oldV1, currentV1, unrelated], pageSize: 2 });
  const plan = await harness.cutover.plan({ binding: BINDING });

  const result = await harness.cutover.apply(applyInput(JSON.parse(JSON.stringify(plan))));

  assert.deepEqual(Object.keys(result).sort(), [
    'assertions',
    'binding',
    'completedAt',
    'confirmation',
    'deleted',
    'digest',
    'digestSemantics',
    'phase',
    'planDigest',
    'preflight',
    'schema',
    'table',
    'verification',
    'zeroProof',
  ]);
  assert.equal(result.schema, REGISTRY_CUTOVER_APPLY_SCHEMA);
  assert.equal(result.phase, 'apply');
  assert.equal(result.digestSemantics, REGISTRY_CUTOVER_DIGEST_SEMANTICS);
  assert.equal(result.planDigest, plan.digest);
  assert.equal(result.assertions.mutationOptIn, true);
  assert.equal(result.assertions.trafficQuiesced, true);
  assert.equal(result.assertions.writerFenceEvidenceDigest, WRITER_FENCE_DIGEST);
  assert.equal(result.assertions.drainEvidenceDigest, DRAIN_EVIDENCE_DIGEST);
  assert.equal(result.assertions.safetyBoundary, 'external-writer-fence-and-drain');
  assert.deepEqual(result.preflight.prefixes, {
    v1: { 'dial:dev:': 1, 'dial:v1:dev:': 1 },
    v2: {
      'dial:install:v2:': 0,
      'dial:token:v2:': 0,
      'dial:target:v2:': 0,
      'dial:regop:v2:': 0,
    },
  });
  assert.equal(result.preflight.scan.complete, true);
  assert.equal(result.preflight.scan.baseTableOnly, true);
  assert.equal(result.preflight.scan.consistentRead, true);
  assert.match(result.preflight.scan.inventoryDigest, /^[a-f0-9]{64}$/);
  assert.match(result.preflight.scan.requestChainDigest, /^[a-f0-9]{64}$/);
  assert.deepEqual(Object.keys(result.preflight).sort(), ['prefixes', 'scan']);
  assert.equal(result.deleted.items, 2);
  assert.deepEqual(result.deleted.prefixes, { 'dial:dev:': 1, 'dial:v1:dev:': 1 });
  assert.equal(result.zeroProof.allSixPrefixesZero, true);
  assert.equal(result.zeroProof.safetyBoundary, 'external-writer-fence-and-drain');
  assert.equal(harness.state.rows.has(keyString(unrelated)), true);
  assert.equal(harness.state.rows.has(keyString(oldV1)), false);
  assert.equal(harness.state.rows.has(keyString(currentV1)), false);
  assert.deepEqual(harness.state.deleteCalls.map(({ prefix }) => prefix).sort(), [...REGISTRY_V1_PREFIXES].sort());
  assert.ok(harness.state.deleteCalls.every(({ key, prefix }) => key.pk.startsWith(prefix)));
  assert.equal(harness.state.describeCalls.length, 6, 'two plan + four apply identity checks');

  const serialized = JSON.stringify(result);
  for (const secret of [
    BINDING.accountId,
    BINDING.tableName,
    BINDING.tableArn,
    harness.state.table.tableId,
    oldV1.pk,
    currentV1.pk,
    'raw-delete-request-1',
  ]) {
    assert.equal(serialized.includes(secret), false, `apply evidence leaked ${secret}`);
  }
});

test('apply requires every explicit phase-two gate and never touches AWS when one is absent', async () => {
  const harness = createHarness({ rows: [row('dial:dev:raw-device')] });
  const plan = await harness.cutover.plan({ binding: BINDING });
  const callsBefore = {
    describe: harness.state.describeCalls.length,
    scan: harness.state.scanCalls.length,
    delete: harness.state.deleteCalls.length,
  };

  await expectCode(
    harness.cutover.apply(applyInput(plan, { allowMutations: false })),
    'mutation-opt-in-required',
  );
  await expectCode(
    harness.cutover.apply(applyInput(plan, { trafficQuiesced: false })),
    'traffic-quiescence-required',
  );
  await expectCode(
    harness.cutover.apply(applyInput(plan, { writerFenceEvidenceDigest: undefined })),
    'writer-fence-evidence-required',
  );
  await expectCode(
    harness.cutover.apply(applyInput(plan, { drainEvidenceDigest: 'B'.repeat(64) })),
    'drain-evidence-required',
  );
  await expectCode(
    harness.cutover.apply(applyInput(plan, { drainEvidenceDigest: WRITER_FENCE_DIGEST })),
    'cutover-evidence-not-distinct',
  );

  assert.deepEqual({
    describe: harness.state.describeCalls.length,
    scan: harness.state.scanCalls.length,
    delete: harness.state.deleteCalls.length,
  }, callsBefore);
});

test('apply rejects a mismatched explicit digest and a tampered plan before any mutation', async () => {
  const harness = createHarness({ rows: [row('dial:dev:raw-device')] });
  const plan = await harness.cutover.plan({ binding: BINDING });
  const callsBefore = harness.state.describeCalls.length;

  await expectCode(
    harness.cutover.apply(applyInput(plan, { expectedPlanDigest: 'c'.repeat(64) })),
    'plan-digest-mismatch',
  );
  const tampered = JSON.parse(JSON.stringify(plan));
  tampered.prefixes.v1['dial:dev:'] = 0;
  await expectCode(harness.cutover.apply(applyInput(tampered)), 'plan-digest-mismatch');

  assert.equal(harness.state.describeCalls.length, callsBefore);
  assert.equal(harness.state.deleteCalls.length, 0);
});

test('binding is exact across account, region, table name, ARN, and the described table', async (t) => {
  const invalidBindings = [
    { ...BINDING, accountId: '999999999999' },
    { ...BINDING, region: 'us-west-2' },
    { ...BINDING, tableName: 'another-table' },
    { ...BINDING, tableArn: BINDING.tableArn.replace('us-east-1', 'us-west-2') },
  ];
  for (const [index, binding] of invalidBindings.entries()) {
    await t.test(`invalid binding ${index + 1}`, async () => {
      const harness = createHarness();
      await expectCode(harness.cutover.plan({ binding }), 'binding-mismatch');
      assert.equal(harness.state.describeCalls.length, 0);
    });
  }

  await t.test('DescribeTable identity mismatch', async () => {
    const harness = createHarness();
    harness.state.table.tableArn = BINDING.tableArn.replace(BINDING.tableName, 'different-table');
    harness.state.table.tableName = 'different-table';
    await expectCode(harness.cutover.plan({ binding: BINDING }), 'binding-mismatch');
    assert.equal(harness.state.scanCalls.length, 0);
  });
});

test('table status, exact string key schema, and absence of global replicas are load-bearing', async (t) => {
  const cases = [
    ['CREATING status', (table) => { table.tableStatus = 'CREATING'; }, 'table-not-active'],
    ['wrong HASH key', (table) => { table.keySchema[0].attributeName = 'id'; }, 'invalid-table-schema'],
    ['numeric sort key', (table) => { table.attributeDefinitions[1].attributeType = 'N'; }, 'invalid-table-schema'],
    ['global replica', (table) => { table.replicas = [{ regionName: 'us-west-2' }]; }, 'global-table-not-supported'],
  ];
  for (const [name, mutate, code] of cases) {
    await t.test(name, async () => {
      const harness = createHarness();
      mutate(harness.state.table);
      await expectCode(harness.cutover.plan({ binding: BINDING }), code);
      assert.equal(harness.state.scanCalls.length, 0);
    });
  }
});

test('table incarnation drift is detected during plan, before apply, and after mutation', async (t) => {
  await t.test('during plan', async () => {
    const harness = createHarness({ rows: [row('dial:dev:raw-device')] });
    harness.state.afterScan = ({ call, state }) => {
      if (call === 1) state.table.tableId = 'replacement-table-id';
    };
    await expectCode(harness.cutover.plan({ binding: BINDING }), 'table-incarnation-drift');
    assert.equal(harness.state.deleteCalls.length, 0);
  });

  await t.test('before apply', async () => {
    const harness = createHarness({ rows: [row('dial:dev:raw-device')] });
    const plan = await harness.cutover.plan({ binding: BINDING });
    harness.state.table.tableId = 'replacement-table-id';
    await expectCode(harness.cutover.apply(applyInput(plan)), 'table-incarnation-drift');
    assert.equal(harness.state.deleteCalls.length, 0);
  });

  await t.test('after a delete', async () => {
    const harness = createHarness({ rows: [row('dial:dev:raw-device')] });
    const plan = await harness.cutover.plan({ binding: BINDING });
    harness.state.afterDelete = ({ state }) => { state.table.tableId = 'replacement-table-id'; };
    await expectCode(harness.cutover.apply(applyInput(plan)), 'table-incarnation-drift');
    assert.equal(harness.state.deleteCalls.length, 1);
  });
});

test('pagination fails closed on cursor cycles, duplicate keys, malformed items, and non-final cursors', async (t) => {
  await t.test('cursor cycle', async () => {
    const first = row('other:a');
    const harness = createHarness({ rows: [first] });
    harness.state.scanOverride = ({ call }) => ({
      items: [first],
      lastEvaluatedKey: first,
      requestId: `scan-${call}`,
    });
    await expectCode(harness.cutover.plan({ binding: BINDING }), 'scan-key-duplicate');
  });

  await t.test('duplicate key on a later page', async () => {
    const first = row('other:a');
    const second = row('other:b');
    const harness = createHarness({ rows: [first, second] });
    harness.state.scanOverride = ({ call }) => call === 1
      ? { items: [first, second], lastEvaluatedKey: second, requestId: 'scan-1' }
      : { items: [first], requestId: 'scan-2' };
    await expectCode(harness.cutover.plan({ binding: BINDING }), 'scan-key-duplicate');
  });

  await t.test('item carries an unprojected value', async () => {
    const harness = createHarness();
    harness.state.scanOverride = () => ({
      items: [{ pk: 'other:a', sk: 'record', secret: 'must-not-enter-core' }],
      requestId: 'scan-1',
    });
    await expectCode(harness.cutover.plan({ binding: BINDING }), 'invalid-scan-item');
  });

  await t.test('cursor is not the final returned key', async () => {
    const harness = createHarness();
    harness.state.scanOverride = () => ({
      items: [row('other:a'), row('other:b')],
      lastEvaluatedKey: row('other:a'),
      requestId: 'scan-1',
    });
    await expectCode(harness.cutover.plan({ binding: BINDING }), 'invalid-scan-cursor');
  });

  await t.test('key exceeds the UTF-8 byte cap', async () => {
    const harness = createHarness();
    harness.state.scanOverride = () => ({
      items: [row('x'.repeat(REGISTRY_CUTOVER_MAX_PK_BYTES + 1))],
      requestId: 'scan-1',
    });
    await expectCode(harness.cutover.plan({ binding: BINDING }), 'invalid-scan-item');
  });
});

test('mandatory request IDs fail closed and are never replaced with local guesses', async (t) => {
  await t.test('DescribeTable request ID', async () => {
    const harness = createHarness();
    harness.state.describeOverride = ({ defaultResult }) => ({ ...defaultResult, requestId: '' });
    await expectCode(harness.cutover.plan({ binding: BINDING }), 'invalid-table-description');
  });

  await t.test('Scan request ID', async () => {
    const harness = createHarness();
    harness.state.scanOverride = ({ defaultResult }) => ({ ...defaultResult, requestId: undefined });
    await expectCode(harness.cutover.plan({ binding: BINDING }), 'invalid-scan-page');
  });

  await t.test('Delete request ID after a mutation still prevents proof', async () => {
    const harness = createHarness({ rows: [row('dial:dev:raw-device')] });
    const plan = await harness.cutover.plan({ binding: BINDING });
    harness.state.deleteOverride = ({ input, state }) => {
      state.rows.delete(keyString(input.key));
      return { requestId: '' };
    };
    await expectCode(harness.cutover.apply(applyInput(plan)), 'invalid-delete-response');
    assert.equal(harness.state.deleteCalls.length, 1);
  });
});

test('apply refuses stale plans and checks the fixed deadline before and after every mutation', async (t) => {
  await t.test('already expired', async () => {
    const harness = createHarness({ rows: [row('dial:dev:raw-device')] });
    const plan = await harness.cutover.plan({ binding: BINDING });
    harness.state.now = NOW + REGISTRY_CUTOVER_PLAN_MAX_AGE_MS;
    await expectCode(harness.cutover.apply(applyInput(plan)), 'plan-expired');
    assert.equal(harness.state.describeCalls.length, 2);
    assert.equal(harness.state.deleteCalls.length, 0);
  });

  await t.test('clock regresses behind plan', async () => {
    const harness = createHarness({ rows: [row('dial:dev:raw-device')] });
    const plan = await harness.cutover.plan({ binding: BINDING });
    harness.state.now = NOW - 1;
    await expectCode(harness.cutover.apply(applyInput(plan)), 'clock-regressed');
    assert.equal(harness.state.deleteCalls.length, 0);
  });

  await t.test('deadline expires during a delete', async () => {
    const harness = createHarness({ rows: [row('dial:dev:raw-device')] });
    const plan = await harness.cutover.plan({ binding: BINDING });
    harness.state.afterDelete = ({ state }) => {
      state.now = NOW + REGISTRY_CUTOVER_PLAN_MAX_AGE_MS;
    };
    await expectCode(harness.cutover.apply(applyInput(plan)), 'plan-expired');
    assert.equal(harness.state.deleteCalls.length, 1);
    assert.equal(harness.state.scanCalls.length, 2, 'plan + preflight only; no final zero scan');
  });
});

test('any six-prefix drift after planning aborts before the first delete', async (t) => {
  await t.test('new V1 row', async () => {
    const harness = createHarness({ rows: [row('dial:dev:raw-device')] });
    const plan = await harness.cutover.plan({ binding: BINDING });
    harness.add(row('dial:v1:dev:late-writer'));
    await expectCode(harness.cutover.apply(applyInput(plan)), 'plan-drift');
    assert.equal(harness.state.deleteCalls.length, 0);
  });

  await t.test('new V2 row', async () => {
    const harness = createHarness({ rows: [row('dial:dev:raw-device')] });
    const plan = await harness.cutover.plan({ binding: BINDING });
    harness.add(row('dial:install:v2:late-writer'));
    await expectCode(harness.cutover.apply(applyInput(plan)), 'plan-drift');
    assert.equal(harness.state.deleteCalls.length, 0);
  });

  await t.test('removed planned row', async () => {
    const planned = row('dial:dev:raw-device');
    const harness = createHarness({ rows: [planned] });
    const plan = await harness.cutover.plan({ binding: BINDING });
    harness.remove(planned);
    await expectCode(harness.cutover.apply(applyInput(plan)), 'plan-drift');
    assert.equal(harness.state.deleteCalls.length, 0);
  });
});

test('a plan with any V2 row can never enter the delete phase', async () => {
  const harness = createHarness({
    rows: [row('dial:dev:raw-v1'), row('dial:target:v2:raw-v2')],
  });
  const plan = await harness.cutover.plan({ binding: BINDING });
  assert.equal(plan.applyEligible, false);

  await expectCode(harness.cutover.apply(applyInput(plan)), 'v2-prefix-not-empty');
  assert.equal(harness.state.deleteCalls.length, 0);
  assert.equal(harness.state.rows.size, 2);
});

test('partial delete failure stops immediately and never fabricates zero proof', async () => {
  const harness = createHarness({
    rows: [row('dial:dev:first'), row('dial:v1:dev:second')],
    pageSize: 10,
  });
  const plan = await harness.cutover.plan({ binding: BINDING });
  harness.state.deleteOverride = ({ call, input, state }) => {
    if (call === 2) throw new Error('raw sensitive delete failure');
    state.rows.delete(keyString(input.key));
    return { requestId: `delete-${call}` };
  };

  await assert.rejects(harness.cutover.apply(applyInput(plan)), (error) => {
    assert.equal(error.code, 'delete-failed');
    assert.equal(error.details.deletedItems, 1);
    assert.equal(JSON.stringify(error).includes('raw sensitive'), false);
    return true;
  });
  assert.equal(harness.state.deleteCalls.length, 2);
  assert.equal(harness.state.scanCalls.length, 2, 'no verification scan follows a partial delete failure');
});

test('writer races visible in either final scan fail closed without zero proof', async (t) => {
  await t.test('row reappears before verification', async () => {
    const harness = createHarness({ rows: [row('dial:dev:planned')] });
    const plan = await harness.cutover.plan({ binding: BINDING });
    harness.state.afterDelete = ({ state }) => {
      state.rows.set(keyString(row('dial:dev:raced')), row('dial:dev:raced'));
    };
    await expectCode(harness.cutover.apply(applyInput(plan)), 'verification-not-zero');
  });

  await t.test('row appears between verification and confirmation', async () => {
    const harness = createHarness({ rows: [row('dial:dev:planned')] });
    const plan = await harness.cutover.plan({ binding: BINDING });
    harness.state.afterScan = ({ call, state }) => {
      // Call 1 is plan, call 2 preflight, call 3 the first final zero scan.
      if (call === 3) state.rows.set(keyString(row('dial:v1:dev:raced')), row('dial:v1:dev:raced'));
    };
    await expectCode(harness.cutover.apply(applyInput(plan)), 'race-detected');
  });
});

test('unrelated table traffic does not create false registry drift or prevent an all-six zero proof', async () => {
  const harness = createHarness({ rows: [row('dial:dev:planned'), row('receipt:before')] });
  const plan = await harness.cutover.plan({ binding: BINDING });
  harness.add(row('receipt:after-plan'));

  const result = await harness.cutover.apply(applyInput(plan));

  assert.equal(result.zeroProof.allSixPrefixesZero, true);
  assert.equal(harness.state.rows.size, 2);
  assert.ok([...harness.state.rows.values()].every(({ pk }) => pk.startsWith('receipt:')));
});

test('constructor and callback response shapes fail closed', async (t) => {
  assert.throws(() => createRegistryCutover(), /requires describeTable, scanPage, and deleteItem/);
  assert.throws(
    () => createRegistryCutover({ describeTable() {}, scanPage() {}, deleteItem() {}, now: 1 }),
    /now must be a function/,
  );

  await t.test('scan response extras are rejected', async () => {
    const harness = createHarness();
    harness.state.scanOverride = ({ defaultResult }) => ({ ...defaultResult, consumedCapacity: 'raw' });
    await expectCode(harness.cutover.plan({ binding: BINDING }), 'invalid-scan-page');
  });

  await t.test('describe response extras are rejected', async () => {
    const harness = createHarness();
    harness.state.describeOverride = ({ defaultResult }) => ({ ...defaultResult, itemCount: 0 });
    await expectCode(harness.cutover.plan({ binding: BINDING }), 'invalid-table-description');
  });
});
