// pocket-tts-backend.test.mjs — the FREE local TTS backend (kyutai pocket-tts serve). Hermetic: injected fetch,
// no network. Confirms the multipart wire, the drop-in ttsBackend contract, tone->cloned-voice, and fail-closed.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createPocketTTSBackend } from '../src/tts.mjs';

test('posts text as multipart to /tts, returns wav audio (drop-in {audio,format})', async () => {
  let captured;
  const fakeFetch = async (url, init) => { captured = { url, init }; return { ok: true, status: 200, arrayBuffer: async () => new Uint8Array([1, 2, 3]).buffer }; };
  const tts = createPocketTTSBackend({ baseUrl: 'http://tts:8000/', fetch: fakeFetch });
  const out = await tts('brief me');
  assert.ok(Buffer.isBuffer(out.audio));
  assert.deepEqual([...out.audio], [1, 2, 3]);
  assert.equal(out.format, 'wav');
  assert.match(captured.url, /^http:\/\/tts:8000\/tts$/); // trailing slash on baseUrl normalized
  assert.equal(captured.init.method, 'POST');
  assert.ok(captured.init.body instanceof FormData);
  assert.equal(captured.init.body.get('text'), 'brief me');
  assert.equal(captured.init.body.get('voice_url'), null); // no voice → server default (never a fake key)
});

test('tone selects a pre-cloned per-tone voice (our free ElevenLabs-tag stand-in); explicit voiceUrl wins', async () => {
  let form;
  const fakeFetch = async (_u, init) => { form = init.body; return { ok: true, status: 200, arrayBuffer: async () => new Uint8Array([9]).buffer }; };
  const tts = createPocketTTSBackend({ fetch: fakeFetch, toneVoices: { urgent: 'hf://voices/urgent.wav', calm: 'hf://voices/calm.wav' } });
  await tts('rotate the token now', { tone: 'urgent' });
  assert.equal(form.get('voice_url'), 'hf://voices/urgent.wav');
  await tts('all good', { tone: 'calm', voiceUrl: 'hf://voices/override.wav' });
  assert.equal(form.get('voice_url'), 'hf://voices/override.wav'); // explicit override beats the tone map
});

test('fail-closed: empty text / provider error / empty audio all throw (never a silent/fake result)', async () => {
  const okFetch = async () => ({ ok: true, status: 200, arrayBuffer: async () => new ArrayBuffer(0) });
  await assert.rejects(createPocketTTSBackend({ fetch: okFetch })(''), /text required/);
  await assert.rejects(createPocketTTSBackend({ fetch: async () => ({ ok: false, status: 502 }) })('x'), /502/);
  await assert.rejects(createPocketTTSBackend({ fetch: okFetch })('x'), /empty audio/);
});
