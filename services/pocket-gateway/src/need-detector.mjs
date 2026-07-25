// need-detector.mjs — Stage-1 of the NeedCarterDetector (the "magical" ring path). RELAY lane.
//
// Carter's design (via atlas's NeedCarterDetector spec): "pattern match and use ML (free) ... then the LLM reads the
// tail or more convo to determine if I am really needed." This is Stage 1 — the CHEAP, zero-LLM pattern gate that
// runs on every tail poll and decides whether Stage 2 (the LLM confirm — atlas's classification over relay's /answer
// retrieval) is worth running at all. Zero match -> STOP: no ring, no inference cost. It kills ~99% of tail noise
// before any model runs.
//
// STRICT SCOPE (anti-false-ring): a Stage-1 hit only ADMITS a message to Stage-2 — it NEVER rings on its own and
// NEVER decides the need kind or confidence. Those are Stage-2's job (an LLM reads the surrounding tail and answers
// "is Carter GENUINELY needed?"). So Stage-1 errs toward ADMITTING (a false positive costs one Stage-2 call that then
// says "not needed"; a false negative would silently MISS a real need — the worse failure). It is pure + stateless:
// debounce/dedupe of already-fired needs is the /detect-need endpoint's job (it holds the seen-seqs store), not this.
//
// LANE: RELAY owns Stage-1 (pattern) + Stage-2 plumbing (reuse /answer retrieval over the tail). ATLAS owns the
// Stage-2 CLASSIFICATION prompt/logic + the NeedCarterSignal it emits. This module deliberately stops at "admit?".

const MAX_SCAN = 8192; // bound the regex scan per text blob (recent-tail messages are already short; defense-in-depth)

// The need-signal patterns (from atlas's spec). Each is a coarse ADMIT trigger, not a classification. `label` gives
// Stage-2 cheap context (and logging) about WHY a message was admitted, without this module deciding the kind.
const PATTERNS = Object.freeze([
  { label: 'mention-carter',   re: /@(?:human-mrrcarter|mrrcarter|carter)\b/i },                 // @carter / @mrrcarter / @human-mrrcarter
  { label: 'need-carter',      re: /\b(?:need|waiting\s+on|waiting\s+for|ping|ask|get)\s+carter\b/i },
  { label: 'your-call',        re: /\byour\s+call\b/i },
  { label: 'decision-yours',   re: /\b(?:decision(?:'s| is)\s+yours|your\s+decision|you\s+decide|up\s+to\s+you)\b/i },
  { label: 'go-request',       re: /\bgo\s*\?/i },                                                // "go?" (a proceed ask), not bare "go"
  { label: 'pick-option',      re: /\boptions?\s+[a-d]\b/i },                                      // "option A" / "options A/B/C"
  { label: 'choose-between',   re: /\b(?:choose|pick|decide)\s+(?:between|among|one\s+of)\b/i },
  { label: 'checkpoint-ready', re: /\bcheckpoint[-\s]?ready\b/i },
  { label: 'greenlight',       re: /\bgreen[-\s]?light\b|\bsign[-\s]?off\b/i },
]);

/** The pattern labels this gate can emit — exported for logging + Stage-2 context binding + tests. */
export const NEED_PATTERN_LABELS = Object.freeze(PATTERNS.map((p) => p.label));

/**
 * Stage-1 over ONE text blob. Pure, case-insensitive, bounded.
 * @param {string} text
 * @returns {{ hit: boolean, matched: string[] }}  matched = which pattern labels fired (empty when no hit)
 */
export function matchNeedPatterns(text) {
  const s = typeof text === 'string' ? text.slice(0, MAX_SCAN) : '';
  if (s.length === 0) return { hit: false, matched: [] };
  const matched = [];
  for (const p of PATTERNS) if (p.re.test(s)) matched.push(p.label); // no /g flag -> no lastIndex state; .test is safe to reuse
  return { hit: matched.length > 0, matched };
}

/** Pull the human-readable text out of a message in any of the shapes the tail delivers. */
function textOf(m) {
  if (typeof m === 'string') return m;
  if (!m || typeof m !== 'object') return '';
  if (typeof m.text === 'string') return m.text;
  if (m.payload && typeof m.payload.message === 'string') return m.payload.message;
  return '';
}
/** Pull a sequence id out of a message (senti event `sequenceId`, or `seq`) for evidence tracking. */
function seqOf(m) {
  if (!m || typeof m !== 'object') return undefined;
  if (Number.isInteger(m.sequenceId)) return m.sequenceId;
  if (Number.isInteger(m.seq)) return m.seq;
  return undefined;
}

/**
 * Stage-1 over a tail of messages (the recent chat). Scans the LAST `max` messages so an old, already-handled need
 * can't dominate the scan; returns each admitted message's seq + matched labels so Stage-2 (and later the signal's
 * evidenceSeqs) can cite the exact chat. Debounce of already-fired seqs is the endpoint's job, not here.
 * @param {Array<string|{text?:string, payload?:{message?:string}, sequenceId?:number, seq?:number}>} messages
 * @param {{ max?: number }} [opts]
 * @returns {{ hit: boolean, hits: Array<{ seq: (number|undefined), matched: string[] }> }}
 */
export function scanTailForNeed(messages, { max = 50 } = {}) {
  const cap = Number.isInteger(max) && max > 0 && max <= 500 ? max : 50;
  const msgs = Array.isArray(messages) ? messages.slice(-cap) : [];
  const hits = [];
  for (const m of msgs) {
    const r = matchNeedPatterns(textOf(m));
    if (r.hit) hits.push({ seq: seqOf(m), matched: r.matched });
  }
  return { hit: hits.length > 0, hits };
}
