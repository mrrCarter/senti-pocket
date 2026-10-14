import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { buildPrObservation } from '../src/pr-observation.mjs';
import { buildPrCard, CARD_STATES } from '../src/pr-card.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const fx = (n) => JSON.parse(readFileSync(join(here, 'fixtures', `pr-${n}.json`), 'utf8'));
const obs = (n) => buildPrObservation(fx(n), { checkedAt: '2026-10-12T00:00:00Z' });

const HEAD = 'HEADSHA2222222222222222222222222222222222';
function synthetic({ draft = false, checkRuns = [{ name: 'ci', status: 'completed', conclusion: 'success', app: 'gh' }], reviews = [], mergeableState } = {}) {
  return buildPrObservation({
    repoId: 'x/y',
    pull: { number: 42, state: 'open', draft, title: 'Do a thing', user: { login: 'dev' }, head: { sha: HEAD }, base: {}, html_url: 'https://e/42', additions: 3, deletions: 1, changed_files: 1, commits: 1, ...(mergeableState ? { mergeable_state: mergeableState } : {}) },
    commits: [{ sha: 'a', author: { login: 'dev' }, commit: { author: { name: 'Dev' }, message: 'do thing' } }],
    reviews,
    checkRuns,
  });
}
const approved = (login = 'rev', commit = HEAD, at = '2026-01-01') => ({ user: { login }, state: 'APPROVED', submitted_at: at, commit_id: commit });
const changesReq = (login = 'rev', commit = HEAD, at = '2026-01-01') => ({ user: { login }, state: 'CHANGES_REQUESTED', submitted_at: at, commit_id: commit });

test('#154 merged, no deployment evidence -> Waiting on deployment', () => {
  const c = buildPrCard(obs(154));
  assert.equal(c.state, CARD_STATES.DEPLOY);
  assert.equal(c.nextAction.button, 'Open PR');
});

test('#154 merged + deployment proven -> Available', () => {
  assert.equal(buildPrCard(obs(154), { deployment: { deployed: true } }).state, CARD_STATES.AVAILABLE);
});

test('#158 draft -> Waiting on implementation', () => {
  assert.equal(buildPrCard(obs(158)).state, CARD_STATES.IMPL);
});

test('open + green + no approval -> Waiting on review, button = Review on GitHub', () => {
  const c = buildPrCard(synthetic());
  assert.equal(c.state, CARD_STATES.REVIEW);
  assert.equal(c.nextAction.button, 'Review on GitHub');
});

test('open + green + ON-HEAD approval -> Needs you; next action does NOT imply a merge', () => {
  const c = buildPrCard(synthetic({ reviews: [approved('rev', HEAD)] }));
  assert.equal(c.state, CARD_STATES.NEEDS_YOU);
  assert.match(c.nextAction.text, /does not merge it for you/);
  assert.equal(c.nextAction.button, 'Open PR');
});

test('P1: a STALE-head approval does NOT flip to Needs you (stays Waiting on review)', () => {
  const c = buildPrCard(synthetic({ reviews: [approved('rev', 'OLDSHA')] }));
  assert.equal(c.state, CARD_STATES.REVIEW, 'stale approval is not a current approval');
  assert.equal(c.measures.verifiedAcceptance.staleApprovals, 1);
  assert.ok(c.measures.verifiedAcceptance.unknowns.includes('stale-head-approvals'));
});

test('open + failing checks -> Waiting on implementation', () => {
  assert.equal(buildPrCard(synthetic({ checkRuns: [{ name: 'ci', status: 'completed', conclusion: 'failure', app: 'gh' }] })).state, CARD_STATES.IMPL);
});

test('P1 zero-check approval: approved + no checks -> flagged approved-without-checks, not verified', () => {
  const c = buildPrCard(synthetic({ reviews: [approved('rev', HEAD)], checkRuns: [] }));
  assert.equal(c.measures.verifiedAcceptance.approvedWithoutChecks, true);
  assert.ok(c.measures.verifiedAcceptance.unknowns.includes('approved-without-checks'));
  assert.ok(c.measures.verifiedAcceptance.unknowns.includes('no-checks-observed'));
});

test('P1 zero-checks: approved with NO checks is UNVERIFIED, not "requirements appear met"', () => {
  const c = buildPrCard(synthetic({ reviews: [approved('rev', HEAD)], checkRuns: [] }));
  assert.equal(c.state, CARD_STATES.NEEDS_YOU);
  assert.equal(c.measures.verifiedAcceptance.requirementsVerified, false);
  assert.match(c.nextAction.text, /UNVERIFIED/);
  assert.doesNotMatch(c.nextAction.text, /requirements appear met/);
});

test('approved + all-green IS verified (requirements appear met)', () => {
  const c = buildPrCard(synthetic({ reviews: [approved('rev', HEAD)] }));
  assert.equal(c.state, CARD_STATES.NEEDS_YOU);
  assert.equal(c.measures.verifiedAcceptance.requirementsVerified, true);
  assert.match(c.nextAction.text, /requirements appear met/);
});

test('P1 source-error checks: a failed check fetch is UNVERIFIED (never green/met)', () => {
  const c = buildPrCard(synthetic({ reviews: [approved('rev', HEAD)], checkRuns: { _error: 'gh failed' } }));
  assert.equal(c.measures.verifiedAcceptance.requirementsVerified, false);
  assert.equal(c.measures.verifiedAcceptance.checks.sourceError, true);
  assert.ok(c.measures.verifiedAcceptance.unknowns.includes('checks-source-error'));
  assert.match(c.nextAction.text, /could not be fetched/);
});

test('P1 changes-requested: a standing CHANGES_REQUESTED -> Waiting on implementation, blocks met', () => {
  const c = buildPrCard(synthetic({ reviews: [approved('rev', HEAD), changesReq('other', HEAD, '2026-02-01')] }));
  assert.equal(c.state, CARD_STATES.IMPL);
  assert.equal(c.measures.verifiedAcceptance.changesRequested, 1);
  assert.equal(c.measures.verifiedAcceptance.requirementsVerified, false);
  assert.ok(c.measures.verifiedAcceptance.unknowns.includes('changes-requested'));
  assert.match(c.nextAction.text, /requested changes/);
});

test('P2 merge dirty (conflicts) -> Waiting on implementation', () => {
  const c = buildPrCard(synthetic({ reviews: [approved('rev', HEAD)], mergeableState: 'dirty' }));
  assert.equal(c.state, CARD_STATES.IMPL);
  assert.equal(c.measures.verifiedAcceptance.mergeBlocked, true);
  assert.match(c.nextAction.text, /conflicts/);
});

test('P2 merge blocked (approved+green but blocked) -> not verified, surfaced', () => {
  const c = buildPrCard(synthetic({ reviews: [approved('rev', HEAD)], mergeableState: 'blocked' }));
  assert.equal(c.measures.verifiedAcceptance.requirementsVerified, false);
  assert.equal(c.measures.verifiedAcceptance.mergeBlocked, true);
  assert.ok(c.measures.verifiedAcceptance.unknowns.includes('merge-blocked'));
});

test('P2 inconclusive checks (null/stale completed) -> Waiting on review, not Needs you', () => {
  const c = buildPrCard(synthetic({ reviews: [approved('rev', HEAD)], checkRuns: [{ name: 'ci', status: 'completed', conclusion: null, app: 'gh' }] }));
  assert.equal(c.state, CARD_STATES.REVIEW);
  assert.equal(c.measures.verifiedAcceptance.requirementsVerified, false);
  assert.ok(c.measures.verifiedAcceptance.unknowns.includes('checks-inconclusive'));
});

test('P2 startup_failure check -> Waiting on implementation (treated as failure)', () => {
  const c = buildPrCard(synthetic({ reviews: [approved('rev', HEAD)], checkRuns: [{ name: 'ci', status: 'completed', conclusion: 'startup_failure', app: 'gh' }] }));
  assert.equal(c.state, CARD_STATES.IMPL);
});

test('two measures stay DISTINCT — never one blended percentage', () => {
  const c = buildPrCard(obs(154));
  assert.ok(c.measures.verifiedAcceptance && c.measures.sourceCoverage);
  assert.doesNotMatch(JSON.stringify(c.measures), /"(percent|pct|readinessScore|completeness)"/i);
});

test('shared-account approvals surface the independence note', () => {
  const c = buildPrCard(synthetic({ reviews: [approved('bot', HEAD, '2026-01-01'), approved('bot', HEAD, '2026-01-02')] }));
  assert.match(c.whoWorkedOnIt.independenceNote, /not independent verification/i);
});

test('unavailable observation -> card passthrough, no fabricated state', () => {
  const c = buildPrCard({ available: false, reason: 'source-error' });
  assert.equal(c.available, false);
  assert.equal(c.state, undefined);
});

test('button text is ALWAYS Open PR or Review on GitHub across states', () => {
  const cards = [buildPrCard(obs(154)), buildPrCard(obs(158)), buildPrCard(synthetic()), buildPrCard(synthetic({ reviews: [approved('r', HEAD)] }))];
  for (const c of cards) assert.ok(['Open PR', 'Review on GitHub'].includes(c.nextAction.button), `button=${c.nextAction.button}`);
});
