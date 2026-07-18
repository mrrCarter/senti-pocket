// handlers.test.mjs — gateway API (GET /sync, POST /actions/execute, POST /tts) + async store.
// Fully hermetic: injected verifyToken / sl runner / bundleStore / ttsBackend. NO live calls.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createGateway, storeKey } from '../src/handlers.mjs';
import { createInMemoryStore } from '../src/store.mjs';
import { computeProposalHash } from '../src/actions.mjs';
import { generateSigningKeypair } from '../src/bundle.mjs';

const KNOWN = '6cf7e861-546a-4b9f-b937-39182a5bd395';
const { privateKey: KEY } = generateSigningKeypair();

const verifyToken = async (headers) => {
  const a = headers && (headers.authorization || headers.Authorization);
  if (a === 'Bearer good') return { humanId: 'consumer-123', scopes: ['pocket:read', 'pocket:write', 'pocket:voice'] };
  if (a === 'Bearer rw') return { humanId: 'consumer-123', scopes: ['pocket:read', 'pocket:write'] }; // no voice
  if (a === 'Bearer noscope') return { humanId: 'consumer-123', scopes: [] };
  return null;
};

function makeProposal(over = {}) {
  const p = { id: 'p1', kind: 'threadedReply', targetSessionId: KNOWN, targetSequence: 230160, renderedPreview: 'Approved.', requiresConfirmation: true, createdAt: '2026-07-18T12:00:00Z', sourceQuestionId: null, ...over };
  p.proposalHash = computeProposalHash(p);
  return p;
}
const makeConfirm = (p) => ({ proposalId: p.id, confirmedProposalHash: p.proposalHash, confirmedAt: '2026-07-18T12:01:00Z' });

// sl runner: reply -> action; read -> optionally landed. `landed` toggles read-back success.
function makeRun(state = { replies: 0, landed: true }) {
  return (args) => {
    if (args[1] === 'reply') { state.replies++; return JSON.stringify({ action: { id: 'act_' + state.replies, targetSequenceId: Number(args[3]), targetCursor: 'c' } }); }
    if (args[1] === 'read') return JSON.stringify({ events: state.landed ? [{ eventId: 'session-action-act_1', agent: { id: 'claude-pocket-relay' }, payload: { targetSequenceId: 230160 } }] : [] });
    return '{}';
  };
}

const baseDeps = (over = {}) => ({
  verifyToken, store: createInMemoryStore(), run: makeRun(), signingKey: KEY, signingKeyId: 'gw-key',
  knownSessionIdsFor: async () => [KNOWN], now: () => '2026-07-18T12:02:00Z', ...over,
});

test('GET /health needs no auth', async () => {
  const gw = createGateway(baseDeps());
  const r = await gw.handle({ method: 'GET', path: '/health' });
  assert.equal(r.status, 200);
  assert.equal(r.body.ok, true);
});

test('auth is fail-closed: no token => 401, wrong scope => 403', async () => {
  const gw = createGateway(baseDeps());
  assert.equal((await gw.handle({ method: 'GET', path: '/sync', headers: {} })).status, 401);
  assert.equal((await gw.handle({ method: 'POST', path: '/actions/execute', headers: { authorization: 'Bearer bad' }, body: {} })).status, 401);
  assert.equal((await gw.handle({ method: 'POST', path: '/actions/execute', headers: { authorization: 'Bearer noscope' }, body: {} })).status, 403);
});

test('no verifyToken wired => everything (except health) is denied', async () => {
  const gw = createGateway(baseDeps({ verifyToken: undefined }));
  assert.equal((await gw.handle({ method: 'GET', path: '/sync', headers: { authorization: 'Bearer good' } })).status, 401);
});

test('GET /sync returns bundles for the authenticated human only', async () => {
  const bundleStore = { listForHuman: async (humanId, since) => [{ checkpointId: 'cp1', forHuman: humanId, since }] };
  const gw = createGateway(baseDeps({ bundleStore }));
  const r = await gw.handle({ method: 'GET', path: '/sync', query: { since: '5' }, headers: { authorization: 'Bearer good' } });
  assert.equal(r.status, 200);
  assert.equal(r.body.bundles[0].forHuman, 'consumer-123');
  assert.equal(r.body.bundles[0].since, 5);
});

test('POST /actions/execute posts once and returns a signed receipt', async () => {
  const state = { replies: 0, landed: true };
  const gw = createGateway(baseDeps({ run: makeRun(state) }));
  const p = makeProposal();
  const r = await gw.handle({ method: 'POST', path: '/actions/execute', headers: { authorization: 'Bearer good' }, body: { proposal: p, confirmation: makeConfirm(p) } });
  assert.equal(r.status, 200);
  assert.equal(r.body.status, 'posted');
  assert.equal(r.body.result.kind, 'action');
  assert.ok(r.body.signature);
  assert.equal(state.replies, 1);
});

test('POST /actions/execute rejects a session the human does not belong to (server-derived authz)', async () => {
  const gw = createGateway(baseDeps({ knownSessionIdsFor: async () => ['00000000-0000-0000-0000-000000000000'] }));
  const p = makeProposal();
  const r = await gw.handle({ method: 'POST', path: '/actions/execute', headers: { authorization: 'Bearer good' }, body: { proposal: p, confirmation: makeConfirm(p) } });
  assert.equal(r.status, 200);
  assert.equal(r.body.status, 'failed');
  assert.match(r.body.failureReason, /not a known session/);
});

test('exactly-once across instances: a concurrent lock holder gets 409, not a second post', async () => {
  const store = createInMemoryStore();
  const gw = createGateway(baseDeps({ store }));
  const p = makeProposal({ id: 'plock' });
  await store.acquireLock(storeKey('consumer-123', 'plock')); // simulate another instance mid-post (namespaced per-human key)
  const r = await gw.handle({ method: 'POST', path: '/actions/execute', headers: { authorization: 'Bearer good' }, body: { proposal: p, confirmation: makeConfirm(p) } });
  assert.equal(r.status, 409);
});

test('exactly-once across instances: read-back miss then retry RE-VERIFIES, never double-posts', async () => {
  const store = createInMemoryStore();
  const state = { replies: 0, landed: false }; // first attempt: read-back misses
  const gw = createGateway(baseDeps({ store, run: makeRun(state) }));
  const p = makeProposal({ id: 'pretry' });
  const body = { proposal: p, confirmation: makeConfirm(p) };
  const r1 = await gw.handle({ method: 'POST', path: '/actions/execute', headers: { authorization: 'Bearer good' }, body });
  assert.equal(r1.body.status, 'failed');
  assert.equal(state.replies, 1);
  state.landed = true; // now the original action is visible
  const r2 = await gw.handle({ method: 'POST', path: '/actions/execute', headers: { authorization: 'Bearer good' }, body });
  assert.equal(r2.body.status, 'posted', 'retry finalizes the emitted action');
  assert.equal(state.replies, 1, 'retry must NOT re-post');
  assert.equal(r2.body.result.actionId, 'act_1');
});

test('POST /tts proxies audio; the provider key never appears in the response', async () => {
  let sawKey = false;
  const ttsBackend = async (text, opts) => {
    // the key lives here only; ensure we return raw pcm bytes, never the key
    const SECRET = 'sk-' + 'z'.repeat(20);
    if (text.includes(SECRET)) sawKey = true;
    return { audio: Buffer.from([1, 2, 3, 4]), format: 'pcm_s16le_24000' };
  };
  const gw = createGateway(baseDeps({ ttsBackend }));
  const r = await gw.handle({ method: 'POST', path: '/tts', headers: { authorization: 'Bearer good' }, body: { text: 'brief me', voiceId: 'v1' } });
  assert.equal(r.status, 200);
  assert.equal(r.headers['x-senti-audio-format'], 'pcm_s16le_24000');
  assert.ok(Buffer.isBuffer(r.body));
  assert.equal(sawKey, false);
});

test('cross-human isolation: same proposal.id from two humans does NOT share idempotency/lock state', async () => {
  const store = createInMemoryStore();
  const vt = async (h) => { const a = h && h.authorization; if (a === 'Bearer alice') return { humanId: 'alice', scopes: ['pocket:write'] }; if (a === 'Bearer bob') return { humanId: 'bob', scopes: ['pocket:write'] }; return null; };
  const state = { replies: 0 };
  const run = (args) => {
    if (args[1] === 'reply') { state.replies++; return JSON.stringify({ action: { id: 'act_' + state.replies, targetSequenceId: Number(args[3]), targetCursor: 'c' } }); }
    if (args[1] === 'read') return JSON.stringify({ events: [{ eventId: 'session-action-act_' + state.replies, agent: { id: 'claude-pocket-relay' }, payload: { targetSequenceId: 230160 } }] });
    return '{}';
  };
  const gw = createGateway(baseDeps({ store, run, verifyToken: vt }));
  const p = makeProposal({ id: 'shared' });
  const body = { proposal: p, confirmation: makeConfirm(p) };
  const ra = await gw.handle({ method: 'POST', path: '/actions/execute', headers: { authorization: 'Bearer alice' }, body });
  const rb = await gw.handle({ method: 'POST', path: '/actions/execute', headers: { authorization: 'Bearer bob' }, body });
  assert.equal(ra.body.status, 'posted');
  assert.equal(rb.body.status, 'posted');
  assert.equal(state.replies, 2, 'each human executes independently — no cross-tenant idempotency collapse');
  assert.notEqual(ra.body.result.actionId, rb.body.result.actionId);
});

test('durable state keyed by PRINCIPAL, not sub: same pairwise sub across sites does not collide', async () => {
  const store = createInMemoryStore();
  const vt = async (h) => {
    const a = h && h.authorization;
    if (a === 'Bearer siteA') return { humanId: 'sub-1', principal: 'siteA|sub-1', scopes: ['pocket:write'] };
    if (a === 'Bearer siteB') return { humanId: 'sub-1', principal: 'siteB|sub-1', scopes: ['pocket:write'] };
    return null;
  };
  const state = { replies: 0 };
  const run = (args) => {
    if (args[1] === 'reply') { state.replies++; return JSON.stringify({ action: { id: 'act_' + state.replies, targetSequenceId: Number(args[3]), targetCursor: 'c' } }); }
    if (args[1] === 'read') return JSON.stringify({ events: [{ eventId: 'session-action-act_' + state.replies, agent: { id: 'claude-pocket-relay' }, payload: { targetSequenceId: 230160 } }] });
    return '{}';
  };
  const gw = createGateway(baseDeps({ store, run, verifyToken: vt }));
  const p = makeProposal({ id: 'shared' });
  const body = { proposal: p, confirmation: makeConfirm(p) };
  const ra = await gw.handle({ method: 'POST', path: '/actions/execute', headers: { authorization: 'Bearer siteA' }, body });
  const rb = await gw.handle({ method: 'POST', path: '/actions/execute', headers: { authorization: 'Bearer siteB' }, body });
  assert.equal(ra.body.status, 'posted');
  assert.equal(rb.body.status, 'posted');
  assert.equal(state.replies, 2, 'same sub + proposal.id at different sites executes independently (no cross-tenant collision)');
});

test('crash recovery: in-flight reservation + landed post => retry FINALIZES via idempotency-key read-back, never re-posts', async () => {
  const store = createInMemoryStore();
  const p = makeProposal({ id: 'pcrash', renderedPreview: 'Approved.' });
  const KEY = computeProposalHash(p); // the reply was posted with --idempotency-key = proposal hash
  const state = { replies: 0 };
  const run = (args) => {
    if (args[1] === 'reply') { state.replies++; return JSON.stringify({ action: { id: 'act_crash', targetSequenceId: Number(args[3]), targetCursor: 'c' } }); }
    if (args[1] === 'read') return JSON.stringify({ events: [{ eventId: 'session-action-act_crash', agent: { id: 'claude-pocket-relay' }, idempotencyToken: KEY, payload: { targetSequenceId: 230160 } }] });
    return '{}';
  };
  const gw = createGateway(baseDeps({ store, run }));
  await store.put(storeKey('consumer-123', 'pcrash'), { state: 'in-flight', proposalId: 'pcrash', reservedAt: '2026-07-18T12:02:00Z' }); // crashed after post
  const r = await gw.handle({ method: 'POST', path: '/actions/execute', headers: { authorization: 'Bearer good' }, body: { proposal: p, confirmation: makeConfirm(p) } });
  assert.equal(r.body.status, 'posted', 'finalized the already-landed post');
  assert.equal(r.body.result.actionId, 'act_crash');
  assert.equal(state.replies, 0, 'crash recovery must NOT re-post');
});

test('reconciliation binds to PROPOSAL IDENTITY, not body: an older identical-content action is never finalized (Echo P1)', async () => {
  const store = createInMemoryStore();
  const p = makeProposal({ id: 'pident', renderedPreview: 'Approved.' });
  const state = { replies: 0 };
  const run = (args) => {
    if (args[1] === 'reply') { state.replies++; return JSON.stringify({ action: { id: 'act_new', targetSequenceId: Number(args[3]), targetCursor: 'c' } }); }
    // an OLDER action with the SAME body but a DIFFERENT idempotency key (a different proposal)
    if (args[1] === 'read') return JSON.stringify({ events: [{ eventId: 'session-action-act_OLD', agent: { id: 'claude-pocket-relay' }, idempotencyToken: 'a-different-proposal-hash', payload: { targetSequenceId: 230160, text: 'Approved.' } }] });
    return '{}';
  };
  const gw = createGateway(baseDeps({ store, run }));
  await store.put(storeKey('consumer-123', 'pident'), { state: 'in-flight', proposalId: 'pident', reservedAt: '2026-07-18T12:02:00Z' });
  const r = await gw.handle({ method: 'POST', path: '/actions/execute', headers: { authorization: 'Bearer good' }, body: { proposal: p, confirmation: makeConfirm(p) } });
  assert.equal(r.status, 409, 'an older identical-content action has a different key => not mis-finalized => unknown/409');
  assert.equal(state.replies, 0, 'never re-posts either');
});

test('unknown prior send: in-flight reservation with NO read-back match does NOT re-post (Echo P0)', async () => {
  const store = createInMemoryStore();
  const state = { replies: 0, landed: true }; // read events carry no matching content
  const gw = createGateway(baseDeps({ store, run: makeRun(state) }));
  const p = makeProposal({ id: 'pcrash2' });
  await store.put(storeKey('consumer-123', 'pcrash2'), { state: 'in-flight', proposalId: 'pcrash2', reservedAt: '2026-07-18T12:02:00Z' });
  const r = await gw.handle({ method: 'POST', path: '/actions/execute', headers: { authorization: 'Bearer good' }, body: { proposal: p, confirmation: makeConfirm(p) } });
  assert.equal(r.status, 409, 'ambiguous prior outcome => reconciliation required, never a blind re-post from one read miss');
  assert.equal(state.replies, 0, 'must NOT re-post');
});

test('ambiguous send (run throws AFTER commit): retry reconciles via idempotency-key read-back, never double-posts', async () => {
  const store = createInMemoryStore();
  const p = makeProposal({ id: 'pamb', renderedPreview: 'Approved.' });
  const KEY = computeProposalHash(p);
  let phase = 'throw'; // first attempt: reply throws AFTER the server committed
  const run = (args) => {
    if (args[1] === 'reply') { if (phase === 'throw') { phase = 'landed'; throw new Error('network reset after send'); } throw new Error('MUST NOT re-post'); }
    if (args[1] === 'read') return JSON.stringify({ events: phase === 'landed' ? [{ eventId: 'session-action-act_amb', agent: { id: 'claude-pocket-relay' }, idempotencyToken: KEY, payload: { targetSequenceId: 230160 } }] : [] });
    return '{}';
  };
  const gw = createGateway(baseDeps({ store, run }));
  const body = { proposal: p, confirmation: makeConfirm(p) };
  const r1 = await gw.handle({ method: 'POST', path: '/actions/execute', headers: { authorization: 'Bearer good' }, body });
  assert.equal(r1.body.status, 'failed'); // ambiguous => failed, but the durable reservation is PRESERVED
  const r2 = await gw.handle({ method: 'POST', path: '/actions/execute', headers: { authorization: 'Bearer good' }, body });
  assert.equal(r2.body.status, 'posted', 'reconciled the committed reply');
  assert.equal(r2.body.result.actionId, 'act_amb');
});

test('POST /tts requires the distinct pocket:voice scope (a read+write token is denied)', async () => {
  const ttsBackend = async () => ({ audio: Buffer.from([1, 2]), format: 'pcm_s16le_24000' });
  const gw = createGateway(baseDeps({ ttsBackend }));
  // read+write only (no voice) => 403 even though it can execute/sync
  const denied = await gw.handle({ method: 'POST', path: '/tts', headers: { authorization: 'Bearer rw' }, body: { text: 'hi', voiceId: 'v' } });
  assert.equal(denied.status, 403);
  assert.match(denied.body.error, /pocket:voice/);
  // a read+write token still authorizes the action + sync routes
  assert.equal((await gw.handle({ method: 'GET', path: '/sync', headers: { authorization: 'Bearer rw' } })).status, 501); // authorized (no bundleStore => 501, not 403)
  // a token WITH pocket:voice => 200
  const ok = await gw.handle({ method: 'POST', path: '/tts', headers: { authorization: 'Bearer good' }, body: { text: 'hi', voiceId: 'v' } });
  assert.equal(ok.status, 200);
});

test('POST /tts rejects oversized text and missing backend', async () => {
  const gw1 = createGateway(baseDeps({ ttsBackend: undefined }));
  assert.equal((await gw1.handle({ method: 'POST', path: '/tts', headers: { authorization: 'Bearer good' }, body: { text: 'hi' } })).status, 501);
  const gw2 = createGateway(baseDeps({ ttsBackend: async () => ({ audio: Buffer.from([0]), format: 'x' }) }));
  const big = 'a'.repeat(9000);
  assert.equal((await gw2.handle({ method: 'POST', path: '/tts', headers: { authorization: 'Bearer good' }, body: { text: big } })).status, 413);
});
