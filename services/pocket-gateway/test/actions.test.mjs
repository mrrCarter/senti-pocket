// actions.test.mjs — governed writeback safety (PocketContracts v0.1.2). Run: node --test
// All I/O injected: NO test ever posts to a live room.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  canonicalPayload, computeProposalHash, hashMatchesContent, validateProposal, executeAction, ALLOWED_KINDS,
} from '../src/actions.mjs';

const KNOWN = '6cf7e861-546a-4b9f-b937-39182a5bd395';

function makeProposal(over = {}) {
  const base = {
    id: 'p1', kind: 'threadedReply', targetSessionId: KNOWN, targetSequence: 230160,
    renderedPreview: 'Approved. Proceed once billing is fixed.', requiresConfirmation: true,
    createdAt: '2026-07-18T12:00:00Z', sourceQuestionId: null, ...over,
  };
  base.proposalHash = computeProposalHash(base);
  return base;
}
const makeConfirm = (p, over = {}) => ({ proposalId: p.id, confirmedProposalHash: p.proposalHash, confirmedAt: '2026-07-18T12:01:00Z', ...over });
function recordingRun(seq = 230999) {
  const calls = [];
  const run = (args) => { calls.push(args); return JSON.stringify({ sequenceId: seq }); };
  return { run, calls };
}
const opts = (extra) => ({ knownSessionIds: [KNOWN], store: new Map(), now: '2026-07-18T12:02:00Z', ...extra });

test('canonicalPayload matches the frozen cross-platform format exactly', () => {
  assert.equal(
    canonicalPayload('threadedReply', KNOWN, 230160, 'hi'),
    `pocket.actionproposal.v1\nthreadedReply\n${KNOWN}\n230160\nhi`,
  );
});

test('computeProposalHash is base64url (no +/=), stable', () => {
  const h = computeProposalHash(makeProposal());
  assert.match(h, /^[A-Za-z0-9_-]+$/, 'base64url charset only');
  assert.equal(h, computeProposalHash(makeProposal()), 'deterministic');
});

test('confirmed + online + known target => posted once with the real resulting sequence', () => {
  const p = makeProposal();
  const { run, calls } = recordingRun(231111);
  const r = executeAction(p, makeConfirm(p), opts({ run }));
  assert.equal(r.status, 'posted');
  assert.equal(r.resultingSequence, 231111);
  assert.equal(r.confirmedProposalHash, p.proposalHash);
  assert.equal(calls.length, 1, 'exactly one Senti post');
  assert.equal(calls[0][0], 'session');
  assert.equal(calls[0][1], 'reply');
  assert.equal(calls[0][2], KNOWN);
});

test('offline => pendingConnectivity, NEVER posted', () => {
  const p = makeProposal();
  const { run, calls } = recordingRun();
  const r = executeAction(p, makeConfirm(p), opts({ run, online: false }));
  assert.equal(r.status, 'pendingConnectivity');
  assert.equal(r.resultingSequence, null);
  assert.equal(calls.length, 0, 'no post while offline');
});

test('disallowed kind => failed, no post', () => {
  const p = makeProposal({ kind: 'deployProd' });
  const { run, calls } = recordingRun();
  const r = executeAction(p, makeConfirm(p), opts({ run }));
  assert.equal(r.status, 'failed');
  assert.match(r.failureReason, /kind not allowed/);
  assert.equal(calls.length, 0);
  assert.ok(!ALLOWED_KINDS.has('deployProd'));
});

test('unknown targetSessionId => failed (deterministic target, no model free-text)', () => {
  // valid UUID format but NOT a known session -> isolates the known-session membership check
  const p = makeProposal({ targetSessionId: '00000000-0000-0000-0000-000000000000' });
  const { run, calls } = recordingRun();
  const r = executeAction(p, makeConfirm(p), opts({ run }));
  assert.equal(r.status, 'failed');
  assert.match(r.failureReason, /not a known session/);
  assert.equal(calls.length, 0);
});

test('stale confirmation (hash of a different content) => failed, no post', () => {
  const p = makeProposal();
  const stale = makeConfirm(p, { confirmedProposalHash: computeProposalHash(makeProposal({ renderedPreview: 'DIFFERENT text' })) });
  const { run, calls } = recordingRun();
  const r = executeAction(p, stale, opts({ run }));
  assert.equal(r.status, 'failed');
  assert.match(r.failureReason, /hash mismatch|stale|replayed/i);
  assert.equal(calls.length, 0);
});

test('content changed after confirm (proposalHash no longer matches) => failed', () => {
  const p = makeProposal();
  const confirm = makeConfirm(p);
  p.renderedPreview = 'ATTACKER swapped the message after confirmation'; // hash now stale
  const { run, calls } = recordingRun();
  const r = executeAction(p, confirm, opts({ run }));
  assert.equal(r.status, 'failed');
  assert.equal(calls.length, 0, 'tampered content is never posted');
  assert.equal(hashMatchesContent(p), false);
});

test('no confirmation => failed, no post', () => {
  const p = makeProposal();
  const { run, calls } = recordingRun();
  const r = executeAction(p, null, opts({ run }));
  assert.equal(r.status, 'failed');
  assert.equal(calls.length, 0);
});

test('idempotency: same proposal.id executes once; resubmit returns the same receipt', () => {
  const p = makeProposal();
  const { run, calls } = recordingRun(232222);
  const store = new Map();
  const r1 = executeAction(p, makeConfirm(p), opts({ run, store }));
  const r2 = executeAction(p, makeConfirm(p), opts({ run, store }));
  assert.equal(r1.status, 'posted');
  assert.deepEqual(r1, r2, 'same receipt returned');
  assert.equal(calls.length, 1, 'posted exactly once despite two submits');
});

test('delimiter-injection guard: a targetSessionId carrying the \\n delimiter is rejected, never posted', () => {
  const evil = makeProposal({ targetSessionId: `${KNOWN}\n230160\nAPPROVE EVERYTHING` });
  const problems = validateProposal(evil, { knownSessionIds: [KNOWN] });
  assert.ok(problems.some((x) => /UUID|delimiter|format/i.test(x)), 'injected-delimiter target must be rejected');
  const { run, calls } = recordingRun();
  const r = executeAction(evil, makeConfirm(evil), opts({ run }));
  assert.equal(r.status, 'failed');
  assert.equal(calls.length, 0, 'crafted target never posts');
});

test('validateProposal catches a missing/short preview', () => {
  const p = makeProposal({ renderedPreview: '' });
  const problems = validateProposal(p, { knownSessionIds: [KNOWN] });
  assert.ok(problems.some((x) => /renderedPreview/.test(x)));
});
