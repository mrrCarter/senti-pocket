// deck-hardening.test.mjs — the 6 deck finds from relay's bug-hunt (build->review->find->fix->verify).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { renderSlide, wrapText, CANVAS } from '../src/deck/templates.mjs';
import { narrateDeck } from '../src/deck/narration.mjs';
import { estimateAudioDurationMs, buildStoryboard } from '../src/deck/video.mjs';

const b64 = (n) => Buffer.alloc(n).toString('base64');
const fontSize = (svg, re) => Number((svg.match(re) || [])[1]);
const CONTENT_W = CANVAS.w - 300; // MARGIN*2

test('#1 stat: a long value scales down to FIT the content width (no overflow)', () => {
  const long = renderSlide({ template: 'stat', content: { value: '1,234,567,890,123', kicker: 'x' } });
  const size = fontSize(long.svg, /font-size="(\d+)" font-weight="850"/);
  assert.ok(size > 0 && size <= 360, 'capped at 360');
  assert.ok(size * '1,234,567,890,123'.length * 0.62 <= CONTENT_W + 1, 'estimated width fits the slide');
  // a short value keeps the big size
  const short = renderSlide({ template: 'stat', content: { value: '42' } });
  assert.equal(fontSize(short.svg, /font-size="(\d+)" font-weight="850"/), 360);
});

test('#3 wrapText: a single unbreakable token longer than maxWidth is hard-clamped (no overflow)', () => {
  const lines = wrapText('x'.repeat(300), 40, 400, 3); // one 300-char token, no spaces
  assert.ok(lines.length >= 1);
  const perChar = 40 * 0.54;
  for (const ln of lines) assert.ok(ln.length * perChar <= 400, `line "${ln.slice(0, 12)}…" fits maxWidth`);
  assert.ok(lines[0].endsWith('…'), 'clamped token is ellipsized');
});

test('#4 twoCol: a null column degrades gracefully (no TypeError -> whole deck 400)', () => {
  const r = renderSlide({ template: 'twoCol', content: { title: 'T', columns: [null, { heading: 'B', body: 'ok' }, undefined] } });
  assert.match(r.svg, /<\/svg>$/, 'renders instead of throwing');
  assert.ok(r.svg.includes('ok'), 'the valid column still renders');
});

test('#6 estimateAudioDurationMs: pcm uses its REAL byte-rate (was 3x wrong via mp3 fallback)', () => {
  // 48000 raw bytes of pcm_s16le_24000 (48000 B/s) = 1000ms
  assert.equal(estimateAudioDurationMs(b64(48000), 'pcm_s16le_24000'), 1000);
  // same bytes mislabeled/estimated at mp3_128 (16000 B/s) would be 3000ms — prove they differ
  assert.equal(estimateAudioDurationMs(b64(48000), 'mp3_44100_128'), 3000);
  assert.equal(estimateAudioDurationMs(b64(88200), 'pcm_s16le_44100'), 1000);
});

test('#5 buildStoryboard: a no-audio slide with a huge slideMs is clamped to MAX (was unbounded)', () => {
  const sb = buildStoryboard([{ template: 'stat', svg: '<svg/>' }], { defaultSlideMs: 999_999_999 });
  assert.ok(sb.shots[0].durationMs <= 120000, 'no-audio duration clamped to MAX_SLIDE_MS');
  assert.ok(sb.shots[0].durationMs >= 1500, 'and floored at MIN');
});

test('#2 narrateDeck: a single over-size slide is dropped (slide-audio-too-big), not counted, never blows the response', async () => {
  const big = async () => ({ audio: Buffer.alloc(3000), format: 'mp3' }); // 3000 raw -> 4000 base64
  // per-slide cap 2000 bytes: this slide's 4000-byte b64 exceeds it -> dropped
  const r = await narrateDeck({ slides: [{ script: 'huge' }, { script: 'ok' }] }, { ttsBackend: big, maxSlideAudioBytes: 2000 });
  assert.equal(r.segments[0].audioSkipped, 'slide-audio-too-big');
  assert.equal(r.segments[0].audio, undefined);
  assert.equal(r.segments[1].audioSkipped, 'slide-audio-too-big'); // both exceed
  assert.equal(r.narratedCount, 0);
  // a slide UNDER the cap still narrates
  const ok = await narrateDeck({ slides: [{ script: 'ok' }] }, { ttsBackend: async () => ({ audio: Buffer.alloc(100), format: 'mp3' }), maxSlideAudioBytes: 2000 });
  assert.ok(ok.segments[0].audio);
  assert.equal(ok.narratedCount, 1);
});
