// actions.test.mjs — governed writeback safety (PocketContracts v0.1.2). Run: node --test
// All I/O injected: NO test ever posts to a live room.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  canonicalPayload, computeProposalHash, hashMatchesContent, validateProposal, executeAction, ALLOWED_KINDS,
  signReceipt, verifyReceipt, canonicalReceiptPayload,
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
function recordingRun(seq = 230999) {
  const calls = [];
  const run = (args) => { calls.push(args); return JSON.stringify({ sequenceId: seq }); };
  return { run, calls };
}
const { publicKey: TESTPUB, privateKey: TESTKEY } = generateSigningKeypair();
// online writeback now REQUIRES signing credentials, so they are part of the default opts.
const opts = (extra) => ({ knownSessionIds: [KNOWN], store: new Map(), now: '2026-07-18T12:02:00Z', signingKey: TESTKEY, signingKeyId: 'gw-key', ...extra });

test('canonicalPayload matches the frozen v0.1.3 length-prefixed format exactly', () => {
  // lp(s) = "<utf8ByteCount>:<s>": 13:threadedReply, 36:<uuid>, 6:230160, 2:hi
  assert.equal(
    canonicalPayload('threadedReply', KNOWN, 230160, 'hi'),
    `pocket.actionproposal.v2\n13:threadedReply36:${KNOWN}6:2301602:hi`,
  );
});

test('length-prefixing defeats the delimiter-shift collision at the hash layer', () => {
  // Two DIFFERENT field tuples that a naive delimiter join could confuse must produce different hashes.
  const a = computeProposalHash({ kind: 'threadedReply', targetSessionId: KNOWN, targetSequence: 1, renderedPreview: '2:hi' });
  const b = computeProposalHash({ kind: 'threadedReply', targetSessionId: KNOWN, targetSequence: 12, renderedPreview: 'hi' });
  assert.notEqual(a, b, 'length-prefixed encoding keeps these distinct');
});

test('KAV: Node proposalHash byte-matches the Swift contract known-answer vector (v0.1.4)', () => {
  // ContractsCrossModuleTests: ('threadedReply','s1',100,'post X') -> mNZp-a77...
  assert.equal(
    canonicalPayload('threadedReply', 's1', 100, 'post X'),
    'pocket.actionproposal.v2\n13:threadedReply2:s13:1006:post X',
  );
  assert.equal(
    computeProposalHash({ kind: 'threadedReply', targetSessionId: 's1', targetSequence: 100, renderedPreview: 'post X' }),
    'mNZp-a77Q1I1LSKOyhsEqjb60JW7Z3Cim_bzmCI_sqc',
    'Node hash must equal the Swift KAV — cross-platform lock',
  );
});

test('canonicalReceiptPayload matches v0.1.6 v3 (all fields bound; epoch-millisecond timestamps)', () => {
  const r = { id: 'p1', proposalId: 'p1', status: 'posted', resultingSequence: 231111, targetSessionId: 's1', confirmedProposalHash: 'H', confirmedByHumanAt: '2026-07-18T12:01:00Z', executedAt: '2026-07-18T12:02:00Z', failureReason: null, signature: null, signingKeyId: 'k' };
  const cu = String(Date.parse(r.confirmedByHumanAt)); // epoch ms
  const eu = String(Date.parse(r.executedAt));
  assert.equal(
    canonicalReceiptPayload(r),
    `pocket.actionreceipt.v3\n2:p12:p16:posted6:2311112:s11:H${cu.length}:${cu}${eu.length}:${eu}0:1:k`,
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

test('posted receipt is Ed25519-signed + verifies; pending receipts stay unsigned (never render as sent)', () => {
  const { publicKey, privateKey } = generateSigningKeypair();
  const p = makeProposal();
  const { run } = recordingRun(231234);
  const posted = executeAction(p, makeConfirm(p), opts({ run, signingKey: privateKey, signingKeyId: 'gw-key' }));
  assert.equal(posted.status, 'posted');
  assert.ok(posted.signature, 'posted receipt is signed');
  assert.equal(posted.signingKeyId, 'gw-key');
  assert.equal(verifyReceipt(posted, publicKey), true, 'gateway signature verifies');
  assert.equal(verifyReceipt({ ...posted, resultingSequence: 999 }, publicKey), false, 'tampered receipt fails');

  const p2 = makeProposal({ id: 'p2' });
  const pending = executeAction(p2, makeConfirm(p2), opts({ run, online: false, signingKey: privateKey }));
  assert.equal(pending.status, 'pendingConnectivity');
  assert.equal(pending.signature, null, 'pending receipt is unsigned');
  assert.equal(verifyReceipt(pending, publicKey), false, 'unsigned pending never verifies as sent');
});

test('(B) online writeback WITHOUT signing credentials => failed, ZERO posts', () => {
  const p = makeProposal();
  const { run, calls } = recordingRun();
  const r = executeAction(p, makeConfirm(p), opts({ run, signingKey: undefined, signingKeyId: undefined }));
  assert.equal(r.status, 'failed');
  assert.match(r.failureReason, /credentials|invalid|ed25519/i);
  assert.equal(calls.length, 0, 'no online side effect without credentials');
});

test('(C) offline pending then online flush posts exactly once (pending is not terminal)', () => {
  const p = makeProposal({ id: 'pflush' });
  const store = new Map();
  const { run, calls } = recordingRun(240001);
  const pending = executeAction(p, makeConfirm(p), opts({ run, store, online: false }));
  assert.equal(pending.status, 'pendingConnectivity');
  assert.equal(calls.length, 0);
  const flushed = executeAction(p, makeConfirm(p), opts({ run, store, online: true }));
  assert.equal(flushed.status, 'posted', 'pending flushes to posted when back online');
  assert.equal(flushed.resultingSequence, 240001);
  assert.equal(calls.length, 1, 'posted exactly once on flush');
  const again = executeAction(p, makeConfirm(p), opts({ run, store, online: true }));
  assert.deepEqual(again, flushed, 'now terminal: same posted receipt');
  assert.equal(calls.length, 1, 'no double-post after terminal');
});

test('(A) non-finite timestamp is handled safely (no trap) and does not verify', () => {
  const p = makeProposal({ id: 'padate' });
  const { run } = recordingRun(241000);
  const signed = executeAction(p, makeConfirm(p), opts({ run }));
  assert.equal(signed.status, 'posted');
  assert.equal(verifyReceipt(signed, TESTPUB), true);
  const tampered = { ...signed, executedAt: 'not-a-date' }; // non-finite -> "" canonical (safe, no trap)
  assert.equal(verifyReceipt(tampered, TESTPUB), false);
});

test('(B) malformed signing key => failed, ZERO posts (preflight before side effect)', () => {
  const p = makeProposal();
  const { run, calls } = recordingRun();
  const r = executeAction(p, makeConfirm(p), opts({ run, signingKey: 'not-a-key' }));
  assert.equal(r.status, 'failed');
  assert.match(r.failureReason, /credentials|invalid|ed25519/i);
  assert.equal(calls.length, 0, 'malformed key: no online post');
});

test('(B) wrong key type (x25519, not ed25519) => failed, ZERO posts', () => {
  const { privateKey: x } = generateKeyPairSync('x25519');
  const p = makeProposal();
  const { run, calls } = recordingRun();
  const r = executeAction(p, makeConfirm(p), opts({ run, signingKey: x }));
  assert.equal(r.status, 'failed');
  assert.equal(calls.length, 0, 'non-ed25519 key: no online post');
});

test('(B) blank keyId => failed, ZERO posts', () => {
  const p = makeProposal();
  const { run, calls } = recordingRun();
  const r = executeAction(p, makeConfirm(p), opts({ run, signingKeyId: '   ' }));
  assert.equal(r.status, 'failed');
  assert.equal(calls.length, 0);
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
