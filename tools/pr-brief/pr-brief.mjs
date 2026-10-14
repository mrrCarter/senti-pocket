#!/usr/bin/env node
// tools/pr-brief/pr-brief.mjs
//
// Zero-dependency CLI: read/explain a PR out loud (text) to the session owner.
// Usage: node pr-brief.mjs <owner/repo> <pr-number> [--json]
// Fetches the live PR via `gh`, builds PR-observation -> card -> spoken brief, prints the card +
// the exact words the phone would speak. Demonstrates the Omar->Pocket PR-voice-briefing without a device.
//
// Production path routes the SAME card through Gemma drafting + the Jev-assessed /brief loop (seam #158 +
// adapter #159) so each spoken segment is gated on grounded support; this CLI uses the deterministic
// extractive brief so it is fully offline and hermetic-safe.

import { execFileSync } from 'node:child_process';
import { buildPrObservation } from './src/pr-observation.mjs';
import { buildPrCard } from './src/pr-card.mjs';
import { cardToSpokenBrief } from './src/pr-spoken-brief.mjs';

function gh(args) {
  try {
    return JSON.parse(execFileSync('gh', args, { encoding: 'utf8', maxBuffer: 20_000_000 }));
  } catch (e) {
    return { _error: String(e.stderr || e.message).slice(0, 200) };
  }
}

// Paginated fetch → the COMPLETE set across all pages (not just page 1). `--jq '.[]'` /
// '.check_runs[]' streams one JSON object per line (JSONL) across all pages; parse line-by-line.
function ghJsonl(args) {
  try {
    const out = execFileSync('gh', ['api', '--paginate', ...args], { encoding: 'utf8', maxBuffer: 50_000_000 });
    return out.split('\n').map((l) => l.trim()).filter(Boolean).map((l) => JSON.parse(l));
  } catch (e) {
    // A FAILED FETCH is a source error, not an empty result — surface it so it never reads as
    // "zero checks / no reviews" (which would wrongly pass as green/met downstream).
    return { _error: String(e.stderr || e.message).slice(0, 200) };
  }
}

export function fetchPr(repo, n) {
  const pull = gh(['api', `repos/${repo}/pulls/${n}`]);
  if (pull._error) return { repoId: repo, pull };
  const head = pull.head && pull.head.sha;
  return {
    repoId: repo,
    pull,
    // reviews carry commit_id (for the stale-head check); all three arrays fully paginated.
    reviews: ghJsonl([`repos/${repo}/pulls/${n}/reviews`, '--jq', '.[]']),
    commits: ghJsonl([`repos/${repo}/pulls/${n}/commits`, '--jq', '.[]']),
    checkRuns: head ? ghJsonl([`repos/${repo}/commits/${head}/check-runs`, '--jq', '.check_runs[]']) : [],
  };
}

export function main(argv) {
  const json = argv.includes('--json');
  const [repo, nStr] = argv.filter((a) => !a.startsWith('--'));
  if (!repo || !/^\d+$/.test(nStr || '')) {
    console.error('Usage: pr-brief <owner/repo> <pr-number> [--json]');
    return 2;
  }
  const composite = fetchPr(repo, Number(nStr));
  const observation = buildPrObservation(composite);
  const card = buildPrCard(observation);
  const spoken = cardToSpokenBrief(card);

  if (json) {
    console.log(JSON.stringify({ observation, card, spoken }, null, 2));
    return card.available ? 0 : 1;
  }
  if (!card.available) {
    console.log(`PR ${repo}#${nStr}: unavailable (${card.reason}).`);
    return 1;
  }
  console.log(`\n=== ${card.id} ===`);
  console.log(`State:   ${card.state}${card.responsibleOwner ? `  (owner: ${card.responsibleOwner})` : ''}`);
  console.log(`What:    ${card.whatItDoes.title}`);
  console.log(`Who:     ${card.whoWorkedOnIt.author}${card.whoWorkedOnIt.independenceNote ? `  [!] ${card.whoWorkedOnIt.independenceNote}` : ''}`);
  console.log(`Next:    ${card.nextAction.text}  [${card.nextAction.button}] ${card.nextAction.url || ''}`);
  console.log(`\n--- SPOKEN (what the phone says) ---\n${spoken.text}\n`);
  return 0;
}

const invokedDirectly = process.argv[1] && process.argv[1].endsWith('pr-brief.mjs');
if (invokedDirectly) process.exit(main(process.argv.slice(2)));
