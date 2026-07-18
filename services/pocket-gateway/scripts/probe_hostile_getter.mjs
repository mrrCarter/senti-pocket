// Adversarial probe: does the SIGNED .posted receipt bind snapshot identity, or can a
// hostile getter flip id/targetSessionId AFTER snapshot so the signed receipt diverges
// from what was validated/confirmed/posted?
import { executeAction, computeProposalHash, verifyReceipt, canonicalReceiptPayload } from '../src/actions.mjs';
import { generateSigningKeypair } from '../src/bundle.mjs';

const GOOD = '6cf7e861-546a-4b9f-b937-39182a5bd395';
const EVIL = 'ffffffff-ffff-ffff-ffff-ffffffffffff';

// hostile proposal: id + targetSessionId are getters that return GOOD on the first read,
// EVIL on every subsequent read (classic TOCTOU between snapshot and later re-read).
function hostile() {
  let idReads = 0, sessReads = 0;
  const base = {
    kind: 'threadedReply',
    targetSequence: 42,
    renderedPreview: 'hostile-getter probe',
    requiresConfirmation: true,
    createdAt: new Date().toISOString(),
    sourceQuestionId: null,
  };
  const p = {
    ...base,
    get id() { return (idReads++ === 0) ? 'good-id' : 'EVIL-id'; },
    get targetSessionId() { return (sessReads++ === 0) ? GOOD : EVIL; },
  };
  // hash must be computed over a STABLE snapshot the human confirms; compute over the good values.
  const stable = { ...base, id: 'good-id', targetSessionId: GOOD };
  p.proposalHash = computeProposalHash(stable);
  return { p, goodHash: p.proposalHash };
}

const { publicKey, privateKey } = generateSigningKeypair();
const { p, goodHash } = hostile();
const confirmation = { proposalId: 'good-id', confirmedProposalHash: goodHash, confirmedAt: new Date().toISOString() };

// mocked run: pretend the reply landed at the GOOD target; read-back verified true.
const run = (args) => {
  if (args[1] === 'reply') return JSON.stringify({ action: { id: 'act_probe', targetSequenceId: 42, targetCursor: 'cur_x' } });
  if (args[1] === 'sync') return '';
  if (args[1] === 'read') return JSON.stringify({ events: [{ eventId: 'session-action-act_probe', agent: { id: 'claude-pocket-relay' }, payload: { targetSequenceId: 42 } }] });
  return '';
};

const r = executeAction(p, confirmation, {
  knownSessionIds: [GOOD],
  store: new Map(),
  signingKey: privateKey,
  signingKeyId: 'gw-probe',
  run,
});

console.log('status         :', r.status);
console.log('receipt.id     :', r.id);
console.log('receipt.propId :', r.proposalId);
console.log('receipt.session:', r.targetSessionId);
console.log('sig verifies   :', verifyReceipt(r, publicKey));
const leaked = (r.id === 'EVIL-id' || r.proposalId === 'EVIL-id' || r.targetSessionId === EVIL);
console.log('\nVULNERABLE (signed receipt bound EVIL identity):', leaked);
if (leaked) console.log('canonicalReceiptPayload (signed bytes):\n' + canonicalReceiptPayload(r));
