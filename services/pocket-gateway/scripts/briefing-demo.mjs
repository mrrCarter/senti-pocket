// briefing-demo.mjs — run the WHOLE gateway briefing pipeline end-to-end and PRINT the human-readable briefing the
// phone would speak. Proves the backend produces a grounded, signature-verified briefing from a checkpoint — the
// content side of the demo, before the Swift app exists. No live services; a throwaway keypair signs+verifies locally.
//
//   node scripts/briefing-demo.mjs                # canned demo checkpoint
//   node scripts/briefing-demo.mjs export.json    # a real `sl session export` JSON (extracts the whole window)
import { readFileSync } from 'node:fs';
import { buildRawCheckpoint } from '../src/extract.mjs';
import { summarize } from '../src/summarize.mjs';
import { buildSignedBundle, verifyBundle, generateSigningKeypair } from '../src/bundle.mjs';

const CANNED = {
  session: { id: 'sess_demo_pocket', title: 'Senti Pocket build' },
  events: [
    { sequenceId: 4101, event: 'session_message', agent: { id: 'claude-pocket-relay' }, payload: { text: 'pocket.bundle.v1 mirrored byte-for-byte; positive + negative KAV verify cross-language.' }, ts: '2026-07-19T00:20:00Z' },
    { sequenceId: 4102, event: 'session_message', agent: { id: 'claude-warden' }, payload: { text: 'bundle-KAV is DEMO-COMPLETE on a clean gate; crypto core airtight.' }, ts: '2026-07-19T00:23:00Z' },
    { sequenceId: 4103, event: 'session_message', agent: { id: 'codex-pocket-pulse' }, payload: { text: 'HOLD: gateway element budget 20000 vs phone 5000 — a valid bundle could be rejected.' }, ts: '2026-07-19T00:40:00Z' },
    { sequenceId: 4104, event: 'session_message', agent: { id: 'claude-pocket-relay' }, payload: { text: 'fixed: pinned the budget to the phone 5000 + conservative accounting + fail-fast.' }, ts: '2026-07-19T01:05:00Z' },
  ],
};

const exportPath = process.argv[2];
const exportJson = exportPath ? JSON.parse(readFileSync(exportPath, 'utf8')) : CANNED;
const seqs = exportJson.events.map((e) => e.sequenceId).filter((n) => Number.isSafeInteger(n));
const ckpt = {
  checkpointId: `cp_${exportJson.session.id}_demo`,
  sessionId: exportJson.session.id,
  startSequence: Math.min(...seqs),
  endSequence: Math.max(...seqs),
  summarySections: { window: { eventCount: exportJson.events.length }, headline: exportJson.session.title },
};

const { rawCheckpoint } = buildRawCheckpoint(ckpt, exportJson, { capturedAt: '2026-07-19T01:06:00Z' });
const summary = summarize(rawCheckpoint, ckpt);
const { publicKey, privateKey } = generateSigningKeypair();
const bundle = buildSignedBundle(rawCheckpoint, summary, privateKey, { signingKeyId: 'briefing-demo', createdAt: '2026-07-19T01:06:00Z' });
const verified = verifyBundle(bundle, publicKey);

const line = (s) => process.stdout.write(s + '\n');
line('\n=== Senti is calling — briefing ===');
line(`signature: ${verified ? 'VERIFIED ✓' : 'UNVERIFIED ✗'}  (${bundle.evidence.length} cited events, seq ${bundle.sequenceStart}..${bundle.sequenceEnd})`);
line(`\n${summary.headline}${summary.grade ? `   [grade ${summary.grade}]` : ''}`);
for (const a of summary.perAgent) {
  line(`\n• ${a.summary}`);
  for (const c of a.claims) line(`    - (${c.kind}) ${c.text}  ⟵ ${c.evidenceIds.join(', ')}`);
}
if (summary.risks.length) line(`\nrisks: ${summary.risks.join(' | ')}`);
if (summary.blockers.length) line(`blockers: ${summary.blockers.join(' | ')}`);
line('\ncited evidence (what each claim is grounded in):');
for (const e of bundle.evidence) line(`  [${e.id}] seq ${e.sequence} · ${e.agentId} · "${e.snippet}"`);
line('');
process.exit(verified ? 0 : 1);
