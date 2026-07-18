// Adversarial probe #3 (stale/future): a caller-supplied freshnessSeconds:NaN must NOT disable the freshness
// gate. An ancient (year-2000) confirmation must be rejected, not posted.
import { executeAction, computeProposalHash } from '../src/actions.mjs';
import { generateSigningKeypair } from '../src/bundle.mjs';

const SID = '6cf7e861-546a-4b9f-b937-39182a5bd395';
const { privateKey } = generateSigningKeypair();

const p = {
  id: 'fresh_nan_1', kind: 'threadedReply', targetSessionId: SID, targetSequence: 7,
  renderedPreview: 'freshness NaN probe', requiresConfirmation: true,
  createdAt: '2000-01-01T00:00:00.000Z', sourceQuestionId: null,
};
p.proposalHash = computeProposalHash(p);
// ancient confirmation (year 2000)
const confirmation = { proposalId: p.id, confirmedProposalHash: p.proposalHash, confirmedAt: '2000-01-01T00:00:05.000Z' };

let posts = 0;
const run = (args) => {
  if (args[1] === 'reply') { posts++; return JSON.stringify({ action: { id: 'act_f', targetSequenceId: 7, targetCursor: 'c' } }); }
  if (args[1] === 'sync') return '';
  if (args[1] === 'read') return JSON.stringify({ events: [{ eventId: 'session-action-act_f', agent: { id: 'claude-pocket-relay' }, payload: { targetSequenceId: 7 } }] });
  return '';
};

for (const badWindow of [{ freshnessSeconds: NaN }, { freshnessSeconds: -1 }, { clockSkewSeconds: NaN }, { freshnessSeconds: 'x' }]) {
  posts = 0;
  const r = executeAction(p, { ...confirmation }, {
    knownSessionIds: [SID], store: new Map(), signingKey: privateKey, signingKeyId: 'gw', run,
    now: '2026-07-18T15:00:00.000Z', // "now" is 2026; the confirm is year-2000 => must be stale
    ...badWindow,
  });
  const bypassed = r.status === 'posted' || posts > 0;
  console.log(JSON.stringify(badWindow), '=> status:', r.status, '| posts:', posts, '| BYPASSED:', bypassed);
}
