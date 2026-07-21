// narration.mjs — turn a deck's per-slide tagged scripts into narration segments (transcript + optional synthesized
// audio). Zero-dep + injected ttsBackend, mirroring the gateway's design: this module owns NO key and reaches nothing on
// its own; the deploy injects deps.ttsBackend (createElevenLabsBackend), exactly as /tts and /brief do.
//
// AUTHOR ONCE, SERVE BOTH (same contract as audio-tags.mjs / handleBrief): each slide's `script` may carry ElevenLabs
// audio tags ([warm], [pause], [emphasis]...). splitTagged() -> { tagged, plain }: `tagged` feeds ElevenLabs (voices the
// tags), `plain` is the display transcript / what AVSpeech + OpenAI-TTS should read. We return BOTH so the caller picks.
//
// HONESTY: audio is synthesized ONLY when a ttsBackend is injected. Without it, segments carry the transcript and an
// explicit audioSkipped reason — never a silent empty/fake audio field.
import { splitTagged, hasAudioTags } from '../audio-tags.mjs';

const TONES = new Set(['calm', 'urgent', 'default']);

/** The narratable script for a slide: explicit slide.script wins, else content.script, else ''. */
function scriptOf(slide) {
  if (!slide || typeof slide !== 'object') return '';
  if (typeof slide.script === 'string') return slide.script;
  if (slide.content && typeof slide.content.script === 'string') return slide.content.script;
  return '';
}

/**
 * Build narration segments for a deck (one segment per slide, index-aligned).
 * @param {{ slides: Array<object> }} deck
 * @param {{ ttsBackend?: Function, voiceId?: string, tone?: string, synthesize?: boolean, modelId?: string, outputFormat?: string }} [opts]
 *   - synthesize (default: true IFF a ttsBackend is provided) — when true, calls ttsBackend(tagged, {...}) per narratable slide.
 * @returns {Promise<{ segments: Array<object>, count: number, narratedCount: number, audioEnabled: boolean }>}
 *   segment: { index, template, tagged, transcript, hasAudioTags, tone, audio?:base64, format?, audioSkipped? }
 */
export async function narrateDeck(deck = {}, opts = {}) {
  const slides = Array.isArray(deck.slides) ? deck.slides : [];
  const ttsBackend = typeof opts.ttsBackend === 'function' ? opts.ttsBackend : null;
  const synthesize = opts.synthesize === undefined ? !!ttsBackend : (!!opts.synthesize && !!ttsBackend);
  const defaultTone = TONES.has(opts.tone) ? opts.tone : 'default';
  // Hard aggregate bound on synthesized audio (base64 response bytes). Raw pcm is ~48 KB/s -> a full narrated deck can be
  // 100s of MB, past Lambda's 6 MB response limit. Once the cap is hit we STOP synthesizing + mark remaining slides
  // honestly ('deck-audio-cap') rather than 500-ing. Compressed formats (mp3) keep normal decks well under it.
  const maxTotalAudioBytes = Number.isFinite(opts.maxTotalAudioBytes) && opts.maxTotalAudioBytes > 0 ? opts.maxTotalAudioBytes : null;

  const segments = [];
  let narratedCount = 0;
  let totalAudioBytes = 0;
  let capReached = false;
  for (let index = 0; index < slides.length; index++) {
    const slide = slides[index];
    const raw = scriptOf(slide);
    const { tagged, plain } = splitTagged(raw);
    const tone = TONES.has(slide && slide.tone) ? slide.tone : defaultTone;
    const seg = {
      index,
      template: slide && slide.template,
      tagged,
      transcript: plain,
      hasAudioTags: hasAudioTags(raw),
      tone,
    };
    if (!plain) {
      // No script -> nothing to narrate. Honest: mark it, don't synthesize silence.
      seg.audioSkipped = 'no-script';
    } else if (!synthesize) {
      seg.audioSkipped = ttsBackend ? 'not-requested' : 'no-backend';
    } else if (maxTotalAudioBytes != null && totalAudioBytes >= maxTotalAudioBytes) {
      seg.audioSkipped = 'deck-audio-cap'; // aggregate bound hit -> stop synthesizing, stay honest (don't 500)
      capReached = true;
    } else {
      // ElevenLabs voices the tags -> feed `tagged`. (A plain-only backend would be fed `plain`; the deploy chooses the
      // backend.) Per-slide failure is isolated + honest — one slide's TTS error never fails the whole deck.
      try {
        const out = await ttsBackend(tagged, {
          voiceId: (slide && slide.voiceId) || opts.voiceId,
          tone,
          modelId: opts.modelId,
          outputFormat: opts.outputFormat,
        });
        if (out && out.audio && out.audio.length) {
          const b64 = Buffer.isBuffer(out.audio) ? out.audio.toString('base64') : Buffer.from(out.audio).toString('base64');
          seg.audio = b64;
          seg.format = out.format || null;
          totalAudioBytes += b64.length;
          narratedCount++;
          if (maxTotalAudioBytes != null && totalAudioBytes >= maxTotalAudioBytes) capReached = true;
        } else {
          seg.audioSkipped = 'empty-audio';
        }
      } catch (e) {
        seg.audioSkipped = 'tts-error';
        seg.audioError = e && e.message ? String(e.message).slice(0, 120) : 'tts failed';
      }
    }
    segments.push(seg);
  }
  return { segments, count: segments.length, narratedCount, audioEnabled: synthesize, audioBytes: totalAudioBytes, capReached };
}
