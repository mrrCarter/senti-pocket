import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { buildPrObservation } from '../src/pr-observation.mjs';
import { buildPrCard } from '../src/pr-card.mjs';
import { cardToSpokenBrief } from '../src/pr-spoken-brief.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const fx = (n) => JSON.parse(readFileSync(join(here, 'fixtures', `pr-${n}.json`), 'utf8'));
const brief = (n, opts) => cardToSpokenBrief(buildPrCard(buildPrObservation(fx(n), { checkedAt: '2026-10-12T00:00:00Z' }), opts));
const HEAD = 'HEADSHA3333333333333333333333333333333333';

test('#154 brief: identifies PR, who, state, next — grounded, bounded segments', () => {
  const b = brief(154);
  assert.match(b.text, /Pull request 154/);
  assert.match(b.text, /Opened by mrrCarter/);
  assert.match(b.text, /Waiting on deployment/);
  assert.ok(b.segments.find((s) => s.kind === 'next'));
  assert.equal(b.segments[0].kind, 'identify');
});

test('#158 draft brief: Waiting on implementation; never falsely claims merged/deployed/available', () => {
  const b = brief(158);
  assert.match(b.text, /Waiting on implementation/);
  assert.doesNotMatch(b.text, /\bmerged\b|\bdeployed\b|\bAvailable\b/i);
});

test('#154 + deployment proven -> Available', () => {
  assert.match(brief(154, { deployment: { deployed: true } }).text, /Available/);
});

test('shared-account reviews surface the independence caveat in the spoken who-line', () => {
  const o = buildPrObservation({
    repoId: 'x/y', pull: { number: 9, state: 'open', title: 'T', user: { login: 'dev' }, head: { sha: HEAD }, base: {}, changed_files: 1, commits: 1 },
    reviews: [
      { user: { login: 'bot' }, state: 'APPROVED', submitted_at: '2026-01-01', commit_id: HEAD },
      { user: { login: 'bot' }, state: 'APPROVED', submitted_at: '2026-01-02', commit_id: HEAD },
    ],
  });
  const who = cardToSpokenBrief(buildPrCard(o)).segments.find((s) => s.kind === 'who');
  assert.match(who.text, /not independent verification/i);
});

const synthBrief = ({ reviews = [], checkRuns = [{ name: 'ci', status: 'completed', conclusion: 'success', app: 'gh' }], mergeableState } = {}) =>
  cardToSpokenBrief(buildPrCard(buildPrObservation({
    repoId: 'x/y',
    pull: { number: 9, state: 'open', title: 'T', user: { login: 'dev' }, head: { sha: HEAD }, base: {}, changed_files: 1, commits: 1, ...(mergeableState ? { mergeable_state: mergeableState } : {}) },
    commits: [{ author: { login: 'dev' }, commit: { author: { name: 'Dev' }, message: 'x' } }],
    reviews, checkRuns,
  })));
const appr = (login, commit = HEAD, at = '2026-01-01') => ({ user: { login }, state: 'APPROVED', submitted_at: at, commit_id: commit });

test('P1 finding-6: a STALE-head approval is NOT spoken as a real approval (uses head-valid count)', () => {
  const who = synthBrief({ reviews: [appr('rev', 'OLDSHA')] }).segments.find((s) => s.kind === 'who');
  // must NOT claim a valid/real approval; "reviewed but not yet approved" is the correct phrasing.
  assert.doesNotMatch(who.text, /valid approval|reviews? approved/i, 'stale approval must not be voiced as a real approval');
  assert.match(who.text, /not yet approved/i);
});

test('P1 finding-6: an ON-HEAD valid approval IS spoken, counted head-valid', () => {
  const who = synthBrief({ reviews: [appr('rev', HEAD)] }).segments.find((s) => s.kind === 'who');
  assert.match(who.text, /1 valid approval/);
});

test('a standing CHANGES_REQUESTED is voiced and caveated', () => {
  const b = synthBrief({ reviews: [{ user: { login: 'rev' }, state: 'CHANGES_REQUESTED', submitted_at: '2026-01-01', commit_id: HEAD }] });
  const who = b.segments.find((s) => s.kind === 'who');
  assert.match(who.text, /change request/i);
  assert.match(b.text, /changes/i);
});

test('unreadable card -> honest failure line, not a fabricated brief', () => {
  const b = cardToSpokenBrief({ available: false });
  assert.match(b.text, /could not be read/);
  assert.equal(b.segments[0].kind, 'error');
});
