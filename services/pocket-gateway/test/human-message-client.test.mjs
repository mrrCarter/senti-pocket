// human-message-client.test.mjs — the concrete gateway->api HUMAN-write client. All I/O injected; NO test hits a live api.
// Covers Warden's RELAY gate: (a) Bearer -> /sessions/{id}/human-message body {message,clientId}; (b) token never
// logged/in-error; (c) fail-closed — any non-{message.id + event.sequenceId} response -> parseHumanMessageResult null.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHumanMessageClient } from '../src/human-message-client.mjs';
import { parseHumanMessageResult } from '../src/actions.mjs';

function fakeFetch(responseBody, { status = 200 } = {}) {
  const calls = [];
  const fetch = async (url, init) => {
    calls.push({ url, init });
    return {
      status,
      ok: status >= 200 && status < 300,
      text: async () => (typeof responseBody === 'string' ? responseBody : JSON.stringify(responseBody)),
    };
  };
  return { fetch, calls };
}

// The exact api success shape (api send_human_message: {ok, message:{id,cursor,senderId,...}, event:{sequenceId, agent:{id}}}).
const OK = {
  ok: true,
  message: { id: 'evt_123', cursor: 'c-9', senderId: 'human-mrrcarter', message: 'post X', priority: 'high', sessionId: 's1' },
  event: { eventId: 'evt_123', sequenceId: 42, agent: { id: 'human-mrrcarter' } },
};

// (a) request shape ------------------------------------------------------------------------------------------------
test('(a) POSTs Bearer<token> to /api/v1/sessions/{id}/human-message with {message, clientId}', async () => {
  const { fetch, calls } = fakeFetch(OK);
  const post = createHumanMessageClient({ fetch, apiBaseUrl: 'https://api.example.com/' }); // trailing slash trimmed
  const out = await post('s1', 'post X', { clientId: 'HASH43', token: 'TOK' });

  assert.equal(calls.length, 1);
  const { url, init } = calls[0];
  assert.equal(url, 'https://api.example.com/api/v1/sessions/s1/human-message');
  assert.equal(init.method, 'POST');
  assert.equal(init.headers.authorization, 'Bearer TOK');
  assert.equal(init.headers['content-type'], 'application/json');
  const sent = JSON.parse(init.body);
  assert.equal(sent.message, 'post X');
  assert.equal(sent.clientId, 'HASH43');
  assert.equal(out, JSON.stringify(OK)); // returns RAW body text
});

test('(a) encodes the sessionId path component', async () => {
  const { fetch, calls } = fakeFetch(OK);
  const post = createHumanMessageClient({ fetch, apiBaseUrl: 'https://api.example.com' });
  await post('s/1 x', 'hi', { clientId: 'H', token: 'TOK' });
  assert.equal(calls[0].url, 'https://api.example.com/api/v1/sessions/s%2F1%20x/human-message');
});

test('(a) normalizes a full "Bearer <cred>" header AND a raw credential to a SINGLE Bearer (no double-wrap)', async () => {
  // handlers currently threads the incoming Authorization header verbatim; the client must not produce "Bearer Bearer ..".
  const full = fakeFetch(OK);
  await createHumanMessageClient({ fetch: full.fetch, apiBaseUrl: 'https://api.example.com' })('s1', 'x', { clientId: 'H', token: 'Bearer RAWCRED' });
  assert.equal(full.calls[0].init.headers.authorization, 'Bearer RAWCRED');
  const raw = fakeFetch(OK);
  await createHumanMessageClient({ fetch: raw.fetch, apiBaseUrl: 'https://api.example.com' })('s1', 'x', { clientId: 'H', token: 'RAWCRED' });
  assert.equal(raw.calls[0].init.headers.authorization, 'Bearer RAWCRED');
});

test('(a) omits clientId when absent (server derives idempotency)', async () => {
  const { fetch, calls } = fakeFetch(OK);
  const post = createHumanMessageClient({ fetch, apiBaseUrl: 'https://api.example.com' });
  await post('s1', 'hi', { token: 'TOK' });
  const sent = JSON.parse(calls[0].init.body);
  assert.equal('clientId' in sent, false);
  assert.equal(sent.message, 'hi');
});

// output feeds the read-back parser -------------------------------------------------------------------------------
test('client output -> parseHumanMessageResult -> correct landing', async () => {
  const { fetch } = fakeFetch(OK);
  const post = createHumanMessageClient({ fetch, apiBaseUrl: 'https://api.example.com' });
  const parsed = parseHumanMessageResult(await post('s1', 'post X', { clientId: 'H', token: 'TOK' }));
  assert.deepEqual(parsed, { messageId: 'evt_123', sequenceId: 42, targetCursor: 'c-9', senderId: 'human-mrrcarter' });
});

// (c) fail-closed --------------------------------------------------------------------------------------------------
test('(c) non-2xx error body -> parseHumanMessageResult null (NOT landed, no false .posted)', async () => {
  const { fetch } = fakeFetch({ error: 'forbidden', detail: 'not a member' }, { status: 403 });
  const post = createHumanMessageClient({ fetch, apiBaseUrl: 'https://api.example.com' });
  assert.equal(parseHumanMessageResult(await post('s1', 'x', { clientId: 'H', token: 'TOK' })), null);
});

test('(c) 200 but missing event.sequenceId -> null (unidentifiable landing)', async () => {
  const noSeq = { ok: true, message: { id: 'evt_1', cursor: 'c', senderId: 'human-mrrcarter' }, event: { agent: { id: 'human-mrrcarter' } } };
  const { fetch } = fakeFetch(noSeq);
  const post = createHumanMessageClient({ fetch, apiBaseUrl: 'https://api.example.com' });
  assert.equal(parseHumanMessageResult(await post('s1', 'x', { clientId: 'H', token: 'TOK' })), null);
});

test('(c) 200 but non-JSON body -> null', async () => {
  const { fetch } = fakeFetch('<html>gateway timeout</html>');
  const post = createHumanMessageClient({ fetch, apiBaseUrl: 'https://api.example.com' });
  assert.equal(parseHumanMessageResult(await post('s1', 'x', { clientId: 'H', token: 'TOK' })), null);
});

// (b) token never leaks --------------------------------------------------------------------------------------------
test('(b) the token value appears ONLY in the Authorization header — never URL or body', async () => {
  const { fetch, calls } = fakeFetch(OK);
  const post = createHumanMessageClient({ fetch, apiBaseUrl: 'https://api.example.com' });
  await post('s1', 'hello', { clientId: 'H', token: 'SECRET_TOKEN_XYZ' });
  const { url, init } = calls[0];
  assert.equal(url.includes('SECRET_TOKEN_XYZ'), false);
  assert.equal(init.body.includes('SECRET_TOKEN_XYZ'), false);
  assert.equal(init.headers.authorization, 'Bearer SECRET_TOKEN_XYZ');
});

test('(b) thrown errors never contain the token value', async () => {
  const { fetch } = fakeFetch(OK);
  const post = createHumanMessageClient({ fetch, apiBaseUrl: 'https://api.example.com' });
  // missing token -> refuses (never falls back to a gateway credential), message names no secret
  await assert.rejects(() => post('s1', 'x', { clientId: 'H' }), /user bearer token required/);
  // an error path WITH a token present must not echo it
  await assert.rejects(() => post('', 'x', { token: 'SUPERSECRET' }), (e) => {
    assert.equal(e.message.includes('SUPERSECRET'), false);
    return true;
  });
});

// factory validation -----------------------------------------------------------------------------------------------
test('factory requires fetch + apiBaseUrl', () => {
  assert.throws(() => createHumanMessageClient({ apiBaseUrl: 'https://x' }), /fetch is required/);
  assert.throws(() => createHumanMessageClient({ fetch: async () => {} }), /apiBaseUrl is required/);
});
