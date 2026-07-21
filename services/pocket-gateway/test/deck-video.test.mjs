// deck-video.test.mjs — storyboard (pure) + assembleDeckVideo (injected raster/encoder), honest fail-closed reasons.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { estimateAudioDurationMs, buildStoryboard, assembleDeckVideo } from '../src/deck/video.mjs';

const b64 = (n) => Buffer.alloc(n).toString('base64'); // n raw bytes -> base64

test('estimateAudioDurationMs: format-aware, 0 for none', () => {
  assert.equal(estimateAudioDurationMs('', 'mp3_44100_128'), 0);
  assert.equal(estimateAudioDurationMs(null, 'mp3_44100_128'), 0);
  // 16000 raw bytes at 16000 B/s (mp3_128) = 1000ms
  assert.equal(estimateAudioDurationMs(b64(16000), 'mp3_44100_128'), 1000);
  // same bytes at 8000 B/s (mp3_64) = 2000ms
  assert.equal(estimateAudioDurationMs(b64(16000), 'mp3_44100_64'), 2000);
  // unknown format falls back to mp3_128
  assert.equal(estimateAudioDurationMs(b64(16000), 'weird'), 1000);
});

test('buildStoryboard: audio slides timed to narration (floor+pad+cap); no-audio -> default; totals summed', () => {
  const slides = [
    { template: 'title', svg: '<svg>0</svg>', width: 1920, height: 1080, narration: { audio: b64(48000), format: 'mp3_44100_128', transcript: 'hi' } }, // 3000ms +600 pad = 3600
    { template: 'stat', svg: '<svg>1</svg>', width: 1920, height: 1080, narration: { audioSkipped: 'no-script' } }, // no audio -> default 5000
    { template: 'quote', svg: '<svg>2</svg>', width: 1920, height: 1080, narration: { audio: b64(1000), format: 'mp3_44100_128' } }, // ~62ms -> floor 1500
  ];
  const sb = buildStoryboard(slides);
  assert.equal(sb.count, 3);
  assert.equal(sb.hasAudio, true);
  assert.equal(sb.shots[0].durationMs, 3600, 'narration length + tail pad');
  assert.equal(sb.shots[1].durationMs, 5000, 'no audio -> default');
  assert.equal(sb.shots[2].durationMs, 1500, 'short clip clamped to floor');
  assert.equal(sb.totalMs, 3600 + 5000 + 1500);
  // carries render + transcript through
  assert.equal(sb.shots[0].svg, '<svg>0</svg>');
  assert.equal(sb.shots[0].transcript, 'hi');
  assert.equal(sb.shots[0].audioBase64.length > 0, true);
});

test('buildStoryboard is deterministic + handles empty', () => {
  const slides = [{ template: 't', svg: '<svg/>', narration: { audio: b64(2000), format: 'mp3_44100_128' } }];
  assert.deepEqual(buildStoryboard(slides), buildStoryboard(structuredClone(slides)));
  assert.deepEqual(buildStoryboard([]), { shots: [], totalMs: 0, count: 0, hasAudio: false });
});

test('assembleDeckVideo: injected raster+encoder -> base64 mp4; frames rastered in order with audio', async () => {
  const rasterCalls = [];
  const rasterize = async (svg, size) => { rasterCalls.push({ svg, size }); return Buffer.from('PNG:' + svg); };
  let encodeInput;
  const encodeVideo = async (input) => { encodeInput = input; return { video: Buffer.from('MP4:' + input.frames.length), format: 'mp4' }; };
  const sb = buildStoryboard([
    { template: 'title', svg: '<svg>A</svg>', width: 1920, height: 1080, narration: { audio: b64(32000), format: 'mp3_44100_128' } },
    { template: 'stat', svg: '<svg>B</svg>', width: 1920, height: 1080 },
  ]);
  const r = await assembleDeckVideo(sb, { rasterize, encodeVideo }, { fps: 24 });
  assert.equal(r.reason, undefined);
  assert.ok(Buffer.isBuffer(r.video), 'video is a raw Buffer (not base64)');
  assert.equal(r.video.toString(), 'MP4:2');
  assert.equal(r.format, 'mp4');
  assert.equal(r.frames, 2);
  assert.equal(r.durationMs, sb.totalMs);
  // rasterized both svgs in order, at slide size
  assert.deepEqual(rasterCalls.map((c) => c.svg), ['<svg>A</svg>', '<svg>B</svg>']);
  assert.deepEqual(rasterCalls[0].size, { width: 1920, height: 1080 });
  // encoder got frames w/ png + duration + audio, and fps
  assert.equal(encodeInput.fps, 24);
  assert.equal(Buffer.from(encodeInput.frames[0].png).toString(), 'PNG:<svg>A</svg>');
  assert.equal(encodeInput.frames[0].audioBase64.length > 0, true);
  assert.equal(encodeInput.frames[1].audioBase64, null);
});

test('assembleDeckVideo: fps clamped to a sane ceiling (unbounded fps -> encoder frame-explosion DoS)', async () => {
  const sb = buildStoryboard([{ template: 't', svg: '<svg/>' }]);
  let seenFps;
  const deps = { rasterize: async () => Buffer.from('png'), encodeVideo: async (input) => { seenFps = input.fps; return { video: Buffer.from('v'), format: 'mp4' }; } };
  // A hostile/unbounded fps makes the injected encoder emit ~fps*totalMs frames -> OOM/timeout. Clamp to MAX_FPS(60).
  await assembleDeckVideo(sb, deps, { fps: 1e9 });
  assert.equal(seenFps, 60, 'huge fps clamped to 60');
  await assembleDeckVideo(sb, deps, { fps: 24 });
  assert.equal(seenFps, 24, 'a valid fps passes through unchanged');
  for (const bad of [0, -5, Infinity, NaN, 'fast']) {
    await assembleDeckVideo(sb, deps, { fps: bad });
    assert.equal(seenFps, 30, `invalid fps ${String(bad)} -> default 30`);
  }
});

test('no capability injected -> honest no-video-capability (never a fake video)', async () => {
  const sb = buildStoryboard([{ template: 't', svg: '<svg/>' }]);
  const r = await assembleDeckVideo(sb, {});
  assert.equal(r.video, null);
  assert.equal(r.reason, 'no-video-capability');
  assert.equal(r.frames, 1);
  // only one of the two present -> still no-capability
  assert.equal((await assembleDeckVideo(sb, { rasterize: async () => Buffer.from('x') })).reason, 'no-video-capability');
});

test('empty storyboard -> empty-deck', async () => {
  const r = await assembleDeckVideo({ shots: [] }, { rasterize: async () => Buffer.from('x'), encodeVideo: async () => ({ video: Buffer.from('y') }) });
  assert.equal(r.reason, 'empty-deck');
});

test('raster failure -> raster-failed + failedIndex (isolated, no video)', async () => {
  const sb = buildStoryboard([{ template: 'a', svg: '<svg>0</svg>' }, { template: 'b', svg: '<svg>1</svg>' }]);
  const rasterize = async (svg) => { if (svg.includes('1')) throw new Error('resvg boom'); return Buffer.from('ok'); };
  const r = await assembleDeckVideo(sb, { rasterize, encodeVideo: async () => ({ video: Buffer.from('v') }) });
  assert.equal(r.video, null);
  assert.equal(r.reason, 'raster-failed');
  assert.equal(r.failedIndex, 1);
  assert.match(r.error, /resvg boom/);
});

test('raster returns empty -> raster-empty', async () => {
  const sb = buildStoryboard([{ template: 'a', svg: '<svg/>' }]);
  const r = await assembleDeckVideo(sb, { rasterize: async () => Buffer.alloc(0), encodeVideo: async () => ({ video: Buffer.from('v') }) });
  assert.equal(r.reason, 'raster-empty');
  assert.equal(r.failedIndex, 0);
});

test('encoder failure / empty -> encode-failed / encode-empty', async () => {
  const sb = buildStoryboard([{ template: 'a', svg: '<svg/>' }]);
  const raster = async () => Buffer.from('png');
  assert.equal((await assembleDeckVideo(sb, { rasterize: raster, encodeVideo: async () => { throw new Error('ffmpeg died'); } })).reason, 'encode-failed');
  assert.equal((await assembleDeckVideo(sb, { rasterize: raster, encodeVideo: async () => ({ video: Buffer.alloc(0) }) })).reason, 'encode-empty');
});
