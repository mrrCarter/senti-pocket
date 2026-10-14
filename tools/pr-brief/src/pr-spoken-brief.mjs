// tools/pr-brief/src/pr-spoken-brief.mjs
//
// Deterministic, extractive card -> spoken brief. Produces the exact words a phone would SAY about a PR:
// what it does, WHO worked on it, its state, and the one next action — grounded only in the card's facts,
// with no model and no hallucination. Returns ordered segments so a voice layer can narrate them.
//
// This is the demo/offline path (a "signed-source / extractive fallback" per the spec). The PRODUCTION path
// routes the SAME card facts through Gemma drafting + the Jev-assessed `/brief` loop (seam #158 + adapter #159),
// which gates each segment on grounded support before it is spoken. This module never invents a merge, a
// deployment, or an independent reviewer that the facts don't show.

const sentence = (s) => (s && /[.!?]$/.test(s.trim()) ? s.trim() : `${(s || '').trim()}.`);

function whatItDoes(card) {
  const { title, change } = card.whatItDoes;
  const bits = [];
  if (change.changedFiles != null && change.commitCount != null) {
    const files = `${change.changedFiles} file${change.changedFiles === 1 ? '' : 's'}`;
    const commits = `${change.commitCount} commit${change.commitCount === 1 ? '' : 's'}`;
    bits.push(`It changes ${files} over ${commits}`);
  }
  return `It is titled: ${title}. ${bits.length ? sentence(bits.join(', ')) : ''}`.trim();
}

function whoWorkedOnIt(card) {
  const w = card.whoWorkedOnIt;
  const parts = [`Opened by ${w.author || 'an unknown author'}`];
  const others = (w.commitAuthors || []).filter((a) => a && a !== w.author);
  if (others.length) parts.push(`with commits also from ${others.slice(0, 3).join(', ')}`);
  // Speak the card's HEAD-VALID approval count (non-self, non-bot, on-head) — never the raw APPROVED
  // dispositions, which would count stale-head, self, and bot approvals as real.
  const approvals = card.measures.verifiedAcceptance.approvals || 0;
  const changes = card.measures.verifiedAcceptance.changesRequested || 0;
  if (changes > 0) parts.push(`${changes} change request${changes === 1 ? '' : 's'} outstanding`);
  else if (approvals > 0) parts.push(`${approvals} valid approval${approvals === 1 ? '' : 's'}`);
  else if ((w.reviewers || []).length) parts.push(`reviewed but not yet approved`);
  let s = sentence(parts.join(', '));
  if (w.independenceNote) s += ` Note: ${sentence(w.independenceNote)}`;
  return s;
}

function stateLine(card) {
  const owner = card.responsibleOwner ? ` The responsible party is ${card.responsibleOwner}.` : '';
  return `${sentence(`Its status is: ${card.state}`)}${owner}`;
}

function caveats(card) {
  // Drop deployment-status here: the state line already conveys it for merged PRs and it is noise otherwise.
  const unknowns = (card.measures.verifiedAcceptance.unknowns || []).filter((u) => u !== 'deployment-status');
  if (!unknowns.length) return '';
  const phrase = {
    'no-checks-observed': 'no CI checks were observed',
    'checks-source-error': 'the checks could not be fetched',
    'checks-inconclusive': 'some checks were inconclusive',
    'approved-without-checks': 'it was approved with no checks observed',
    'stale-head-approvals': 'some approvals are on an older commit',
    'changes-requested': 'a reviewer requested changes',
    'merge-blocked': 'GitHub reports the merge is blocked',
  };
  const parts = unknowns.map((u) => phrase[u] || `${u.replace(/-/g, ' ')} is unknown`);
  return sentence(`${unknowns.length === 1 ? 'Caveat' : 'Caveats'}: ${parts.join('; ')}`);
}

/**
 * @param {object} card - output of buildPrCard (available:true).
 * @returns { text, segments:[{kind,text}] }  — segments in speaking order; text is them joined.
 */
export function cardToSpokenBrief(card) {
  if (!card || card.available !== true) {
    return { text: 'That pull request could not be read.', segments: [{ kind: 'error', text: 'That pull request could not be read.' }] };
  }
  const idLine = sentence(`Pull request ${card.number}`);
  const segs = [
    { kind: 'identify', text: idLine },
    { kind: 'what', text: whatItDoes(card) },
    { kind: 'who', text: whoWorkedOnIt(card) },
    { kind: 'state', text: stateLine(card) },
    { kind: 'next', text: sentence(`Next: ${card.nextAction.text}`) },
  ];
  const cav = caveats(card);
  if (cav) segs.push({ kind: 'caveat', text: cav });
  return { text: segs.map((s) => s.text).join(' '), segments: segs };
}
