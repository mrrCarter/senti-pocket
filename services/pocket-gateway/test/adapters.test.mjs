// adapters.test.mjs — Lambda/API-Gateway adapter, ElevenLabs TTS backend, DynamoDB store. Hermetic (fakes only).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { lambdaHandler } from '../src/lambda.mjs';
import { createElevenLabsBackend } from '../src/tts.mjs';
import { createDynamoStore, withLock } from '../src/store.mjs';

// ---------- Lambda / API Gateway HTTP API v2 adapter ----------
test('lambdaHandler maps an API Gateway v2 event to the gateway and back (JSON)', async () => {
  let seen;
  const gw = { handle: async (req) => { seen = req; return { status: 200, body: { ok: true } }; } };
  const handler = lambdaHandler(gw);
  const res = await handler({
    requestContext: { http: { method: 'POST', path: '/actions/execute' }, domainName: 'gw.senti.app' },
    headers: { Authorization: 'Bearer x', DPoP: 'proof' },
    queryStringParameters: { since: '5' },
    body: JSON.stringify({ a: 1 }),
  });
  assert.equal(res.statusCode, 200);
  assert.equal(res.isBase64Encoded, false);
  assert.deepEqual(JSON.parse(res.body), { ok: true });
  assert.equal(seen.method, 'POST');
  assert.equal(seen.headers.authorization, 'Bearer x'); // header lowercased
  assert.equal(seen.headers['x-http-method'], 'POST');   // supplied from the trusted event
  assert.equal(seen.headers['x-http-url'], 'https://gw.senti.app/actions/execute');
});

test('lambdaHandler OVERWRITES caller-forwarded x-http-method/x-http-url (DPoP binding cannot be spoofed)', async () => {
  let seen;
  const gw = { handle: async (req) => { seen = req; return { status: 200, body: {} }; } };
  // canonicalBaseUrl pins the URL to the deploy origin, ignoring an attacker Host header
  const handler = lambdaHandler(gw, { canonicalBaseUrl: 'https://pocket-api.sentinelayer.com/' });
  await handler({
    requestContext: { http: { method: 'POST', path: '/v1/pocket/actions' }, domainName: 'attacker.evil' },
    headers: { host: 'attacker.evil', 'x-http-method': 'GET', 'x-http-url': 'https://evil/attacker' },
    body: '{}',
  });
  assert.equal(seen.headers['x-http-method'], 'POST', 'method comes from the event, not the caller');
  assert.equal(seen.headers['x-http-url'], 'https://pocket-api.sentinelayer.com/v1/pocket/actions', 'url is the canonical origin + path, never the spoofed header/host');
});

test('lambdaHandler base64-encodes a binary (audio) response', async () => {
  const gw = { handle: async () => ({ status: 200, headers: { 'x-senti-audio-format': 'pcm_s16le_24000' }, body: Buffer.from([1, 2, 3, 4]) }) };
  const res = await lambdaHandler(gw)({ requestContext: { http: { method: 'POST', path: '/tts' } }, headers: {} });
  assert.equal(res.isBase64Encoded, true);
  assert.equal(res.headers['x-senti-audio-format'], 'pcm_s16le_24000');
  assert.deepEqual(Buffer.from(res.body, 'base64'), Buffer.from([1, 2, 3, 4]));
});

test('lambdaHandler decodes a base64 request body', async () => {
  let seen;
  const gw = { handle: async (req) => { seen = req; return { status: 200, body: {} }; } };
  await lambdaHandler(gw)({ requestContext: { http: { method: 'POST', path: '/x' } }, headers: {}, body: Buffer.from('{"k":1}').toString('base64'), isBase64Encoded: true });
  assert.equal(seen.body, '{"k":1}');
});

// ---------- ElevenLabs TTS backend ----------
test('tts backend calls ElevenLabs with the key server-side; returns pcm; key never in the audio', async () => {
  let captured;
  const fakeFetch = async (url, init) => { captured = { url, init }; return { ok: true, status: 200, arrayBuffer: async () => new Uint8Array([9, 8, 7]).buffer }; };
  const tts = createElevenLabsBackend({ apiKey: 'sk-secret', fetch: fakeFetch, defaultVoiceId: 'voice-1' });
  const out = await tts('brief me', { modelId: 'eleven_flash_v2_5', outputFormat: 'pcm_24000', tone: 'urgent' });
  assert.ok(Buffer.isBuffer(out.audio));
  assert.deepEqual([...out.audio], [9, 8, 7]);
  assert.equal(out.format, 'pcm_s16le_24000');
  assert.equal(captured.init.headers['xi-api-key'], 'sk-secret'); // key sent to provider, not returned
  assert.match(captured.url, /\/v1\/text-to-speech\/voice-1$/);
  const bodySent = JSON.parse(captured.init.body);
  assert.equal(bodySent.model_id, 'eleven_flash_v2_5');
  assert.equal(bodySent.output_format, 'pcm_24000');
});

test('tts backend throws on provider error / empty audio / missing voice / missing key', async () => {
  const errFetch = async () => ({ ok: false, status: 429, arrayBuffer: async () => new ArrayBuffer(0) });
  await assert.rejects(createElevenLabsBackend({ apiKey: 'k', fetch: errFetch, defaultVoiceId: 'v' })('t'), /elevenlabs error 429/);
  const emptyFetch = async () => ({ ok: true, status: 200, arrayBuffer: async () => new ArrayBuffer(0) });
  await assert.rejects(createElevenLabsBackend({ apiKey: 'k', fetch: emptyFetch, defaultVoiceId: 'v' })('t'), /empty audio/);
  await assert.rejects(createElevenLabsBackend({ apiKey: 'k', fetch: emptyFetch })('t'), /voiceId required/);
  assert.throws(() => createElevenLabsBackend({ fetch: emptyFetch }), /apiKey required/);
});

// ---------- DynamoDB store (fake client modeling conditions + TTL + reserved-word validation) ----------
function throwCond() { const e = new Error('conditional'); e.name = 'ConditionalCheckFailedException'; throw e; }
// DynamoDB rejects a BARE reserved word (owner, ttl, ...) in an expression unless aliased via ExpressionAttributeNames.
function assertAliased(expr) {
  for (const w of ['owner', 'ttl']) {
    if (new RegExp('(^|[^#\\w.])' + w + '\\b').test(expr || '')) throw new Error('reserved word "' + w + '" must be aliased via ExpressionAttributeNames');
  }
}
function fakeDynamo() {
  const items = new Map(); // key "pk sk" -> item
  const k = (K) => K.pk + ' ' + K.sk;
  return {
    items,
    async get({ Key }) { return { Item: items.get(k(Key)) }; },
    async put({ Item, ConditionExpression, ExpressionAttributeValues }) {
      const key = k(Item);
      if (ConditionExpression) {
        assertAliased(ConditionExpression);
        const cur = items.get(key);
        const nowV = ExpressionAttributeValues && ExpressionAttributeValues[':now'];
        if (ConditionExpression === 'attribute_not_exists(pk)') { if (cur) throwCond(); }
        else if (ConditionExpression === 'attribute_not_exists(pk) OR #ttl <= :now') {
          const expired = cur && Number.isFinite(cur.ttl) && Number.isFinite(nowV) && cur.ttl <= nowV; // <= : reacquire AT expiry
          if (cur && !expired) throwCond();
        } else throw new Error('unmodeled put ConditionExpression: ' + ConditionExpression);
      }
      items.set(key, Item);
    },
    async delete({ Key, ConditionExpression, ExpressionAttributeNames, ExpressionAttributeValues }) {
      const key = k(Key);
      if (ConditionExpression) {
        assertAliased(ConditionExpression);
        if (ConditionExpression === '#o = :t') {
          const attr = ExpressionAttributeNames['#o'];
          const item = items.get(key);
          if (!item || item[attr] !== ExpressionAttributeValues[':t']) throwCond();
        } else throw new Error('unmodeled delete ConditionExpression: ' + ConditionExpression);
      }
      items.delete(key);
    },
  };
}

test('createDynamoStore: get/put/delete + OWNER-FENCED lock + putIfAbsent (aliased reserved words)', async () => {
  const client = fakeDynamo();
  const store = createDynamoStore({ client, table: 'pocket', now: () => 1_000_000_000_000 });
  assert.equal(await store.get('k1'), undefined);
  await store.put('k1', { status: 'posted' });
  assert.deepEqual(await store.get('k1'), { status: 'posted' });

  const t1 = await store.acquireLock('k1');
  assert.ok(t1, 'acquire returns an owner token');
  assert.equal(await store.acquireLock('k1'), null, 'second acquire blocked by conditional put');
  await store.releaseLock('k1', 'not-the-owner'); // fenced: a non-owner release is a no-op (conditional fails)
  assert.equal(await store.acquireLock('k1'), null, 'still held after a non-owner release attempt');
  await store.releaseLock('k1', t1); // owner releases
  assert.ok(await store.acquireLock('k1'), 'released lock re-acquirable');

  assert.equal(await store.putIfAbsent('k2', { v: 1 }), true);
  assert.equal(await store.putIfAbsent('k2', { v: 2 }), false, 'reserve is atomic');
  assert.deepEqual(await store.get('k2'), { v: 1 });
  await store.delete('k1');
  assert.equal(await store.get('k1'), undefined);
});

test('createDynamoStore: a LOGICALLY-EXPIRED lock is re-acquirable before Dynamo TTL deletion lag', async () => {
  const client = fakeDynamo();
  let clock = 1_000_000_000_000; // ms
  const store = createDynamoStore({ client, table: 'pocket', ttlSeconds: 30, now: () => clock });
  const t1 = await store.acquireLock('kexp');
  assert.ok(t1);
  assert.equal(await store.acquireLock('kexp'), null, 'held while fresh');
  clock += 31_000; // advance past ttlSeconds; the item still physically exists (TTL deletion lags)
  const t2 = await store.acquireLock('kexp');
  assert.ok(t2, 'expired lock re-acquired without waiting for eventual TTL sweep');
  assert.notEqual(t1, t2);
});

test('createDynamoStore: lock is re-acquirable AT the exact expiry boundary (ttl <= now)', async () => {
  const client = fakeDynamo();
  let clock = 2_000_000_000_000;
  const store = createDynamoStore({ client, table: 'pocket', ttlSeconds: 10, now: () => clock });
  assert.ok(await store.acquireLock('kb'));
  clock += 10_000; // EXACTLY ttlSeconds later => stored ttl == now
  assert.ok(await store.acquireLock('kb'), 're-acquirable at the exact expiry instant (uses <=, not <)');
});

test('createDynamoStore: putIfAbsent sets a TOP-LEVEL ttl (so DynamoDB TTL can expire replay records)', async () => {
  const client = fakeDynamo();
  const store = createDynamoStore({ client, table: 'pocket' });
  await store.putIfAbsent('dpop-jti:x', { exp: 12345 }, { ttlEpochSec: 12345 });
  const item = client.items.get('dpop-jti:x record');
  assert.equal(item.ttl, 12345, 'ttl is a top-level attribute, not nested under value');
});

test('withLock over the DynamoDB store serializes; a held key returns {locked:false}', async () => {
  const store = createDynamoStore({ client: fakeDynamo(), table: 'pocket', now: () => 1_000_000_000 });
  const r1 = await withLock(store, 'kx', async () => 42);
  assert.deepEqual(r1, { locked: true, value: 42 });
  await store.acquireLock('kheld');
  const r2 = await withLock(store, 'kheld', async () => { throw new Error('should not run'); });
  assert.deepEqual(r2, { locked: false });
});
