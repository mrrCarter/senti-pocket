// video.mjs — assemble a rendered deck (SVG slides + per-slide narration audio) into a video, via INJECTED capabilities.
//
// Zero-dep by design: rasterization (SVG->PNG) and video muxing (frames+audio->mp4) need native binaries (resvg/sharp,
// ffmpeg) that the DEPLOY owns — so this module builds the DETERMINISTIC storyboard (pure, testable) and delegates the
// heavy lifting to injected `rasterize` + `encodeVideo` functions. Same philosophy as ttsBackend: the gateway core
// stays pure; the deploy wires the tools. Honest + fail-closed: no capability injected -> a typed reason, never a
// fabricated/empty video.

// Approx audio bytes/sec by format, so a slide's on-screen time can track its narration length. base64 -> raw is *3/4.
const BYTES_PER_SEC = { mp3_44100_128: 16000, mp3_44100_192: 24000, mp3_22050_32: 4000, mp3_44100_64: 8000 };
const DEFAULT_SLIDE_MS = 5000;   // a slide with no narration holds this long
const MIN_SLIDE_MS = 1500;       // floor so a very short line still reads
const TAIL_PAD_MS = 600;         // breath after the narration ends
const MAX_SLIDE_MS = 120000;     // guard a pathological single slide

/** Estimate a narration clip's duration (ms) from its base64 size + format. Deterministic; 0 for no audio. */
export function estimateAudioDurationMs(audioBase64, format) {
  if (typeof audioBase64 !== 'string' || audioBase64.length === 0) return 0;
  const rawBytes = Math.floor((audioBase64.length * 3) / 4);
  const bps = BYTES_PER_SEC[format] || BYTES_PER_SEC.mp3_44100_128;
  return Math.round((rawBytes / bps) * 1000);
}

/**
 * Deterministic storyboard: one shot per slide with its render, on-screen duration, and narration clip. Pure — no I/O.
 * @param {Array<{template,style,svg,width,height,narration?:{audio?,format?,transcript?}}>} slides  renderDeck().slides
 * @param {{ defaultSlideMs?, padMs? }} [opts]
 * @returns {{ shots: Array<object>, totalMs: number, count: number, hasAudio: boolean }}
 */
export function buildStoryboard(slides, opts = {}) {
  const list = Array.isArray(slides) ? slides : [];
  const defaultMs = Number.isFinite(opts.defaultSlideMs) && opts.defaultSlideMs > 0 ? opts.defaultSlideMs : DEFAULT_SLIDE_MS;
  const padMs = Number.isFinite(opts.padMs) && opts.padMs >= 0 ? opts.padMs : TAIL_PAD_MS;
  let totalMs = 0;
  let hasAudio = false;
  const shots = list.map((s, index) => {
    const n = s && s.narration;
    const audio = n && typeof n.audio === 'string' && n.audio.length ? n.audio : null;
    if (audio) hasAudio = true;
    const audioMs = estimateAudioDurationMs(audio, n && n.format);
    const durationMs = audio
      ? Math.min(MAX_SLIDE_MS, Math.max(MIN_SLIDE_MS, audioMs + padMs))
      : defaultMs;
    totalMs += durationMs;
    return {
      index,
      template: s && s.template,
      svg: s && s.svg,
      width: (s && s.width) || 1920,
      height: (s && s.height) || 1080,
      durationMs,
      audioBase64: audio,
      audioFormat: (n && n.format) || null,
      transcript: (n && n.transcript) || '',
    };
  });
  return { shots, totalMs, count: shots.length, hasAudio };
}

/**
 * Assemble the storyboard into a video via injected tools.
 * @param {{shots:Array<object>}} storyboard  buildStoryboard() output
 * @param {{ rasterize:(svg:string,size:{width,height})=>Promise<Buffer>, encodeVideo:(input:{frames,fps,totalMs})=>Promise<{video:Buffer,format?:string}> }} deps
 * @param {{ fps?:number }} [opts]
 * @returns {Promise<{video:string|null, format:string|null, durationMs:number, frames:number, reason?:string, failedIndex?:number, error?:string}>}
 *   On success: video is base64 mp4. On any gap: video=null + a typed reason (no-video-capability / raster-failed /
 *   raster-empty / encode-failed / encode-empty), never a silent/fake video.
 */
export async function assembleDeckVideo(storyboard = {}, deps = {}, opts = {}) {
  const shots = Array.isArray(storyboard.shots) ? storyboard.shots : [];
  const rasterize = typeof deps.rasterize === 'function' ? deps.rasterize : null;
  const encodeVideo = typeof deps.encodeVideo === 'function' ? deps.encodeVideo : null;
  const fps = Number.isFinite(opts.fps) && opts.fps > 0 ? opts.fps : 30;
  if (!rasterize || !encodeVideo) {
    return { video: null, format: null, durationMs: storyboard.totalMs || 0, frames: shots.length, reason: 'no-video-capability' };
  }
  if (shots.length === 0) return { video: null, format: null, durationMs: 0, frames: 0, reason: 'empty-deck' };

  const frames = [];
  for (const shot of shots) {
    let png;
    try { png = await rasterize(shot.svg, { width: shot.width, height: shot.height }); }
    catch (e) { return { video: null, format: null, durationMs: 0, frames: frames.length, reason: 'raster-failed', failedIndex: shot.index, error: errMsg(e) }; }
    if (!png || !png.length) return { video: null, format: null, durationMs: 0, frames: frames.length, reason: 'raster-empty', failedIndex: shot.index };
    frames.push({ png, durationMs: shot.durationMs, audioBase64: shot.audioBase64, audioFormat: shot.audioFormat });
  }

  let out;
  try { out = await encodeVideo({ frames, fps, totalMs: storyboard.totalMs }); }
  catch (e) { return { video: null, format: null, durationMs: 0, frames: frames.length, reason: 'encode-failed', error: errMsg(e) }; }
  if (!out || !out.video || !out.video.length) {
    return { video: null, format: null, durationMs: 0, frames: frames.length, reason: 'encode-empty' };
  }
  const video = Buffer.isBuffer(out.video) ? out.video.toString('base64') : Buffer.from(out.video).toString('base64');
  return { video, format: out.format || 'mp4', durationMs: storyboard.totalMs || 0, frames: frames.length };
}

function errMsg(e) { return e && e.message ? String(e.message).slice(0, 120) : 'error'; }
