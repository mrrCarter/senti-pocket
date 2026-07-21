// tts.mjs — ElevenLabs TTS backend for POST /tts (Echo P1: concrete backend). The provider API key lives ONLY
// here (server-side); the phone sends text + a voiceId and receives raw PCM — never the key. `fetch` is injectable
// (built-in on Node ≥18) so this is hermetically testable with no network.

/** Map a coarse tone hint to ElevenLabs voice_settings. */
function toneToSettings(tone) {
  switch (String(tone || '').toLowerCase()) {
    case 'urgent': return { stability: 0.3, similarity_boost: 0.75 };
    case 'calm': return { stability: 0.85, similarity_boost: 0.6 };
    default: return { stability: 0.5, similarity_boost: 0.7 };
  }
}

/**
 * @param {{ apiKey:string, fetch?:Function, baseUrl?:string, defaultVoiceId?:string }} cfg
 * @returns ttsBackend(text, {voiceId,modelId,outputFormat,tone}) -> { audio: Buffer, format }
 */
export function createElevenLabsBackend(cfg = {}) {
  const { apiKey, baseUrl = 'https://api.elevenlabs.io', defaultVoiceId } = cfg;
  const doFetch = cfg.fetch || globalThis.fetch;
  if (!apiKey) throw new Error('ElevenLabs apiKey required (server-side only)');
  if (typeof doFetch !== 'function') throw new Error('no fetch implementation available');

  // Descriptive labels for raw PCM (a PCM consumer needs encoding+rate to decode); mp3/other are self-describing.
  const PCM_LABELS = { pcm_16000: 'pcm_s16le_16000', pcm_22050: 'pcm_s16le_22050', pcm_24000: 'pcm_s16le_24000', pcm_44100: 'pcm_s16le_44100' };

  return async function ttsBackend(text, opts = {}) {
    const voiceId = opts.voiceId || defaultVoiceId;
    if (!voiceId) throw new Error('voiceId required');
    const outputFormat = opts.outputFormat || 'pcm_24000';
    // ElevenLabs takes output_format as a QUERY parameter (NOT a body field), and the Accept header must match it. The
    // prior code sent output_format in the BODY (ignored by the API) with a hardcoded accept:audio/pcm and a hardcoded
    // 'pcm_s16le_24000' return label — so a non-pcm request (e.g. /deck narration's mp3_44100_128, added for the
    // audio-size cap) was silently NOT honored and the bytes were mislabeled. Now the format is applied end-to-end
    // and labeled honestly, so the mp3 size savings actually take effect and the consumer can decode correctly.
    const accept = outputFormat.startsWith('mp3') ? 'audio/mpeg'
      : outputFormat.startsWith('ulaw') ? 'audio/basic'
      : 'audio/pcm';
    const url = `${baseUrl}/v1/text-to-speech/${encodeURIComponent(voiceId)}?output_format=${encodeURIComponent(outputFormat)}`;
    const res = await doFetch(url, {
      method: 'POST',
      headers: { 'xi-api-key': apiKey, 'content-type': 'application/json', accept },
      body: JSON.stringify({
        text,
        model_id: opts.modelId || 'eleven_flash_v2_5',
        voice_settings: toneToSettings(opts.tone),
      }),
    });
    if (!res || !res.ok) throw new Error('elevenlabs error ' + (res && res.status));
    const audio = Buffer.from(await res.arrayBuffer());
    if (audio.length === 0) throw new Error('elevenlabs returned empty audio');
    return { audio, format: PCM_LABELS[outputFormat] || outputFormat };
  };
}
