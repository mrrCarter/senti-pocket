// deck-endpoint.test.mjs — POST /deck through the real createGateway().handle(): auth, scope gating, audio opt-in, errors.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createGateway } from '../src/handlers.mjs';

const FULL = ['sessions:read', 'sessions:write', 'pocket:voice'];
const gateway = (scopes = FULL, ttsBackend) => createGateway({
  verifyToken: async (headers) => (headers && headers.authorization ? { humanId: 'mrrcarter', scopes } : null),
  ttsBackend,
});
const post = (gw, body, headers = { authorization: 'Bearer t' }) => gw.handle({ method: 'POST', path: '/deck', headers, body });
const parse = (res) => (typeof res.body === 'string' ? JSON.parse(res.body) : res.body);

const DECK = { style: 'midnight', brand: 'SentinelLayer', slides: [
  { template: 'title', content: { title: 'Answer the call.' }, script: '[warm] Senti briefs you, then writes as you.' },
  { template: 'stat', content: { value: '264681', label: 'first live write' } },
] };

test('POST /deck (read scope) -> 200, deterministic SVGs + transcripts, no audio unless requested', async () => {
  const res = await post(gateway(['sessions:read']), DECK);
  assert.equal(res.status, 200);
  const b = parse(res);
  assert.equal(b.count, 2);
  assert.equal(b.audioEnabled, false);
  assert.match(b.slides[0].svg, /<svg /);
  assert.equal(b.slides[0].narration.transcript, 'Senti briefs you, then writes as you.');
  assert.equal(b.slides[0].narration.audio, null);
  assert.equal(b.slides[0].narration.audioSkipped, 'no-backend');
  assert.equal(b.slides[1].narration.audioSkipped, 'no-script');
});

test('narrate:true with pocket:voice + backend -> base64 audio, fed the TAGGED script', async () => {
  const calls = [];
  const tts = async (text) => { calls.push(text); return { audio: Buffer.from('A:' + text), format: 'pcm_24000' }; };
  const res = await post(gateway(FULL, tts), { ...DECK, narrate: true, voiceId: 'v1' });
  const b = parse(res);
  assert.equal(res.status, 200);
  assert.equal(b.audioEnabled, true);
  assert.equal(b.narratedCount, 1);
  assert.ok(b.slides[0].narration.audio, 'audio present');
  assert.equal(Buffer.from(b.slides[0].narration.audio, 'base64').toString(), 'A:[warm] Senti briefs you, then writes as you.');
  assert.equal(calls[0], '[warm] Senti briefs you, then writes as you.');
});

test('auth required -> 401 without a token', async () => {
  const res = await post(gateway(), DECK, {});
  assert.equal(res.status, 401);
});

test('missing sessions:read scope -> 403', async () => {
  const res = await post(gateway(['pocket:voice']), DECK);
  assert.equal(res.status, 403);
  assert.match(parse(res).error, /sessions:read/);
});

test('narrate:true WITHOUT pocket:voice -> 403 (voice egress gated even for a read+write token)', async () => {
  const res = await post(gateway(['sessions:read', 'sessions:write']), { ...DECK, narrate: true });
  assert.equal(res.status, 403);
  assert.match(parse(res).error, /pocket:voice/);
});

test('narrate:true with pocket:voice but NO backend -> 200, honest no-backend (never fake audio)', async () => {
  const res = await post(gateway(FULL, undefined), { ...DECK, narrate: true });
  const b = parse(res);
  assert.equal(res.status, 200);
  assert.equal(b.audioEnabled, false);
  assert.equal(b.slides[0].narration.audioSkipped, 'no-backend');
});

test('invalid JSON body -> 400', async () => {
  const res = await post(gateway(), '{not json');
  assert.equal(res.status, 400);
  assert.match(parse(res).error, /invalid JSON/);
});

test('empty / missing slides -> 400', async () => {
  assert.equal((await post(gateway(), { slides: [] })).status, 400);
  assert.equal((await post(gateway(), { foo: 1 })).status, 400);
});

test('too many slides -> 413', async () => {
  const big = { slides: Array.from({ length: 61 }, () => ({ template: 'stat', content: { value: '1' } })) };
  assert.equal((await post(gateway(), big)).status, 413);
});

test('unknown template -> 400 render failed (not a 500)', async () => {
  const res = await post(gateway(), { slides: [{ template: 'bogus' }] });
  assert.equal(res.status, 400);
  assert.match(parse(res).error, /render failed/);
});

test('oversized slide script (narrate) -> 413', async () => {
  const res = await post(gateway(FULL, async () => ({ audio: Buffer.from('x'), format: 'pcm' })),
    { narrate: true, slides: [{ template: 'title', script: 'x'.repeat(8193) }] });
  assert.equal(res.status, 413);
});

test('accepts {deck:{...}} envelope as well as a bare deck', async () => {
  const res = await post(gateway(['sessions:read']), { deck: DECK });
  assert.equal(res.status, 200);
  assert.equal(parse(res).count, 2);
});
