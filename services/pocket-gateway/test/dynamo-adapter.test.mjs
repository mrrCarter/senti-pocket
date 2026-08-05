// dynamo-adapter.test.mjs — the PROD DEPLOY SEAM: createDynamoClientAdapter over a v3 DocumentClient's .send(Command).
//
// SHAPE-PROVEN, LIVE-UNVERIFIED (warden scope). These tests prove the adapter produces the exact
// { get, put, delete, transactWrite? } shape consumed by the stores and Registry V2 — including the full { Item }
// response for get (not a stripped r.Item) and unchanged AWS exceptions — using fake commands + a fake .send. They do
// NOT exercise real AWS, so they do NOT discharge the three real-AWS confirmations that remain AWS-day:
//   (1) the real @aws-sdk client surfaces a failed condition as e.name/e.code === 'ConditionalCheckFailedException';
//   (2) real DynamoDB TTL deletion behavior; (3) the table's TTL attribute is configured on `ttl`.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { DEVICE_REGISTRATION_VERSION, createDynamoDeviceRegistryV2 } from '../src/device-registry-v2.mjs';
import { createDynamoClientAdapter, createDynamoStore, withLock } from '../src/store.mjs';

// Fake v3 lib-dynamodb Command classes — capture the params + tag which command (the real classes carry `.input`).
class GetCommand { constructor(input) { this.input = input; this.__kind = 'Get'; } }
class PutCommand { constructor(input) { this.input = input; this.__kind = 'Put'; } }
class DeleteCommand { constructor(input) { this.input = input; this.__kind = 'Delete'; } }
class TransactWriteCommand { constructor(input) { this.input = input; this.__kind = 'TransactWrite'; } }
const COMMANDS = { GetCommand, PutCommand, DeleteCommand };
const V2_COMMANDS = { ...COMMANDS, TransactWriteCommand };

function throwCond() { const e = new Error('The conditional request failed'); e.name = 'ConditionalCheckFailedException'; throw e; }

// A fake DocumentClient whose .send(command) records the call + defers to a behavior fn (returns a response OR throws).
function fakeDoc(behavior) {
  const calls = [];
  return { calls, async send(command) { calls.push({ kind: command.__kind, input: command.input }); return behavior ? behavior(command) : {}; } };
}

// ---------- shape / routing ----------
test('adapter routes get->GetCommand, put->PutCommand, delete->DeleteCommand with the EXACT params', async () => {
  const doc = fakeDoc((cmd) => (cmd.__kind === 'Get' ? { Item: { value: { ok: 1 } } } : {}));
  const a = createDynamoClientAdapter(doc, COMMANDS);
  await a.get({ TableName: 't', Key: { pk: 'a', sk: 'record' } });
  await a.put({ TableName: 't', Item: { pk: 'a', sk: 'record', value: 1 } });
  await a.delete({ TableName: 't', Key: { pk: 'a', sk: 'lock' } });
  assert.deepEqual(doc.calls.map((c) => c.kind), ['Get', 'Put', 'Delete'], 'each store method maps to its Command class');
  assert.deepEqual(doc.calls[0].input, { TableName: 't', Key: { pk: 'a', sk: 'record' } });
  assert.deepEqual(doc.calls[1].input, { TableName: 't', Item: { pk: 'a', sk: 'record', value: 1 } });
  assert.deepEqual(doc.calls[2].input, { TableName: 't', Key: { pk: 'a', sk: 'lock' } });
  assert.equal(Object.hasOwn(a, 'query'), false);
  assert.equal(Object.hasOwn(a, 'transactWrite'), false);
});

test('adapter routes optional transactWrite through the exact injected command', async () => {
  const doc = fakeDoc();
  const adapter = createDynamoClientAdapter(doc, V2_COMMANDS);
  const transaction = { TransactItems: [{ Put: { TableName: 't', Item: { pk: 'i', sk: 'binding' } } }] };
  await adapter.transactWrite(transaction);
  assert.deepEqual(doc.calls, [{ kind: 'TransactWrite', input: transaction }]);
});

test('adapter.get resolves the FULL { Item } response (NOT a stripped r.Item) — store.get reads r.Item.value', async () => {
  const doc = fakeDoc(() => ({ Item: { pk: 'a', sk: 'record', value: { status: 'posted' } }, $metadata: { httpStatusCode: 200 } }));
  const r = await createDynamoClientAdapter(doc, COMMANDS).get({ TableName: 't', Key: { pk: 'a', sk: 'record' } });
  // The regression this guards: returning `r.Item` (a `.then(r=>r.Item)` wrapper) would make store.get read undefined
  // for EVERY record -> idempotency/emitted-marker misses -> duplicate governed posts.
  assert.ok(r && r.Item, 'adapter.get must return { Item } so store.get can read r.Item.value');
  assert.deepEqual(r.Item.value, { status: 'posted' });
});

test('adapter propagates ConditionalCheckFailedException UNCHANGED (name AND code) so store.isCond() catches it', async () => {
  const byName = createDynamoClientAdapter(fakeDoc(() => throwCond()), COMMANDS);
  await assert.rejects(byName.put({ TableName: 't', Item: {} }), (e) => e.name === 'ConditionalCheckFailedException');
  // Some SDK paths surface `.code` instead of `.name`; store.isCond keys on BOTH — prove either flavor passes through.
  const byCode = createDynamoClientAdapter(fakeDoc(() => { const e = new Error('cond'); e.code = 'ConditionalCheckFailedException'; throw e; }), COMMANDS);
  await assert.rejects(byCode.delete({ TableName: 't', Key: {} }), (e) => e.code === 'ConditionalCheckFailedException');
});

test('factory validates its inputs (fail-closed)', () => {
  assert.throws(() => createDynamoClientAdapter(null, COMMANDS), /DynamoDBDocumentClient/);
  assert.throws(() => createDynamoClientAdapter({}, COMMANDS), /DynamoDBDocumentClient/);            // no .send
  assert.throws(() => createDynamoClientAdapter(fakeDoc(), {}), /GetCommand, PutCommand, DeleteCommand/);
  assert.throws(() => createDynamoClientAdapter(fakeDoc(), { GetCommand, PutCommand }), /must be injected/); // missing DeleteCommand
  const transactionOnly = createDynamoClientAdapter(fakeDoc(), { ...COMMANDS, TransactWriteCommand });
  assert.equal(typeof transactionOnly.transactWrite, 'function');
  assert.equal(Object.hasOwn(transactionOnly, 'query'), false);
});

test('Registry V2 retries the real JavaScript message-form cancellation through the v3 adapter seam', async () => {
  const cancellation = Object.assign(
    new Error(
      'Transaction cancelled, please refer cancellation reasons for specific reasons [None, ConditionalCheckFailed, None]',
    ),
    {
      name: 'TransactionCanceledException',
      $fault: 'client',
      $metadata: {
        httpStatusCode: 400,
        requestId: 'test-request-id',
        attempts: 1,
        totalRetryDelay: 0,
      },
      CancellationReasons: undefined,
    },
  );
  let transactionCalls = 0;
  const doc = fakeDoc((command) => {
    if (command.__kind === 'Get') return {};
    if (command.__kind === 'TransactWrite') {
      transactionCalls += 1;
      if (transactionCalls === 1) throw cancellation;
      return {};
    }
    throw new Error(`unexpected command: ${command.__kind}`);
  });
  const delays = [];
  const registry = createDynamoDeviceRegistryV2({
    client: createDynamoClientAdapter(doc, V2_COMMANDS),
    table: 'Pocket',
    hmacKey: Buffer.alloc(32, 0x5a),
    now: () => Date.parse('2026-07-31T06:00:00.000Z'),
    retryDelay: async (attempt) => {
      delays.push(attempt);
    },
  });
  const result = await registry.register({
    principal: 'principal',
    humanId: 'human',
    registrationVersion: DEVICE_REGISTRATION_VERSION,
    installationId: Buffer.alloc(32, 0x31).toString('base64url'),
    idempotencyKey: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    voipToken: 'aabbccddeeff',
    sessionId: 'session',
    platform: 'apns',
  });
  assert.match(result.bindingId, /^bind_/);
  assert.equal(transactionCalls, 2);
  assert.deepEqual(delays, [1]);
  assert.equal(Object.hasOwn(cancellation, 'CancellationReasons'), true);
  assert.equal(cancellation.CancellationReasons, undefined);
});

// ---------- INTEGRATION: adapter shape == createDynamoStore's consumed contract (warden gate #1) ----------
// Wire the adapter into the REAL createDynamoStore over a fake .send that MODELS DynamoDB's conditional puts, then run
// the store's own semantics through it. If the adapter shape were wrong (e.g. the .then(r=>r.Item) trap), store.get
// would read undefined and the lock/reserve conditionals would not surface — these assertions would fail.
function fakeSendBackedDynamo() {
  const items = new Map(); // "pk sk" -> item
  const k = (K) => K.pk + ' ' + K.sk;
  return {
    items,
    async send(command) {
      const { __kind: kind, input } = command;
      if (kind === 'Get') return { Item: items.get(k(input.Key)) };
      if (kind === 'Put') {
        const key = k(input.Item);
        const ce = input.ConditionExpression;
        if (ce) {
          const cur = items.get(key);
          const nowV = input.ExpressionAttributeValues && input.ExpressionAttributeValues[':now'];
          if (ce === 'attribute_not_exists(pk)') { if (cur) throwCond(); }
          else if (ce === 'attribute_not_exists(pk) OR #ttl <= :now') {
            const expired = cur && Number.isFinite(cur.ttl) && Number.isFinite(nowV) && cur.ttl <= nowV; // <= : reacquire AT expiry
            if (cur && !expired) throwCond();
          } else throw new Error('unmodeled put ConditionExpression: ' + ce);
        }
        items.set(key, input.Item);
        return {};
      }
      if (kind === 'Delete') {
        const key = k(input.Key);
        const ce = input.ConditionExpression;
        if (ce === '#o = :t') {
          const attr = input.ExpressionAttributeNames['#o'];
          const item = items.get(key);
          if (!item || item[attr] !== input.ExpressionAttributeValues[':t']) throwCond(); // fenced
        } else if (ce) throw new Error('unmodeled delete ConditionExpression: ' + ce);
        items.delete(key);
        return {};
      }
      throw new Error('unmodeled command kind: ' + kind);
    },
  };
}

test('INTEGRATION: createDynamoStore over the adapter — get/put + owner-fenced lock + putIfAbsent all work', async () => {
  const client = createDynamoClientAdapter(fakeSendBackedDynamo(), COMMANDS);
  const store = createDynamoStore({ client, table: 'pocket', now: () => 1_000_000_000_000 });

  // record roundtrip — proves the { Item }.value shape flows through the adapter
  assert.equal(await store.get('k1'), undefined);
  await store.put('k1', { status: 'posted' });
  assert.deepEqual(await store.get('k1'), { status: 'posted' });

  // owner-fenced lock via conditional put/delete THROUGH the adapter
  const t1 = await store.acquireLock('k1');
  assert.ok(t1);
  assert.equal(await store.acquireLock('k1'), null, 'second acquire blocked (CCFE passed through the adapter)');
  await store.releaseLock('k1', 'not-owner');
  assert.equal(await store.acquireLock('k1'), null, 'still held after a non-owner release (fenced)');
  await store.releaseLock('k1', t1);
  assert.ok(await store.acquireLock('k1'), 'released lock re-acquirable');

  // atomic reserve
  assert.equal(await store.putIfAbsent('k2', { v: 1 }), true);
  assert.equal(await store.putIfAbsent('k2', { v: 2 }), false, 'reserve is atomic through the adapter');
  assert.deepEqual(await store.get('k2'), { v: 1 });
});

test('INTEGRATION: a logically-expired lock is re-acquirable through the adapter (ttl <= now)', async () => {
  let clock = 2_000_000_000_000;
  const store = createDynamoStore({ client: createDynamoClientAdapter(fakeSendBackedDynamo(), COMMANDS), table: 'pocket', ttlSeconds: 10, now: () => clock });
  assert.ok(await store.acquireLock('kb'));
  assert.equal(await store.acquireLock('kb'), null, 'held while fresh');
  clock += 10_000; // exactly ttlSeconds later => stored ttl == now
  assert.ok(await store.acquireLock('kb'), 're-acquired at expiry through the adapter (uses <=, not <)');
});

test('INTEGRATION: withLock over the adapter-backed store serializes; a held key returns { locked:false }', async () => {
  const store = createDynamoStore({ client: createDynamoClientAdapter(fakeSendBackedDynamo(), COMMANDS), table: 'pocket', now: () => 1_000_000_000 });
  assert.deepEqual(await withLock(store, 'kx', async () => 42), { locked: true, value: 42 });
  await store.acquireLock('kheld');
  assert.deepEqual(await withLock(store, 'kheld', async () => { throw new Error('should not run'); }), { locked: false });
});
