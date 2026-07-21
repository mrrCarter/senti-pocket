// deck-narration.test.mjs — narrateDeck: tagged/plain split, injected TTS, honest skip reasons, per-slide isolation.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { narrateDeck } from '../src/deck/narration.mjs';

// A mock ttsBackend that echoes what it was asked to voice, so we can assert it received the TAGGED text.
function mockTts(calls) {
  return async (text, opts) => {
    calls.push({ text, opts });
    return { audio: Buffer.from('AUDIO:' + text), format: 'pcm_s16le_24000' };
  };
}

test('narrates each slide: tagged->TTS, plain->transcript, base64 audio', async () => {
  const calls = [];
  const deck = { slides: [
    { template: 'title', script: '[warm] Welcome to Pocket. [pause] It writes as you.' },
    { template: 'stat', content: { script: 'Two hundred and six merges, all gated.' } },
  ] };
  const r = await narrateDeck(deck, { ttsBackend: mockTts(calls), voiceId: 'v1', tone: 'calm' });
  assert.equal(r.count, 2);
  assert.equal(r.narratedCount, 2);
  assert.equal(r.audioEnabled, true);
  // slide 0: tags voiced (tagged), transcript stripped
  assert.equal(r.segments[0].tagged, '[warm] Welcome to Pocket. [pause] It writes as you.');
  assert.equal(r.segments[0].transcript, 'Welcome to Pocket. It writes as you.');
  assert.equal(r.segments[0].hasAudioTags, true);
  assert.ok(r.segments[0].audio, 'audio present');
  assert.equal(Buffer.from(r.segments[0].audio, 'base64').toString(), 'AUDIO:[warm] Welcome to Pocket. [pause] It writes as you.', 'TTS was fed the TAGGED text');
  assert.equal(r.segments[0].format, 'pcm_s16le_24000');
  // slide 1: content.script + no tags
  assert.equal(r.segments[1].transcript, 'Two hundred and six merges, all gated.');
  assert.equal(r.segments[1].hasAudioTags, false);
  // voiceId + tone threaded to the backend
  assert.equal(calls[0].opts.voiceId, 'v1');
  assert.equal(calls[0].opts.tone, 'calm');
});

test('no ttsBackend -> transcript only, honest audioSkipped=no-backend (never fake audio)', async () => {
  const r = await narrateDeck({ slides: [{ template: 'title', script: 'Hello.' }] });
  assert.equal(r.audioEnabled, false);
  assert.equal(r.narratedCount, 0);
  assert.equal(r.segments[0].transcript, 'Hello.');
  assert.equal(r.segments[0].audio, undefined);
  assert.equal(r.segments[0].audioSkipped, 'no-backend');
});

test('synthesize:false with a backend -> not-requested', async () => {
  const r = await narrateDeck({ slides: [{ template: 'title', script: 'Hi.' }] }, { ttsBackend: mockTts([]), synthesize: false });
  assert.equal(r.segments[0].audioSkipped, 'not-requested');
  assert.equal(r.narratedCount, 0);
});

test('slide without a script -> audioSkipped=no-script (no silent synthesis)', async () => {
  const r = await narrateDeck({ slides: [{ template: 'section', content: { title: 'Only a title' } }] }, { ttsBackend: mockTts([]) });
  assert.equal(r.segments[0].transcript, '');
  assert.equal(r.segments[0].audioSkipped, 'no-script');
  assert.equal(r.segments[0].audio, undefined);
});

test('per-slide TTS failure is isolated + honest — the rest of the deck still narrates', async () => {
  let n = 0;
  const flaky = async (text) => { n++; if (n === 1) throw new Error('elevenlabs 429 rate limit'); return { audio: Buffer.from(text), format: 'pcm' }; };
  const r = await narrateDeck({ slides: [{ script: 'first' }, { script: 'second' }] }, { ttsBackend: flaky });
  assert.equal(r.segments[0].audioSkipped, 'tts-error');
  assert.match(r.segments[0].audioError, /rate limit/);
  assert.equal(r.segments[0].audio, undefined);
  assert.ok(r.segments[1].audio, 'second slide still narrated');
  assert.equal(r.narratedCount, 1, 'one of two succeeded');
});

test('empty audio from backend -> audioSkipped=empty-audio (not counted as narrated)', async () => {
  const empty = async () => ({ audio: Buffer.alloc(0), format: 'pcm' });
  const r = await narrateDeck({ slides: [{ script: 'x' }] }, { ttsBackend: empty });
  assert.equal(r.segments[0].audioSkipped, 'empty-audio');
  assert.equal(r.narratedCount, 0);
});

test('per-slide tone overrides deck default; invalid tone falls back', async () => {
  const calls = [];
  const r = await narrateDeck({ slides: [{ script: 'a', tone: 'urgent' }, { script: 'b', tone: 'bogus' }] }, { ttsBackend: mockTts(calls), tone: 'calm' });
  assert.equal(r.segments[0].tone, 'urgent');   // slide override
  assert.equal(r.segments[1].tone, 'calm');     // invalid -> deck default
  assert.equal(calls[0].opts.tone, 'urgent');
});

test('maxTotalAudioBytes caps aggregate audio — stops past the bound, honest deck-audio-cap (relay Finding 1)', async () => {
  const chunk = async () => ({ audio: Buffer.alloc(700), format: 'mp3' }); // 700 raw -> 936 base64 bytes each
  const r = await narrateDeck({ slides: [{ script: 'a' }, { script: 'b' }, { script: 'c' }] }, { ttsBackend: chunk, maxTotalAudioBytes: 1200 });
  assert.ok(r.segments[0].audio, 'slide 0 narrated (total ~936 < 1200)');
  assert.ok(r.segments[1].audio, 'slide 1 narrated (crosses the cap)');
  assert.equal(r.segments[2].audioSkipped, 'deck-audio-cap', 'slide 2 skipped once cap reached');
  assert.equal(r.segments[2].audio, undefined);
  assert.equal(r.capReached, true);
  assert.equal(r.narratedCount, 2);
  assert.ok(r.audioBytes >= 1200, 'aggregate bytes tracked');
});

test('maxNarratedSlides caps synth CALL-COUNT (serial TTS time bound) — past N -> deck-slide-cap', async () => {
  const chunk = async () => ({ audio: Buffer.alloc(10), format: 'mp3' }); // tiny audio -> byte cap never triggers
  const r = await narrateDeck({ slides: Array.from({ length: 5 }, (_, i) => ({ script: 's' + i })) }, { ttsBackend: chunk, maxNarratedSlides: 2 });
  assert.equal(r.narratedCount, 2, 'only 2 slides synthesized');
  assert.ok(r.segments[0].audio && r.segments[1].audio);
  assert.equal(r.segments[2].audioSkipped, 'deck-slide-cap', 'slide 2 hits count cap');
  assert.equal(r.segments[4].audioSkipped, 'deck-slide-cap');
  assert.equal(r.capReached, true);
});

test('no cap -> all narrate; capReached false; audioBytes summed', async () => {
  const chunk = async () => ({ audio: Buffer.alloc(30), format: 'mp3' });
  const r = await narrateDeck({ slides: [{ script: 'a' }, { script: 'b' }] }, { ttsBackend: chunk });
  assert.equal(r.capReached, false);
  assert.equal(r.narratedCount, 2);
  assert.ok(r.audioBytes > 0);
});

test('empty deck -> empty result, no throw', async () => {
  const r = await narrateDeck({}, { ttsBackend: mockTts([]) });
  assert.deepEqual(r, { segments: [], count: 0, narratedCount: 0, audioEnabled: true, audioBytes: 0, capReached: false });
});
