// deck-video-backend.mjs — the INJECTED {rasterize, encodeVideo} native backend that lights up the gateway's
// /deck?format=video (services/pocket-gateway/src/deck/video.mjs `assembleDeckVideo`). forge lane (render/encode).
// The gateway core stays deployable-anywhere and honestly 501s without these; this is the deploy-owned native pair
// (same philosophy as ttsBackend / deviceRegistry). Offline + user-space:
//   - rasterize(svg, {width,height}) -> PNG Buffer, via resvg (native SVG->PNG).
//   - encodeVideo({frames:[{png,durationMs,audioBase64,audioFormat}], fps, totalMs}) -> {video: mp4 Buffer, format:'mp4'}
//     via ffmpeg: each PNG shows for its slide's durationMs with that slide's narration audio (padded with silence to
//     the slide time), then all per-slide clips concat into ONE mp4. No fabrication: any resvg/ffmpeg failure THROWS,
//     and video.mjs maps it to a typed reason (raster-failed / encode-failed / ...) — never a fake/silent video.
import { execFileSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

export function createDeckVideoBackend({ resvgBin, ffmpegBin, fps = 24 } = {}) {
  if (!resvgBin || !ffmpegBin) throw new Error('createDeckVideoBackend: resvgBin + ffmpegBin are required');

  function rasterize(svg, size = {}) {
    const width = Math.max(1, Math.round(Number(size.width) || 1280));
    const height = Math.max(1, Math.round(Number(size.height) || 720));
    const dir = mkdtempSync(join(tmpdir(), 'dvr-'));
    try {
      const svgPath = join(dir, 'in.svg');
      const pngPath = join(dir, 'out.png');
      writeFileSync(svgPath, typeof svg === 'string' ? svg : String(svg ?? ''));
      execFileSync(resvgBin, ['--width', String(width), '--height', String(height), svgPath, pngPath], { stdio: 'pipe' });
      const png = readFileSync(pngPath);
      if (!png.length) throw new Error('resvg produced an empty png');
      return png;
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }

  // ffmpeg input args for a raw/encoded audio buffer given its declared format (tts backend labels).
  function audioSpec(format) {
    const f = String(format || '').toLowerCase();
    if (f.startsWith('mp3')) return { ext: 'mp3', pre: [] };
    const pcm = f.match(/pcm_s16le_(\d+)/) || f.match(/pcm_(\d+)/);
    if (pcm) return { ext: 'pcm', pre: ['-f', 's16le', '-ar', pcm[1], '-ac', '1'] };
    if (f.startsWith('ulaw')) { const r = f.split('_')[1] || '8000'; return { ext: 'ulaw', pre: ['-f', 'mulaw', '-ar', r, '-ac', '1'] }; }
    return { ext: 'aud', pre: [] }; // ffmpeg autodetects (wav / aiff / m4a / ...)
  }

  function encodeVideo({ frames = [], fps: fpsIn } = {}) {
    if (!Array.isArray(frames) || frames.length === 0) throw new Error('encodeVideo: no frames');
    const rate = Math.max(1, Math.min(60, Math.round(Number(fpsIn) || fps)));
    const dir = mkdtempSync(join(tmpdir(), 'dve-'));
    try {
      const clips = [];
      frames.forEach((fr, i) => {
        if (!fr || !fr.png || !fr.png.length) throw new Error('encodeVideo: frame ' + i + ' has no png');
        const pngPath = join(dir, `f${i}.png`);
        writeFileSync(pngPath, fr.png);
        const durSec = Math.max(0.5, (Number(fr.durationMs) || 2000) / 1000);
        const clip = join(dir, `c${i}.mp4`);
        const args = ['-y', '-loop', '1', '-i', pngPath];
        let hasAudio = false;
        if (fr.audioBase64) {
          const spec = audioSpec(fr.audioFormat);
          const audioPath = join(dir, `a${i}.${spec.ext}`);
          writeFileSync(audioPath, Buffer.from(fr.audioBase64, 'base64'));
          args.push(...spec.pre, '-i', audioPath);
          hasAudio = true;
        } else {
          args.push('-f', 'lavfi', '-i', 'anullsrc=channel_layout=mono:sample_rate=44100');
        }
        args.push('-t', String(durSec), '-vf', 'scale=trunc(iw/2)*2:trunc(ih/2)*2', '-pix_fmt', 'yuv420p', '-r', String(rate), '-c:v', 'libx264');
        if (hasAudio) args.push('-af', 'apad'); // pad the narration with trailing silence to fill the slide duration
        args.push('-c:a', 'aac', '-b:a', '128k', clip);
        execFileSync(ffmpegBin, args, { stdio: 'pipe' });
        clips.push(clip);
      });
      const listPath = join(dir, 'list.txt');
      writeFileSync(listPath, clips.map((c) => `file '${c}'`).join('\n'));
      const outPath = join(dir, 'deck.mp4');
      execFileSync(ffmpegBin, ['-y', '-f', 'concat', '-safe', '0', '-i', listPath, '-c', 'copy', outPath], { stdio: 'pipe' });
      const video = readFileSync(outPath);
      if (!video.length) throw new Error('encodeVideo produced an empty mp4');
      return { video, format: 'mp4' };
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }

  return { rasterize, encodeVideo };
}
