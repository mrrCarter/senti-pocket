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

/** In-memory store — single process, so the primitives are trivially atomic. Used for dev + hermetic tests. */
export function createInMemoryStore() {
  const records = new Map();
  const locks = new Set();
  return {
    async get(key) { return records.get(key); },
    async put(key, value) { records.set(key, value); return value; },
    async delete(key) { records.delete(key); },
    /** true if acquired; false if already held (mirrors DynamoDB conditional-put lock). */
    async acquireLock(key) { if (locks.has(key)) return false; locks.add(key); return true; },
    async releaseLock(key) { locks.delete(key); },
    /** atomic reserve: true if stored, false if the key already existed. */
    async putIfAbsent(key, value) { if (records.has(key)) return false; records.set(key, value); return true; },
    // test/debug introspection only
    _records: records,
    _locks: locks,
  };
}

/**
 * Run `fn` while holding the store's cross-instance lock for `key`. Releases in a finally (even on throw).
 * Returns { locked:false } without running fn if the lock is already held (caller decides 409 vs retry).
 */
export async function withLock(store, key, fn) {
  const got = await store.acquireLock(key);
  if (!got) return { locked: false };
  try {
    return { locked: true, value: await fn() };
  } finally {
    await store.releaseLock(key);
  }
}
