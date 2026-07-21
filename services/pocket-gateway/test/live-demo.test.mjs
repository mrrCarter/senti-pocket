// live-demo.test.mjs — the LOCAL live-write composition. Hermetic (fake fetch routes /auth/me + /human-message; fake run
// for read-back). Proves the composition wires REAL SENTI auth + REAL /human-message + forwards the SAME token, and is
// fail-closed on bad auth / non-member — the same gated invariants as prod, over an in-memory store + dev receipt key.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createLiveDemoGateway, createLiveDemoServer } from '../src/live-demo.mjs';
import { computeProposalHash } from '../src/actions.mjs';
import { generateSigningKeypair } from '../src/bundle.mjs';

const KNOWN = '6cf7e861-546a-4b9f-b937-39182a5bd395';

function makeHumanProposal(over = {}) {
  const p = { id: 'plive1', kind: 'humanMessage', targetSessionId: KNOWN, targetSequence: 0, renderedPreview: 'first live message from Pocket', requiresConfirmation: true, createdAt: '2026-07-20T20:00:00Z', sourceQuestionId: null, ...over };
  p.proposalHash = computeProposalHash(p);
  return p;
}
const makeConfirm = (p) => ({ proposalId: p.id, confirmedProposalHash: p.proposalHash, confirmedAt: '2026-07-20T20:00:05Z' });

// fetch routes /auth/me (verifier, .json) + /human-message (client, .text)
function liveFakeFetch({ meStatus = 200, mid = 'hm_live_1', seq = 5001 } = {}) {
  const calls = [];
  const fetch = async (url, init) => {
    calls.push({ url, init });
    if (url.endsWith('/api/v1/auth/me')) {
      // REAL contract: /auth/me returns a distinct `id` (canonical) + `github_username`; the human write is authored as
      // human-<normalize(github_username)> = human-mrrcarter — which is what the read-back must match.
      return meStatus === 200
        ? { ok: true, status: 200, json: async () => ({ id: 'uuid-carter', github_username: 'mrrCarter' }) }
        : { ok: false, status: meStatus, json: async () => ({ error: 'no' }) };
    }
    if (url.includes('/human-message')) {
      const text = JSON.stringify({ ok: true, message: { id: mid, cursor: 'c-1', senderId: 'human-mrrcarter' }, event: { eventId: mid, sequenceId: seq, agent: { id: 'human-mrrcarter' } } });
      return { ok: true, status: 200, text: async () => text };
    }
    return { ok: false, status: 404, text: async () => '{}', json: async () => ({}) };
  };
  return { fetch, calls };
}
// read-back: the human message is in the room under human-mrrcarter
const makeRun = (mid = 'hm_live_1', seq = 5001) => (args) => {
  if (args[1] === 'read') return JSON.stringify({ events: [{ eventId: mid, agent: { id: 'human-mrrcarter' }, sequenceId: seq }] });
  return '{}';
};

test('LIVE-DEMO e2e: real /auth/me auth + real /human-message post => sequence receipt; SAME token both hops', async () => {
  const { fetch, calls } = liveFakeFetch();
  const gw = createLiveDemoGateway({ apiBaseUrl: 'https://api.example.com', fetch, run: makeRun(), knownSessionIdsFor: async () => [KNOWN], now: () => '2026-07-20T20:00:03Z' });
  const p = makeHumanProposal();
  const out = await gw.handle({ method: 'POST', path: '/actions/execute', headers: { authorization: 'Bearer SENTI_USER_TOK' }, body: JSON.stringify({ proposal: p, confirmation: makeConfirm(p) }) });

  const meCall = calls.find((c) => c.url.endsWith('/auth/me'));
  const hmCall = calls.find((c) => c.url.includes('/human-message'));
  assert.ok(meCall, '/auth/me called (real token validation)');
  assert.equal(meCall.init.headers.authorization, 'Bearer SENTI_USER_TOK');
  assert.ok(hmCall, '/human-message called (real post)');
  assert.equal(hmCall.init.headers.authorization, 'Bearer SENTI_USER_TOK'); // SAME token forwarded to the write
  assert.equal(out.status, 200);
  assert.equal(out.body.status, 'posted');
  assert.equal(out.body.result.kind, 'sequence');
  assert.equal(out.body.result.sequenceId, 5001);
});

test('LIVE-DEMO fail-closed: invalid SENTI token (/auth/me 401) => 401, no /human-message post', async () => {
  const { fetch, calls } = liveFakeFetch({ meStatus: 401 });
  const gw = createLiveDemoGateway({ apiBaseUrl: 'https://api.example.com', fetch, run: makeRun(), knownSessionIdsFor: async () => [KNOWN] });
  const p = makeHumanProposal();
  const out = await gw.handle({ method: 'POST', path: '/actions/execute', headers: { authorization: 'Bearer BAD' }, body: JSON.stringify({ proposal: p, confirmation: makeConfirm(p) }) });
  assert.equal(out.status, 401);
  assert.equal(calls.some((c) => c.url.includes('/human-message')), false, 'no post when auth fails');
});

test('LIVE-DEMO non-member => 403 before any post (membership precheck holds in the composition)', async () => {
  const { fetch, calls } = liveFakeFetch();
  const gw = createLiveDemoGateway({ apiBaseUrl: 'https://api.example.com', fetch, run: makeRun(), knownSessionIdsFor: async () => [] });
  const p = makeHumanProposal();
  const out = await gw.handle({ method: 'POST', path: '/actions/execute', headers: { authorization: 'Bearer SENTI_USER_TOK' }, body: JSON.stringify({ proposal: p, confirmation: makeConfirm(p) }) });
  assert.equal(out.status, 403);
  assert.equal(calls.some((c) => c.url.includes('/human-message')), false, 'no post for a non-member');
});

test('createLiveDemoServer constructs an http server (listen/close) + exposes the receipt pubkey', () => {
  const { server, publicKeyB64url } = createLiveDemoServer({ apiBaseUrl: 'https://a', fetch: async () => {}, run: () => '{}', knownSessionIdsFor: async () => [] });
  assert.equal(typeof server.listen, 'function');
  assert.equal(typeof server.close, 'function');
  assert.equal(typeof publicKeyB64url, 'string');
  assert.ok(publicKeyB64url.length > 0);
  server.close();
});

test('createLiveDemoGateway exposes the receipt-signing PUBLIC key matching the signing key (sig-verify-at-render, #2)', () => {
  const { publicKey, privateKey } = generateSigningKeypair();
  const gw = createLiveDemoGateway({ apiBaseUrl: 'https://a', fetch: async () => {}, run: () => '{}', knownSessionIdsFor: async () => [], signingKey: privateKey });
  assert.equal(typeof gw.demoPublicKeyB64url, 'string');
  assert.ok(gw.demoPublicKeyB64url.length > 0);
  // MUST equal the signing key's public key — else pinning it can't verify the receipt signature.
  assert.equal(gw.demoPublicKeyB64url, publicKey.export({ format: 'jwk' }).x);
});

test('factory requires apiBaseUrl + run + knownSessionIdsFor (fetch defaults to global)', () => {
  const ok = { apiBaseUrl: 'https://a', fetch: async () => {}, run: () => {}, knownSessionIdsFor: async () => [] };
  assert.throws(() => createLiveDemoGateway({ ...ok, apiBaseUrl: undefined }), /apiBaseUrl/);
  assert.throws(() => createLiveDemoGateway({ ...ok, fetch: null }), /fetch is required/); // explicit non-function (bypasses the global default)
  assert.throws(() => createLiveDemoGateway({ ...ok, run: undefined }), /run/);
  assert.throws(() => createLiveDemoGateway({ ...ok, knownSessionIdsFor: undefined }), /knownSessionIdsFor/);
});
