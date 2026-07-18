// summarize.test.mjs — deterministic grounded summarizer + full extract->summarize->bundle->sign->verify pipeline.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { summarize, SUMMARY_BASELINE_SCHEMA } from '../src/summarize.mjs';
import { buildRawCheckpoint, extractCheckpoint } from '../src/extract.mjs';
import { buildSignedBundle, verifyBundle, generateSigningKeypair } from '../src/bundle.mjs';

const SID = '954233b7-1822-42bc-9cfe-1eb95eb0357a';
const EXPORT = {
  session: { id: SID, title: 'AIdenID-Live-Demo' },
  events: [
    { sequenceId: 100, event: 'session_message', agent: { id: 'claude-pocket-relay' }, payload: { text: 'parser fixed' }, ts: '2026-07-18T10:35:00Z' },
    { sequenceId: 101, event: 'session_message', agent: { id: 'claude-warden' }, payload: { text: 'STRONG PASS on #275' }, ts: '2026-07-18T10:36:00Z' },
    { sequenceId: 102, event: 'session_message', agent: { id: 'claude-pocket-relay' }, payload: { text: 'pushed fix; re-running' }, ts: '2026-07-18T10:37:00Z' },
    { sequenceId: 103, event: 'session_message', agent: { id: 'claude-warden' }, payload: { text: 'gate green' }, ts: '2026-07-18T10:38:00Z' },
  ],
};
const CKPT = { checkpointId: 'cp_954233b7_000012', sessionId: SID, startSequence: 100, endSequence: 103, summarySections: { window: { eventCount: 4 } } };

const rc = () => buildRawCheckpoint(CKPT, EXPORT).rawCheckpoint;

test('summarize produces a frozen-schema CheckpointSummary', () => {
  const s = summarize(rc(), CKPT);
  assert.equal(s.checkpointId, 'cp_954233b7_000012');
  assert.deepEqual(Object.keys(s).sort(), ['blockers', 'checkpointId', 'grade', 'headline', 'perAgent', 'risks', 'summaryBaselineSchema']);
  assert.equal(s.perAgent.length, 2);
  assert.deepEqual(s.perAgent.map((a) => a.agentId), ['claude-pocket-relay', 'claude-warden']);
});

test('every AgentSummary evidence cites a REAL event sequence (grounded), bounded per agent', () => {
  const s = summarize(rc(), CKPT);
  const realSeqs = new Set(EXPORT.events.map((e) => e.sequenceId));
  for (const a of s.perAgent) {
    assert.ok(a.evidence.length >= 1 && a.evidence.length <= 5);
    for (const ev of a.evidence) {
      assert.ok(realSeqs.has(ev.sequence), 'evidence anchored to a real event');
      assert.equal(ev.id, `ev_cp_954233b7_000012_${ev.sequence}`);
      assert.equal(ev.agentId, a.agentId, 'evidence attributed to the summarizing agent');
      assert.equal(ev.sessionId, SID);
    }
  }
});

test('summarize is deterministic: same input => byte-identical output', () => {
  assert.deepEqual(summarize(rc(), CKPT), summarize(rc(), CKPT));
});

test('senti summarySections pass through as provenance (headline/grade/risks/blockers)', () => {
  const desc = { ...CKPT, grade: 'A', summarySections: { ...CKPT.summarySections, headline: 'Billing gate cleared; parser shipped', risks: ['CI still down'], blockers: [] } };
  const s = summarize(rc(), desc);
  assert.equal(s.headline, 'Billing gate cleared; parser shipped');
  assert.equal(s.summaryBaselineSchema, 'checkpoint_summary_sections_v1');
  assert.equal(s.grade, 'A');
  assert.deepEqual(s.risks, ['CI still down']);
});

test('baseline schema label when senti provides no headline; sessionTitle preferred, else generated', () => {
  // no sections.headline -> baseline schema; headline falls back to the sessionTitle
  const s = summarize(rc(), { ...CKPT, summarySections: { window: { eventCount: 4 } } });
  assert.equal(s.summaryBaselineSchema, SUMMARY_BASELINE_SCHEMA);
  assert.equal(s.headline, 'AIdenID-Live-Demo');
  // no title anywhere -> deterministic generated headline
  const noTitle = buildRawCheckpoint({ checkpointId: 'cp_nt', sessionId: SID, startSequence: 100, endSequence: 103, summarySections: { window: { eventCount: 4 } } }, { session: { id: SID }, events: EXPORT.events }).rawCheckpoint;
  assert.match(summarize(noTitle, {}).headline, /cp_nt: 4 events from 2 agents/);
});

test('FULL PIPELINE: extract -> summarize -> buildSignedBundle -> verifyBundle', () => {
  const run = (args) => (args.includes('list') ? JSON.stringify([CKPT]) : JSON.stringify(EXPORT));
  const { rawCheckpoint, checkpoint } = extractCheckpoint(SID, { run });
  const summary = summarize(rawCheckpoint, checkpoint);
  const { publicKey, privateKey } = generateSigningKeypair();
  const signed = buildSignedBundle(rawCheckpoint, summary, privateKey, { signingKeyId: 'gw-key', createdAt: '2026-07-18T11:00:00Z' });
  assert.equal(verifyBundle(signed, publicKey), true, 'signed bundle verifies end-to-end');
  assert.equal(verifyBundle({ ...signed, summary: { ...signed.summary, headline: 'TAMPERED' } }, publicKey), false, 'tamper breaks the signature');
  assert.equal(signed.summary.perAgent.length, 2);
  assert.ok(signed.evidence.length >= 2, 'bundle carries a deduped grounded evidence set');
  assert.equal(signed.events, undefined, 'raw room events never cross to the phone');
});
