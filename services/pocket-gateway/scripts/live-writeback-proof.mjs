// live-writeback-proof.mjs — drive the REAL governed writeback against a live throwaway test session.
// Usage: node scripts/live-writeback-proof.mjs <sessionId> <targetSequence>
// Proves the full path: sl session reply -> parseActionResult -> real verifyActionLanded read-back
// -> result=.action -> Ed25519-signed .posted receipt that verifies. NEVER run against a live room.
import { executeAction, computeProposalHash, verifyReceipt } from '../src/actions.mjs';
import { generateSigningKeypair } from '../src/bundle.mjs';
import { makeSlRunner } from '../src/sl-runner.mjs';

const [sid, tseqStr] = process.argv.slice(2);
const tseq = Number(tseqStr);
if (!sid || !Number.isInteger(tseq)) {
  console.error('usage: node scripts/live-writeback-proof.mjs <sessionId> <targetSeq>');
  process.exit(1);
}

// SHELL-FREE sl runner (Echo #233114): node + SL_CLI_JS, never `cmd /c` (which re-parses metacharacters). On Windows
// set SL_CLI_JS to the sentinelayer-cli.js path.
const run = makeSlRunner({ maxBuffer: 256 * 1024 * 1024 });

const { publicKey, privateKey } = generateSigningKeypair();
const p = {
  id: 'lp_' + tseq,
  kind: 'threadedReply',
  targetSessionId: sid,
  targetSequence: tseq,
  renderedPreview: 'Live-proof governed reply: approved. (relay writeback e2e)',
  requiresConfirmation: true,
  createdAt: new Date().toISOString(),
  sourceQuestionId: null,
};
p.proposalHash = computeProposalHash(p);
const confirmation = { proposalId: p.id, confirmedProposalHash: p.proposalHash, confirmedAt: new Date().toISOString() };

const r = executeAction(p, confirmation, {
  knownSessionIds: [sid],
  store: new Map(),
  signingKey: privateKey,
  signingKeyId: 'gw-live-key',
  agent: 'claude-pocket-relay',
  run, // real sl; real verifyActionLanded read-back (no injected verifyReadback)
});

console.log(JSON.stringify({
  status: r.status,
  result: r.result,
  signaturePresent: !!r.signature,
  receiptVerifies: verifyReceipt(r, publicKey),
  failureReason: r.failureReason,
}, null, 2));
