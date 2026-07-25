// store.test.mjs — the shared TTL write-option contract for put/putIfAbsent (Pulse #78 R7). ABSENT/undefined -> durable
// (backward-compatible); PRESENT-invalid (string/NaN/Infinity/null/nonpositive/fractional/unsafe) -> fail closed BEFORE any
// write on BOTH adapters; valid -> a top-level Dynamo `ttl`; the option value is read EXACTLY once (getter TOCTOU-safe).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createInMemoryStore, createDynamoStore } from '../src/store.mjs';

const VALID = 1_770_000_900;
const BAD = ['900', NaN, Infinity, -Infinity, 0, -1, 1.5, Number.MAX_VALUE, Number.MAX_SAFE_INTEGER + 1, true, null];

function fakeClient() {
  const puts = [];
  return { puts, async get() { return undefined; }, async put(p) { puts.push(p); return {}; }, async delete() {} };
}

test('put: omitted ttl option -> durable (no ttl attr), backward-compatible', async () => {
  assert.deepEqual(await createInMemoryStore().put('k', { v: 1 }), { v: 1 });
  const c = fakeClient();
  await createDynamoStore({ client: c, table: 'T' }).put('k', { v: 1 });
  assert.equal(Object.hasOwn(c.puts[0].Item, 'ttl'), false, 'no ttl when option omitted');
  const c2 = fakeClient();
  await createDynamoStore({ client: c2, table: 'T' }).put('k', { v: 1 }, {}); // empty opts -> durable
  assert.equal(Object.hasOwn(c2.puts[0].Item, 'ttl'), false);
});

test('put: explicit undefined ttlEpochSec -> durable (counts as absent, backward-compat)', async () => {
  const c = fakeClient();
  await createDynamoStore({ client: c, table: 'T' }).put('k', { v: 1 }, { ttlEpochSec: undefined });
  assert.equal(Object.hasOwn(c.puts[0].Item, 'ttl'), false);
  await assert.doesNotReject(createInMemoryStore().put('k', { v: 1 }, { ttlEpochSec: undefined }));
});

test('put: valid ttlEpochSec -> top-level Dynamo ttl exact', async () => {
  const c = fakeClient();
  await createDynamoStore({ client: c, table: 'T' }).put('k', { v: 1 }, { ttlEpochSec: VALID });
  assert.equal(c.puts[0].Item.ttl, VALID);
});

test('put + putIfAbsent: PRESENT-invalid ttlEpochSec FAILS CLOSED on BOTH adapters, before any write', async () => {
  for (const bad of BAD) {
    const mem = createInMemoryStore();
    await assert.rejects(mem.put('k', { v: 1 }, { ttlEpochSec: bad }), /positive safe integer/, `mem put rejects ${String(bad)}`);
    await assert.rejects(mem.putIfAbsent('k', { v: 1 }, { ttlEpochSec: bad }), /positive safe integer/, `mem putIfAbsent rejects ${String(bad)}`);
    assert.equal(mem._records.size, 0, `no in-memory write for ${String(bad)}`);
    const c = fakeClient();
    await assert.rejects(createDynamoStore({ client: c, table: 'T' }).put('k', { v: 1 }, { ttlEpochSec: bad }), /positive safe integer/, `dynamo put rejects ${String(bad)}`);
    await assert.rejects(createDynamoStore({ client: c, table: 'T' }).putIfAbsent('k', { v: 1 }, { ttlEpochSec: bad }), /positive safe integer/);
    assert.equal(c.puts.length, 0, `no dynamo write for ${String(bad)} (fail closed BEFORE write)`);
  }
});

test('ttl option value is read EXACTLY ONCE (getter TOCTOU-safe)', async () => {
  let reads = 0;
  const opts = { get ttlEpochSec() { reads += 1; return VALID; } };
  const c = fakeClient();
  await createDynamoStore({ client: c, table: 'T' }).put('k', { v: 1 }, opts);
  assert.equal(reads, 1, 'getter evaluated exactly once');
  assert.equal(c.puts[0].Item.ttl, VALID);
});

test('putIfAbsent keeps atomic-reserve semantics with a valid ttl (conditional put + top-level ttl)', async () => {
  const c = fakeClient();
  const d = createDynamoStore({ client: c, table: 'T' });
  assert.equal(await d.putIfAbsent('k', { v: 1 }, { ttlEpochSec: VALID }), true);
  assert.equal(c.puts[0].Item.ttl, VALID);
  assert.equal(c.puts[0].ConditionExpression, 'attribute_not_exists(pk)', 'still conditional (atomic reserve)');
});