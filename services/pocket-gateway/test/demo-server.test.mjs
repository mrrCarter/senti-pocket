// demo-server.test.mjs — launcher HTTP/bind/boot/bounds tests (Echo #233248 P2 + the P1 server hardening).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { createDemoServer } from '../src/demo-server.mjs';
import { computeProposalHash } from '../src/actions.mjs';

const DISPOSABLE = '22222222-2222-4222-8222-222222222222';
function mockRun(state = { replies: 0 }) {
  return (args) => {
    if (args[1] === 'reply') { state.replies += 1; return JSON.stringify({ action: { id: 'act_' + state.replies, targetSequenceId: Number(args[3]), targetCursor: 'c' } }); }
    if (args[1] === 'read') return JSON.stringify({ events: [{ eventId: 'session-action-act_' + state.replies, agent: { id: 'claude-pocket-relay' }, payload: { targetSequenceId: 5 } }] });
    return '{}';
  };
}
async function boot(opts = {}) {
  const h = createDemoServer({ run: mockRun(), now: () => '2026-07-18T12:02:00Z', ...opts });
  h.server.listen(0, '127.0.0.1');
  await once(h.server, 'listening');
  h.base = 'http://127.0.0.1:' + h.server.address().port;
  return h;
}
const auth = (t) => ({ Authorization: 'Bearer ' + t });

test('boot: refuses a protected/live room as DEMO_SESSION', () => {
  assert.throws(() => createDemoServer({ demoSession: '6cf7e861-546a-4b9f-b937-39182a5bd395', run: mockRun() }), /disposable|protected/i);
});

test('health needs no auth; every other route is fail-closed 401', async () => {
  const h = await boot();
  try {
    assert.equal((await fetch(h.base + '/health')).status, 200);
    assert.equal((await fetch(h.base + '/sync')).status, 401);
    assert.equal((await fetch(h.base + '/sync', { headers: auth(h.token) })).status, 200);
    assert.equal((await fetch(h.base + '/sync', { headers: { Authorization: 'Bearer wrong' } })).status, 401);
  } finally { h.server.close(); }
});

test('exact JSON MIME: a substring content-type is rejected (415)', async () => {
  const h = await boot();
  try {
    assert.equal((await fetch(h.base + '/actions/execute', { method: 'POST', headers: { ...auth(h.token), 'content-type': 'text/plain; x=application/json' }, body: '{}' })).status, 415);
    assert.equal((await fetch(h.base + '/actions/execute', { method: 'POST', headers: { ...auth(h.token), 'content-type': 'application/json; charset=utf-8' }, body: '{}' })).status, 400, 'valid JSON MIME with charset is accepted (then 400 for the missing proposal.id)');
  } finally { h.server.close(); }
});

test('streaming BYTE cap => 413 (not an EOF)', async () => {
  const h = await boot({ maxBody: 256 });
  try {
    const big = 'x'.repeat(2000);
    const r = await fetch(h.base + '/actions/execute', { method: 'POST', headers: { ...auth(h.token), 'content-type': 'application/json' }, body: big });
    assert.equal(r.status, 413);
  } finally { h.server.close(); }
});

test('POSITIVE disposable auth: no confirmation => writeback refused (422), never a fake posted', async () => {
  const h = await boot({ demoSession: DISPOSABLE }); // set but NOT confirmed
  assert.equal(h.writable, false);
  try {
    const p = { id: 'p1', kind: 'threadedReply', targetSessionId: DISPOSABLE, targetSequence: 5, renderedPreview: 'ok', requiresConfirmation: true, createdAt: '2026-07-18T12:00:00Z', sourceQuestionId: null };
    p.proposalHash = computeProposalHash(p);
    const r = await fetch(h.base + '/actions/execute', { method: 'POST', headers: { ...auth(h.token), 'content-type': 'application/json' }, body: JSON.stringify({ proposal: p, confirmation: { proposalId: p.id, confirmedProposalHash: p.proposalHash, confirmedAt: '2026-07-18T12:01:00Z' } }) });
    assert.equal(r.status, 422, 'unconfirmed disposable => refused, not writable');
    assert.equal((await r.json()).error, 'proposal_rejected');
  } finally { h.server.close(); }
});

test('POSITIVE disposable auth: explicit confirmation => real (mocked) governed write-back posts', async () => {
  const state = { replies: 0 };
  const h = await boot({ demoSession: DISPOSABLE, disposableConfirm: DISPOSABLE, run: mockRun(state) });
  assert.equal(h.writable, true);
  try {
    const p = { id: 'p2', kind: 'threadedReply', targetSessionId: DISPOSABLE, targetSequence: 5, renderedPreview: 'Approved on stage.', requiresConfirmation: true, createdAt: '2026-07-18T12:00:00Z', sourceQuestionId: null };
    p.proposalHash = computeProposalHash(p);
    const r = await fetch(h.base + '/actions/execute', { method: 'POST', headers: { ...auth(h.token), 'content-type': 'application/json' }, body: JSON.stringify({ proposal: p, confirmation: { proposalId: p.id, confirmedProposalHash: p.proposalHash, confirmedAt: '2026-07-18T12:01:30Z' } }) });
    assert.equal(r.status, 200);
    const j = await r.json();
    assert.equal(j.status, 'posted');
    assert.ok(j.signature);
    assert.equal(state.replies, 1);
  } finally { h.server.close(); }
});
