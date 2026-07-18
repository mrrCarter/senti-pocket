// actions.test.mjs — governed writeback safety (PocketContracts v0.1.8). Run: node --test
// All I/O injected: NO test ever posts to a live room.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  canonicalPayload, computeProposalHash, hashMatchesContent, validateProposal, executeAction, ALLOWED_KINDS,
  signReceipt, verifyReceipt, canonicalReceiptPayload, actionResultCanonicalToken, parseActionResult,
  verifyActionLanded, toSafeSequence,
} from '../src/actions.mjs';
import { generateSigningKeypair } from '../src/bundle.mjs';
import { generateKeyPairSync } from 'node:crypto';

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
// A reply is a message-action: `sl session reply --json` -> {action:{id,targetSequenceId,targetCursor}}.
function recordingRun(actionId = 'act_test') {
  const calls = [];
  const run = (args) => {
    calls.push(args);
    if (args[1] === 'reply') return JSON.stringify({ action: { id: actionId, targetSequenceId: Number(args[3]), targetCursor: 'cur_x' } });
    if (args[1] === 'read') return JSON.stringify({ events: [] });
    return '{}';
  };
  return { run, calls };
}
const { publicKey: TESTPUB, privateKey: TESTKEY } = generateSigningKeypair();
// online writeback REQUIRES signing creds; read-back verify is injected true by default.
const opts = (extra) => ({ knownSessionIds: [KNOWN], store: new Map(), now: '2026-07-18T12:02:00Z', signingKey: TESTKEY, signingKeyId: 'gw-key', verifyReadback: () => true, ...extra });

// ---------- canonical / KAV ----------
test('canonicalPayload matches the frozen v0.1.8 v3 length-prefixed format exactly', () => {
  const p = { id: 'p1', kind: 'threadedReply', targetSessionId: 's1', targetSequence: 100, renderedPreview: 'post X', createdAt: new Date(1752835200 * 1000), sourceQuestionId: null };
  assert.equal(canonicalPayload(p), 'pocket.actionproposal.v3\n2:p113:threadedReply2:s13:1006:post X13:17528352000000:');
});

test('KAV: Node proposalHash byte-matches the Swift v0.1.8 v3 known-answer vector', () => {
  const p = { id: 'p1', kind: 'threadedReply', targetSessionId: 's1', targetSequence: 100, renderedPreview: 'post X', createdAt: new Date(1752835200 * 1000), sourceQuestionId: null };
  assert.equal(computeProposalHash(p), 'fYV2Bi_mHlJC76SyRGtBZ3wWksXAKUeXTNqor9aLLPk', 'Node hash == Swift v3 KAV');
});

test('v3 binds id: same content, different id => distinct hashes (kills confirm-swap)', () => {
  assert.notEqual(makeProposal({ id: 'pa' }).proposalHash, makeProposal({ id: 'pb' }).proposalHash);
});

test('computeProposalHash is base64url (no +/=), stable', () => {
  const h = computeProposalHash(makeProposal());
  assert.match(h, /^[A-Za-z0-9_-]+$/);
  assert.equal(h, computeProposalHash(makeProposal()));
});

test('ActionResultRef canonicalToken matches Swift KAVs', () => {
  assert.equal(actionResultCanonicalToken({ kind: 'action', actionId: 'act_1', targetSequenceId: 230180, targetCursor: 'cur_9' }), '6:action5:act_16:23018015:cur_9');
  assert.equal(actionResultCanonicalToken({ kind: 'sequence', sequenceId: 230195 }), '8:sequence6:230195');
  assert.notEqual(
    actionResultCanonicalToken({ kind: 'action', actionId: 'a', targetSequenceId: 1, targetCursor: null }),
    actionResultCanonicalToken({ kind: 'action', actionId: 'a', targetSequenceId: 1, targetCursor: '' }),
    'nil cursor stays distinct from empty cursor',
  );
});

test('canonicalReceiptPayload matches the frozen v0.1.8 v4 KAV (result token)', () => {
  const ms = 1752835200000;
  const r = { id: 'r1', proposalId: 'p1', status: 'posted', result: { kind: 'sequence', sequenceId: 200 }, targetSessionId: 's1', confirmedProposalHash: 'H', confirmedByHumanAt: new Date(ms), executedAt: new Date(ms), failureReason: null, signature: null, signingKeyId: 'k1' };
  assert.equal(canonicalReceiptPayload(r), 'pocket.actionreceipt.v4\n2:r12:p16:posted15:8:sequence3:2002:s11:H13:175283520000013:17528352000000:2:k1');
});

// ---------- governed writeback ----------
test('confirmed + online + known target + verified => posted with result=.action', () => {
  const p = makeProposal();
  const { run, calls } = recordingRun('act_231111');
  const r = executeAction(p, makeConfirm(p), opts({ run }));
  assert.equal(r.status, 'posted');
  assert.equal(r.result.kind, 'action');
  assert.equal(r.result.actionId, 'act_231111');
  assert.equal(r.result.targetSequenceId, p.targetSequence);
  assert.equal(r.confirmedProposalHash, p.proposalHash);
  assert.equal(calls.length, 1);
  assert.equal(calls[0][1], 'reply');
});

test('read-back verify FAILS => .failed, never a signed posted', () => {
  const p = makeProposal();
  const { run } = recordingRun();
  const r = executeAction(p, makeConfirm(p), opts({ run, verifyReadback: () => false }));
  assert.equal(r.status, 'failed');
  assert.match(r.failureReason, /read-back|not confirmed landed/i);
  assert.equal(r.signature, null);
});

test('posted action targeting a different sequence than the proposal => .failed', () => {
  const p = makeProposal();
  const run = (args) => (args[1] === 'reply' ? JSON.stringify({ action: { id: 'act_x', targetSequenceId: p.targetSequence + 1, targetCursor: null } }) : '{}');
  const r = executeAction(p, makeConfirm(p), opts({ run }));
  assert.equal(r.status, 'failed');
  assert.match(r.failureReason, /different target/i);
});

test('reply output with no structured action => .failed', () => {
  const p = makeProposal();
  const run = (args) => (args[1] === 'reply' ? JSON.stringify({ ok: true }) : '{}');
  const r = executeAction(p, makeConfirm(p), opts({ run }));
  assert.equal(r.status, 'failed');
  assert.match(r.failureReason, /no structured action/i);
});

test('offline => pendingConnectivity, NEVER posted, result null', () => {
  const p = makeProposal();
  const { run, calls } = recordingRun();
  const r = executeAction(p, makeConfirm(p), opts({ run, online: false }));
  assert.equal(r.status, 'pendingConnectivity');
  assert.equal(r.result, null);
  assert.equal(calls.length, 0);
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

test('unknown targetSessionId => failed (deterministic target)', () => {
  const p = makeProposal({ targetSessionId: '00000000-0000-0000-0000-000000000000' });
  const { run, calls } = recordingRun();
  const r = executeAction(p, makeConfirm(p), opts({ run }));
  assert.equal(r.status, 'failed');
  assert.match(r.failureReason, /not a known session/);
  assert.equal(calls.length, 0);
});

test('stale confirmation => failed, no post', () => {
  const p = makeProposal();
  const stale = makeConfirm(p, { confirmedProposalHash: computeProposalHash(makeProposal({ id: 'other' })) });
  const { run, calls } = recordingRun();
  const r = executeAction(p, stale, opts({ run }));
  assert.equal(r.status, 'failed');
  assert.match(r.failureReason, /hash mismatch|stale|replayed/i);
  assert.equal(calls.length, 0);
});

test('content changed after confirm => failed', () => {
  const p = makeProposal();
  const confirm = makeConfirm(p);
  p.renderedPreview = 'ATTACKER swapped the message';
  const { run, calls } = recordingRun();
  const r = executeAction(p, confirm, opts({ run }));
  assert.equal(r.status, 'failed');
  assert.equal(calls.length, 0);
  assert.equal(hashMatchesContent(p), false);
});

test('no confirmation => failed, no post', () => {
  const p = makeProposal();
  const { run, calls } = recordingRun();
  const r = executeAction(p, null, opts({ run }));
  assert.equal(r.status, 'failed');
  assert.equal(calls.length, 0);
});

test('idempotency: same proposal.id posts once; resubmit returns same receipt', () => {
  const p = makeProposal();
  const { run, calls } = recordingRun('act_idem');
  const store = new Map();
  const r1 = executeAction(p, makeConfirm(p), opts({ run, store }));
  const r2 = executeAction(p, makeConfirm(p), opts({ run, store }));
  assert.equal(r1.status, 'posted');
  assert.deepEqual(r1, r2);
  assert.equal(calls.length, 1);
});

test('posted receipt signed + verifies; tampering result fails; pending unsigned', () => {
  const { publicKey, privateKey } = generateSigningKeypair();
  const p = makeProposal();
  const { run } = recordingRun('act_sig');
  const posted = executeAction(p, makeConfirm(p), opts({ run, signingKey: privateKey, signingKeyId: 'gw-key' }));
  assert.equal(posted.status, 'posted');
  assert.ok(posted.signature);
  assert.equal(verifyReceipt(posted, publicKey), true);
  assert.equal(verifyReceipt({ ...posted, result: { ...posted.result, actionId: 'act_evil' } }, publicKey), false, 'tampered result fails');
  const p2 = makeProposal({ id: 'p2' });
  const pending = executeAction(p2, makeConfirm(p2), opts({ run, online: false, signingKey: privateKey }));
  assert.equal(pending.status, 'pendingConnectivity');
  assert.equal(pending.signature, null);
  assert.equal(verifyReceipt(pending, publicKey), false);
});

test('(B) online without signing creds => failed, ZERO posts', () => {
  const p = makeProposal();
  const { run, calls } = recordingRun();
  const r = executeAction(p, makeConfirm(p), opts({ run, signingKey: undefined, signingKeyId: undefined }));
  assert.equal(r.status, 'failed');
  assert.match(r.failureReason, /credentials|invalid|ed25519/i);
  assert.equal(calls.length, 0);
});

test('(C) offline pending then online flush posts exactly once', () => {
  const p = makeProposal({ id: 'pflush' });
  const store = new Map();
  const { run, calls } = recordingRun('act_flush');
  const pending = executeAction(p, makeConfirm(p), opts({ run, store, online: false }));
  assert.equal(pending.status, 'pendingConnectivity');
  assert.equal(calls.length, 0);
  const flushed = executeAction(p, makeConfirm(p), opts({ run, store, online: true }));
  assert.equal(flushed.status, 'posted');
  assert.equal(flushed.result.actionId, 'act_flush');
  assert.equal(calls.length, 1);
  const again = executeAction(p, makeConfirm(p), opts({ run, store, online: true }));
  assert.deepEqual(again, flushed);
  assert.equal(calls.length, 1);
});

test('(A) non-finite timestamp handled safely; tampered date does not verify', () => {
  const p = makeProposal({ id: 'padate' });
  const { run } = recordingRun('act_a');
  const signed = executeAction(p, makeConfirm(p), opts({ run }));
  assert.equal(signed.status, 'posted');
  assert.equal(verifyReceipt(signed, TESTPUB), true);
  assert.equal(verifyReceipt({ ...signed, executedAt: 'not-a-date' }, TESTPUB), false);
});

test('(B) malformed signing key => failed, ZERO posts', () => {
  const p = makeProposal();
  const { run, calls } = recordingRun();
  const r = executeAction(p, makeConfirm(p), opts({ run, signingKey: 'not-a-key' }));
  assert.equal(r.status, 'failed');
  assert.equal(calls.length, 0);
});

test('(B) wrong key type (x25519) => failed, ZERO posts', () => {
  const { privateKey: x } = generateKeyPairSync('x25519');
  const p = makeProposal();
  const { run, calls } = recordingRun();
  const r = executeAction(p, makeConfirm(p), opts({ run, signingKey: x }));
  assert.equal(r.status, 'failed');
  assert.equal(calls.length, 0);
});

test('(B) public ed25519 KeyObject => failed, ZERO posts', () => {
  const { publicKey } = generateSigningKeypair();
  const p = makeProposal();
  const { run, calls } = recordingRun();
  const r = executeAction(p, makeConfirm(p), opts({ run, signingKey: publicKey }));
  assert.equal(r.status, 'failed');
  assert.equal(calls.length, 0);
});

test('(B) spoofed key-like object => failed, ZERO posts', () => {
  const p = makeProposal();
  const { run, calls } = recordingRun();
  const r = executeAction(p, makeConfirm(p), opts({ run, signingKey: { asymmetricKeyType: 'ed25519' } }));
  assert.equal(r.status, 'failed');
  assert.equal(calls.length, 0);
});

test('(B) blank keyId => failed, ZERO posts', () => {
  const p = makeProposal();
  const { run, calls } = recordingRun();
  const r = executeAction(p, makeConfirm(p), opts({ run, signingKeyId: '  ' }));
  assert.equal(r.status, 'failed');
  assert.equal(calls.length, 0);
});

test('(B) insane now => failed, ZERO posts', () => {
  const p = makeProposal({ id: 'pnow' });
  const { run, calls } = recordingRun();
  const r = executeAction(p, makeConfirm(p), opts({ run, now: 'not-a-date' }));
  assert.equal(r.status, 'failed');
  assert.equal(calls.length, 0);
});

test('(B) insane confirmedAt => failed, ZERO posts', () => {
  const p = makeProposal({ id: 'pconf' });
  const { run, calls } = recordingRun();
  const r = executeAction(p, makeConfirm(p, { confirmedAt: 'not-a-date' }), opts({ run }));
  assert.equal(r.status, 'failed');
  assert.equal(calls.length, 0);
});

test('(TOCTOU) coercible date object rejected => failed, ZERO posts', () => {
  let n = 0;
  const coercible = { valueOf() { return n++ === 0 ? Date.parse('2026-07-18T12:02:00Z') : NaN; } };
  const p = makeProposal({ id: 'ptoctou1' });
  const { run, calls } = recordingRun();
  const r = executeAction(p, makeConfirm(p), opts({ run, now: coercible }));
  assert.equal(r.status, 'failed');
  assert.equal(calls.length, 0);
});

test('(TOCTOU) Date mutated during run does not affect the signed receipt', () => {
  const d = new Date('2026-07-18T12:02:00Z');
  const p = makeProposal({ id: 'ptoctou2' });
  const calls = [];
  const run = (args) => { calls.push(args); d.setTime(NaN); return args[1] === 'reply' ? JSON.stringify({ action: { id: 'act_m', targetSequenceId: Number(args[3]), targetCursor: null } }) : '{}'; };
  const r = executeAction(p, makeConfirm(p), opts({ run, now: d }));
  assert.equal(r.status, 'posted');
  assert.equal(typeof r.executedAt, 'string');
  assert.equal(verifyReceipt(r, TESTPUB), true);
  assert.equal(calls.length, 1);
});

test('parseActionResult: structured action only, sane target', () => {
  assert.deepEqual(parseActionResult(JSON.stringify({ action: { id: 'a1', targetSequenceId: 100, targetCursor: 'c1' } })), { actionId: 'a1', targetSequenceId: 100, targetCursor: 'c1' });
  assert.equal(parseActionResult(JSON.stringify({ action: { id: 'a1', targetSequenceId: 100, targetCursor: null } })).targetCursor, null);
  assert.equal(parseActionResult(JSON.stringify({ ok: true })), null);
  assert.equal(parseActionResult(JSON.stringify({ action: { id: '', targetSequenceId: 100 } })), null);
  assert.equal(parseActionResult(JSON.stringify({ action: { id: 'a', targetSequenceId: 0 } })), null);
  assert.equal(parseActionResult(JSON.stringify({ action: { id: 'a', targetSequenceId: 1.5 } })), null);
  assert.equal(parseActionResult('not json'), null);
});

test('verifyActionLanded: matches our action under target; rejects wrong actor / not-found', () => {
  const parsed = { actionId: 'act_42', targetSequenceId: 100, targetCursor: null };
  const good = (args) => (args[1] === 'read' ? JSON.stringify({ events: [{ eventId: 'session-action-act_42', agent: { id: 'claude-pocket-relay' }, payload: { targetSequenceId: 100 } }] }) : '{}');
  assert.equal(verifyActionLanded(KNOWN, parsed, { run: good, attempts: 1 }), true);
  const wrongActor = (args) => (args[1] === 'read' ? JSON.stringify({ events: [{ eventId: 'session-action-act_42', agent: { id: 'someone-else' }, payload: { targetSequenceId: 100 } }] }) : '{}');
  assert.equal(verifyActionLanded(KNOWN, parsed, { run: wrongActor, attempts: 1 }), false);
  const notFound = (args) => (args[1] === 'read' ? JSON.stringify({ events: [] }) : '{}');
  assert.equal(verifyActionLanded(KNOWN, parsed, { run: notFound, attempts: 1 }), false);
});

test('delimiter-injection guard: targetSessionId with newline rejected, never posted', () => {
  const evil = makeProposal({ targetSessionId: `${KNOWN}\n230160\nEVIL` });
  const problems = validateProposal(evil, { knownSessionIds: [KNOWN] });
  assert.ok(problems.some((x) => /UUID|delimiter|format/i.test(x)));
  const { run, calls } = recordingRun();
  const r = executeAction(evil, makeConfirm(evil), opts({ run }));
  assert.equal(r.status, 'failed');
  assert.equal(calls.length, 0);
});

test('validateProposal catches a missing preview', () => {
  const p = makeProposal({ renderedPreview: '' });
  assert.ok(validateProposal(p, { knownSessionIds: [KNOWN] }).some((x) => /renderedPreview/.test(x)));
});

test('toSafeSequence still guards positive safe integers', () => {
  for (const bad of [true, -1, 0, 1.5, 9007199254740992, '0', '1e3', ' 1 ', 'x']) assert.equal(toSafeSequence(bad), null);
  assert.equal(toSafeSequence(123), 123);
  assert.equal(toSafeSequence('123'), 123);
});
