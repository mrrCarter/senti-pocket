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
  assert.equal(form.get('voice_url'), 'hf://voices/override.wav'); // explicit override (SAME trusted origin hf://voices) beats the tone map
});

test('SSRF defense: a caller voiceUrl on an UNtrusted origin is dropped, never forwarded to the fetching serve', async () => {
  let form;
  const fakeFetch = async (_u, init) => { form = init.body; return { ok: true, status: 200, arrayBuffer: async () => new Uint8Array([7]).buffer }; };
  const tts = createPocketTTSBackend({ fetch: fakeFetch, toneVoices: { calm: 'hf://voices/calm.wav' }, defaultVoiceUrl: 'hf://voices/default.wav' });
  // pocket-tts FETCHES voice_url server-side -> an attacker origin must NOT reach it (SSRF). Dropped -> config voice.
  await tts('hi', { voiceUrl: 'http://169.254.169.254/latest/meta-data/' });
  assert.equal(form.get('voice_url'), 'hf://voices/default.wav'); // untrusted -> config default, never the attacker URL
  await tts('hi', { tone: 'calm', voiceUrl: 'https://evil.example/x.wav' });
  assert.equal(form.get('voice_url'), 'hf://voices/calm.wav'); // untrusted -> config tone voice
  await tts('hi', { voiceUrl: 'not a url' });
  assert.equal(form.get('voice_url'), 'hf://voices/default.wav'); // unparseable -> never trusted -> dropped
  // a deploy can explicitly trust an ADDITIONAL origin via cfg.allowedVoiceUrlOrigins
  let form2;
  const fetch2 = async (_u, init) => { form2 = init.body; return { ok: true, status: 200, arrayBuffer: async () => new Uint8Array([8]).buffer }; };
  const tts2 = createPocketTTSBackend({ fetch: fetch2, allowedVoiceUrlOrigins: ['https://cdn.trusted.example'] });
  await tts2('hi', { voiceUrl: 'https://cdn.trusted.example/v/x.wav' });
  assert.equal(form2.get('voice_url'), 'https://cdn.trusted.example/v/x.wav'); // trusted origin -> honored
});

test('fail-closed: empty text / provider error / empty audio all throw (never a silent/fake result)', async () => {
  const okFetch = async () => ({ ok: true, status: 200, arrayBuffer: async () => new ArrayBuffer(0) });
  await assert.rejects(createPocketTTSBackend({ fetch: okFetch })(''), /text required/);
  await assert.rejects(createPocketTTSBackend({ fetch: async () => ({ ok: false, status: 502 }) })('x'), /502/);
  await assert.rejects(createPocketTTSBackend({ fetch: okFetch })('x'), /empty audio/);
});

test('hard timeout: a hung pocket-tts serve is aborted -> fail-closed (never hangs the ring/brief)', async () => {
  // a fetch that never resolves unless its abort signal fires — simulates a hung/slow serve
  const hungFetch = (url, init) => new Promise((_resolve, reject) => {
    init?.signal?.addEventListener('abort', () => reject(new Error('The operation was aborted')));
  });
  const tts = createPocketTTSBackend({ fetch: hungFetch, timeoutMs: 25 });
  await assert.rejects(() => tts('brief me', {}), /abort/i);
  // and the happy path still passes the signal through without interfering (timer cleared on resolve)
  let sawSignal = false;
  const okFetch = async (_u, init) => { sawSignal = init?.signal instanceof AbortSignal; return { ok: true, status: 200, arrayBuffer: async () => new Uint8Array([1]).buffer }; };
  const ok = await createPocketTTSBackend({ fetch: okFetch, timeoutMs: 25 })('hi');
  assert.equal(sawSignal, true, 'signal is wired even on the happy path');
  assert.equal(ok.format, 'wav');
});
