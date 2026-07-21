import { randomUUID } from 'node:crypto';
// store.mjs — pluggable ASYNC store for the gateway (Echo P0: production exactly-once across Lambda instances).
//
// The governed-writeback core (executeAction) is synchronous and per-request. Cross-INSTANCE exactly-once needs a
// distributed store with two atomic primitives:
//   - acquireLock(key)/releaseLock(key): a short-TTL mutex so only one instance runs the post for a proposal.id.
//   - get(key)/put(key,value): durable record of the terminal receipt OR the emitted marker (so a later request on a
//     DIFFERENT instance loads the emitted actionId and RE-VERIFIES instead of re-posting).
//
// PROD adapter (DynamoDB) — documented contract, not deployed here (no AWS creds in this env):
//   acquireLock  -> PutItem {pk:key, sk:'lock', ttl:now+30s} with ConditionExpression attribute_not_exists(pk)
//                   (ConditionalCheckFailed => lock held => return false)
//   releaseLock  -> DeleteItem {pk:key, sk:'lock'}
//   get/put      -> GetItem/PutItem {pk:key, sk:'record'}
//   putIfAbsent  -> PutItem ConditionExpression attribute_not_exists(pk) (ConditionalCheckFailed => false)
// The TTL on the lock self-heals a crash-before-release; the record has no TTL (idempotency is durable).

/**
 * In-memory store — single process, so the primitives are trivially atomic. Used for dev + hermetic tests.
 * acquireLock returns an OWNER TOKEN (or null if held); releaseLock only releases if the caller still owns it
 * (fencing) — so a lock that expired and was re-acquired by another instance is never released out from under it.
 */
export function createInMemoryStore() {
  const records = new Map();
  const locks = new Map(); // key -> owner token
  return {
    async get(key) { return records.get(key); },
    async put(key, value) { records.set(key, value); return value; },
    async delete(key) { records.delete(key); },
    /** returns a fresh owner token if acquired; null if already held. */
    async acquireLock(key) { if (locks.has(key)) return null; const token = randomUUID(); locks.set(key, token); return token; },
    /** fenced release: no-op unless the caller's token still owns the lock. */
    async releaseLock(key, token) { if (locks.get(key) === token) locks.delete(key); },
    /** atomic reserve: true if stored, false if the key already existed. */
    async putIfAbsent(key, value) { if (records.has(key)) return false; records.set(key, value); return true; },
    // test/debug introspection only
    _records: records,
    _locks: locks,
  };
}

/**
 * DynamoDB-backed store for PROD cross-instance exactly-once. Zero-dep: the caller injects a DocumentClient-like
 * `client` with async get/put/delete (deploy wires @aws-sdk/lib-dynamodb). Lock + putIfAbsent use a conditional
 * put (attribute_not_exists) so they are atomic across Lambda instances; the lock item carries a TTL that self-heals
 * a crash-before-release. Records (idempotency/emitted markers) are durable with no TTL.
 * @param {{ client:object, table:string, ttlSeconds?:number, now?:()=>number }} cfg
 */
export function createDynamoStore(cfg = {}) {
  const { client, table, ttlSeconds = 900, now = () => Date.now() } = cfg;
  if (!client || !table) throw new Error('createDynamoStore requires { client, table }');
  const rk = (key) => ({ pk: key, sk: 'record' });
  const lk = (key) => ({ pk: key, sk: 'lock' });
  const isCond = (e) => e && (e.name === 'ConditionalCheckFailedException' || e.code === 'ConditionalCheckFailedException');
  const nowSec = () => Math.floor(now() / 1000);
  return {
    async get(key) { const r = await client.get({ TableName: table, Key: rk(key) }); return r && r.Item ? r.Item.value : undefined; },
    async put(key, value) { await client.put({ TableName: table, Item: { ...rk(key), value } }); return value; },
    async delete(key) { await client.delete({ TableName: table, Key: rk(key) }); },
    async acquireLock(key) {
      const token = randomUUID();
      // Acquire if no lock exists OR the existing lock is LOGICALLY EXPIRED (ttl < now). DynamoDB TTL DELETION lags
      // (can be hours), so we must not wait for it (Echo P1). `#ttl` aliases the attribute name defensively.
      try {
        await client.put({
          TableName: table,
          Item: { ...lk(key), owner: token, ttl: nowSec() + ttlSeconds },
          ConditionExpression: 'attribute_not_exists(pk) OR #ttl <= :now',
          ExpressionAttributeNames: { '#ttl': 'ttl' },
          ExpressionAttributeValues: { ':now': nowSec() },
        });
        return token;
      } catch (e) { if (isCond(e)) return null; throw e; }
    },
    async releaseLock(key, token) {
      // FENCED: delete ONLY if we still own it (a TTL-expired + re-acquired lock is never released out from under
      // its new owner). `owner` is a DynamoDB RESERVED WORD => alias via #o (Echo P1), else the delete errors.
      try { await client.delete({ TableName: table, Key: lk(key), ConditionExpression: '#o = :t', ExpressionAttributeNames: { '#o': 'owner' }, ExpressionAttributeValues: { ':t': token } }); }
      catch (e) { if (isCond(e)) return; throw e; }
    },
    async putIfAbsent(key, value, opts = {}) {
      // optional TOP-LEVEL `ttl` (absolute epoch-seconds) so DynamoDB TTL can expire the item — e.g. DPoP jti replay
      // records, which must NOT be nested under `value` where TTL can't see them (Echo P1).
      const item = { ...rk(key), value };
      if (Number.isFinite(opts.ttlEpochSec)) item.ttl = opts.ttlEpochSec;
      try {
        await client.put({ TableName: table, Item: item, ConditionExpression: 'attribute_not_exists(pk)' });
        return true;
      } catch (e) { if (isCond(e)) return false; throw e; }
    },
  };
}

/**
 * PROD DEPLOY SEAM — adapt a v3 `@aws-sdk/lib-dynamodb` DocumentClient to the `{ get, put, delete }` async contract that
 * `createDynamoStore` CONSUMES. The v3 DocumentClient exposes `.send(new GetCommand(params))`, NOT bare
 * get/put/delete-returning-promises (that was the aws-sdk v2 DocumentClient shape). This thin wrapper is the ONLY place
 * that knows the v3 Command API, so `createDynamoStore` stays SDK-agnostic + hermetically testable against a plain fake.
 *
 * The Command classes are INJECTED (not imported) so this module stays ZERO-DEP + testable WITHOUT `@aws-sdk` installed:
 * the deploy passes the real `{ GetCommand, PutCommand, DeleteCommand }`; tests pass fakes that capture their params.
 *
 * SHAPE CONTRACT (must match what `createDynamoStore` reads — see its get / acquireLock / putIfAbsent):
 *   - `get` MUST resolve to the FULL response `{ Item }` (the store reads `r.Item.value`) — NOT a bare `r.Item`.
 *     Returning `r.Item` would make every record read `undefined` → idempotency/emitted-marker misses → DUPLICATE posts.
 *   - `put`/`delete`: the return value is unused by the store, but a thrown `ConditionalCheckFailedException` MUST
 *     propagate UNCHANGED (the store's `isCond()` keys on `e.name`/`e.code`). So this wrapper does NO try/catch — throws
 *     pass straight through.
 *
 * @param {{ send:Function }} docClient  a v3 DynamoDBDocumentClient (`DynamoDBDocumentClient.from(new DynamoDBClient())`)
 * @param {{ GetCommand:Function, PutCommand:Function, DeleteCommand:Function }} commands  lib-dynamodb Command classes
 * @returns {{ get:Function, put:Function, delete:Function }}  exactly the shape `createDynamoStore({ client })` expects
 */
export function createDynamoClientAdapter(docClient, commands = {}) {
  if (!docClient || typeof docClient.send !== 'function') throw new Error('createDynamoClientAdapter: a v3 DynamoDBDocumentClient (with .send) is required');
  const { GetCommand, PutCommand, DeleteCommand } = commands;
  if (typeof GetCommand !== 'function' || typeof PutCommand !== 'function' || typeof DeleteCommand !== 'function') {
    throw new Error('createDynamoClientAdapter: { GetCommand, PutCommand, DeleteCommand } from @aws-sdk/lib-dynamodb must be injected');
  }
  return {
    // Return the FULL send() response ({ Item, $metadata, ... }); the store reads `r.Item.value`. Do NOT `.then(r=>r.Item)`.
    get: (params) => docClient.send(new GetCommand(params)),
    // Return unused by the store; a ConditionalCheckFailedException propagates unchanged (no try/catch here — by design).
    put: (params) => docClient.send(new PutCommand(params)),
    delete: (params) => docClient.send(new DeleteCommand(params)),
  };
}

/**
 * Store-backed DPoP jti replay guard (prod): single-use jti across instances via an atomic putIfAbsent. `seen`
 * returns true iff the jti was already recorded (a replay). Shape mirrors createInMemoryReplayGuard (auth.mjs).
 */
export function createStoreReplayGuard(store, { prefix = 'dpop-jti:' } = {}) {
  return {
    async seen(jti, expiresAtSec) {
      // ttlEpochSec sets a TOP-LEVEL DynamoDB ttl so the jti record self-expires at the proof's window end (Echo P1).
      const stored = await store.putIfAbsent(prefix + jti, { exp: expiresAtSec }, { ttlEpochSec: expiresAtSec });
      return !stored; // putIfAbsent false => key already existed => replay
    },
  };
}

/**
 * Run `fn` while holding the store's cross-instance lock for `key`. Releases in a finally (even on throw).
 * Returns { locked:false } without running fn if the lock is already held (caller decides 409 vs retry).
 */
export async function withLock(store, key, fn) {
  const token = await store.acquireLock(key); // owner token, or null if held
  if (!token) return { locked: false };
  try {
    return { locked: true, value: await fn() };
  } finally {
    await store.releaseLock(key, token); // fenced release (only if we still own it)
  }
}
