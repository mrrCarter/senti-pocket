// Adversarial probe #2 (exact read-back area): if a governed post LANDS but the bounded
// read-back transiently misses (busy room / eventual consistency), executeAction returns
// .failed WITHOUT storing -> a retry of the same proposal.id RE-POSTS => duplicate governed write.
// A governed writeback must be exactly-once; double-execution of a human-confirmed post is a trust bug.
import { executeAction, computeProposalHash } from '../src/actions.mjs';
import { generateSigningKeypair } from '../src/bundle.mjs';

const SID = '6cf7e861-546a-4b9f-b937-39182a5bd395';
const { privateKey } = generateSigningKeypair();

const p = {
  id: 'dup_probe_1',
  kind: 'threadedReply',
  targetSessionId: SID,
  targetSequence: 42,
  renderedPreview: 'dup-post probe',
  requiresConfirmation: true,
  createdAt: new Date().toISOString(),
  sourceQuestionId: null,
};
p.proposalHash = computeProposalHash(p);
const confirmation = { proposalId: p.id, confirmedProposalHash: p.proposalHash, confirmedAt: new Date().toISOString() };

let replyCalls = 0;
// run: every reply SUCCEEDS server-side; but read-back returns an EMPTY room (event not yet visible).
const run = (args) => {
  if (args[1] === 'reply') { replyCalls++; return JSON.stringify({ action: { id: 'act_dup_' + replyCalls, targetSequenceId: 42, targetCursor: 'c' } }); }
  if (args[1] === 'sync') return '';
  if (args[1] === 'read') return JSON.stringify({ events: [] }); // read-back MISSES (transient)
  return '';
};

const store = new Map();
const opts = { knownSessionIds: [SID], store, signingKey: privateKey, signingKeyId: 'gw-dup', run };

const r1 = executeAction(p, { ...confirmation }, opts);
const r2 = executeAction(p, { ...confirmation }, opts); // retry SAME proposal id

console.log('r1.status   :', r1.status);
console.log('r2.status   :', r2.status);
console.log('reply calls :', replyCalls, '(server-side POSTS actually made)');
console.log('\nDUP-POST BUG (a confirmed post executed', replyCalls, 'times):', replyCalls > 1);
