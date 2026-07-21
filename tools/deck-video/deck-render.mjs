#!/usr/bin/env node
// deck-render.mjs — {title, script, tone-tag} slides → narration (macOS `say`, offline) → per-slide video
// (ffmpeg drawtext) → a single deck.mp4. forge lane: the VIDEO-ASSEMBLY half of Carter's "slides + voice + tags →
// video/audio" (warden owns the narration BACKEND; this turns narration + slides into an actual playable mp4).
// No TTS key, no resvg: `say` makes the audio, ffmpeg draws the slides + muxes. Audio-emotion tags ([warm]/[emphasis])
// are STRIPPED from the spoken text (say has none) but RENDERED on-slide as a "tone" label — and would drive
// ElevenLabs in the gateway path. Deterministic + offline → demoable today; verified by extracting a frame.
import { execFileSync } from 'node:child_process';
import { writeFileSync, mkdirSync, readFileSync, existsSync } from 'node:fs';

const FF = process.env.FFMPEG || `${process.env.HOME}/tools/ff/ffmpeg`;
const FONT = existsSync('/System/Library/Fonts/Supplemental/Arial.ttf')
  ? '/System/Library/Fonts/Supplemental/Arial.ttf' : '/System/Library/Fonts/Helvetica.ttc';
const FONT_BOLD = existsSync('/System/Library/Fonts/Supplemental/Arial Bold.ttf')
  ? '/System/Library/Fonts/Supplemental/Arial Bold.ttf' : FONT;
const W = 1280, H = 720;
const work = process.env.DECK_WORK || '/tmp/deckwork';
mkdirSync(work, { recursive: true });

const deck = process.env.DECK_JSON && existsSync(process.env.DECK_JSON)
  ? JSON.parse(readFileSync(process.env.DECK_JSON, 'utf8'))
  : {
      title: 'Senti Pocket',
      slides: [
        { title: 'Senti Pocket', script: 'Your agent team, in your pocket. A verified checkpoint calls your phone, briefs you out loud, and takes your spoken go.', tone: 'warm' },
        { title: 'Governed writeback', script: 'You confirm the exact action by voice. Only then does Pocket post as you, and only behind a verified gateway signature.', tone: 'confident' },
        { title: 'Grounded, on device', script: 'Every answer is grounded in the verified evidence. No fabrication. Gemma reasons on device, offline.', tone: 'calm' },
      ],
    };

const stripTags = (s) => String(s || '').replace(/\[[^\]]*\]/g, '').replace(/\s+/g, ' ').trim();
const wrap = (s, n = 40) => {
  const words = String(s || '').split(/\s+/); const lines = []; let cur = '';
  for (const w of words) {
    if ((cur ? cur + ' ' + w : w).length > n) { if (cur) lines.push(cur); cur = w; } else cur = cur ? cur + ' ' + w : w;
  }
  if (cur) lines.push(cur);
  return lines.join('\n');
};
const durationOf = (aiff) => {
  const out = execFileSync('/usr/bin/afinfo', [aiff], { encoding: 'utf8' });
  const m = out.match(/estimated duration:\s*([0-9.]+)\s*sec/i);
  return m ? Math.max(1.5, parseFloat(m[1]) + 0.5) : 4;
};
const dt = (font, file, size, color, x, y, extra = '') =>
  `drawtext=fontfile=${font}:textfile=${file}:fontsize=${size}:fontcolor=${color}:x=${x}:y=${y}${extra}`;

const parts = [];
deck.slides.forEach((s, i) => {
  const spoken = stripTags(s.script) || s.title || `Slide ${i + 1}`;
  const aiff = `${work}/s${i}.aiff`;
  execFileSync('/usr/bin/say', ['-o', aiff, spoken]);
  const dur = durationOf(aiff);
  writeFileSync(`${work}/s${i}-title.txt`, String(s.title || deck.title || ''));
  writeFileSync(`${work}/s${i}-body.txt`, wrap(stripTags(s.script)));
  writeFileSync(`${work}/s${i}-tone.txt`, s.tone ? `tone: ${s.tone}` : '');
  writeFileSync(`${work}/s${i}-foot.txt`, `Senti Pocket   ${i + 1} / ${deck.slides.length}`);
  const vf = [
    dt(FONT_BOLD, `${work}/s${i}-title.txt`, 58, 'white', 90, 110),
    dt(FONT, `${work}/s${i}-body.txt`, 40, '0xc9c9e6', 90, 250, ':line_spacing=16'),
    dt(FONT, `${work}/s${i}-tone.txt`, 28, '0x8a8ad0', 90, 'h-90'),
    dt(FONT, `${work}/s${i}-foot.txt`, 24, '0x5a5a86', 'w-tw-60', 'h-66'),
  ].join(',');
  const mp4 = `${work}/s${i}.mp4`;
  execFileSync(FF, [
    '-y', '-f', 'lavfi', '-i', `color=c=0x141428:s=${W}x${H}:d=${dur}`,
    '-i', aiff, '-vf', vf,
    '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-r', '24', '-c:a', 'aac', '-b:a', '128k', '-shortest', mp4,
  ], { stdio: 'pipe' });
  parts.push(mp4);
  process.stdout.write(`[deck] slide ${i + 1}/${deck.slides.length} rendered (${dur.toFixed(1)}s audio+video)\n`);
});

const listPath = `${work}/list.txt`;
writeFileSync(listPath, parts.map((p) => `file '${p}'`).join('\n'));
const outPath = process.env.OUT || `${process.env.HOME}/deck-demo.mp4`;
execFileSync(FF, ['-y', '-f', 'concat', '-safe', '0', '-i', listPath, '-c', 'copy', outPath], { stdio: 'pipe' });
process.stdout.write(`[deck] DONE -> ${outPath}\n`);
