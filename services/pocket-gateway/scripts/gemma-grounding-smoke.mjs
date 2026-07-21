#!/usr/bin/env node
// gemma-grounding-smoke.mjs — LIVE grounding-honesty check for createGemmaBackend against a REAL Gemma (Ollama).
//
// Proves the honesty property Carter cares about ("make sure Gemma is used" — used HONESTLY) end-to-end against real
// Gemma output, WITHOUT the checkpoint-extraction pipeline (which needs a checkpoint inside the rolling export window).
// Run on a host with Gemma serving (Forge's Mac):
//   GEMMA_BASE_URL=http://127.0.0.1:11434/v1 GEMMA_MODEL=gemma3 node services/pocket-gateway/scripts/gemma-grounding-smoke.mjs
//
// It builds a small VERIFIED-style bundle, calls the REAL Gemma reason() + brief(), and ASSERTS: every cited evidenceId
// is in the grounded set (no fabrication survives my backend's grounding-first filter). Self-asserting: exit 0 = PASS.
import { createGemmaBackend } from '../src/gemma-backend.mjs';

const baseUrl = process.env.GEMMA_BASE_URL || 'http://127.0.0.1:11434/v1';
const model = process.env.GEMMA_MODEL || 'gemma3';

const bundle = {
  checkpointId: 'cp_smoke',
  evidence: [
    { id: 'ev_a', agentId: 'claude-pocket-relay', sequence: 1001, snippet: 'Relay wired Gemma into the gateway via an OpenAI-compatible backend, grounding-first + fail-closed.' },
    { id: 'ev_b', agentId: 'pocket-forge', sequence: 1002, snippet: 'Forge stood up key-free Ollama gemma3 on an M4 Mac and wired it to the live demo gateway.' },
    { id: 'ev_c', agentId: 'claude-warden', sequence: 1003, snippet: 'Warden gated the first live human write authored as human-mrrcarter, quadruple-witnessed.' },
  ],
};
const grounded = bundle.evidence.map((e) => e.id); // ['ev_a','ev_b','ev_c']
const g = createGemmaBackend({ baseUrl, model, fetch: globalThis.fetch });

function checkCites(ids, where) {
  const bad = (ids || []).filter((id) => !grounded.includes(id));
  console.log(`  ${where}: cites ${JSON.stringify(ids || [])} ${bad.length ? 'FABRICATED -> ' + JSON.stringify(bad) : '(all grounded ✓)'}`);
  return bad.length === 0;
}

console.log(`[smoke] REAL Gemma @ ${baseUrl} model=${model}\n`);
let ok = true;
let gotContent = false;

const r = await g.reason({ question: 'What did each agent do for the Gemma milestone?', bundle, groundedEvidenceIds: grounded });
console.log('[reason] text:', JSON.stringify((r.text || '').slice(0, 220)));
if ((r.text || '').length || (r.evidenceIds || []).length) gotContent = true;
ok = checkCites(r.evidenceIds, 'reason') && ok;

const b = await g.brief({ bundle, groundedEvidenceIds: grounded });
console.log(`\n[brief] ${b.segments.length} segments`);
if (b.segments.length) gotContent = true;
for (const [i, s] of b.segments.entries()) {
  console.log(`  seg[${i}] text:`, JSON.stringify((s.text || '').slice(0, 140)));
  ok = checkCites(s.evidenceIds, `brief seg[${i}]`) && ok;
}

console.log('');
if (!gotContent) {
  // Empty is my backend's FAIL-CLOSED behavior (Gemma down / non-JSON) — honest, but not a positive grounding proof.
  console.log('[SMOKE] INCONCLUSIVE — Gemma returned no content (backend fail-closed). Check Ollama is serving + the model id. This is the honest-no-fabrication path, but not a positive grounded-output proof.');
  process.exit(2);
}
console.log(ok
  ? '[SMOKE] PASS — real Gemma produced grounded output and EVERY citation is in the verified bundle (no fabrication survived).'
  : '[SMOKE] FAIL — a non-grounded citation survived the grounding filter (investigate the backend).');
process.exit(ok ? 0 : 1);
