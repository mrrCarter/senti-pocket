// actions.test.mjs — governed writeback safety (PocketContracts v0.1.8). Run: node --test
// All I/O injected: NO test ever posts to a live room.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  canonicalPayload, computeProposalHash, hashMatchesContent, validateProposal, executeAction, ALLOWED_KINDS,
  signReceipt, verifyReceipt, canonicalReceiptPayload, actionResultCanonicalToken, parseActionResult,
  verifyActionLanded, verifyHumanMessageLanded, parseHumanMessageResult, toSafeSequence, snapshotProposal, validateActionResultRef,
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
test('canonicalPayload matches the frozen v0.1.8 v3 format exactly (@7e1cfbe, sourceQuestionId presence-flag)', async () => {
  const p = { id: 'p1', kind: 'threadedReply', targetSessionId: 's1', targetSequence: 100, renderedPreview: 'post X', createdAt: new Date(1752835200 * 1000), sourceQuestionId: null };
  // sourceQuestionId=null -> presence flag "0" (not lp("")); tail is ...13:17528352000000 + 0
  assert.equal(canonicalPayload(p), 'pocket.actionproposal.v3\n2:p113:threadedReply2:s13:1006:post X13:17528352000000');
});

test('KAV: humanMessage(seq=0) canonicalPayload + proposalHash pin Node<->Swift byte-parity (Forge #2 — cross-verify on Mac)', () => {
  // THE authority path posts AS human-mrrcarter (Carter himself) — asserted != tested until this KAV is green on
  // BOTH impls. Swift ActionProposal.computeHash MUST produce these identical canonical bytes + hash for this proposal.
  const p = { id: 'p1', kind: 'humanMessage', targetSessionId: 's1', targetSequence: 0, renderedPreview: 'post X', createdAt: new Date(1752835200 * 1000), sourceQuestionId: null };
  // seq=0 -> "1:0" sentinel (lp(String(0))="1:0", byte-exact w/ Swift @9842cef); kind -> "12:humanMessage".
  assert.equal(canonicalPayload(p), 'pocket.actionproposal.v3\n2:p112:humanMessage2:s11:06:post X13:17528352000000');
  assert.equal(computeProposalHash(p), 'NaD2_tUZjseqqQzhGfROsNKxELJOYyHCWsmeVW9dmFM');
});

test('KAV: Node proposalHash byte-matches the Swift v0.1.8 v3 known-answer vector (@7e1cfbe)', async () => {
  const p = { id: 'p1', kind: 'threadedReply', targetSessionId: 's1', targetSequence: 100, renderedPreview: 'post X', createdAt: new Date(1752835200 * 1000), sourceQuestionId: null };
  assert.equal(computeProposalHash(p), 'Wk4lhnUOCRAiFMXVaroaDiv2lyHsRGJsmAJg_mjm1NY', 'Node hash == Swift v3 KAV @7e1cfbe');
});

test('sourceQuestionId presence flag: null distinct from empty string', async () => {
  const base = { id: 'p1', kind: 'threadedReply', targetSessionId: 's1', targetSequence: 100, renderedPreview: 'x', createdAt: new Date(1752835200 * 1000) };
  assert.notEqual(canonicalPayload({ ...base, sourceQuestionId: null }), canonicalPayload({ ...base, sourceQuestionId: '' }));
});

test('v3 binds id: same content, different id => distinct hashes (kills confirm-swap)', async () => {
  assert.notEqual(makeProposal({ id: 'pa' }).proposalHash, makeProposal({ id: 'pb' }).proposalHash);
});

test('computeProposalHash is base64url (no +/=), stable', async () => {
  const h = computeProposalHash(makeProposal());
  assert.match(h, /^[A-Za-z0-9_-]+$/);
  assert.equal(h, computeProposalHash(makeProposal()));
});

test('ActionResultRef canonicalToken matches Swift KAVs', async () => {
  assert.equal(actionResultCanonicalToken({ kind: 'action', actionId: 'act_1', targetSequenceId: 230180, targetCursor: 'cur_9' }), '6:action5:act_16:23018015:cur_9');
  assert.equal(actionResultCanonicalToken({ kind: 'sequence', sequenceId: 230195 }), '8:sequence6:230195');
  assert.notEqual(
    actionResultCanonicalToken({ kind: 'action', actionId: 'a', targetSequenceId: 1, targetCursor: null }),
    actionResultCanonicalToken({ kind: 'action', actionId: 'a', targetSequenceId: 1, targetCursor: '' }),
    'nil cursor stays distinct from empty cursor',
  );
});

test('canonicalReceiptPayload matches the frozen v0.1.8 v4 KAV (result token)', async () => {
  const ms = 1752835200000;
  const r = { id: 'r1', proposalId: 'p1', status: 'posted', result: { kind: 'sequence', sequenceId: 200 }, targetSessionId: 's1', confirmedProposalHash: 'H', confirmedByHumanAt: new Date(ms), executedAt: new Date(ms), failureReason: null, signature: null, signingKeyId: 'k1' };
  assert.equal(canonicalReceiptPayload(r), 'pocket.actionreceipt.v4\n2:r12:p16:posted15:8:sequence3:2002:s11:H13:175283520000013:17528352000000:2:k1');
});

// ---------- governed writeback ----------
test('confirmed + online + known target + verified => posted with result=.action', async () => {
  const p = makeProposal();
  const { run, calls } = recordingRun('act_231111');
  const r = await executeAction(p, makeConfirm(p), opts({ run }));
  assert.equal(r.status, 'posted');
  assert.equal(r.result.kind, 'action');
  assert.equal(r.result.actionId, 'act_231111');
  assert.equal(r.result.targetSequenceId, p.targetSequence);
  assert.equal(r.confirmedProposalHash, p.proposalHash);
  assert.equal(calls.length, 1);
  assert.equal(calls[0][1], 'reply');
});

test('read-back verify FAILS => .failed, never a signed posted', async () => {
  const p = makeProposal();
  const { run } = recordingRun();
  const r = await executeAction(p, makeConfirm(p), opts({ run, verifyReadback: () => false }));
  assert.equal(r.status, 'failed');
  assert.match(r.failureReason, /read-back|not confirmed landed/i);
  assert.equal(r.signature, null);
});

test('posted action targeting a different sequence than the proposal => .failed', async () => {
  const p = makeProposal();
  const run = (args) => (args[1] === 'reply' ? JSON.stringify({ action: { id: 'act_x', targetSequenceId: p.targetSequence + 1, targetCursor: null } }) : '{}');
  const r = await executeAction(p, makeConfirm(p), opts({ run }));
  assert.equal(r.status, 'failed');
  assert.match(r.failureReason, /different target/i);
});

test('reply output with no structured action => .failed', async () => {
  const p = makeProposal();
  const run = (args) => (args[1] === 'reply' ? JSON.stringify({ ok: true }) : '{}');
  const r = await executeAction(p, makeConfirm(p), opts({ run }));
  assert.equal(r.status, 'failed');
  assert.match(r.failureReason, /no structured action/i);
});

test('offline => pendingConnectivity, NEVER posted, result null', async () => {
  const p = makeProposal();
  const { run, calls } = recordingRun();
  const r = await executeAction(p, makeConfirm(p), opts({ run, online: false }));
  assert.equal(r.status, 'pendingConnectivity');
  assert.equal(r.result, null);
  assert.equal(calls.length, 0);
});

test('disallowed kind => failed, no post', async () => {
  const p = makeProposal({ kind: 'deployProd' });
  const { run, calls } = recordingRun();
  const r = await executeAction(p, makeConfirm(p), opts({ run }));
  assert.equal(r.status, 'failed');
  assert.match(r.failureReason, /kind not allowed/);
  assert.equal(calls.length, 0);
  assert.ok(!ALLOWED_KINDS.has('deployProd'));
});

test('unknown targetSessionId => failed (deterministic target)', async () => {
  const p = makeProposal({ targetSessionId: '00000000-0000-0000-0000-000000000000' });
  const { run, calls } = recordingRun();
  const r = await executeAction(p, makeConfirm(p), opts({ run }));
  assert.equal(r.status, 'failed');
  assert.match(r.failureReason, /not a known session/);
  assert.equal(calls.length, 0);
});

test('stale confirmation => failed, no post', async () => {
  const p = makeProposal();
  const stale = makeConfirm(p, { confirmedProposalHash: computeProposalHash(makeProposal({ id: 'other' })) });
  const { run, calls } = recordingRun();
  const r = await executeAction(p, stale, opts({ run }));
  assert.equal(r.status, 'failed');
  assert.match(r.failureReason, /hash mismatch|stale|replayed/i);
  assert.equal(calls.length, 0);
});

test('content changed after confirm => failed', async () => {
  const p = makeProposal();
  const confirm = makeConfirm(p);
  p.renderedPreview = 'ATTACKER swapped the message';
  const { run, calls } = recordingRun();
  const r = await executeAction(p, confirm, opts({ run }));
  assert.equal(r.status, 'failed');
  assert.equal(calls.length, 0);
  assert.equal(hashMatchesContent(p), false);
});

test('no confirmation => failed, no post', async () => {
  const p = makeProposal();
  const { run, calls } = recordingRun();
  const r = await executeAction(p, null, opts({ run }));
  assert.equal(r.status, 'failed');
  assert.equal(calls.length, 0);
});

test('idempotency: same proposal.id posts once; resubmit returns same receipt', async () => {
  const p = makeProposal();
  const { run, calls } = recordingRun('act_idem');
  const store = new Map();
  const r1 = await executeAction(p, makeConfirm(p), opts({ run, store }));
  const r2 = await executeAction(p, makeConfirm(p), opts({ run, store }));
  assert.equal(r1.status, 'posted');
  assert.deepEqual(r1, r2);
  assert.equal(calls.length, 1);
});

test('posted receipt signed + verifies; tampering result fails; pending unsigned', async () => {
  const { publicKey, privateKey } = generateSigningKeypair();
  const p = makeProposal();
  const { run } = recordingRun('act_sig');
  const posted = await executeAction(p, makeConfirm(p), opts({ run, signingKey: privateKey, signingKeyId: 'gw-key' }));
  assert.equal(posted.status, 'posted');
  assert.ok(posted.signature);
  assert.equal(verifyReceipt(posted, publicKey), true);
  assert.equal(verifyReceipt({ ...posted, result: { ...posted.result, actionId: 'act_evil' } }, publicKey), false, 'tampered result fails');
  const p2 = makeProposal({ id: 'p2' });
  const pending = await executeAction(p2, makeConfirm(p2), opts({ run, online: false, signingKey: privateKey }));
  assert.equal(pending.status, 'pendingConnectivity');
  assert.equal(pending.signature, null);
  assert.equal(verifyReceipt(pending, publicKey), false);
});

test('(B) online without signing creds => failed, ZERO posts', async () => {
  const p = makeProposal();
  const { run, calls } = recordingRun();
  const r = await executeAction(p, makeConfirm(p), opts({ run, signingKey: undefined, signingKeyId: undefined }));
  assert.equal(r.status, 'failed');
  assert.match(r.failureReason, /credentials|invalid|ed25519/i);
  assert.equal(calls.length, 0);
});

test('(C) offline pending then online flush posts exactly once', async () => {
  const p = makeProposal({ id: 'pflush' });
  const store = new Map();
  const { run, calls } = recordingRun('act_flush');
  const pending = await executeAction(p, makeConfirm(p), opts({ run, store, online: false }));
  assert.equal(pending.status, 'pendingConnectivity');
  assert.equal(calls.length, 0);
  const flushed = await executeAction(p, makeConfirm(p), opts({ run, store, online: true }));
  assert.equal(flushed.status, 'posted');
  assert.equal(flushed.result.actionId, 'act_flush');
  assert.equal(calls.length, 1);
  const again = await executeAction(p, makeConfirm(p), opts({ run, store, online: true }));
  assert.deepEqual(again, flushed);
  assert.equal(calls.length, 1);
});

test('(A) non-finite timestamp handled safely; tampered date does not verify', async () => {
  const p = makeProposal({ id: 'padate' });
  const { run } = recordingRun('act_a');
  const signed = await executeAction(p, makeConfirm(p), opts({ run }));
  assert.equal(signed.status, 'posted');
  assert.equal(verifyReceipt(signed, TESTPUB), true);
  assert.equal(verifyReceipt({ ...signed, executedAt: 'not-a-date' }, TESTPUB), false);
});

test('(B) malformed signing key => failed, ZERO posts', async () => {
  const p = makeProposal();
  const { run, calls } = recordingRun();
  const r = await executeAction(p, makeConfirm(p), opts({ run, signingKey: 'not-a-key' }));
  assert.equal(r.status, 'failed');
  assert.equal(calls.length, 0);
});

test('(B) wrong key type (x25519) => failed, ZERO posts', async () => {
  const { privateKey: x } = generateKeyPairSync('x25519');
  const p = makeProposal();
  const { run, calls } = recordingRun();
  const r = await executeAction(p, makeConfirm(p), opts({ run, signingKey: x }));
  assert.equal(r.status, 'failed');
  assert.equal(calls.length, 0);
});

test('(B) public ed25519 KeyObject => failed, ZERO posts', async () => {
  const { publicKey } = generateSigningKeypair();
  const p = makeProposal();
  const { run, calls } = recordingRun();
  const r = await executeAction(p, makeConfirm(p), opts({ run, signingKey: publicKey }));
  assert.equal(r.status, 'failed');
  assert.equal(calls.length, 0);
});

test('(B) spoofed key-like object => failed, ZERO posts', async () => {
  const p = makeProposal();
  const { run, calls } = recordingRun();
  const r = await executeAction(p, makeConfirm(p), opts({ run, signingKey: { asymmetricKeyType: 'ed25519' } }));
  assert.equal(r.status, 'failed');
  assert.equal(calls.length, 0);
});

test('(B) blank keyId => failed, ZERO posts', async () => {
  const p = makeProposal();
  const { run, calls } = recordingRun();
  const r = await executeAction(p, makeConfirm(p), opts({ run, signingKeyId: '  ' }));
  assert.equal(r.status, 'failed');
  assert.equal(calls.length, 0);
});

test('(B) insane now => failed, ZERO posts', async () => {
  const p = makeProposal({ id: 'pnow' });
  const { run, calls } = recordingRun();
  const r = await executeAction(p, makeConfirm(p), opts({ run, now: 'not-a-date' }));
  assert.equal(r.status, 'failed');
  assert.equal(calls.length, 0);
});

test('(B) insane confirmedAt => failed, ZERO posts', async () => {
  const p = makeProposal({ id: 'pconf' });
  const { run, calls } = recordingRun();
  const r = await executeAction(p, makeConfirm(p, { confirmedAt: 'not-a-date' }), opts({ run }));
  assert.equal(r.status, 'failed');
  assert.equal(calls.length, 0);
});

test('(TOCTOU) coercible date object rejected => failed, ZERO posts', async () => {
  let n = 0;
  const coercible = { valueOf() { return n++ === 0 ? Date.parse('2026-07-18T12:02:00Z') : NaN; } };
  const p = makeProposal({ id: 'ptoctou1' });
  const { run, calls } = recordingRun();
  const r = await executeAction(p, makeConfirm(p), opts({ run, now: coercible }));
  assert.equal(r.status, 'failed');
  assert.equal(calls.length, 0);
});

test('(TOCTOU) Date mutated during run does not affect the signed receipt', async () => {
  const d = new Date('2026-07-18T12:02:00Z');
  const p = makeProposal({ id: 'ptoctou2' });
  const calls = [];
  const run = (args) => { calls.push(args); d.setTime(NaN); return args[1] === 'reply' ? JSON.stringify({ action: { id: 'act_m', targetSequenceId: Number(args[3]), targetCursor: null } }) : '{}'; };
  const r = await executeAction(p, makeConfirm(p), opts({ run, now: d }));
  assert.equal(r.status, 'posted');
  assert.equal(typeof r.executedAt, 'string');
  assert.equal(verifyReceipt(r, TESTPUB), true);
  assert.equal(calls.length, 1);
});

test('parseActionResult: structured action only, sane target', async () => {
  assert.deepEqual(parseActionResult(JSON.stringify({ action: { id: 'a1', targetSequenceId: 100, targetCursor: 'c1' } })), { actionId: 'a1', targetSequenceId: 100, targetCursor: 'c1' });
  assert.equal(parseActionResult(JSON.stringify({ action: { id: 'a1', targetSequenceId: 100, targetCursor: null } })).targetCursor, null);
  assert.equal(parseActionResult(JSON.stringify({ ok: true })), null);
  assert.equal(parseActionResult(JSON.stringify({ action: { id: '', targetSequenceId: 100 } })), null);
  assert.equal(parseActionResult(JSON.stringify({ action: { id: 'a', targetSequenceId: 0 } })), null);
  assert.equal(parseActionResult(JSON.stringify({ action: { id: 'a', targetSequenceId: 1.5 } })), null);
  assert.equal(parseActionResult('not json'), null);
});

test('verifyActionLanded: matches our action under target; rejects wrong actor / not-found', async () => {
  const parsed = { actionId: 'act_42', targetSequenceId: 100, targetCursor: null };
  const good = (args) => (args[1] === 'read' ? JSON.stringify({ events: [{ eventId: 'session-action-act_42', agent: { id: 'claude-pocket-relay' }, payload: { targetSequenceId: 100 } }] }) : '{}');
  assert.equal(verifyActionLanded(KNOWN, parsed, { run: good, attempts: 1 }), true);
  const wrongActor = (args) => (args[1] === 'read' ? JSON.stringify({ events: [{ eventId: 'session-action-act_42', agent: { id: 'someone-else' }, payload: { targetSequenceId: 100 } }] }) : '{}');
  assert.equal(verifyActionLanded(KNOWN, parsed, { run: wrongActor, attempts: 1 }), false);
  const notFound = (args) => (args[1] === 'read' ? JSON.stringify({ events: [] }) : '{}');
  assert.equal(verifyActionLanded(KNOWN, parsed, { run: notFound, attempts: 1 }), false);
});

test('delimiter-injection guard: targetSessionId with newline rejected, never posted', async () => {
  const evil = makeProposal({ targetSessionId: `${KNOWN}\n230160\nEVIL` });
  const problems = validateProposal(evil, { knownSessionIds: [KNOWN] });
  assert.ok(problems.some((x) => /UUID|delimiter|format/i.test(x)));
  const { run, calls } = recordingRun();
  const r = await executeAction(evil, makeConfirm(evil), opts({ run }));
  assert.equal(r.status, 'failed');
  assert.equal(calls.length, 0);
});

test('validateProposal catches a missing preview', async () => {
  const p = makeProposal({ renderedPreview: '' });
  assert.ok(validateProposal(p, { knownSessionIds: [KNOWN] }).some((x) => /renderedPreview/.test(x)));
});

test('toSafeSequence still guards positive safe integers', async () => {
  for (const bad of [true, -1, 0, 1.5, 9007199254740992, '0', '1e3', ' 1 ', 'x']) assert.equal(toSafeSequence(bad), null);
  assert.equal(toSafeSequence(123), 123);
  assert.equal(toSafeSequence('123'), 123);
});

test('(TOCTOU) getter-backed renderedPreview: EVIL content is never posted (snapshot reads once)', async () => {
  const SAFE = 'SAFE CONFIRMED';
  const base = { id: 'pgetter', kind: 'threadedReply', targetSessionId: KNOWN, targetSequence: 230160, requiresConfirmation: true, createdAt: '2026-07-18T12:00:00Z', sourceQuestionId: null };
  const safeHash = computeProposalHash({ ...base, renderedPreview: SAFE });
  let reads = 0;
  const evil = { ...base };
  Object.defineProperty(evil, 'renderedPreview', { enumerable: true, get() { return reads++ === 0 ? SAFE : 'EVIL POSTED'; } });
  Object.defineProperty(evil, 'proposalHash', { enumerable: true, value: safeHash });
  const confirmation = { proposalId: 'pgetter', confirmedProposalHash: safeHash, confirmedAt: '2026-07-18T12:01:00Z' };
  const { run, calls } = recordingRun('act_g');
  const r = await executeAction(evil, confirmation, opts({ run }));
  const postedPreview = (calls.find((c) => c[1] === 'reply') || [])[4];
  assert.notEqual(postedPreview, 'EVIL POSTED', 'EVIL content must never be posted');
  if (r.status === 'posted') assert.equal(postedPreview, SAFE);
});

// ---------- Echo exact-head regressions @3f149b7 (locked so they can never silently return) ----------
test('(TOCTOU/P1) SIGNED receipt binds SNAPSHOT identity, not a getter that flips id/session after snapshot', async () => {
  const EVIL_SESS = 'ffffffff-ffff-ffff-ffff-ffffffffffff';
  const base = { kind: 'threadedReply', targetSequence: 230160, renderedPreview: 'ok', requiresConfirmation: true, createdAt: '2026-07-18T12:00:00Z', sourceQuestionId: null };
  const goodHash = computeProposalHash({ ...base, id: 'good-id', targetSessionId: KNOWN });
  let idR = 0, sR = 0;
  const evil = { ...base };
  Object.defineProperty(evil, 'id', { enumerable: true, get() { return idR++ === 0 ? 'good-id' : 'EVIL-id'; } });
  Object.defineProperty(evil, 'targetSessionId', { enumerable: true, get() { return sR++ === 0 ? KNOWN : EVIL_SESS; } });
  Object.defineProperty(evil, 'proposalHash', { enumerable: true, value: goodHash });
  const confirmation = { proposalId: 'good-id', confirmedProposalHash: goodHash, confirmedAt: '2026-07-18T12:01:00Z' };
  const r = await executeAction(evil, confirmation, opts({ run: recordingRun('act_hg').run }));
  assert.equal(r.status, 'posted');
  // the ONE signed artifact must carry snapshot identity — never the post-snapshot EVIL flips.
  assert.equal(r.id, 'good-id');
  assert.equal(r.proposalId, 'good-id');
  assert.equal(r.targetSessionId, KNOWN);
  assert.notEqual(r.targetSessionId, EVIL_SESS);
  assert.equal(verifyReceipt(r, TESTPUB), true);
});

test('(atomicity/P0) read-back miss never re-posts on retry; the emitted action finalizes exactly-once', async () => {
  const p = makeProposal({ id: 'pdup' });
  const store = new Map();
  let posts = 0;
  const run = (args) => (args[1] === 'reply'
    ? (posts++, JSON.stringify({ action: { id: 'act_dup_' + posts, targetSequenceId: Number(args[3]), targetCursor: 'c' } }))
    : '{}');
  const r1 = await executeAction(p, makeConfirm(p), opts({ run, store, verifyReadback: () => false }));
  assert.equal(r1.status, 'failed');
  assert.equal(posts, 1);
  const r2 = await executeAction(p, makeConfirm(p), opts({ run, store, verifyReadback: () => false }));
  assert.equal(r2.status, 'failed');
  assert.equal(posts, 1, 'retry must NOT re-post an already-emitted governed write');
  const r3 = await executeAction(p, makeConfirm(p), opts({ run, store, verifyReadback: () => true }));
  assert.equal(r3.status, 'posted');
  assert.equal(posts, 1, 'finalize re-verifies the SAME emitted action; never re-posts');
  assert.equal(r3.result.actionId, 'act_dup_1');
  assert.equal(verifyReceipt(r3, TESTPUB), true);
});

test('(freshness/P0) NaN/negative/garbage freshness window cannot bypass the stale gate', async () => {
  const p = makeProposal({ id: 'pfresh', createdAt: '2000-01-01T00:00:00Z' });
  const ancient = makeConfirm(p, { confirmedAt: '2000-01-01T00:00:05Z' }); // years before `now`
  for (const bad of [{ freshnessSeconds: NaN }, { freshnessSeconds: -1 }, { clockSkewSeconds: NaN }, { freshnessSeconds: 'x' }, { freshnessSeconds: Infinity }]) {
    const { run, calls } = recordingRun();
    const r = await executeAction(p, ancient, opts({ run, store: new Map(), ...bad }));
    assert.equal(r.status, 'failed', JSON.stringify(bad));
    assert.match(r.failureReason, /freshness|stale|future/i);
    assert.equal(calls.length, 0, 'stale confirm must never post: ' + JSON.stringify(bad));
  }
});

test('(freshness) years-old confirmation => failed, ZERO posts', async () => {
  const p = makeProposal({ id: 'pold' });
  const { run, calls } = recordingRun();
  const r = await executeAction(p, makeConfirm(p, { confirmedAt: '2000-01-01T00:00:00Z' }), opts({ run, now: '2026-07-18T12:02:00Z' }));
  assert.equal(r.status, 'failed');
  assert.match(r.failureReason, /freshness|stale|future/i);
  assert.equal(calls.length, 0);
});

test('(freshness) far-future confirmation => failed, ZERO posts', async () => {
  const p = makeProposal({ id: 'pfut' });
  const { run, calls } = recordingRun();
  const r = await executeAction(p, makeConfirm(p, { confirmedAt: '2027-01-01T00:00:00Z' }), opts({ run, now: '2026-07-18T12:02:00Z' }));
  assert.equal(r.status, 'failed');
  assert.equal(calls.length, 0);
});

test('(fail-closed) omitted knownSessionIds => failed, ZERO posts (never trust any UUID)', async () => {
  const p = makeProposal();
  const { run, calls } = recordingRun();
  const r = await executeAction(p, makeConfirm(p), opts({ run, knownSessionIds: undefined }));
  assert.equal(r.status, 'failed');
  assert.match(r.failureReason, /allowlist|known session/i);
  assert.equal(calls.length, 0);
});

test('validateActionResultRef structural bounds', async () => {
  assert.equal(validateActionResultRef({ kind: 'action', actionId: 'a', targetSequenceId: 5, targetCursor: null }), true);
  assert.equal(validateActionResultRef({ kind: 'action', actionId: '', targetSequenceId: 5 }), false);
  assert.equal(validateActionResultRef({ kind: 'action', actionId: 'a', targetSequenceId: 0 }), false);
  assert.equal(validateActionResultRef({ kind: 'sequence', sequenceId: 10 }), true);
  assert.equal(validateActionResultRef({ kind: 'sequence', sequenceId: -1 }), false);
  assert.equal(validateActionResultRef({ kind: 'nope' }), false);
});

test('snapshotProposal reads each field once + freezes', async () => {
  let reads = 0;
  const p = { id: 'p', kind: 'threadedReply', targetSessionId: KNOWN, targetSequence: 1, requiresConfirmation: true, createdAt: '2026-07-18T12:00:00Z', sourceQuestionId: null, proposalHash: 'h' };
  Object.defineProperty(p, 'renderedPreview', { enumerable: true, get() { reads++; return 'x'; } });
  const s = snapshotProposal(p);
  assert.equal(reads, 1, 'renderedPreview read exactly once');
  assert.equal(s.renderedPreview, 'x');
  assert.equal(Object.isFrozen(s), true);
  assert.equal(typeof s.createdAt, 'number');
});

// ---------- humanMessage (native Pocket write) — Warden a/b/c ----------
test('humanMessage: posts via /human-message as human-mrrcarter -> signed .posted, kind:sequence result (Warden a+b)', async () => {
  const p = makeProposal({ kind: 'humanMessage', targetSequence: 0, renderedPreview: 'Carter: ship it.' });
  let posted = null;
  const postHumanMessage = async (sessionId, text, o) => {
    posted = { sessionId, text, clientId: o.clientId, token: o.token };
    return JSON.stringify({ ok: true, message: { id: 'hm_abc', cursor: 'c9', senderId: 'human-mrrcarter' }, event: { sequenceId: 230733, agent: { id: 'human-mrrcarter' } } });
  };
  const { privateKey, publicKey } = generateSigningKeypair();
  const r = await executeAction(p, makeConfirm(p), opts({ postHumanMessage, userToken: 'Bearer user-tok', signingKey: privateKey, signingKeyId: 'gw-key' }));
  assert.equal(r.status, 'posted');
  assert.equal(r.result.kind, 'sequence');              // (b) ActionResultRef = the resulting sequence
  assert.equal(r.result.sequenceId, 230733);
  assert.ok(r.signature && verifyReceipt(r, publicKey)); // (b) minted + SIGNED + verifies
  assert.equal(posted.clientId, p.proposalHash);         // deterministic proposal-tied idempotency
  assert.equal(posted.text, 'Carter: ship it.');
  assert.equal(posted.token, 'Bearer user-tok');         // the user's bearer authorizes the human identity
});

test('verifyHumanMessageLanded: eventId===messageId + who===human-mrrcarter; rejects wrong author / miss (Warden a, closes #1)', () => {
  const found = (agentId) => () => JSON.stringify({ events: [{ eventId: 'hm_abc', agent: { id: agentId } }] });
  assert.equal(verifyHumanMessageLanded('s1', { messageId: 'hm_abc' }, { run: found('human-mrrcarter') }), true);
  assert.equal(verifyHumanMessageLanded('s1', { messageId: 'hm_abc' }, { run: found('claude-pocket-relay') }), false); // same msg, WRONG author
  assert.equal(verifyHumanMessageLanded('s1', { messageId: 'hm_abc' }, { run: () => JSON.stringify({ events: [] }) }), false); // not landed
});

test('humanMessage validateProposal: ENFORCES targetSequence===0 (Atlas ==0 mirror); other kinds keep >0', () => {
  assert.deepEqual(validateProposal(makeProposal({ kind: 'humanMessage', targetSequence: 0 }), { knownSessionIds: [KNOWN] }), []);
  assert.ok(validateProposal(makeProposal({ kind: 'humanMessage', targetSequence: 7 }), { knownSessionIds: [KNOWN] }).some((m) => /targetSequence must be 0/.test(m)));
  assert.ok(validateProposal(makeProposal({ kind: 'threadedReply', targetSequence: 0 }), { knownSessionIds: [KNOWN] }).some((m) => /invalid targetSequence/.test(m)));
  assert.ok(ALLOWED_KINDS.has('humanMessage'));
});

test('humanMessage keeps governed-write invariants: membership fail-closed (post never called) + confirmedProposalHash bind (Warden c)', async () => {
  const p = makeProposal({ kind: 'humanMessage', targetSequence: 0 });
  let called = false;
  const pm = async () => { called = true; return JSON.stringify({ ok: true, message: { id: 'hm_x' }, event: { sequenceId: 1, agent: { id: 'human-mrrcarter' } } }); };
  const nonMember = await executeAction(p, makeConfirm(p), opts({ postHumanMessage: pm, knownSessionIds: ['00000000-0000-0000-0000-000000000000'] }));
  assert.equal(nonMember.status, 'failed');
  assert.equal(called, false); // membership fail-closed BEFORE any post — no confused-deputy write
  const tampered = await executeAction(p, makeConfirm(p, { confirmedProposalHash: 'tampered' }), opts({ postHumanMessage: pm }));
  assert.equal(tampered.status, 'failed'); // content-integrity confirmedProposalHash bind holds for humanMessage too
});

test('parseHumanMessageResult: {message:{id}, event:{sequenceId}} -> {messageId, sequenceId}; null on no durable sequence', () => {
  const good = parseHumanMessageResult(JSON.stringify({ message: { id: 'hm_1', cursor: 'c' }, event: { sequenceId: 42, agent: { id: 'human-mrrcarter' } } }));
  assert.equal(good.messageId, 'hm_1');
  assert.equal(good.sequenceId, 42);
  assert.equal(good.senderId, 'human-mrrcarter');
  assert.equal(parseHumanMessageResult(JSON.stringify({ message: { id: 'hm_1' }, event: {} })), null); // no sequence -> unidentifiable
  assert.equal(parseHumanMessageResult('not json'), null);
});
