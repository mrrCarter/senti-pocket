// brief-pipeline.test.mjs — the state-machined briefing pipeline: PLAN -> DRAFT -> VERIFY -> DONE|UNAVAILABLE.
// Every Gemma sub-agent is MOCKED, so this proves the orchestration + every fail-closed transition deterministically
// (no live endpoint / native dep). Grounding discipline is verified to match the shipped brief()/handleBrief filter.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createBriefPipeline } from '../src/deck/brief-pipeline.mjs';

const GROUNDED = ['ev-1', 'ev-2', 'ev-3'];
const BUNDLE = { evidence: GROUNDED.map((id) => ({ id, text: `body ${id}` })) };

// A configurable mock backend: records calls; plan/draft behavior is supplied per test.
function mock({ plan, draft } = {}) {
  const calls = { plan: [], draft: [] };
  return {
    calls,
    plan: async (a) => { calls.plan.push(a); return plan ? plan(a) : { points: [] }; },
    draft: async (a) => { calls.draft.push(a); return draft ? draft(a) : { text: '', evidenceIds: [] }; },
  };
}
const run = (m, extra = {}) => createBriefPipeline({ plan: m.plan, draft: m.draft, ...extra })
  .brief({ bundle: BUNDLE, groundedEvidenceIds: GROUNDED });

test('happy path: PLAN -> DRAFT -> VERIFY -> DONE, grounded segments only', async () => {
  const m = mock({
    plan: () => ({ points: [{ label: 'a', evidenceIds: ['ev-1'] }, { label: 'b', evidenceIds: ['ev-2'] }] }),
    draft: ({ point }) => ({ text: `seg for ${point.label}`, taggedText: `[warm] seg for ${point.label}`, evidenceIds: point.evidenceIds }),
  });
  const r = await run(m);
  assert.equal(r.status, 'briefed');
  assert.deepEqual(r.trace, ['plan', 'draft', 'verify', 'done']);
  assert.equal(r.segments.length, 2);
  assert.equal(r.segments[0].text, 'seg for a');
  assert.equal(r.segments[0].taggedText, '[warm] seg for a');
  assert.deepEqual(r.segments[0].evidenceIds, ['ev-1']);
  assert.equal(m.calls.plan.length, 1);
  assert.equal(m.calls.draft.length, 2, 'one DRAFT sub-agent call per surviving point');
  // the DRAFT sub-agent receives the point + bundle + grounding
  assert.deepEqual(m.calls.draft[0].point.evidenceIds, ['ev-1']);
  assert.equal(m.calls.draft[0].bundle, BUNDLE);
});

test('empty grounding -> UNAVAILABLE before ANY sub-agent call (fail-fast, no wasted Gemma)', async () => {
  const m = mock({ plan: () => ({ points: [{ evidenceIds: ['ev-1'] }] }) });
  const r = await createBriefPipeline({ plan: m.plan, draft: m.draft }).brief({ bundle: BUNDLE, groundedEvidenceIds: [] });
  assert.equal(r.status, 'unavailable');
  assert.deepEqual(r.trace, ['plan', 'unavailable']);
  assert.equal(m.calls.plan.length, 0, 'PLAN must not run when nothing is grounded');
  assert.equal(m.calls.draft.length, 0);
});

test('PLAN throws -> UNAVAILABLE (fail-closed)', async () => {
  const m = mock();
  m.plan = async () => { throw new Error('gemma down'); };
  const r = await run(m);
  assert.equal(r.status, 'unavailable');
  assert.deepEqual(r.trace, ['plan', 'unavailable']);
  assert.equal(m.calls.draft.length, 0);
});

test('PLAN returns no points -> UNAVAILABLE', async () => {
  const r = await run(mock({ plan: () => ({ points: [] }) }));
  assert.equal(r.status, 'unavailable');
});

test('PLAN returns only UNGROUNDED points -> UNAVAILABLE (ungrounded point never drafted)', async () => {
  const m = mock({ plan: () => ({ points: [{ label: 'x', evidenceIds: ['ev-HALLUCINATED'] }, { label: 'y', evidenceIds: [] }] }) });
  const r = await run(m);
  assert.equal(r.status, 'unavailable');
  assert.equal(m.calls.draft.length, 0, 'no grounded point survived planning -> DRAFT never runs');
});

test('one DRAFT throws -> that point drops, the rest survive (partial brief, not total failure)', async () => {
  const m = mock({
    plan: () => ({ points: [{ label: 'a', evidenceIds: ['ev-1'] }, { label: 'b', evidenceIds: ['ev-2'] }] }),
    draft: ({ point }) => { if (point.label === 'a') throw new Error('draft blip'); return { text: 'ok b', evidenceIds: ['ev-2'] }; },
  });
  const r = await run(m);
  assert.equal(r.status, 'briefed');
  assert.equal(r.segments.length, 1);
  assert.equal(r.segments[0].text, 'ok b');
});

test('VERIFY drops hallucinated cites; a segment keeps ONLY grounded ids', async () => {
  const m = mock({
    plan: () => ({ points: [{ label: 'a', evidenceIds: ['ev-1'] }] }),
    draft: () => ({ text: 'mixed', evidenceIds: ['ev-1', 'ev-HALLUCINATED', 'ev-2'] }),
  });
  const r = await run(m);
  assert.equal(r.status, 'briefed');
  assert.deepEqual(r.segments[0].evidenceIds, ['ev-1', 'ev-2'], 'hallucinated id dropped, grounded kept, order preserved');
});

test('VERIFY drops a segment with grounded cites but EMPTY text', async () => {
  const m = mock({
    plan: () => ({ points: [{ label: 'a', evidenceIds: ['ev-1'] }] }),
    draft: () => ({ text: '   ', evidenceIds: ['ev-1'] }),
  });
  const r = await run(m);
  assert.equal(r.status, 'unavailable', 'a citation with no words is not a segment');
  assert.deepEqual(r.trace, ['plan', 'draft', 'verify', 'unavailable']);
});

test('all DRAFT segments ungrounded -> UNAVAILABLE (never a fabricated brief)', async () => {
  const m = mock({
    plan: () => ({ points: [{ label: 'a', evidenceIds: ['ev-1'] }] }),
    draft: () => ({ text: 'fabricated', evidenceIds: ['ev-NOPE'] }),
  });
  const r = await run(m);
  assert.equal(r.status, 'unavailable');
  assert.equal(r.segments.length, 0);
});

test('maxPoints bounds the DRAFT fan-out', async () => {
  const m = mock({
    plan: () => ({ points: Array.from({ length: 10 }, (_, i) => ({ label: `p${i}`, evidenceIds: ['ev-1'] })) }),
    draft: ({ point }) => ({ text: point.label, evidenceIds: ['ev-1'] }),
  });
  const r = await run(m, { maxPoints: 3 });
  assert.equal(m.calls.draft.length, 3, 'only maxPoints points are drafted');
  assert.equal(r.segments.length, 3);
});

test('maxSegments bounds the terminal output', async () => {
  const m = mock({
    plan: () => ({ points: Array.from({ length: 5 }, (_, i) => ({ label: `p${i}`, evidenceIds: ['ev-1'] })) }),
    draft: ({ point }) => ({ text: point.label, evidenceIds: ['ev-1'] }),
  });
  const r = await run(m, { maxPoints: 5, maxSegments: 2 });
  assert.equal(r.segments.length, 2);
});

test('constructor requires both sub-agents', () => {
  assert.throws(() => createBriefPipeline({ plan: async () => ({ points: [] }) }), /plan and draft/);
  assert.throws(() => createBriefPipeline({ draft: async () => ({}) }), /plan and draft/);
  assert.throws(() => createBriefPipeline({}), /plan and draft/);
});

test('drop-in shape: segments match deps.brief { text, evidenceIds, taggedText? }', async () => {
  const m = mock({
    plan: () => ({ points: [{ label: 'a', evidenceIds: ['ev-1'] }] }),
    draft: () => ({ text: 'plain only', evidenceIds: ['ev-1'] }), // no taggedText
  });
  const r = await run(m);
  const seg = r.segments[0];
  assert.deepEqual(Object.keys(seg).sort(), ['evidenceIds', 'text'], 'taggedText omitted when absent (optional field)');
  assert.equal(typeof seg.text, 'string');
  assert.ok(Array.isArray(seg.evidenceIds));
});

test('draftConcurrency>1 runs DRAFT in parallel — order + isolation preserved (Atlas latency finding)', async () => {
  let inFlight = 0, maxInFlight = 0;
  const m = mock({
    plan: () => ({ points: [{ label: 'a', evidenceIds: ['ev-1'] }, { label: 'b', evidenceIds: ['ev-2'] }, { label: 'c', evidenceIds: ['ev-3'] }] }),
    draft: async ({ point }) => {
      inFlight++; maxInFlight = Math.max(maxInFlight, inFlight);
      await new Promise((r) => setTimeout(r, 5));           // hold the slot so overlaps are observable
      inFlight--;
      if (point.label === 'b') throw new Error('draft b fails'); // isolation: only b drops
      return { text: point.label, evidenceIds: point.evidenceIds };
    },
  });
  const r = await run(m, { draftConcurrency: 3 });
  assert.equal(r.status, 'briefed');
  assert.ok(maxInFlight >= 2, 'draftConcurrency=3 -> drafts overlap (>=2 concurrently)');
  assert.deepEqual(r.segments.map((s) => s.text), ['a', 'c'], 'segment ORDER preserved; failing point b dropped, not the whole brief');
});

test('default draftConcurrency=1 keeps DRAFT STRICTLY sequential (on-device thermal discipline)', async () => {
  let inFlight = 0, maxInFlight = 0;
  const m = mock({
    plan: () => ({ points: Array.from({ length: 3 }, (_, i) => ({ label: `p${i}`, evidenceIds: ['ev-1'] })) }),
    draft: async ({ point }) => {
      inFlight++; maxInFlight = Math.max(maxInFlight, inFlight);
      await new Promise((r) => setTimeout(r, 3));
      inFlight--;
      return { text: point.label, evidenceIds: ['ev-1'] };
    },
  });
  const r = await run(m); // no draftConcurrency -> default 1
  assert.equal(maxInFlight, 1, 'default never co-schedules on-device inference (strictly one draft at a time)');
  assert.deepEqual(r.segments.map((s) => s.text), ['p0', 'p1', 'p2'], 'order preserved');
});
