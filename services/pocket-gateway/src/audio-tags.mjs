// audio-tags.mjs — expressive audio-tag support so a briefing is AUTHORED ONCE with tags and the
// ElevenLabs switch is a one-line flip (Carter 2026-07-20). Tags are ElevenLabs-v3-style bracketed
// prosody/emotion cues, e.g. "[warm] Two agents shipped the fix. [pause] The one blocker is the Mac."
//
// On-device AVSpeech and OpenAI TTS can't voice the tags, so we STRIP them for those backends and
// serve the plain text; ElevenLabs consumes the tagged form directly. Author once, serve both — no
// re-generation needed when we flip TTS providers.

// Injected into the LLM briefing prompt so the model emits sparse, safe cues (prosody/emotion only).
export const AUDIO_TAG_HINT =
  'Add sparse ElevenLabs-style audio tags in square brackets to guide spoken delivery — e.g. [warm], ' +
  '[calm], [serious], [emphasis], [pause], [reassuring]. At most ONE tag per sentence, only where it ' +
  'aids natural delivery. Never invent sound effects; prosody/emotion cues only.';

// Matches a single bracketed tag: [word], [two words], [pause] — bounded, LOWERCASE-led, no nesting.
// Case-sensitive on purpose: audio tags are lowercase (we control the LLM output), so legitimate
// bracketed text like [ERROR], [TODO], or [0] is left intact rather than mistaken for a cue.
const STRIP_RE = /\s*\[[a-z][a-z0-9 _-]{0,24}\]\s*/g;
const DETECT_RE = /\[[a-z][a-z0-9 _-]{0,24}\]/;

/** Strip bracketed audio tags -> clean text for TTS backends that don't voice them (AVSpeech, OpenAI TTS). */
export function stripAudioTags(text) {
  if (typeof text !== 'string') return '';
  return text.replace(STRIP_RE, ' ').replace(/\s{2,}/g, ' ').trim();
}

/** True if the text carries at least one audio tag (so a caller knows an ElevenLabs read would differ). */
export function hasAudioTags(text) {
  return typeof text === 'string' && DETECT_RE.test(text);
}

/**
 * Author once, serve both. Returns { tagged, plain }:
 *  - tagged: the original with audio tags intact (feed to ElevenLabs).
 *  - plain : tags stripped (feed to AVSpeech / OpenAI TTS, or store as the display transcript).
 */
export function splitTagged(text) {
  const tagged = typeof text === 'string' ? text.trim() : '';
  return { tagged, plain: stripAudioTags(tagged) };
}
