// gemma-backend.test.mjs — deps.reason + deps.brief over an OpenAI-compatible Gemma endpoint. Hermetic (fake fetch).
// Proves grounding-first (hallucinated cites dropped), fail-closed (non-JSON / HTTP error -> empty, never fabricated),
// key-free vs keyed auth, and the request shape. Downstream routeAnswer/handleBrief re-apply grounding — belt+suspenders.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createGemmaBackend } from '../src/gemma-backend.mjs';

const BUNDLE = {
  checkpointId: 'cp_1',
  evidence: [
    { id: 'ev_1', agentId: 'claude-pocket-relay', sequence: 101, snippet: 'parser fixed' },
    { id: 'ev_2', agentId: 'claude-warden', sequence: 102, snippet: 'STRONG PASS' },
  ],
};
const GROUNDED = ['ev_1', 'ev_2'];

// fake OpenAI /chat/completions: returns `content` as choices[0].message.content
function fakeChat(content, { ok = true, status = 200 } = {}) {
  const calls = [];
  const fetch = async (url, init) => {
    calls.push({ url, init, body: JSON.parse(init.body) });
    return { ok, status, json: async () => ({ choices: [{ message: { content } }] }) };
  };
  return { fetch, calls };
}

test('reason: grounded answer; hallucinated cites dropped; confidence clamped; ungrounded topics dropped', async () => {
  const content = JSON.stringify({
    text: 'The parser was fixed.', taggedText: '[warm] The parser was fixed.',
    evidenceIds: ['ev_1', 'ev_hallucinated'], confidence: 1.4,
    nearestTopics: [{ label: 'parser', evidenceId: 'ev_1' }, { label: 'ghost', evidenceId: 'ev_x' }],
  });
  const { fetch, calls } = fakeChat(content);
  const g = createGemmaBackend({ baseUrl: 'http://localhost:11434/v1/', model: 'gemma3', fetch }); // trailing slash trimmed
  const r = await g.reason({ question: 'what happened to the parser?', bundle: BUNDLE, groundedEvidenceIds: GROUNDED });
  assert.equal(r.text, 'The parser was fixed.');
  assert.equal(r.taggedText, '[warm] The parser was fixed.');
  assert.deepEqual(r.evidenceIds, ['ev_1'], 'hallucinated ev_hallucinated dropped (grounding-first)');
  assert.equal(r.llmConfidence, 1, 'confidence clamped to [0,1]');
  assert.deepEqual(r.nearestTopics, [{ label: 'parser', evidenceId: 'ev_1' }], 'ungrounded topic ev_x dropped');
  // request shape
  assert.equal(calls[0].url, 'http://localhost:11434/v1/chat/completions');
  assert.equal(calls[0].body.model, 'gemma3');
  assert.equal(calls[0].body.messages.length, 2, 'system + user');
  assert.equal(calls[0].init.headers.authorization, undefined, 'no apiKey -> no Authorization header (key-free Ollama)');
});

test('reason: ALL citations hallucinated (grounded set empties) -> text nulled too (parity with brief; defense-in-depth)', async () => {
  const { fetch } = fakeChat(JSON.stringify({ text: 'confident but ungrounded', evidenceIds: ['ev_ghost1', 'ev_ghost2'], confidence: 0.95 }));
  const g = createGemmaBackend({ baseUrl: 'http://x/v1', fetch });
  const r = await g.reason({ question: 'q', bundle: BUNDLE, groundedEvidenceIds: GROUNDED });
  assert.deepEqual(r.evidenceIds, [], 'all hallucinated cites dropped');
  assert.equal(r.text, '', 'ungrounded -> empty text (was: text kept; now the backend fail-closes on its own, not just via routeAnswer)');
  assert.equal(r.taggedText, undefined);
});

test('reason: apiKey -> Authorization: Bearer sent (AI Studio path)', async () => {
  const { fetch, calls } = fakeChat(JSON.stringify({ text: 'x', evidenceIds: ['ev_1'], confidence: 0.9 }));
  const g = createGemmaBackend({ baseUrl: 'https://ai.example/v1', apiKey: 'FREE_KEY', fetch });
  await g.reason({ question: 'q', bundle: BUNDLE, groundedEvidenceIds: GROUNDED });
  assert.equal(calls[0].init.headers.authorization, 'Bearer FREE_KEY');
});

test('reason: fail-closed on non-JSON content -> empty (routes to unavailable, never fabricated)', async () => {
  const { fetch } = fakeChat('sorry, I cannot help with that'); // not JSON, no braces
  const g = createGemmaBackend({ baseUrl: 'http://x/v1', fetch });
  const r = await g.reason({ question: 'q', bundle: BUNDLE, groundedEvidenceIds: GROUNDED });
  assert.deepEqual(r, { text: '', evidenceIds: [], llmConfidence: 0, nearestTopics: [] });
});

test('reason: fail-closed on HTTP error -> empty', async () => {
  const { fetch } = fakeChat('{}', { ok: false, status: 500 });
  const g = createGemmaBackend({ baseUrl: 'http://x/v1', fetch });
  const r = await g.reason({ question: 'q', bundle: BUNDLE, groundedEvidenceIds: GROUNDED });
  assert.equal(r.text, '');
  assert.deepEqual(r.evidenceIds, []);
});

test('reason: JSON wrapped in prose/fences still parses (safeJson robustness)', async () => {
  const wrapped = 'Here is the answer:\n```json\n' + JSON.stringify({ text: 'grounded', evidenceIds: ['ev_2'], confidence: 0.8 }) + '\n```';
  const { fetch } = fakeChat(wrapped);
  const g = createGemmaBackend({ baseUrl: 'http://x/v1', fetch });
  const r = await g.reason({ question: 'q', bundle: BUNDLE, groundedEvidenceIds: GROUNDED });
  assert.equal(r.text, 'grounded');
  assert.deepEqual(r.evidenceIds, ['ev_2']);
});

test('brief: grounded segments kept; ungrounded + empty-text dropped', async () => {
  const content = JSON.stringify({ segments: [
    { text: 'Relay fixed the parser.', taggedText: '[calm] Relay fixed the parser.', evidenceIds: ['ev_1'] },
    { text: 'Ungrounded claim.', evidenceIds: ['ev_ghost'] }, // dropped: no grounded cite
    { text: '', evidenceIds: ['ev_2'] },                       // dropped: no text
  ] });
  const { fetch } = fakeChat(content);
  const g = createGemmaBackend({ baseUrl: 'http://x/v1', fetch });
  const b = await g.brief({ bundle: BUNDLE, groundedEvidenceIds: GROUNDED });
  assert.equal(b.segments.length, 1);
  assert.equal(b.segments[0].text, 'Relay fixed the parser.');
  assert.deepEqual(b.segments[0].evidenceIds, ['ev_1']);
});

test('brief: a WHITESPACE-ONLY segment with a grounded cite is DROPPED (isGrounded alignment — was kept by s.text-truthy)', async () => {
  const content = JSON.stringify({ segments: [
    { text: 'A real grounded segment.', evidenceIds: ['ev_1'] },
    { text: '   \n\t  ', evidenceIds: ['ev_2'] }, // whitespace-only + grounded cite -> now dropped (no words for the phone)
  ] });
  const { fetch } = fakeChat(content);
  const g = createGemmaBackend({ baseUrl: 'http://x/v1', fetch });
  const b = await g.brief({ bundle: BUNDLE, groundedEvidenceIds: GROUNDED });
  assert.equal(b.segments.length, 1, 'only the real segment survives; whitespace-only dropped');
  assert.equal(b.segments[0].text, 'A real grounded segment.');
});

test('brief: fail-closed on non-JSON -> no segments', async () => {
  const { fetch } = fakeChat('nope');
  const g = createGemmaBackend({ baseUrl: 'http://x/v1', fetch });
  assert.deepEqual(await g.brief({ bundle: BUNDLE, groundedEvidenceIds: GROUNDED }), { segments: [] });
});

test('reason: explicit EMPTY groundedEvidenceIds grounds against NOTHING (not the whole bundle) — fail-closed', async () => {
  const { fetch } = fakeChat(JSON.stringify({ text: 'grounded-looking', evidenceIds: ['ev_1', 'ev_2'], confidence: 0.9 }));
  const g = createGemmaBackend({ baseUrl: 'http://x/v1', fetch });
  // the model cites real bundle ids, but the RETRIEVAL grounding is EMPTY -> every cite must be dropped
  const r = await g.reason({ question: 'q', bundle: BUNDLE, groundedEvidenceIds: [] });
  assert.deepEqual(r.evidenceIds, [], 'explicit [] grounds against nothing (was: silently fell back to the entire bundle)');
  // control: ABSENT grounding still derives from the bundle -> the same cites survive
  const r2 = await g.reason({ question: 'q', bundle: BUNDLE });
  assert.deepEqual(r2.evidenceIds, ['ev_1', 'ev_2'], 'absent grounding derives from the bundle');
});

test('factory requires baseUrl + fetch', () => {
  assert.throws(() => createGemmaBackend({ fetch: async () => {} }), /baseUrl is required/);
  assert.throws(() => createGemmaBackend({ baseUrl: 'http://x', fetch: null }), /fetch is required/);
});
